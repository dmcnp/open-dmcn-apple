import DMCNKit
import DMCNKitSamples
import Foundation
import Testing

@testable import AppState

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// Serves the sample mailbox, but holds the first listing until told to release it, so a test can
/// sign out, or start the next account, with that listing still in flight.
private actor HeldMailbox: MailboxService {
    private let sample: SampleMailbox
    private let fails: Bool
    private var gate: CheckedContinuation<Void, Never>?
    var isHolding: Bool { gate != nil }

    init(_ sample: SampleMailbox, fails: Bool = false) {
        self.sample = sample
        self.fails = fails
    }

    func release() {
        gate?.resume()
        gate = nil
    }

    func list(_ keys: some AccountKeys, limit: Int, cursor: String?) async throws -> MailboxPage {
        await withCheckedContinuation { gate = $0 }
        if fails { throw APIError(status: 502, message: "the relay is down") }
        return try await sample.list(keys, limit: limit, cursor: cursor)
    }

    func body(hash: String, keys: some AccountKeys) async throws -> Dmcn_Relay_MailboxBody {
        try await sample.body(hash: hash, keys: keys)
    }

    func lookup(_ address: String) async throws -> IdentityLookup {
        try await sample.lookup(address)
    }

    func signOut() async {}
}

@MainActor
private func services(_ account: SampleAccount, mailbox: any MailboxService) -> SessionServices {
    let live = SessionServices.sample(account)
    return SessionServices(
        host: "held", keys: live.keys, deviceID: live.deviceID, inbox: Inbox(service: mailbox, keys: account.keys),
        flags: live.flags, labels: live.labels, contacts: live.contacts, filter: live.filter, sent: live.sent,
        drafts: live.drafts, settings: live.settings, storage: live.storage, bridge: live.bridge,
        directory: live.directory, identityRecord: live.identityRecord, deleteMessage: live.deleteMessage,
        composer: nil, isLocalOnly: live.isLocalOnly, search: nil)
}

/// Starts a session whose first listing is held, and returns once it is.
@MainActor
private func startHeld(_ model: AppModel, fails: Bool = false) async throws -> (
    session: MailSession, mailbox: HeldMailbox, load: Task<Void, Never>
) {
    let account = try await SampleAccount()
    let mailbox = HeldMailbox(account.mailbox, fails: fails)
    let load = Task { await model.start(services(account, mailbox: mailbox)) }
    while await !mailbox.isHolding { await Task.yield() }
    guard case .signedIn(let session) = model.phase else { throw APIError(status: 0, message: "no session") }
    return (session, mailbox, load)
}

@MainActor
private func signedIn(_ model: AppModel) throws -> MailSession {
    guard case .signedIn(let session) = model.phase else { throw APIError(status: 0, message: "no session") }
    return session
}

@MainActor
@Suite struct OneSessionNeverReachesAnother {
    @Test func theSampleAccountLoads() async throws {
        let model = AppModel()
        await model.exploreSampleMail()
        let session = try signedIn(model)
        #expect(!session.messages.isEmpty)
        #expect(!session.loadFailed)
        #expect(!session.rows.isEmpty)
    }

    @Test(arguments: [false, true])
    func whatArrivesAfterSignOutIsDropped(fails: Bool) async throws {
        let model = AppModel()
        let (session, mailbox, load) = try await startHeld(model, fails: fails)
        await model.signOut()
        await mailbox.release()
        await load.value
        #expect(session.closed)
        #expect(session.messages.isEmpty)
        #expect(session.errorMessage == nil)
        #expect(!session.loadFailed)
        #expect(!session.isLoading)
    }

    @Test func theNextAccountLoadsWhileTheLastOnesListingIsInFlight() async throws {
        let model = AppModel()
        let (first, mailbox, load) = try await startHeld(model)
        await model.signOut()
        await model.exploreSampleMail()
        let next = try signedIn(model)
        let count = next.messages.count
        #expect(count > 0)
        await mailbox.release()
        await load.value
        #expect(next.messages.count == count)
        #expect(first.messages.isEmpty)
        #expect(!next.isLoading)
    }

