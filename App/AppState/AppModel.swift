import DMCNKit
import Foundation
import Observation

#if DEBUG
    import DMCNKitSamples
#endif

/// The app before and around a session: which accounts this device holds, unlocking one, and
/// what belongs to the device rather than the account. Everything about the mailbox itself is in
/// `MailSession`, one per sign-in, so nothing of one account can reach the next.
@MainActor
@Observable
final class AppModel {
    enum Phase {
        /// Nothing read from the vault yet, so there's no telling whether this device has accounts.
        case starting
        case signedOut
        case signedIn(MailSession)
    }

    private(set) var phase: Phase = .starting
    private(set) var accounts: [DeviceAccount] = []
    /// The mailbox request waiting on an admin, if there is one.
    private(set) var pendingPetition: DeviceAccount?
    /// The address the admin chose. Set once, and claiming it is the person's own action.
    private(set) var assignedAddress: String?
    private(set) var lockReason: LockReason?
    private(set) var authError: String?
    private(set) var isBusy = false

    var theme: ThemePreference {
        didSet { defaults.set(theme.rawValue, forKey: "theme") }
    }
    var lockOnLeave: Bool {
        didSet { defaults.set(lockOnLeave, forKey: "lockOnLeave") }
    }

    private let vault: any AccountVault
    private let transport: any HTTPTransport
    private let dataDirectory: URL
    private let defaults: UserDefaults
    /// The open account's keys, for the one thing that needs them whole: writing a backup.
    private var openKeys: KeyPayload?
    private var leftAt: Date?

    /// How long the app may sit in the background before it locks: the web's grace period.
    static let lockGrace: TimeInterval = 120

    init(
        vault: any AccountVault = InMemoryVault(),
        transport: any HTTPTransport = URLSessionTransport(),
        dataDirectory: URL = FileManager.default.temporaryDirectory.appending(path: "dmcn-preview"),
        defaults: UserDefaults = .standard
    ) {
        self.vault = vault
        self.transport = transport
        self.dataDirectory = dataDirectory
        self.defaults = defaults
        theme = ThemePreference(rawValue: defaults.string(forKey: "theme") ?? "") ?? .system
        lockOnLeave = defaults.object(forKey: "lockOnLeave") as? Bool ?? true
    }

    func loadAccounts() async {
        let held = await vault.accounts()
        accounts = held.filter { $0.petitionCode == nil }
        pendingPetition = held.first { $0.petitionCode != nil }
        if case .starting = phase { phase = .signedOut }
    }

    // MARK: Getting keys onto the device

    /// Opens a backup file. Nothing is kept until `finishImport`.
    func openBackup(_ data: Data, passphrase: String, host: String) async throws -> OpenedBackup {
        guard let url = Self.hostURL(host) else { throw AuthError.badHost }
        let contents = try await BackupFile.read(data: data, passphrase: passphrase)
        return OpenedBackup(address: contents.address, host: url, keys: contents.keys)
    }

    /// Proves the keys against the directory, then keeps them. In that order, so a backup for the
    /// wrong server leaves nothing behind.
    func finishImport(_ backup: OpenedBackup, protection: KeyProtection, passphrase: String?) async throws {
        let client = WebHostClient(baseURL: backup.host, transport: transport)
        try await client.importIdentity(backup.keys.accountKeys(address: backup.address))
        let account = DeviceAccount(address: backup.address, host: Self.hostName(backup.host), protection: protection)
        try await keep(backup.keys, for: account, passphrase: passphrase)
        await start(account: account, keys: backup.keys, client: client)
    }

    func register(localPart: String, host: String, protection: KeyProtection, passphrase: String?) async throws {
        guard let url = Self.hostURL(host) else { throw AuthError.badHost }
        let address = "\(localPart)@\(Self.hostName(url))"
        if let problem = validateChosenAddress(address) { throw AuthError.refused(problem) }
        let keys = KeyPayload.generate()
        let client = WebHostClient(baseURL: url, transport: transport)
        _ = try await client.register(keys, address: address)
        let account = DeviceAccount(address: address, host: Self.hostName(url), protection: protection)
        try await keep(keys, for: account, passphrase: passphrase)
        try await client.signIn(keys.accountKeys(address: address))
        await start(account: account, keys: keys, client: client)
    }

