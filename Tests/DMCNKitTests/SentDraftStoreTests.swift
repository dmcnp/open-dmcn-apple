import Foundation
import Crypto
import Testing
@testable import DMCNKit

private let me = SoftwareAccountKeys(address: "me@parity.example")
private let device = fill(16, 0xd1)

private func compose(_ id: UInt8, sentAt: Int64 = 1_760_000_000, subject: String = "Hi", text: String = "Hello")
    -> SplitMessage.Draft
{
    SplitMessage.Draft(
        messageID: fill(16, id), threadID: fill(16, 0x61), recipientAddress: me.address, to: ["ada@parity.example"],
        bcc: ["hidden@parity.example"], subject: subject, bodyText: text, sentAt: sentAt)
}

/// Keys that count private-key operations, each of which can be a biometric prompt.
private final class CountingKeys: AccountKeys, @unchecked Sendable {
    let lock = NSLock()
    var agreements = 0
    var address: String { me.address }
    var ed25519Public: Data { me.ed25519Public }
    var x25519Public: Data { me.x25519Public }
    func sign(_ message: Data) throws -> Data { try me.sign(message) }
    func sharedSecret(withEphemeral ephemeralPublic: Data) throws -> SharedSecret {
        lock.withLock { agreements += 1 }
        return try me.sharedSecret(withEphemeral: ephemeralPublic)
    }
}

@Suite struct SentMail {
    @Test func aCopyListsFromItsHeaderAndOpensItsBodyLazily() async throws {
        let storage = InMemoryPersonalStorage()
        let sent = SentStore(storage: storage, keys: me)
        var draft = compose(0x51)
        draft.replyToID = fill(16, 0x71)
        try await sent.keepCopy(of: draft, from: me, deviceID: device)

        let id = fill(16, 0x51).hex
        #expect(try await storage.listKeys(prefix: "sent/").map(\.key) == ["sent/" + id])
        #expect(try await storage.listKeys(prefix: "sent-body/").map(\.key) == ["sent-body/" + id])

        let rows = try await sent.list()
        #expect(rows.map(\.hash) == ["sent:" + id])
        #expect(rows[0].subject == "Hi")
        #expect(rows[0].bcc == ["hidden@parity.example"])
        #expect(rows[0].messageID == id)
        #expect(rows[0].signedByThisAccount)

        let opened = try await sent.open(rows[0].hash)
        #expect(opened.bodyText == "Hello")
        #expect(opened.htmlBody == nil)
        #expect(opened.replyToID == fill(16, 0x71).hex)
    }

    @Test func theStoredShapeIsTheBrowsers() async throws {
        let storage = InMemoryPersonalStorage()
        try await SentStore(storage: storage, keys: me).keepCopy(of: compose(0x51), from: me, deviceID: device)
        let id = fill(16, 0x51).hex
        let header = try #require(try await storedObject(storage, "sent/" + id))
        #expect(Set(header.keys) == ["recipients", "encryptedHeader", "headerNonce", "headerTag"])
        guard case .array(let recipients)? = header["recipients"], case .object(let r)? = recipients.first else {
            Issue.record("recipients is not an array of objects")
            return
        }
        #expect(Set(r.keys) == ["recipientXPub", "ephemeralXPub", "wrappedCek", "cekNonce", "cekTag", "kdf"])
        #expect(r.int("kdf") == 2)
        let body = try #require(try await storedObject(storage, "sent-body/" + id))
        #expect(Set(body.keys) == ["encryptedBody", "bodyNonce", "bodyTag"])
    }

    @Test func aReplylessMessageSaysSo() async throws {
        let sent = SentStore(storage: InMemoryPersonalStorage(), keys: me)
        try await sent.keepCopy(of: compose(0x51), from: me, deviceID: device)
        let row = try #require(try await sent.list().first)
        #expect(try await sent.open(row.hash).replyToID == nil)
    }

    @Test func aRowThatLostItsGenerationIsTriedNewestFirst() async throws {
        for generation in [SealGeneration.v2, .v1] {
            let storage = InMemoryPersonalStorage()
            let sent = SentStore(storage: storage, keys: me)
            let env = try SplitMessage.seal(
                compose(0x51), from: me, to: [.init(x25519Public: me.x25519Public)], generation: generation)
            try await sent.putEnvelope(env)
            var header = StoredSentHeader(env)
            header.recipients[0].kdf = nil
            try await storage.put("sent/" + fill(16, 0x51).hex, header)

            let row = try #require(try await sent.list().first)
            #expect(try await sent.open(row.hash).bodyText == "Hello")
        }
    }