    @Test func aFailedLoadSaysSo() async throws {
        let model = AppModel()
        let (session, mailbox, load) = try await startHeld(model, fails: true)
        await mailbox.release()
        await load.value
        #expect(session.loadFailed)
        #expect(session.listError != nil)
    }
}

@MainActor
@Suite struct UnlockingAnAccount {
    private func model(_ vault: InMemoryVault) -> AppModel {
        AppModel(vault: vault, defaults: UserDefaults(suiteName: UUID().uuidString)!)
    }

    @Test func nothingIsDecidedUntilTheAccountsAreRead() async {
        let vault = InMemoryVault()
        let account = DeviceAccount(address: "ada@sample.example", host: "sample.example", protection: .passphrase)
        await vault.save(account, secret: Data())
        let model = model(vault)
        guard case .starting = model.phase else {
            Issue.record("must not offer set-up before knowing what's on the device")
            return
        }
        await model.loadAccounts()
        guard case .signedOut = model.phase else {
            Issue.record("reading the accounts ends the wait")
            return
        }
        #expect(model.accounts == [account])
    }

    @Test func aWrongPassphraseStaysLockedAndSaysSo() async throws {
        let vault = InMemoryVault()
        let keys = KeyPayload.generate()
        let bundle = try await EncryptedBundle.encrypt(keys.serialized(), passphrase: "right horse")
        let account = DeviceAccount(address: "ada@sample.example", host: "sample.example", protection: .passphrase)
        await vault.save(account, secret: try JSONEncoder().encode(bundle))
        let model = model(vault)
        await model.loadAccounts()
        #expect(model.accounts == [account])
        await model.unlock(account, passphrase: "wrong horse")
        guard case .signedOut = model.phase else {
            Issue.record("a wrong passphrase must not sign in")
            return
        }
        #expect(model.authError != nil)
        #expect(!model.isBusy)
    }

    @Test func aRemovedAccountLeavesTheList() async throws {
        let vault = InMemoryVault()
        let account = DeviceAccount(address: "ada@sample.example", host: "sample.example", protection: .device)
        await vault.save(account, secret: Data([1]))
        let model = model(vault)
        await model.loadAccounts()
        await vault.remove(account)
        await model.loadAccounts()
        #expect(model.accounts.isEmpty)
    }

    @Test func aBackupForAnotherServerNeedsAUsableHost() async {
        await #expect(throws: AuthError.self) {
            _ = try await model(InMemoryVault()).openBackup(Data(), passphrase: "x", host: "http://plain.example")
        }
    }
}