    private func keep(_ keys: KeyPayload, for account: DeviceAccount, passphrase: String?) async throws {
        let secret: Data
        switch account.protection {
        case .device:
            secret = keys.serialized()
        case .passphrase:
            guard let passphrase, !passphrase.isEmpty else { throw KeystoreError.passphraseRequired }
            secret = try JSONEncoder().encode(
                try await EncryptedBundle.encrypt(keys.serialized(), passphrase: passphrase))
        }
        try await vault.save(account, secret: secret)
        await loadAccounts()
    }

    // MARK: Asking for a mailbox

    /// How a mailbox is had on `host`, or nil when that can't be told yet. A wrong guess costs
    /// nothing: the form it leads to says what the server refused.
    func signupMode(host: String) async -> SignupMode? {
        guard let url = Self.hostURL(host) else { return nil }
        return try? await WebHostClient(baseURL: url, transport: transport).signupMode()
    }

    /// Files a request for a mailbox and parks the keys under its code. They're encrypted and stored
    /// before the wait starts, so closing the app can't lose what the address will be bound to.
    func requestMailbox(host: String, protection: KeyProtection, passphrase: String?) async throws {
        guard let url = Self.hostURL(host) else { throw AuthError.badHost }
        let keys = KeyPayload.generate()
        let ticket = try await WebHostClient(baseURL: url, transport: transport).createPetition(keys)
        let account = DeviceAccount.petition(
            code: ticket.code, host: Self.hostName(url), protection: protection, expires: ticket.expiresAt)
        try await keep(keys, for: account, passphrase: passphrase)
    }

    /// Asks where the request stands. Stops at an assigned address: claiming unlocks the keys, which
    /// may mean a Face ID prompt, and that should come from a tap, not a timer.
    func checkPetition() async {
        guard let pending = pendingPetition, let code = pending.petitionCode, assignedAddress == nil,
            let url = Self.hostURL(pending.host)
        else { return }
        do {
            let status = try await WebHostClient(baseURL: url, transport: transport).petitionStatus(code: code)
            if case .assigned(let address) = status { assignedAddress = address }
        } catch let error as APIError where error.status == 404 {
            // Expired, or finished elsewhere. Either way this code is spent.
            await cancelPetition()
            authError = error.message
        } catch {
            // A failed check is only a missed check: the next one may answer.
        }
    }

    /// Takes the address the admin assigned: claims it, moves the keys to it, and signs in. The keys
    /// move before signing in, so a failed sign-in leaves an account to unlock, not a lost one.
    func claimPetition(passphrase: String?) async throws {
        guard let pending = pendingPetition, let code = pending.petitionCode, let address = assignedAddress,
            let url = Self.hostURL(pending.host)
        else { return }
        let keys = try await keys(of: pending, passphrase: passphrase)
        let client = WebHostClient(baseURL: url, transport: transport)
        _ = try await client.completePetition(code: code, address: address, keys: keys)
        let account = DeviceAccount(address: address, host: pending.host, protection: pending.protection)
        try await vault.save(account, secret: try await vault.read(pending))
        await vault.remove(pending)
        assignedAddress = nil
        await loadAccounts()
        try await client.signIn(keys.accountKeys(address: address))
        await start(account: account, keys: keys, client: client)
    }

    /// Drops the request and its keys. Nothing was created, so there's nothing else to undo.
    func cancelPetition() async {
        guard let pending = pendingPetition else { return }
        await vault.remove(pending)
        assignedAddress = nil
        await loadAccounts()
    }

    // MARK: Unlocking

    func unlock(_ account: DeviceAccount, passphrase: String?) async {
        guard !isBusy, let url = Self.hostURL(account.host) else { return }
        isBusy = true
        authError = nil
        defer { isBusy = false }
        do {
            let keys = try await keys(of: account, passphrase: passphrase)
            let client = WebHostClient(baseURL: url, transport: transport)
            try await client.signIn(keys.accountKeys(address: account.address))
            await start(account: account, keys: keys, client: client)
        } catch is AccountRekeyedError {
            lockReason = .rekeyed
        } catch {
            authError = error.localizedDescription
        }
    }

    private func keys(of account: DeviceAccount, passphrase: String?) async throws -> KeyPayload {
        let secret = try await vault.read(account)
        switch account.protection {
        case .device:
            return try KeyPayload(serialized: secret)
        case .passphrase:
            let bundle = try JSONDecoder().decode(EncryptedBundle.self, from: secret)
            return try KeyPayload(serialized: try await bundle.decrypt(passphrase: passphrase ?? ""))
        }
    }

