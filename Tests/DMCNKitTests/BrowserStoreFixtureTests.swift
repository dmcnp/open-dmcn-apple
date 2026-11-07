// Fixtures/browser-store.json was written by the browser client's real code (src/lib) running under
// node: FlagStore, SettingsStore, ContactStore, SentStore, DraftStore and PersonalStore itself,
// through a host with the relay's rules. These tests read it through the whole Swift path, host and
// all, so a difference from the browser in any key, shape or seal shows up here.
//
// The other direction is the last test: set DMCN_STORE_INTEROP_OUT to a file and it writes what the
// kit's stores wrote, for the same browser code to open.

import Foundation
import Testing
@testable import DMCNKit

private let flagged = String(repeating: "a1", count: 32)
private let plainFlags = String(repeating: "b2", count: 32)
private let richSent = "sent:" + String(repeating: "51", count: 16)
private let lostKdfSent = "sent:" + String(repeating: "52", count: 16)
private let richDraft = String(repeating: "d1", count: 16)
private let plainDraft = String(repeating: "d2", count: 16)

private func seededStore(_ f: BrowserStore) async throws -> (PersonalStore, StoreHost) {
    let host = StoreHost(kv: f.kv.mapValues { StoreHost.Record(sealed: $0.sealed, version: $0.version) })
    return (try await signedInStore(host: host, keys: f.owner()), host)
}

@Suite struct BrowserStoreFixture {
    @Test func flags() async throws {
        let f = try BrowserStore.load()
        let (store, _) = try await seededStore(f)
        let flags = try await FlagStore(storage: store, deviceID: fill(16, 1)).list()

        // The third row in the store is garbage, and is skipped.
        #expect(flags.count == 2)
        let first = try #require(flags[flagged])
        #expect(first.v == 1)
        #expect(first.read == true)
        #expect(first.labelIds == ["lab1", "lab2"])
        #expect(first.folderId == "fold1")
        #expect(first.trashedAt == 1_760_000_000_123)
        #expect(first.deviceId == f.device_id)
        #expect(first.archived == nil)

        let second = try #require(flags[plainFlags])
        #expect(second.starred == false)
        #expect(second.archived == true)
    }

    @Test func labelsWithFieldsFromANewerClient() async throws {
        let (store, _) = try await seededStore(BrowserStore.load())
        let labels = LabelStore(storage: store)
        let (doc, version) = try await labels.get()
        #expect(version == 1)
        #expect(doc.labels.map(\.name) == ["Work ✓", "Home"])
        #expect(doc.labels.map(\.color) == ["#ef4444", "#10b981"])
        #expect(doc.folders.map(\.id) == ["fold1"])

        try await labels.renameLabel(id: "lab1", name: "Job")
        let saved = try #require(try await storedObject(store, LabelStore.key))
        #expect(saved["sortOrder"] == .array([.string("lab2"), .string("lab1")]))
        #expect(try await labels.get().doc.labels[0].fields["shade"] == .int(3))
    }

    @Test func settingsWithFieldsFromANewerClient() async throws {
        let (store, _) = try await seededStore(BrowserStore.load())
        let settings = SettingsStore(storage: store)
        let read = try await settings.get().settings
        #expect(read.displayName == "Old Name")
        #expect(read.signature == "Ada ✓\nparity.example")
        #expect(read.composePlainText == true)
        #expect(read.remoteImagesForTrusted == false)
        #expect(read.gettingStartedHidden == true)
        #expect(read.trashDays == 3)

        try await settings.update { $0.signature = "Changed" }
        let saved = try #require(try await storedObject(store, SettingsStore.key))
        let newer: JSONValue = .object([
            "nested": .array([
                .int(1), .double(2.5), .null, .bool(true), .string("x"), .object(["deep": .int(1_730_000_000_123)]),
            ]),
            "big": .int(9_007_199_254_740_991),
        ])
        #expect(saved["newerClient"] == newer)
    }