@MainActor
@Suite struct LeavingTheApp {
    private func signedInModel() async -> AppModel {
        let model = AppModel(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        await model.exploreSampleMail()
        return model
    }

    @Test func aQuickGlanceElsewhereDoesntLock() async throws {
        let model = await signedInModel()
        let left = Date()
        model.didLeave(at: left)
        await model.didReturn(at: left.addingTimeInterval(AppModel.lockGrace - 1))
        _ = try signedIn(model)
    }

    @Test func rereadingTheAccountsLeavesASessionOpen() async throws {
        let model = await signedInModel()
        await model.loadAccounts()
        _ = try signedIn(model)
    }

    @Test func stayingAwayLocks() async {
        let model = await signedInModel()
        let left = Date()
        model.didLeave(at: left)
        await model.didReturn(at: left.addingTimeInterval(AppModel.lockGrace))
        guard case .signedOut = model.phase else {
            Issue.record("should have locked")
            return
        }
        #expect(model.lockReason == .locked)
    }

    @Test func turningLockOffKeepsTheSession() async throws {
        let model = await signedInModel()
        model.lockOnLeave = false
        let left = Date()
        model.didLeave(at: left)
        await model.didReturn(at: left.addingTimeInterval(AppModel.lockGrace * 10))
        _ = try signedIn(model)
    }
}

@MainActor
@Suite struct UsingTheMailbox {
    private func session() async throws -> MailSession {
        let model = AppModel(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        await model.exploreSampleMail()
        return try signedIn(model)
    }

    private func settle(_ until: () -> Bool) async {
        for _ in 0..<2000 where !until() {
            try? await Task.sleep(for: .milliseconds(1))
        }
    }

    @Test func archivingMovesARowOutOfTheInbox() async throws {
        let session = try await session()
        let row = try #require(session.rows.first { !$0.isSent })
        session.toggleArchive(row)
        await settle { !session.rows.contains { $0.id == row.id } }
        #expect(!session.rows.contains { $0.id == row.id })
        session.select(.archive)
        #expect(session.rows.contains { $0.id == row.id })
    }

    @Test func deleteMovesToDeletedAndRestoreBringsItBack() async throws {
        let session = try await session()
        let row = try #require(session.rows.first { !$0.isSent })
        session.trash(row)
        await settle { !session.rows.contains { $0.id == row.id } }
        session.select(.deleted)
        let deleted = try #require(session.rows.first { $0.id == row.id })
        #expect(deleted.inDeleted)
        session.restore(deleted)
        await settle { session.flag(row.id)?.trashedAt == nil }
        session.select(.inbox)
        #expect(session.rows.contains { $0.id == row.id })
    }

    @Test func aWriteTheRelayRefusesIsSaidOutLoud() async throws {
        let session = try await session()
        session.select(.sent)
        let row = try #require(session.rows.first)
        session.toggleStar(row.id)
        await settle { session.errorMessage != nil }
        #expect(session.errorMessage != nil)
    }

    @Test func typingASearchMovesToSearchAndClearingComesBack() async throws {
        let session = try await session()
        session.select(.archive)
        session.query = "subject:verified"
        #expect(session.folder == .search)
        session.query = ""
        #expect(session.folder == .archive)
    }

    @Test func openingAMessageMarksItRead() async throws {
        let session = try await session()
        let row = try #require(session.rows.first { $0.isUnread })
        session.open(row)
        #expect(session.openMessage?.id == row.id)
        await settle { session.flag(row.id)?.read == true }
        #expect(session.flag(row.id)?.read == true)
    }

    @Test func aForgedSenderIsWithheldAndOffersNoPeek() async throws {
        let session = try await session()
        let row = try #require(session.rows.first { $0.subject == "A forged sender" })
        session.open(row)
        let reader = try #require(session.openMessage)
        await reader.load()
        #expect(reader.decision.withheld)
        #expect(!reader.decision.plainTextOffered)
        #expect(reader.decision.counterpartyAddress == nil)
        #expect(reader.body == .loading)
    }

    @Test(arguments: ["A forged sender", "A sender the domain no longer vouches for"])
    func aWithheldMessageCantBeForwarded(subject: String) async throws {
        let session = try await session()
        let row = try #require(session.rows.first { $0.subject == subject })
        session.open(row)
        let reader = try #require(session.openMessage)
        await reader.load()
        #expect(reader.decision.withheld || reader.decision.disowned)
        #expect(!reader.canForward)
        reader.forward()
        #expect(session.composing == nil)
        #expect(session.openMessage != nil)
    }

    @Test func aDisownedMessageCanBeReadButIsntQuotedUnderItsAddress() async throws {
        let session = try await session()
        let row = try #require(session.rows.first { $0.subject == "A sender the domain no longer vouches for" })
        session.open(row)
        let reader = try #require(session.openMessage)
        await reader.load()
        #expect(reader.decision.gated && reader.decision.plainTextOffered)
        #expect(reader.decision.counterpartyName == "Sender not vouched for")
        guard case .text(let text) = reader.body else {
            Issue.record("expected the text, got \(reader.body)")
            return
        }
        #expect(!text.isEmpty)
        reader.reply(all: false)
        #expect(session.composing?.body.contains("wrote:") == false)
    }

    @Test func aReadableMessageForwardsWithItsSender() async throws {
        let session = try await session()
        let row = try #require(session.rows.first { $0.subject == "A verified sender" })
        session.open(row)
        let reader = try #require(session.openMessage)
        await reader.load()
        #expect(reader.canForward)
        reader.forward()
        #expect(session.composing?.body.contains(reader.message.senderAddress) == true)
    }

    @Test func theFingerprintComesFromTheKeysNotTheDirectory() async throws {
        let session = try await session()
        #expect(session.fingerprintGrouped.count == 49)
        #expect(session.fingerprintGrouped.split(separator: "·").count == 10)
    }

    @Test func theNewsletterCarriesHTML() async throws {
        let session = try await session()
        let row = try #require(session.rows.first { $0.subject == "A newsletter" })
        session.open(row)
        let reader = try #require(session.openMessage)
        await reader.load()
        #expect(reader.html?.contains("Scripts are off.") == true)
    }

    @Test func aVerifiedMessageOpensItsBody() async throws {
        let session = try await session()
        let row = try #require(session.rows.first { $0.subject == "A verified sender" })
        session.open(row)
        let reader = try #require(session.openMessage)
        await reader.load()
        guard case .text(let text) = reader.body else {
            Issue.record("expected the body, got \(reader.body)")
            return
        }
        #expect(!text.isEmpty)
    }

    @Test func aReplyOpensTheComposerAddressedToTheSender() async throws {
        let session = try await session()
        let row = try #require(session.rows.first { $0.subject == "A verified sender" })
        session.open(row)
        let reader = try #require(session.openMessage)
        await reader.load()
        reader.reply(all: false)
        #expect(session.openMessage == nil)
        #expect(session.composing?.to.recipients == [reader.message.senderAddress])
        #expect(session.composing?.body.contains("wrote:") == true)
    }

    @Test func sampleMailCantSend() async throws {
        let session = try await session()
        session.compose()
        let compose = try #require(session.composing)
        compose.to.pick("someone@sample.example")
        await compose.send()
        #expect(compose.error != nil)
        #expect(compose.sentReport == nil)
    }
}

@Suite struct HostAddresses {
    @Test(arguments: [
        ("mail.example.org", "https://mail.example.org/"),
        ("https://mail.example.org/", "https://mail.example.org/"),
        ("  mail.example.org:8443/inbox ", "https://mail.example.org:8443/"),
        ("https://[::1]:8443/", "https://[::1]:8443/"),
    ])
    @MainActor func keepsOnlyTheHostAndPort(input: String, expected: String) {
        #expect(AppModel.hostURL(input)?.absoluteString == expected)
    }

