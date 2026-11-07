import DMCNKit
import Foundation

/// How an account's keys are protected on this device. `device` is the web's passkey: unlocking
/// is a biometric or passcode prompt. `passphrase` is the same Argon2id keystore the web uses.
enum KeyProtection: String, Codable, Sendable {
    case device, passphrase
}

/// An account this device holds keys for. There's no account list on any server: the keys are
/// the account, and this is the only record they're here.
struct DeviceAccount: Identifiable, Codable, Hashable, Sendable {
    let address: String
    /// The web host this account talks to. A browser takes this from the page it was served by;
    /// an app has to remember it, and that's why one app can serve any deployment.
    let host: String
    let protection: KeyProtection
    /// When a waiting mailbox request lapses. nil on an account.
    var petitionExpires: Date?

    var id: String { address }

    /// A request for a mailbox rather than an account: keys parked under the code an admin was given,
    /// until there's an address to move them to. The wait is a human one, so they're kept like any
    /// others, and never listed as an account.
    var petitionCode: String? {
        address.hasPrefix(Self.petitionPrefix) ? String(address.dropFirst(Self.petitionPrefix.count)) : nil
    }

    static func petition(code: String, host: String, protection: KeyProtection, expires: Date?) -> DeviceAccount {
        DeviceAccount(
            address: petitionPrefix + code, host: host, protection: protection, petitionExpires: expires)
    }

    // No real address has this shape, so it can't collide with one.
    private static let petitionPrefix = "petition:"
}

/// Where accounts' secrets live. The Keychain in the app, memory in tests and previews. A secret
/// is what `AppModel` hands it: raw key bytes for `.device`, an encrypted bundle for `.passphrase`.
protocol AccountVault: Sendable {
    func accounts() async -> [DeviceAccount]
    func save(_ account: DeviceAccount, secret: Data) async throws
    /// Asks the system for a biometric or passcode prompt when the account is `.device`.
    func read(_ account: DeviceAccount) async throws -> Data
    func remove(_ account: DeviceAccount) async
}

actor InMemoryVault: AccountVault {
    private var held: [DeviceAccount: Data] = [:]

    func accounts() -> [DeviceAccount] {
        held.keys.sorted { $0.address < $1.address }
    }

    func save(_ account: DeviceAccount, secret: Data) {
        held[account] = secret
    }

    func read(_ account: DeviceAccount) throws -> Data {
        guard let secret = held[account] else { throw VaultError.missing }
        return secret
    }

    func remove(_ account: DeviceAccount) {
        held[account] = nil
    }
}

enum VaultError: LocalizedError {
    case missing

    var errorDescription: String? { "The keys for this account aren't on this device any more." }
}

/// Why the account picker is showing, said above the list.
enum LockReason: Equatable {
    case locked, expired, rekeyed

    var message: String {
        switch self {
        case .locked: "Locked while you were away. Unlock to continue."
        case .expired: "Your session expired. Unlock again to continue."
        case .rekeyed:
            "This account got a new key on another device, so this one can no longer sign in to it. Import a newer backup to catch up. Nothing here was deleted: the key stored on this device still opens the mail that arrived before the change."
        }
    }
}

/// A backup that opened, waiting for the person to choose how it's protected here.
struct OpenedBackup: Sendable {
    let address: String
    let host: URL
    let keys: KeyPayload
}

enum ThemePreference: String, Hashable, Sendable {
    case light, dark, system
}

/// The small bucketed meter under a new passphrase.
enum PassphraseStrength: Equatable {
    case weak, fair, strong

    init(_ passphrase: String) {
        var score = 0
        if passphrase.count >= 8 { score += 1 }
        if passphrase.count >= 14 { score += 1 }
        let isASCIILetter = { (c: Character) in c.isASCII && c.isLetter }
        if passphrase.contains(where: \.isNumber), passphrase.contains(where: isASCIILetter) { score += 1 }
        if passphrase.contains(where: { !($0.isASCII && ($0.isLetter || $0.isNumber)) }) { score += 1 }
        self = score <= 1 ? .weak : score == 2 ? .fair : .strong
    }

    var fraction: Double {
        switch self {
        case .weak: 0.33
        case .fair: 0.66
        case .strong: 1
        }
    }

    var label: String {
        switch self {
        case .weak: "Weak"
        case .fair: "Fair"
        case .strong: "Strong"
        }
    }
}