    /// Deletes this device's keys for an account. The picker asks first: it's not signing out.
    func forget(_ account: DeviceAccount) {
        Task {
            await vault.remove(account)
            try? FileManager.default.removeItem(at: Self.directory(for: account.address, in: dataDirectory))
            await loadAccounts()
        }
    }

    private func start(account: DeviceAccount, keys: KeyPayload, client: WebHostClient) async {
        do {
            let services = try await SessionServices.live(
                host: account.host, client: client, payload: keys, address: account.address,
                directory: Self.directory(for: account.address, in: dataDirectory))
            openKeys = keys
            await start(services)
        } catch {
            authError = error.localizedDescription
        }
    }

    func start(_ services: SessionServices) async {
        lockReason = nil
        authError = nil
        let session = MailSession(services: services)
        phase = .signedIn(session)
        await session.refresh()
    }

    #if DEBUG
        /// Signs in to an in-memory account holding one of every state a screen can show.
        func exploreSampleMail() async {
            do {
                await start(SessionServices.sample(try await SampleAccount()))
            } catch {
                authError = "Couldn't set up the sample mail: \(error.localizedDescription)"
            }
        }
    #endif

    // MARK: Leaving

    /// Drops everything decrypted first; telling the host can wait on the network.
    func signOut() async {
        guard case .signedIn(let session) = phase else { return }
        await session.putAwayDraft()
        phase = .signedOut
        openKeys = nil
        await loadAccounts()
        await session.close()
    }

    /// The other account's unlock is on the picker, and that's where this leaves the person.
    func lockForSwitch(to account: DeviceAccount) async {
        await signOut()
    }

    /// The app left the foreground. A quick glance elsewhere doesn't lock it; a longer stay does.
    func didLeave(at date: Date = Date()) {
        leftAt = date
    }

    func didReturn(at date: Date = Date()) async {
        defer { leftAt = nil }
        guard lockOnLeave, let leftAt, date.timeIntervalSince(leftAt) >= Self.lockGrace else { return }
        guard case .signedIn = phase else { return }
        await signOut()
        lockReason = .locked
    }

    /// The open account as a backup file.
    func backup(passphrase: String) async throws -> (data: Data, filename: String) {
        guard case .signedIn(let session) = phase, let openKeys else { throw AuthError.noKeys }
        let data = try await BackupFile.make(address: session.address, keys: openKeys, passphrase: passphrase)
        return (data, "dmcn-keystore-\(Self.fileSafe(session.address)).json")
    }

    // MARK: Addresses

    private static func directory(for address: String, in base: URL) -> URL {
        base.appending(path: fileSafe(address), directoryHint: .isDirectory)
    }

    private static func fileSafe(_ address: String) -> String {
        String(address.map { $0.isASCII && ($0.isLetter || $0.isNumber || "._@-".contains($0)) ? $0 : "_" })
    }

    private static func hostName(_ url: URL) -> String {
        url.host(percentEncoded: false) ?? url.absoluteString
    }

    /// `mail.example.org`, or a pasted `https://mail.example.org/`, as the host's base URL.
    /// Debug builds also take `http://` to this machine, for a dmcnd running locally in dev mode.
    static func hostURL(_ input: String) -> URL? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.contains("://") { text = "https://" + text }
        // Both lowercased: neither cares about case, and `HTTP://LOCALHOST` is still this machine.
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(),
            var host = url.host(percentEncoded: true)?.lowercased(), !host.isEmpty,
            scheme == "https" || (scheme == "http" && allowsPlainHTTP(to: host))
        else { return nil }
        // An IPv6 literal comes back from host() without its brackets, and the URL needs them.
        if host.contains(":"), !host.hasPrefix("[") { host = "[\(host)]" }
        return URL(string: "\(scheme)://\(host)\(url.port.map { ":\($0)" } ?? "")/")
    }

    /// Plain HTTP never leaves this machine, and never ships: a release build always says no.
    private static func allowsPlainHTTP(to host: String) -> Bool {
        #if DEBUG
            ["localhost", "127.0.0.1", "::1"].contains(host)
        #else
            false
        #endif
    }
}

enum AuthError: LocalizedError {
    case badHost, noKeys, refused(String)

    var errorDescription: String? {
        switch self {
        case .badHost: "That server address doesn't look right."
        case .noKeys: "There are no keys to back up in this session."
        case .refused(let reason): reason
        }
    }
}