    @Test(arguments: [
        "http://mail.example.org", "https://", "not a host",
        "http://192.168.1.5:18099", "http://localhost.evil.example",
    ])
    @MainActor func refusesAnythingElse(input: String) {
        #expect(AppModel.hostURL(input) == nil)
    }

    #if DEBUG
        @Test(arguments: [
            ("http://localhost:18099", "http://localhost:18099/"),
            ("HTTP://LOCALHOST:18099/inbox", "http://localhost:18099/"),
            ("http://127.0.0.1:18099", "http://127.0.0.1:18099/"),
            ("http://[::1]:18099", "http://[::1]:18099/"),
        ])
        @MainActor func debugTakesPlainHTTPToThisMachine(input: String, expected: String) {
            #expect(AppModel.hostURL(input)?.absoluteString == expected)
        }
    #endif
}

@Suite struct PassphraseStrengthMeter {
    @Test(arguments: [
        ("", PassphraseStrength.weak), ("short", .weak), ("longenough", .weak), ("longenough1", .fair),
        ("a much longer passphrase 1", .strong),
    ])
    func buckets(passphrase: String, expected: PassphraseStrength) {
        #expect(PassphraseStrength(passphrase) == expected)
    }
}

/// Just enough of a petition-mode `dmcnd`: signing in fails, so what's left afterwards is on show.
private actor PetitionHost: HTTPTransport {
    var assigned: String?
    var expired = false
    private(set) var completed = 0

    func assign(_ address: String) { assigned = address }
    func expire() { expired = true }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let path = request.url?.path ?? ""
        switch (request.httpMethod ?? "GET", path) {
        case ("POST", "/api/v1/petition"):
            return reply(200, ["code": "0428-9173-5560", "expires_at": "2030-01-02T03:04:05Z"])
        case ("GET", "/api/v1/petition/status"):
            if expired { return reply(404, ["error": "gone", "code": "unknown_code"]) }
            guard let assigned else { return reply(200, ["status": "pending"]) }
            return reply(200, ["status": "assigned", "address": assigned])
        case ("POST", "/api/v1/petition/complete"):
            completed += 1
            return reply(200, ["status": "active", "address": assigned ?? ""])
        case ("GET", "/api/v1/relay-hints"):
            return reply(200, ["relay_hints": [String]()])
        default:
            return reply(500, ["error": "not here"])
        }
    }