    @Test func contactsOfEveryVintage() async throws {
        let f = try BrowserStore.load()
        let (store, _) = try await seededStore(f)
        let contacts = ContactStore(
            storage: store, pins: InMemoryPersonalStorage(), owner: f.address, deviceID: fill(16, 1))
        let records = await contacts.refresh()
        // The fifth row is sealed to someone else.
        #expect(records.count == 4)

        let pinned = try #require(await contacts.contact(for: "pinned@parity.example"))
        #expect(pinned.v == 3)
        #expect(pinned.name == "Pinned Person")
        #expect(pinned.notes == "met in Lisbon")
        #expect(pinned.provenance == .inPerson)
        #expect(pinned.ed25519Pub == fill(32, 0x31).base64EncodedString())
        #expect(pinned.x25519Pub == fill(32, 0x32).base64EncodedString())
        #expect(pinned.pinnedAt == 1_760_000_000_456)
        #expect(pinned.adminKeyCustody == true)
        #expect(pinned.pinSeq == 2)

        let plain = try #require(await contacts.contact(for: "plain.person@parity.example"))
        #expect(plain.name == "Plain")
        #expect(plain.provenance == nil)
        #expect(plain.pinnedFacts == nil)

        let old = try #require(await contacts.contact(for: "old@parity.example"))
        #expect(old.v == 1)
        try await contacts.update("old@parity.example", name: "Older")
        let saved = try #require(try await storedObject(store, ContactStore.key(for: "old@parity.example")))
        #expect(saved["fromTheFuture"] == .string("keep me"))
        #expect(saved["v"] == .int(3))

        let gone = try #require(await contacts.contact(for: "gone@parity.example"))
        #expect(gone.noIdentity == true)
        #expect(gone.pinnedFacts == .absentIdentity)
    }

    @Test func sentRowsAndBodies() async throws {
        let f = try BrowserStore.load()
        let (store, _) = try await seededStore(f)
        let sent = SentStore(storage: store, keys: try f.owner())
        let rows = try await sent.list()
        #expect(rows.map(\.hash) == [lostKdfSent, richSent])
        #expect(rows.map(\.signedByThisAccount) == [true, true])

        let rich = rows[1]
        #expect(rich.subject == "From the browser ✓")
        #expect(rich.to == ["ada@parity.example"])
        #expect(rich.cc == ["cy@parity.example"])
        #expect(rich.bcc == ["hidden@parity.example"])
        #expect(rich.sentAt == 1_760_000_100)
        #expect(rich.attachmentCount == 1)

        let opened = try await sent.open(richSent)
        #expect(opened.bodyText == "Hello from the browser. ünïcödé ✓")
        #expect(opened.htmlBody == "<p>Hello from the <b>browser</b></p>")
        #expect(opened.replyToID == fill(16, 0x71).hex)
        #expect(opened.content.attachments.map(\.filename) == ["note.txt"])
        #expect(opened.content.attachments.first?.content == Data("hello".utf8))

        // Stored without its generation, sealed with the current one.
        #expect(try await sent.open(lostKdfSent).bodyText == "Stored before the row kept kdf.")
    }