    @Test func listsNewestFirstAndSkipsWhatItCannotRead() async throws {
        let storage = InMemoryPersonalStorage()
        let sent = SentStore(storage: storage, keys: me)
        try await sent.keepCopy(of: compose(0x51, sentAt: 100, subject: "old"), from: me, deviceID: device)
        try await sent.keepCopy(of: compose(0x52, sentAt: 300, subject: "new"), from: me, deviceID: device)
        // Sealed to someone else, and a row of another shape.
        let other = SoftwareAccountKeys(address: "x@parity.example")
        let foreign = try SplitMessage.seal(compose(0x53), from: other, to: [.init(x25519Public: other.x25519Public)])
        try await storage.put("sent/" + fill(16, 0x53).hex, StoredSentHeader(foreign))
        try await storage.put("sent/" + fill(16, 0x54).hex, ["legacy": true])

        #expect(try await sent.list().map(\.subject) == ["new", "old"])
    }

    @Test func aRowNotSignedByThisAccountIsMarked() async throws {
        let storage = InMemoryPersonalStorage()
        let forger = SoftwareAccountKeys(address: me.address)
        let planted = try SplitMessage.seal(compose(0x51), from: forger, to: [.init(x25519Public: me.x25519Public)])
        let sent = SentStore(storage: storage, keys: me)
        try await sent.putEnvelope(planted)
        #expect(try await sent.list().first?.signedByThisAccount == false)
    }

    @Test func aRowAlreadyOpenedIsNotOpenedAgain() async throws {
        let keys = CountingKeys()
        let storage = InMemoryPersonalStorage()
        let sent = SentStore(storage: storage, keys: keys)
        try await sent.keepCopy(of: compose(0x51), from: me, deviceID: device)
        _ = try await sent.list()
        let afterFirst = keys.lock.withLock { keys.agreements }
        #expect(afterFirst == 1)
        let row = try #require(try await sent.list().first)
        _ = try await sent.open(row.hash)
        #expect(keys.lock.withLock { keys.agreements } == afterFirst)
    }

    @Test func openingWithoutAListingListsFirst() async throws {
        let storage = InMemoryPersonalStorage()
        try await SentStore(storage: storage, keys: me).keepCopy(of: compose(0x51), from: me, deviceID: device)
        let fresh = SentStore(storage: storage, keys: me)
        #expect(try await fresh.open("sent:" + fill(16, 0x51).hex).bodyText == "Hello")
        await #expect(throws: SentNotFoundError()) { try await fresh.open("sent:" + fill(16, 0x59).hex) }
    }

    @Test func aTamperedBodyIsRefused() async throws {
        let storage = InMemoryPersonalStorage()
        let sent = SentStore(storage: storage, keys: me)
        let one = try SplitMessage.seal(compose(0x51), from: me, to: [.init(x25519Public: me.x25519Public)])
        let two = try SplitMessage.seal(
            compose(0x51, text: "Swapped"), from: me, to: [.init(x25519Public: me.x25519Public)])
        try await sent.putEnvelope(one)
        try await storage.put("sent-body/" + fill(16, 0x51).hex, StoredSentBody(two))
        let row = try #require(try await sent.list().first)
        await #expect(throws: (any Error).self) { try await sent.open(row.hash) }
    }

    @Test func deletingTakesBothHalves() async throws {
        let storage = InMemoryPersonalStorage()
        let sent = SentStore(storage: storage, keys: me)
        try await sent.keepCopy(of: compose(0x51), from: me, deviceID: device)
        _ = try await sent.list()
        try await sent.delete(messageID: fill(16, 0x51).hex)
        #expect(try await storage.stat().count == 0)
        #expect(try await sent.list().isEmpty)
    }

    @Test func aHashIsRecognised() {
        #expect(SentStore.isSentHash("sent:abc"))
        #expect(!SentStore.isSentHash(String(repeating: "a", count: 64)))
    }
}

/// A device copy kept in memory, as the app's own backstop would on disk.
private actor MemoryBackstop: DraftBackstop {
    var map: [String: LocalDraft] = [:]
    func get(_ key: String) -> LocalDraft? { map[key] }
    func put(_ key: String, _ value: LocalDraft) { map[key] = value }
    func delete(_ key: String) { map[key] = nil }
    func entries(prefix: String) -> [(key: String, value: LocalDraft)] {
        map.filter { $0.key.hasPrefix(prefix) }.map { ($0.key, $0.value) }
    }
}