    private func reply(_ status: Int, _ object: Any) -> (Data, HTTPURLResponse) {
        (
            try! JSONSerialization.data(withJSONObject: object),
            HTTPURLResponse(
                url: URL(string: "https://mail.test/")!, statusCode: status, httpVersion: nil, headerFields: nil)!
        )
    }
}

@MainActor
@Suite struct AskingForAMailbox {
    private let vault = InMemoryVault()
    private let host = PetitionHost()

    private func model() -> AppModel {
        AppModel(
            vault: vault, transport: host,
            dataDirectory: FileManager.default.temporaryDirectory.appending(path: UUID().uuidString),
            defaults: UserDefaults(suiteName: UUID().uuidString)!)
    }

    private func requested() async throws -> AppModel {
        let app = model()
        try await app.requestMailbox(host: "mail.test", protection: .passphrase, passphrase: "correct horse")
        return app
    }

    @Test func theKeysWaitUnderTheCodeAndArentAnAccount() async throws {
        let app = try await requested()
        #expect(app.accounts.isEmpty)
        #expect(app.pendingPetition?.petitionCode == "0428-9173-5560")
        #expect(app.pendingPetition?.petitionExpires != nil)
    }

    @Test func closingTheAppDoesntLoseTheRequest() async throws {
        _ = try await requested()
        let reopened = model()
        await reopened.loadAccounts()
        #expect(reopened.pendingPetition?.petitionCode == "0428-9173-5560")
    }

    @Test func aPendingRequestStaysPending() async throws {
        let app = try await requested()
        await app.checkPetition()
        #expect(app.assignedAddress == nil)
        #expect(app.pendingPetition != nil)
    }

    @Test func anAssignedAddressWaitsForThePersonToTakeIt() async throws {
        let app = try await requested()
        await host.assign("alice@mail.test")
        await app.checkPetition()
        #expect(app.assignedAddress == "alice@mail.test")
        #expect(await host.completed == 0)
        #expect(app.accounts.isEmpty)
    }

    @Test func claimingMovesTheKeysEvenIfSigningInThenFails() async throws {
        let app = try await requested()
        await host.assign("alice@mail.test")
        await app.checkPetition()
        await #expect(throws: (any Error).self) { try await app.claimPetition(passphrase: "correct horse") }
        #expect(await host.completed == 1)
        #expect(app.pendingPetition == nil)
        #expect(app.assignedAddress == nil)
        #expect(app.accounts.map(\.address) == ["alice@mail.test"])
        #expect(app.accounts.first?.protection == .passphrase)
    }

    @Test func aWrongPassphraseClaimsNothing() async throws {
        let app = try await requested()
        await host.assign("alice@mail.test")
        await app.checkPetition()
        await #expect(throws: (any Error).self) { try await app.claimPetition(passphrase: "wrong") }
        #expect(await host.completed == 0)
        #expect(app.pendingPetition != nil)
        #expect(app.assignedAddress == "alice@mail.test")
    }

    @Test func anExpiredRequestIsClearedAndSaysSo() async throws {
        let app = try await requested()
        await host.expire()
        await app.checkPetition()
        #expect(app.pendingPetition == nil)
        #expect(app.authError == "That request expired. You can ask for a new one.")
    }

    @Test func startingOverDropsTheKeys() async throws {
        let app = try await requested()
        await app.cancelPetition()
        #expect(app.pendingPetition == nil)
        #expect(await vault.accounts().isEmpty)
    }
}