    @Test func draftsWhole() async throws {
        let f = try BrowserStore.load()
        let (store, _) = try await seededStore(f)
        let drafts = DraftStore(storage: store, address: f.address)

        // The rich draft's row holds a snippet the browser cut inside an emoji, which Foundation's
        // decoder refuses as it stands.
        let rows = try await drafts.list()
        #expect(rows.map(\.id) == [plainDraft, richDraft])
        #expect(rows[1].subject == "Re: Lunch again")
        #expect(rows[1].attachmentCount == 1)
        #expect(rows[1].snippet == String(repeating: "x", count: 138) + "\u{FFFD}…")
        #expect(rows[0].snippet == "plain text")

        let loaded = try #require(try await drafts.load(richDraft))
        #expect(loaded.base == DraftBase(head: 2, body: 2, atts: [fill(16, 0xc1).hex]))
        #expect(loaded.updatedAt == 1_760_000_300_222)
        let c = loaded.content
        #expect(c.pending == DraftPending(to: "half@par"))
        #expect(c.showCcBcc)
        #expect(c.rich)
        #expect(c.html == #"<p>hi <img src="cid:dot@parity"></p>"#)
        #expect(
            c.replyTo
                == ComposeReplyTo(
                    to: ["ada@parity.example"], cc: ["cy@parity.example"], subject: "Lunch", sentTo: [f.address],
                    quote: "> hi", quoteHtml: "<blockquote>hi</blockquote>",
                    replyToId: String(repeating: "51", count: 16), threadId: String(repeating: "61", count: 16)))
        #expect(
            c.attachments == [
                DraftAttachment(
                    attachmentID: fill(16, 0xc1), filename: "dot.png", contentType: "image/png", sizeBytes: 3,
                    contentHash: fill(32, 0xc2), content: Data([1, 2, 3]), contentID: "dot@parity",
                    disposition: "inline")
            ])

        let plain = try #require(try await drafts.load(plainDraft))
        #expect(plain.content.replyTo == nil)
        #expect(plain.content.text == "  plain\n\ttext  ")

        // Saving on top of what the browser stored is a normal compare-and-swap.
        let next = try await drafts.save(plainDraft, content: plain.content, base: plain.base, updatedAt: 9)
        #expect(next.head == 2)
    }

    @Test func theSmallTextRulesAgreeWithTheBrowsers() throws {
        let f = try BrowserStore.load()
        for c in f.snippets { #expect(DraftStore.snippet(c.text) == c.snippet) }
        for c in f.contact_ids { #expect(ContactStore.id(for: c.address) == c.id) }
        for c in f.reply_subjects { #expect(DraftStore.replySubject(c.subject) == c.reply) }
    }

    /// What the kit writes, for the browser's code to open. Skipped unless asked for.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DMCN_STORE_INTEROP_OUT"] != nil))
    func writeForTheBrowser() async throws {
        let f = try BrowserStore.load()
        let keys = try f.owner()
        let (store, host) = try await seededStore(f)
        let device = fill(16, 0xe2)

        let flags = FlagStore(storage: store, deviceID: device, now: { 1_770_000_000_001 })
        try await flags.list()
        try await flags.set(flagged, FlagDelta(starred: .set(true), trashedAt: .clear))
        try await flags.set(String(repeating: "c3", count: 32), FlagDelta(read: .set(false), labelIds: .set(["x"])))

        let labels = LabelStore(storage: store)
        try await labels.renameLabel(id: "lab1", name: "Job ✓")
        let folder = try await labels.createFolder(name: " Bills ")

        try await SettingsStore(storage: store).update {
            $0.signature = "From Swift ✓"
            $0.composePlainText = nil
            $0.trashDays = 5
        }

        let contacts = ContactStore(storage: store, pins: InMemoryPersonalStorage(), owner: f.address, deviceID: device)
        await contacts.refresh()
        try await contacts.update("old@parity.example", name: "Older", notes: "from swift")
        try await contacts.put(
            ContactRecord(
                address: "Swift@Parity.Example", name: "From Swift", fingerprint: "fp-s", provenance: .fingerprint,
                ed25519Pub: fill(32, 0x41).base64EncodedString(), x25519Pub: fill(32, 0x42).base64EncodedString(),
                pinnedAt: 1_770_000_000_002, adminKeyCustody: false, pinSeq: 3))

        let sent = SentStore(storage: store, keys: keys)
        try await sent.keepCopy(
            of: SplitMessage.Draft(
                messageID: fill(16, 0x53), threadID: fill(16, 0x63), replyToID: fill(16, 0x51),
                recipientAddress: f.address, to: ["ada@parity.example"], bcc: ["hidden@parity.example"],
                subject: "From Swift ✓", bodyText: "Hello from Swift. ünïcödé ✓", sentAt: 1_770_000_100),
            from: keys, deviceID: device)

        let drafts = DraftStore(storage: store, address: f.address)
        let plain = try #require(try await drafts.load(plainDraft))
        var edited = plain.content
        edited.text = "edited in Swift 🙂"
        try await drafts.save(plainDraft, content: edited, base: plain.base, updatedAt: 1_770_000_200_000)
        try await drafts.save(
            String(repeating: "d3", count: 16),
            content: DraftContent(
                from: f.address, to: ["ada@parity.example"], pending: DraftPending(bcc: "half"), subject: "New",
                rich: true, text: "with a file", html: "<p>with a file</p>",
                replyTo: ComposeReplyTo(to: ["ada@parity.example"], subject: "Lunch", threadId: "ab"),
                attachments: [
                    DraftAttachment(
                        attachmentID: fill(16, 0xc3), filename: "a.bin", contentType: "application/octet-stream",
                        sizeBytes: 2, contentHash: fill(32, 0xc4), content: Data([9, 8]))
                ]),
            base: .new, updatedAt: 1_770_000_200_001)

        let out: [String: JSONValue] = [
            "folder_id": .string(folder),
            "blob_v2": try StoreJSON.decode(
                JSONValue.self,
                from: StoreJSON.encode(SealedBlob.seal(Data("From Swift ✓".utf8), to: [keys.x25519Public]))),
            "blob_v1": try StoreJSON.decode(
                JSONValue.self,
                from: StoreJSON.encode(
                    SealedBlob.seal(Data("From Swift ✓".utf8), to: [keys.x25519Public], generation: .v1))),
            "blob_two": try StoreJSON.decode(
                JSONValue.self,
                from: StoreJSON.encode(
                    SealedBlob.seal(
                        Data("From Swift ✓".utf8), to: [f.stranger().x25519Public, keys.x25519Public]))),
            "kv": .object(
                await host.kv.mapValues {
                    .object(["sealed": .string($0.sealed), "version": .int(Int64($0.version))])
                }),
        ]
        let path = try #require(ProcessInfo.processInfo.environment["DMCN_STORE_INTEROP_OUT"])
        try StoreJSON.encode(out).write(to: URL(fileURLWithPath: path))
    }
}