private func attachment(_ n: UInt8, contentID: String? = nil) -> DraftAttachment {
    DraftAttachment(
        attachmentID: fill(16, n), filename: "file\(n).pdf", contentType: "application/pdf", sizeBytes: 3,
        contentHash: fill(32, n), content: Data([n, n, n]), contentID: contentID,
        disposition: contentID == nil ? nil : "inline")
}

private func content(text: String = "Hello", attachments: [DraftAttachment] = []) -> DraftContent {
    DraftContent(
        from: me.address, to: ["ada@parity.example"], pending: DraftPending(cc: "half@"), showCcBcc: true,
        subject: "Lunch", rich: true, text: text, html: "<p>\(text)</p>", attachments: attachments)
}

@Suite struct Drafting {
    let id = String(repeating: "d1", count: 16)

    @Test func theRowIsWrittenLastSoItNeverPointsAtNothing() async throws {
        let storage = RacingStorage(races: 0)
        let drafts = DraftStore(storage: storage, address: me.address)
        try await drafts.save(id, content: content(attachments: [attachment(1)]), base: .new, updatedAt: 5)
        #expect(
            await storage.puts.map(\.key) == [
                "draft-att/\(id)/" + fill(16, 1).hex, "draft-body/" + id, "drafts/" + id,
            ])
    }

    @Test func aSavedDraftComesBackWhole() async throws {
        let drafts = DraftStore(storage: InMemoryPersonalStorage(), address: me.address)
        var saved = content(attachments: [attachment(1), attachment(2, contentID: "dot@parity")])
        saved.replyTo = ComposeReplyTo(to: ["ada@parity.example"], subject: "Lunch", replyToId: "ab")
        let base = try await drafts.save(id, content: saved, base: .new, updatedAt: 5)
        #expect(base == DraftBase(head: 1, body: 1, atts: [fill(16, 1).hex, fill(16, 2).hex]))

        let loaded = try #require(try await drafts.load(id))
        #expect(loaded.content == saved)
        #expect(loaded.base == base)
        #expect(loaded.updatedAt == 5)
        #expect(try await drafts.isStored(id))
    }

    @Test func theStoredShapeIsTheBrowsers() async throws {
        let storage = InMemoryPersonalStorage()
        let drafts = DraftStore(storage: storage, address: me.address)
        try await drafts.save(id, content: content(attachments: [attachment(1)]), base: .new, updatedAt: 5)
        let head = try #require(try await storedObject(storage, "drafts/" + id))
        #expect(
            Set(head.keys) == ["v", "from", "to", "cc", "bcc", "subject", "snippet", "updatedAt", "attachments"])
        #expect(
            head["attachments"]
                == .array([
                    .object([
                        "id": .string(fill(16, 1).hex), "filename": .string("file1.pdf"),
                        "contentType": .string("application/pdf"), "sizeBytes": .int(3),
                        "contentHash": .string(fill(32, 1).base64EncodedString()),
                    ])
                ]))
        let body = try #require(try await storedObject(storage, "draft-body/" + id))
        #expect(Set(body.keys) == ["v", "pending", "showCcBcc", "rich", "text", "html", "replyTo"])
        // The browser's `ComposeReplyTo | null` is a written null, not an absent key.
        #expect(body["replyTo"] == .null)
        #expect(
            try await storedObject(storage, "draft-att/\(id)/" + fill(16, 1).hex) == [
                "content": .string(Data([1, 1, 1]).base64EncodedString())
            ])
    }

    @Test func anAttachmentIsWrittenOnceAndRemovedAfterTheRow() async throws {
        let storage = RacingStorage(races: 0)
        let drafts = DraftStore(storage: storage, address: me.address)
        let base = try await drafts.save(id, content: content(attachments: [attachment(1)]), base: .new, updatedAt: 5)
        let next = try await drafts.save(id, content: content(attachments: [attachment(1)]), base: base, updatedAt: 6)
        #expect(await storage.puts.filter { $0.key.hasPrefix("draft-att/") }.count == 1)
        #expect(next == DraftBase(head: 2, body: 2, atts: base.atts))

        let dropped = try await drafts.save(id, content: content(attachments: []), base: next, updatedAt: 7)
        #expect(dropped.atts.isEmpty)
        #expect(try await storage.listKeys(prefix: "draft-att/").isEmpty)
    }

    @Test func aSaveOverAnotherDevicesCopyIsAConflict() async throws {
        let storage = InMemoryPersonalStorage()
        let here = DraftStore(storage: storage, address: me.address)
        let there = DraftStore(storage: storage, address: me.address)
        let base = try await here.save(id, content: content(), base: .new, updatedAt: 5)
        let opened = try #require(try await there.load(id))
        try await there.save(id, content: content(text: "From there"), base: opened.base, updatedAt: 6)

        await #expect(throws: DraftConflictError()) {
            try await here.save(id, content: content(text: "From here"), base: base, updatedAt: 7)
        }
        #expect(try await here.load(id)?.content.text == "From there")

        // "Keep this copy".
        try await here.save(id, content: content(text: "From here"), base: base, updatedAt: 8, force: true)
        #expect(try await here.load(id)?.content.text == "From here")
    }

    @Test func aDraftSentElsewhereIsAConflictAndNoLongerStored() async throws {
        let storage = InMemoryPersonalStorage()
        let drafts = DraftStore(storage: storage, address: me.address)
        let base = try await drafts.save(id, content: content(), base: .new, updatedAt: 5)
        try await drafts.delete(id)
        await #expect(throws: DraftConflictError()) {
            try await drafts.save(id, content: content(), base: base, updatedAt: 6)
        }
        #expect(try await drafts.isStored(id) == false)
    }

    @Test func aPartThatNeverMadeItUpIsLeftOut() async throws {
        let storage = InMemoryPersonalStorage()
        let drafts = DraftStore(storage: storage, address: me.address)
        try await drafts.save(
            id, content: content(attachments: [attachment(1), attachment(2)]), base: .new, updatedAt: 5)
        try await storage.delete("draft-att/\(id)/" + fill(16, 1).hex)
        let loaded = try #require(try await drafts.load(id))
        #expect(loaded.content.attachments == [attachment(2)])
        #expect(loaded.base.atts == [fill(16, 2).hex])
    }

    @Test func listsNewestFirstWithoutReadingBodies() async throws {
        let drafts = DraftStore(storage: InMemoryPersonalStorage(), address: me.address)
        try await drafts.save("aa", content: content(text: "older"), base: .new, updatedAt: 5)
        try await drafts.save(
            "bb", content: content(text: "newer", attachments: [attachment(1)]), base: .new, updatedAt: 9)
        let rows = try await drafts.list()
        #expect(rows.map(\.id) == ["bb", "aa"])
        #expect(rows.map(\.snippet) == ["newer", "older"])
        #expect(rows.map(\.attachmentCount) == [1, 0])
    }

    @Test func deletingRemovesEveryPart() async throws {
        let storage = InMemoryPersonalStorage()
        let drafts = DraftStore(storage: storage, address: me.address)
        try await drafts.save(id, content: content(attachments: [attachment(1)]), base: .new, updatedAt: 5)
        try await drafts.delete(id)
        #expect(try await storage.stat().count == 0)
        #expect(try await drafts.load(id) == nil)
    }

    @Test func anIDIsThirtyTwoHexCharacters() {
        #expect(DraftStore.newID().count == 32)
        #expect(Data(hex: DraftStore.newID()) != nil)
    }

    @Test func aCutInsideAnEmojiDropsTheHalf() {
        let text = String(repeating: "x", count: 138) + "🙂 and more"
        let snippet = DraftStore.snippet(text)
        #expect(snippet == String(repeating: "x", count: 138) + "…")
        // The browser's cut keeps half the pair; a Swift string can't hold that.
        #expect(snippet.utf16.count == 139)
    }

    @Test func whatCountsAsWorthKeeping() {
        var c = DraftContent(from: me.address, text: "sig")
        #expect(!DraftStore.hasContent(c, untouchedText: " sig\n"))
        c.text = "sig and more"
        #expect(DraftStore.hasContent(c, untouchedText: "sig"))
        c.text = "sig"
        c.pending.bcc = "half@"
        #expect(DraftStore.hasContent(c, untouchedText: "sig"))

        var reply = DraftContent(from: me.address, to: ["ada@parity.example"], subject: "Re: Lunch", text: "> quote")
        reply.replyTo = ComposeReplyTo(to: ["ada@parity.example"], subject: "Lunch")
        #expect(!DraftStore.hasContent(reply, untouchedText: "> quote"))
        reply.subject = "Re: Dinner"
        #expect(DraftStore.hasContent(reply, untouchedText: "> quote"))
    }
}

