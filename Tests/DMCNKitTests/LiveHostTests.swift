import DMCNKit
import Foundation
import Testing

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// The whole path against a real `dmcnd`, using the calls the app makes. Everything else in this
/// suite uses fixtures and fake hosts, so this is the one place a wrong reading of the server
/// shows up. Skipped unless a host is named:
///
///     DMCND_DEV=true DMCND_DOMAIN=localhost DMCND_LISTEN=127.0.0.1:18099 dmcnd
///     DMCN_LIVE_HOST=http://127.0.0.1:18099 swift test --filter LiveHost
private let liveHost = ProcessInfo.processInfo.environment["DMCN_LIVE_HOST"].flatMap(URL.init(string:))

private struct LiveAccount {
    let address: String
    let keys: SoftwareAccountKeys
    let payload: KeyPayload
    let client: WebHostClient
    let storage: PersonalStore
    let inbox: Inbox
    let contacts: ContactStore
    let sent: SentStore

    init(_ name: String, host: URL) async throws {
        address = "\(name)-\(UInt32.random(in: 0...UInt32.max))@localhost"
        payload = KeyPayload.generate()
        keys = payload.accountKeys(address: address)
        client = WebHostClient(baseURL: host)
        _ = try await client.register(payload, address: address)
        try await client.signIn(keys)
        let local = FileManager.default.temporaryDirectory.appending(path: "dmcn-live-\(UUID().uuidString)")
        storage = PersonalStore(client: client, keys: keys, localDirectory: local.appending(path: "local"))
        inbox = Inbox(service: client, keys: keys)
        contacts = ContactStore(
            storage: storage, pins: LocalPersonalStorage(directory: local.appending(path: "device")), owner: address,
            deviceID: payload.deviceId)
        sent = SentStore(storage: storage, keys: keys)
    }

    var composer: Composer {
        Composer(host: client, account: keys, deviceID: payload.deviceId, contacts: contacts, sent: sent)
    }
}

/// One pair for every test: the host rate-limits registration, as it should.
private let pair = Task {
    let host = try #require(liveHost)
    return (try await LiveAccount("ada", host: host), try await LiveAccount("bob", host: host))
}

@Suite(.enabled(if: liveHost != nil), .serialized) struct LiveHost {

    @Test func mailGoesFromOneAccountToAnother() async throws {
        let (ada, bob) = try await pair.value

        let draft = DraftContent(from: ada.address, to: [bob.address], subject: "Hello from Swift", text: "It works.")
        let report = try await ada.composer.send(draft)
        #expect(report.keptInSent)

        let received = try await bob.inbox.allPreviews()
        let message = try #require(received.first { $0.subject == "Hello from Swift" })
        #expect(message.senderAddress == ada.address)
        guard case .verified(let address) = message.sender else {
            Issue.record("expected a verified sender, got \(message.sender)")
            return
        }
        #expect(address == ada.address)

        let summary = try #require(message.summary)
        let opened = try #require(try await bob.inbox.openMessage(summary))
        #expect(opened.bodyText == "It works.")

        let kept = try await ada.sent.list()
        #expect(kept.contains { $0.subject == "Hello from Swift" })
    }

    @Test func aReplyThreadsBack() async throws {
        let (ada, bob) = try await pair.value
        _ = try await ada.composer.send(
            DraftContent(from: ada.address, to: [bob.address], subject: "Thread me", text: "First."))
        let first = try #require(try await bob.inbox.allPreviews().first { $0.subject == "Thread me" })
        let original = ReplyOriginal(
            senderAddress: first.senderAddress, to: first.to, cc: first.cc, subject: first.subject,
            messageID: first.messageID, threadID: first.threadID, sentAt: first.sentAt, bodyText: "First.")
        var reply = ComposeReplies.opening(
            ComposeReplies.reply(to: original, all: false, me: bob.address), from: bob.address)
        reply.text = "Second.\n\n" + reply.text
        _ = try await bob.composer.send(reply)
        let back = try #require(try await ada.inbox.allPreviews().first { $0.subject.hasSuffix("Thread me") })
        #expect(back.threadID == first.threadID)
    }

    @Test func attachmentsArriveWhole() async throws {
        let (ada, bob) = try await pair.value
        let bytes = Data((0..<40_000).map { UInt8(truncatingIfNeeded: $0) })
        let attachments = try ComposeAttachments.adding(
            [.init(name: "data.bin", contentType: "application/octet-stream", content: bytes)], to: [])
        _ = try await ada.composer.send(
            DraftContent(
                from: ada.address, to: [bob.address], subject: "With a file", text: "See attached.",
                attachments: attachments))
        let message = try #require(try await bob.inbox.allPreviews().first { $0.subject == "With a file" })
        let summary = try #require(message.summary)
        let opened = try #require(try await bob.inbox.openMessage(summary))
        #expect(opened.downloads.first?.filename == "data.bin")
        #expect(opened.downloads.first?.content == bytes)
    }

    @Test func thePersonalStoreRoundTrips() async throws {
        let (ada, _) = try await pair.value
        let isLocal = await ada.storage.isLocalOnly
        let flags = FlagStore(storage: ada.storage, deviceID: ada.payload.deviceId)
        let hash = String(repeating: "ab", count: 32)
        _ = try await flags.set(hash, FlagDelta(starred: .set(true)))
        #expect(try await flags.list()[hash]?.starred == true)

        let labels = LabelStore(storage: ada.storage)
        let id = try await labels.createLabel(name: "Work", color: "#3b82f6")
        await labels.refresh()
        #expect(await labels.doc.labels.contains { $0.id == id })

        let settings = SettingsStore(storage: ada.storage)
        try await settings.update { $0.signature = "Ada" }
        await settings.refresh()
        #expect(await settings.settings.signature == "Ada")

        try await ada.contacts.allowlist(
            ContactRecord(address: "someone@localhost", name: "Someone", fingerprint: "", provenance: .userApproved))
        let list = await ada.contacts.refresh()
        #expect(list.contains { $0.address == "someone@localhost" })

        let drafts = DraftStore(storage: ada.storage, address: ada.address)
        let draftID = DraftStore.newID()
        _ = try await drafts.save(
            draftID, content: DraftContent(from: ada.address, subject: "Unfinished", text: "Words."), base: .new,
            updatedAt: systemClock())
        #expect(try await drafts.list().contains { $0.subject == "Unfinished" })
        let loaded = try await drafts.load(draftID)
        #expect(loaded?.content.text == "Words.")
        #expect(!isLocal)
    }

    /// Whatever the key turns out to hold, it has to come back as 32 bytes, or no bridge verifies.
    @Test func theRootKeyReadsBackFromTheRealPage() async throws {
        let client = WebHostClient(baseURL: try #require(liveHost))
        let key = try #require(try await client.domainRootKey())
        #expect(Data(base64Encoded: key)?.count == 32)
    }

    @Test func theServerSaysHowToSignUp() async throws {
        let client = WebHostClient(baseURL: try #require(liveHost))
        #expect(try await client.signupMode() == .register)
    }

    @Test func theDirectoryAnswersForRealAndRefusesForNobody() async throws {
        let (ada, _) = try await pair.value
        _ = try await ada.client.list(ada.keys, limit: 10, cursor: nil)
        let directory = try await ada.client.directoryAnswer(for: ada.address, keys: ada.keys)
        #expect(directory.fingerprint.isEmpty == false)
        await #expect(throws: (any Error).self) {
            _ = try await ada.client.directoryAnswer(for: "nobody-here@localhost", keys: ada.keys)
        }
    }
}