@Suite struct DraftDeviceCopy {
    let id = String(repeating: "d1", count: 16)

    fileprivate func stores() -> (DraftStore, MemoryBackstop, InMemoryPersonalStorage) {
        let storage = InMemoryPersonalStorage()
        let backstop = MemoryBackstop()
        return (DraftStore(storage: storage, address: " Me@Parity.Example ", backstop: backstop), backstop, storage)
    }

    @Test func withoutABackstopNothingIsKept() async throws {
        let drafts = DraftStore(storage: InMemoryPersonalStorage(), address: me.address)
        try await drafts.saveLocal(id, content: content(), base: .new, updatedAt: 5)
        #expect(try await drafts.load(id) == nil)
        #expect(try await drafts.settleLocal(now: 1_000_000) == false)
    }

    @Test func aDeviceCopyOpensFirstAndIsKeyedPerAccount() async throws {
        let (drafts, backstop, _) = stores()
        try await drafts.save(id, content: content(text: "stored"), base: .new, updatedAt: 5)
        try await drafts.saveLocal(id, content: content(text: "local"), base: DraftBase(head: 1, body: 1), updatedAt: 6)
        #expect(try await drafts.load(id)?.content.text == "local")
        #expect(await backstop.map.keys.first == "draft::me@parity.example::" + id)
    }

    @Test func theListPrefersWhicheverCopyIsNewer() async throws {
        let (drafts, _, _) = stores()
        try await drafts.save(id, content: content(text: "stored"), base: .new, updatedAt: 5)
        try await drafts.saveLocal(id, content: content(text: "local"), base: DraftBase(head: 1, body: 1), updatedAt: 6)
        #expect(try await drafts.list().map(\.snippet) == ["local"])
        try await drafts.save(
            id, content: content(text: "stored later"), base: DraftBase(head: 1, body: 1), updatedAt: 7)
        #expect(try await drafts.list().map(\.snippet) == ["stored later"])
    }

    @Test func aCopyOfSomethingRemovedElsewhereIsNotResurrected() async throws {
        let (drafts, _, _) = stores()
        try await drafts.saveLocal(id, content: content(), base: DraftBase(head: 4, body: 4), updatedAt: 6)
        #expect(try await drafts.list().isEmpty)
        // A draft that never reached the relay is another matter.
        try await drafts.saveLocal("new", content: content(text: "only here"), base: .new, updatedAt: 6)
        #expect(try await drafts.list().map(\.id) == ["new"])
    }

    @Test func clearingLeavesANewerCopyAlone() async throws {
        let (drafts, backstop, _) = stores()
        try await drafts.saveLocal(id, content: content(), base: .new, updatedAt: 6)
        try await drafts.clearLocal(id, updatedAt: 5)
        #expect(await backstop.map.count == 1)
        try await drafts.clearLocal(id, updatedAt: 6)
        #expect(await backstop.map.isEmpty)
    }

    @Test func settlingUploadsWhatIsOldEnoughAndNotOpen() async throws {
        let (drafts, backstop, storage) = stores()
        try await drafts.saveLocal("old", content: content(), base: .new, updatedAt: 0)
        try await drafts.saveLocal("open", content: content(), base: .new, updatedAt: 0)
        try await drafts.saveLocal("young", content: content(), base: .new, updatedAt: 50_000)
        #expect(try await drafts.settleLocal(skip: ["open"], now: 60_000))
        #expect(try await storage.listKeys(prefix: "drafts/").map(\.key) == ["drafts/old"])
        #expect(await backstop.map.count == 2)
    }

    @Test func settlingDropsACopyWhoseDraftWentAway() async throws {
        let (drafts, backstop, _) = stores()
        try await drafts.saveLocal(id, content: content(), base: DraftBase(head: 1, body: 1), updatedAt: 0)
        // It names a stored version, and nothing is stored: sent or discarded on another device.
        #expect(try await drafts.settleLocal(now: 100_000))
        #expect(await backstop.map.isEmpty)
    }

    @Test func settlingKeepsACopyWhenBothChanged() async throws {
        let (drafts, backstop, _) = stores()
        let base = try await drafts.save(id, content: content(text: "one"), base: .new, updatedAt: 1)
        try await drafts.save(id, content: content(text: "two"), base: base, updatedAt: 2)
        try await drafts.saveLocal(id, content: content(text: "mine"), base: base, updatedAt: 3)
        #expect(try await drafts.settleLocal(now: 100_000) == false)
        #expect(await backstop.map.count == 1)
    }
}
