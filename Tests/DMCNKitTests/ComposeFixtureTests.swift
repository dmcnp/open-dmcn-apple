// Fixtures/browser-compose.json was written by the browser client's real code under node:
// encryptSplit and the pure helpers directly, and handleSend, buildReply, plainScaffold and
// commitPending sliced out of their components and run as written with the network stubbed. So each
// scenario below is what the browser actually did, not what its source was read to mean.
//
// The other direction is the last test: set DMCN_COMPOSE_INTEROP_OUT to a file and it writes what
// the kit sealed and sent, for the browser's decryptHeader, decryptBody and SentStore to open.

import Crypto
import Foundation
import Testing
@testable import DMCNKit

private struct Fixture: Decodable {
    struct Person: Decodable {
        let ed25519_seed: String
        let x25519_private: String
    }
    struct Sender: Decodable {
        let address: String
        let ed25519_seed: String
        let x25519_private: String
        let device_id: String
    }
    struct Attachment: Decodable {
        let attachment_id: String
        let filename: String
        let content_type: String
        let size_bytes: Int
        let content_hash: String
        let content: String
        let content_id: String?
        let disposition: String?

        var value: DraftAttachment {
            DraftAttachment(
                attachmentID: unhex(attachment_id), filename: filename, contentType: content_type,
                sizeBytes: size_bytes, contentHash: unhex(content_hash),
                content: content == "fill:5a" ? fill(size_bytes, 0x5a) : unhex(content), contentID: content_id,
                disposition: disposition)
        }
    }
    struct Seal: Decodable {
        struct Input: Decodable {
            let message_id: String
            let thread_id: String
            let reply_to_id: String?
            let recipient_address: String
            let to: [String]
            let cc: [String]
            let bcc: [String]
            let subject: String
            let body_text: String
            let body_html: String?
            let sent_at: Int64
            let attachments: [Attachment]
        }
        let name: String
        let input: Input
        let envelope: String
        let content: String
        let header: String
        let signature: String
        let body_content_address: String
        let header_size_class: UInt32
        let body_size_class: UInt32

        var draft: SplitMessage.Draft {
            SplitMessage.Draft(
                messageID: unhex(input.message_id), threadID: unhex(input.thread_id),
                replyToID: input.reply_to_id.map(unhex), recipientAddress: input.recipient_address, to: input.to,
                cc: input.cc, bcc: input.bcc, subject: input.subject, bodyText: input.body_text,
                bodyHTML: input.body_html, attachments: input.attachments.map(\.value), sentAt: input.sent_at)
        }
    }
    struct Copy: Decodable {
        let browser_verifies: Bool
        let recipient_address: String
        let sender_address: String
        let to: [String]
        let cc: [String]
        let bcc: [String]
        let subject: String
        let snippet: String
        let body_size: UInt64
        let attachment_count: UInt32
        let reply_to_id: String
        let thread_id: String
        let body_text: String
        let html: String?
        let attachments: [String]
        let device_id: String
    }
    struct Scenario: Decodable {
        struct Contact: Decodable {
            let address: String
            let name: String
        }
        struct ReplyTo: Decodable {
            let to: [String]
            let subject: String
            let replyToId: String
            let threadId: String
        }
        struct Answer: Decodable {
            let status: Int
            let body: [String: JSONValue]
        }
        struct Pending: Decodable {
            let to: String
            let cc: String
            let bcc: String
        }
        struct Input: Decodable {
            let from: String
            let to: [String]
            let cc: [String]
            let bcc: [String]
            let pending: Pending
            let subject: String
            let text: String
            let reply_to: ReplyTo?
            let attachments: [Attachment]
            let contacts: [Contact]
            let legacy_route: Bool
            let sent_fails: Bool
            let directory: [String: Answer]
            let send_status: [String: Int]
        }
        struct Post: Decodable {
            let fields: [String]
            let sender_address: String
            let recipient_address: String
            let onion: Bool
            let sealed_to: String
            let copy: Copy
        }
        struct LegacyCopy: Decodable {
            let recipient: String
            let sender_address: String
            let copy: Copy
        }
        struct SentCopy: Decodable {
            let copy: Copy
        }
        struct Report: Decodable {
            struct Save: Decodable {
                let address: String
                let name: String
            }
            let text: String
            let save_contact: Save?
        }
        struct Expected: Decodable {
            let posts: [Post]
            let legacy: [LegacyCopy]
            let sent_copy: SentCopy?
            let error: String?
            let report: [Report]?
            let closed: Bool
            let draft_removed: Bool
        }
        let name: String
        let input: Input
        let expected: Expected
    }
    struct Reply: Decodable {
        struct Original: Decodable {
            let sender: String
            let to: [String]
            let cc: [String]
            let subject: String
            let message_id: String
            let thread_id: String
            let sent_at: Int64
            let body: String?
        }
        struct Expected: Decodable {
            let to: [String]
            let cc: [String]
            let subject: String
            let quote: String?
            let reply_to_id: String
            let thread_id: String
            let sent_to: [String]
        }
        let name: String
        let all: Bool
        let me: String
        let contact_name: String?
        let original: Original
        let expected: Expected
    }
    struct Scaffold: Decodable {
        let is_reply: Bool
        let quote: String?
        let signature: String
        let expected: String
    }
    struct PendingCase: Decodable {
        let values: [String]
        let pending: String
        let expected: [String]
    }
    struct Pin: Decodable {
        struct Contact: Decodable {
            let ed25519Pub: String?
            let x25519Pub: String?
            let adminKeyCustody: Bool?
            let noIdentity: Bool?
        }
        let contact: Contact?
        let observed: PinnedFacts?
        let verdict: String
        let changed: [String]
    }
    struct DirectoryFacts: Decodable {
        struct Answer: Decodable {
            let ed25519_pub: String
            let x25519_pub: String
            let admin_key_custody: Bool?
            let legacy: Bool?
        }
        let answer: Answer
        let facts: PinnedFacts
    }
    struct Warnings: Decodable {
        let plain, unexplained, replaced, recovered, stolen, gone: String
    }
    struct ForwardPlan: Decodable {
        struct Forward: Decodable {
            let address: String
            let forwardTo: String?
        }
        struct Copy: Decodable {
            let forAddr: String
            let target: String
        }
        let forwards: [Forward]
        let recipients: [String]
        let sender: String
        let expected: [Copy]
    }
    struct ForwardWords: Decodable {
        let dmcn, email, unknown, unsendable, only, failed, only_failed, closed: String
    }
    struct UserAttachments: Decodable {
        struct Item: Decodable {
            let contentType: String
            let filename: String
        }
        let all: [Item]
        let expected: [String]
    }

    let sender: Sender
    let people: [String: Person]
    let seals: [Seal]
    let scenarios: [Scenario]
    let replies: [Reply]
    let scaffolds: [Scaffold]
    let pending: [PendingCase]
    let pins: [Pin]
    let directory_facts: [DirectoryFacts]
    let warnings: Warnings
    let forward_plans: [ForwardPlan]
    let forward_words: ForwardWords
    let user_attachments: [UserAttachments]

    static func load() throws -> Fixture {
        let url = try #require(
            Bundle.module.url(forResource: "browser-compose", withExtension: "json", subdirectory: "Fixtures"))
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }

    func alice() throws -> SoftwareAccountKeys {
        try SoftwareAccountKeys(
            address: sender.address, ed25519Seed: unhex(sender.ed25519_seed),
            x25519Private: unhex(sender.x25519_private))
    }

    func person(_ address: String) throws -> SoftwareAccountKeys {
        let p = try #require(people[address])
        return try SoftwareAccountKeys(
            address: address, ed25519Seed: unhex(p.ed25519_seed), x25519Private: unhex(p.x25519_private))
    }
}

private func opened(_ env: Dmcn_Message_EncryptedEnvelope, keys: some AccountKeys) throws -> (
    OpenedHeader, Dmcn_Message_MessageContent
) {
    let header = try SplitMessage.openHeader(Dmcn_Relay_MailboxEntry(filing: env), keys: keys)
    return (header, try SplitMessage.openBody(Dmcn_Relay_MailboxBody(filing: env), of: header))
}

@Suite struct BrowserComposeSeals {
    @Test func swiftOpensWhatTheBrowserSealed() throws {
        let f = try Fixture.load()
        let bob = try f.person("bob@parity.example")
        for seal in f.seals {
            let env = try Dmcn_Message_EncryptedEnvelope(serializedBytes: unhex(seal.envelope))
            let (header, content) = try opened(env, keys: bob)
            let h = header.header
            #expect(h.senderAddress == f.sender.address, "\(seal.name)")
            #expect(h.senderPublicKey == (try f.alice()).ed25519Public)
            #expect(h.messageID == unhex(seal.input.message_id))
            #expect(h.threadID == unhex(seal.input.thread_id))
            #expect(h.replyToID == seal.input.reply_to_id.map(unhex) ?? Data(count: 16))
            #expect(h.recipientAddress == seal.input.recipient_address)
            #expect(h.to == seal.input.to)
            #expect(h.cc == seal.input.cc)
            #expect(h.bcc == seal.input.bcc)
            #expect(h.subject == seal.input.subject)
            #expect(h.attachmentCount == UInt32(seal.input.attachments.count))
            #expect(h.sentAt == seal.input.sent_at)
            #expect(env.headerSizeClass == seal.header_size_class)
            #expect(env.bodySizeClass == seal.body_size_class)
            #expect(String(decoding: content.body.content, as: UTF8.self) == seal.input.body_text)
            #expect(
                content.alternatives.map(\.contentType) == ((seal.input.body_html ?? "").isEmpty ? [] : ["text/html"]))
            #expect(
                content.alternatives.first.map { String(decoding: $0.content, as: UTF8.self) }
                    == seal.input.body_html.flatMap { $0.isEmpty ? nil : $0 })
            let expected = seal.input.attachments.map(\.value)
            #expect(content.attachments.map(\.filename) == expected.map(\.filename))
            #expect(content.attachments.map(\.content) == expected.map(\.content))
            #expect(content.attachments.map(\.contentID) == expected.map { $0.contentID ?? "" })
            #expect(content.attachments.map(\.disposition) == expected.map { $0.disposition ?? "" })
            #expect(content.attachments.map(\.attachmentID) == expected.map(\.attachmentID))
            #expect(content.attachments.map(\.contentHash) == expected.map(\.contentHash))
        }
    }

    /// The bytes both signatures and hashes cover, compared with the browser's. Signatures aren't
    /// compared as bytes: CryptoKit's aren't deterministic. The browser's has to verify over ours.
    @Test func theSignedEncodingsMatchTheBrowsers() throws {
        let f = try Fixture.load()
        let alice = try f.alice()
        for seal in f.seals {
            let contentBytes = try SplitMessage.contentBytes(of: seal.draft)
            if seal.name == "big attachment" {
                #expect(Data(SHA256.hash(data: contentBytes)) == unhex(seal.content))
            } else {
                #expect(contentBytes == unhex(seal.content), "\(seal.name)")
            }
            let header = SplitMessage.header(
                of: seal.draft, from: alice, contentBytes: contentBytes,
                bodyContentAddress: unhex(seal.body_content_address))
            let bytes = try Canonical.marshal(header)
            #expect(bytes == unhex(seal.header), "\(seal.name)")
            #expect(
                verifyEd25519(
                    publicKey: alice.ed25519Public, message: SignatureContext.messageHeader.signable(bytes),
                    signature: unhex(seal.signature)))
        }
    }

    /// What it sealed before attachments and alternatives existed is what it seals now.
    @Test func aTextOnlyMessageCarriesNoNewFields() throws {
        let f = try Fixture.load()
        let seal = try #require(f.seals.first { $0.name == "text only" })
        var expected = Dmcn_Message_MessageContent()
        expected.body.contentType = "text/plain"
        expected.body.content = Data(seal.input.body_text.utf8)
        #expect(try SplitMessage.contentBytes(of: seal.draft) == Canonical.marshal(expected))
    }
}

/// `Composer.send` run against what the browser's handleSend did with the same inputs.
@Suite struct BrowserSendScenarios {
    private func expectCopy(
        _ env: Dmcn_Message_EncryptedEnvelope, _ copy: Fixture.Copy, keys: some AccountKeys, _ name: String
    ) throws {
        let (header, content) = try opened(env, keys: keys)
        let h = header.header
        #expect(h.recipientAddress == copy.recipient_address, "\(name)")
        #expect(h.senderAddress == copy.sender_address, "\(name)")
        #expect(h.to == copy.to, "\(name)")
        #expect(h.cc == copy.cc, "\(name)")
        #expect(h.bcc == copy.bcc, "\(name)")
        #expect(h.subject == copy.subject, "\(name)")
        #expect(h.snippet == copy.snippet, "\(name)")
        #expect(h.bodySize == copy.body_size, "\(name)")
        #expect(h.attachmentCount == copy.attachment_count, "\(name)")
        // The browser leaves an absent reply id off the wire and signs the 16 zeros Go fills in.
        #expect(h.replyToID == (copy.reply_to_id.isEmpty ? Data(count: 16) : unhex(copy.reply_to_id)), "\(name)")
        #expect(String(decoding: content.body.content, as: UTF8.self) == copy.body_text, "\(name)")
        #expect(content.alternatives.isEmpty == (copy.html == nil), "\(name)")
        #expect(content.attachments.map(\.filename) == copy.attachments, "\(name)")
        #expect(env.recipients[0].deviceID == unhex(copy.device_id), "\(name)")
    }

    @Test func everyScenario() async throws {
        let f = try Fixture.load()
        let alice = try f.alice()
        let deviceID = unhex(f.sender.device_id)
        for s in f.scenarios {
            let host = ComposeHost(
                sender: alice.ed25519Public,
                directory: s.input.directory.mapValues { .init(status: $0.status, body: $0.body) },
                sendStatus: s.input.send_status)
            let client = WebHostClient(baseURL: URL(string: "https://host.example")!, transport: host)
            try await client.signIn(alice)
            let storage: any PersonalStorage = s.input.sent_fails ? RefusingStorage() : InMemoryPersonalStorage()
            let sent = SentStore(storage: storage, keys: alice)
            let contacts = ContactStore(
                storage: InMemoryPersonalStorage(), pins: InMemoryPersonalStorage(), owner: alice.address,
                deviceID: deviceID)
            for c in s.input.contacts {
                try await contacts.put(ContactRecord(address: c.address, name: c.name, fingerprint: ""))
            }
            let route = FakeLegacyRoute(bridge: try f.person("bridge@parity.example").x25519Public)
            let composer = Composer(
                host: client, account: alice, deviceID: deviceID, contacts: contacts, sent: sent,
                legacyRoute: s.input.legacy_route ? route : nil)

            let content = DraftContent(
                from: s.input.from, to: s.input.to, cc: s.input.cc, bcc: s.input.bcc,
                pending: DraftPending(to: s.input.pending.to, cc: s.input.pending.cc, bcc: s.input.pending.bcc),
                subject: s.input.subject, text: s.input.text,
                replyTo: s.input.reply_to.map {
                    ComposeReplyTo(to: $0.to, subject: $0.subject, replyToId: $0.replyToId, threadId: $0.threadId)
                }, attachments: s.input.attachments.map(\.value))

            var report: SentReport?
            var failure: (any Error)?
            do {
                report = try await composer.send(content)
            } catch {
                failure = error
            }

            // Lookups all happen first here, so a lookup failure stops what the browser would have
            // half delivered. No scenario below differs by it: each fails on its first recipient.
            let posts = await host.posts
            #expect(posts.map(\.recipient) == s.expected.posts.map(\.recipient_address), "\(s.name)")
            #expect(posts.map(\.onion) == s.expected.posts.map(\.onion), "\(s.name)")
            for (post, expected) in zip(posts, s.expected.posts) {
                #expect(post.fields.keys.sorted() == expected.fields, "\(s.name)")
                #expect(post.fields.string("sender_address") == expected.sender_address, "\(s.name)")
                let keys = try f.person(expected.sealed_to)
                #expect(post.envelope.recipients.map(\.recipientXPub) == [keys.x25519Public], "\(s.name)")
                try expectCopy(post.envelope, expected.copy, keys: keys, s.name)
            }

            // One compose, one message id, whatever route each copy took.
            let ids = Set(posts.compactMap { $0.fields.string("message_id") })
            #expect(ids.count <= 1, "\(s.name)")
            if let id = ids.first { #expect(posts[0].envelope.messageID.hex == id, "\(s.name)") }

            let deliveries = await route.deliveries
            #expect(deliveries.map(\.recipient) == s.expected.legacy.map(\.recipient), "\(s.name)")
            for (delivery, expected) in zip(deliveries, s.expected.legacy) {
                #expect(delivery.senderAddress == expected.sender_address, "\(s.name)")
                let env = try Dmcn_Message_EncryptedEnvelope(serializedBytes: delivery.bytes)
                try expectCopy(env, expected.copy, keys: try f.person("bridge@parity.example"), s.name)
            }

            if let error = s.expected.error, error.hasPrefix("This message reached") {
                // Reached some and not others: no error, a report of who has it, and the draft kept.
                let got = try #require(report, "\(s.name) should have reported")
                let text = PartialSend.message(delivered: got.delivered, undelivered: got.undelivered)
                #expect(text == error, "\(s.name)")
            } else if let error = s.expected.error {
                let thrown = try #require(failure, "\(s.name) should have failed")
                // These two are the browser's own words. The rest of its errors are the server's,
                // which is why they aren't compared.
                if error == "Add at least one recipient." || error.contains("closed their account") {
                    let text = (thrown as? LocalizedError)?.errorDescription ?? ""
                    #expect(text.hasPrefix(error), "\(s.name)")
                }
                #expect(report == nil)
            } else {
                #expect(failure == nil, "\(s.name): \(String(describing: failure))")
            }

            if s.expected.error == nil {
                let items = try #require(report).items
                #expect(items.map(\.text) == (s.expected.report ?? []).map(\.text), "\(s.name)")
                #expect(items.map(\.saveContact?.address) == (s.expected.report ?? []).map(\.save_contact?.address))
                #expect(items.map(\.saveContact?.name) == (s.expected.report ?? []).map(\.save_contact?.name))
                #expect(try #require(report).keptInSent == !s.input.sent_fails, "\(s.name)")
            }

            let kept = try await storage.list(prefix: "sent/", as: StoredSentHeader.self)
            #expect(kept.count == (s.expected.sent_copy == nil ? 0 : 1), "\(s.name)")
            if let expected = s.expected.sent_copy, let row = kept.first {
                let header = try row.value.open(with: alice)
                let body = try #require(
                    try await storage.get(
                        "sent-body/" + header.header.messageID.hex, as: StoredSentBody.self))
                let content = try SplitMessage.openBody(body.value.mailboxBody, of: header)
                #expect(header.header.recipientAddress == expected.copy.recipient_address, "\(s.name)")
                #expect(header.header.to == expected.copy.to, "\(s.name)")
                #expect(header.header.cc == expected.copy.cc, "\(s.name)")
                #expect(header.header.bcc == expected.copy.bcc, "\(s.name)")
                #expect(content.attachments.map(\.filename) == expected.copy.attachments, "\(s.name)")
                #expect(
                    header.header.messageID.hex == (posts.first?.envelope.messageID.hex ?? header.header.messageID.hex))
            }
        }
    }

    /// A browser-sealed empty message opens here even though the browser can't verify its own. This
    /// is the case that shows up as `browser_verifies: false`, and it must stay the only one.
    @Test func onlyTheEmptyMessageFailsTheBrowsersOwnCheck() throws {
        let f = try Fixture.load()
        let failing = f.scenarios.filter { s in s.expected.posts.contains { !$0.copy.browser_verifies } }
        #expect(failing.map(\.name) == ["empty message"])
    }

    @Test func threadsContinueOrStartFresh() async throws {
        let f = try Fixture.load()
        let kept = try #require(f.scenarios.first { $0.name == "reply keeps the thread" })
        #expect(kept.expected.posts[0].copy.thread_id == String(repeating: "61", count: 16))
        let fresh = try #require(f.scenarios.first { $0.name == "reply to a message with no thread" })
        #expect(fresh.expected.posts[0].copy.thread_id != String(repeating: "00", count: 16))
        #expect(fresh.expected.posts[0].copy.reply_to_id == String(repeating: "52", count: 16))

        let alice = try f.alice()
        let host = ComposeHost(
            sender: alice.ed25519Public,
            directory: fresh.input.directory.mapValues { .init(status: $0.status, body: $0.body) })
        let client = WebHostClient(baseURL: URL(string: "https://host.example")!, transport: host)
        try await client.signIn(alice)
        let composer = Composer(
            host: client, account: alice, deviceID: fill(16, 1),
            contacts: ContactStore(
                storage: InMemoryPersonalStorage(), pins: InMemoryPersonalStorage(), owner: alice.address,
                deviceID: fill(16, 1)), sent: SentStore(storage: InMemoryPersonalStorage(), keys: alice))
        for (thread, expected) in [
            (String(repeating: "61", count: 16), Data?.some(fill(16, 0x61))),
            (String(repeating: "00", count: 16), nil), ("", nil),
        ] {
            try await composer.send(
                DraftContent(
                    from: "", to: ["bob@parity.example"],
                    replyTo: ComposeReplyTo(
                        to: [], subject: "", replyToId: String(repeating: "52", count: 16), threadId: thread)))
            let post = try #require(await host.posts.last)
            let (header, _) = try opened(post.envelope, keys: try f.person("bob@parity.example"))
            if let expected {
                #expect(header.header.threadID == expected)
            } else {
                #expect(header.header.threadID.count == 16)
                #expect(header.header.threadID != Data(count: 16))
            }
            #expect(header.header.replyToID == fill(16, 0x52))
        }
    }
}

@Suite struct BrowserReplyVectors {
    private let enUS = Locale(identifier: "en_US")
    private let utc = TimeZone(identifier: "UTC")!

    @Test func replies() throws {
        for c in try Fixture.load().replies {
            let o = c.original
            let original = ReplyOriginal(
                senderAddress: o.sender, to: o.to, cc: o.cc, subject: o.subject, messageID: o.message_id,
                threadID: o.thread_id, sentAt: o.sent_at, bodyText: o.body)
            let reply = ComposeReplies.reply(
                to: original, all: c.all, me: c.me, senderName: c.contact_name, locale: enUS, timeZone: utc)
            #expect(reply.to == c.expected.to, "\(c.name)")
            #expect(reply.cc ?? [] == c.expected.cc, "\(c.name)")
            #expect(reply.subject == c.expected.subject, "\(c.name)")
            #expect(reply.quote == c.expected.quote, "\(c.name)")
            #expect(reply.replyToId == c.expected.reply_to_id, "\(c.name)")
            #expect(reply.threadId == c.expected.thread_id, "\(c.name)")
            #expect(reply.sentTo == c.expected.sent_to, "\(c.name)")
        }
    }

    @Test func startingText() throws {
        for c in try Fixture.load().scaffolds {
            #expect(
                ComposeReplies.startingText(signature: c.signature, isReply: c.is_reply, quote: c.quote) == c.expected)
        }
    }

    @Test func committingARecipient() throws {
        for c in try Fixture.load().pending {
            #expect(Composer.committing(c.pending, into: c.values) == c.expected, "\(c.pending)")
        }
    }

    @Test func userAttachments() throws {
        for c in try Fixture.load().user_attachments {
            let records = c.all.map {
                var r = Dmcn_Message_AttachmentRecord()
                r.contentType = $0.contentType
                r.filename = $0.filename
                return r
            }
            #expect(ComposeReplies.userAttachments(records).map(\.filename) == c.expected)
        }
    }
}

@Suite struct BrowserPinVectors {
    private let enUS = Locale(identifier: "en_US")
    private let utc = TimeZone(identifier: "UTC")!

    @Test func verdicts() throws {
        for c in try Fixture.load().pins {
            let contact = c.contact.map {
                ContactRecord(
                    address: "p@x", name: "", fingerprint: "", ed25519Pub: $0.ed25519Pub, x25519Pub: $0.x25519Pub,
                    adminKeyCustody: $0.adminKeyCustody, noIdentity: $0.noIdentity)
            }
            let verdict: ComposePin.Verdict =
                switch c.verdict {
                case "unpinned": .unpinned
                case "match": .match
                case "changed": .changed
                default: .recordChanged
                }
            #expect(ComposePin.check(contact, observed: c.observed) == verdict, "\(c)")
            if let pinned = contact?.pinnedFacts, let observed = c.observed {
                #expect(ComposePin.changedFacts(pinned: pinned, observed: observed) == c.changed, "\(c)")
            }
        }
    }

    @Test func factsFromADirectoryAnswer() throws {
        for c in try Fixture.load().directory_facts {
            let lookup = RecipientLookup(
                address: "p@x", ed25519Pub: c.answer.ed25519_pub, x25519Pub: c.answer.x25519_pub,
                legacy: c.answer.legacy ?? false, adminKeyCustody: c.answer.admin_key_custody ?? false)
            #expect(ComposePin.facts(from: lookup) == c.facts)
        }
    }

    @Test func theWordsMatch() throws {
        let w = try Fixture.load().warnings
        let at: Int64 = 1_788_430_860
        func warn(_ change: ComposePin.KeyChange?) -> String {
            ComposePin.keyWarning("p@x", change: change, locale: enUS, timeZone: utc)
        }
        #expect(warn(nil) == w.plain)
        #expect(warn(.unexplained) == w.unexplained)
        #expect(warn(.replaced(at: at)) == w.replaced)
        #expect(warn(.recovered(at: at)) == w.recovered)
        #expect(warn(.reportedStolen(at: at)) == w.stolen)
        #expect(ComposePin.identityGoneWarning("p@x") == w.gone)
    }
}

@Suite struct BrowserForwardingVectors {
    @Test func plans() throws {
        for c in try Fixture.load().forward_plans {
            let plan = ComposeForwarding.plan(
                forwards: c.forwards.map { ($0.address, $0.forwardTo) }, recipients: c.recipients, sender: c.sender)
            #expect(plan.map(\.forAddress) == c.expected.map(\.forAddr))
            #expect(plan.map(\.target) == c.expected.map(\.target))
        }
    }

    @Test func theWordsMatch() throws {
        let w = try Fixture.load().forward_words
        #expect(ComposeForwarding.notice("a@x", target: "f@y", kind: .identity) == w.dmcn)
        #expect(ComposeForwarding.notice("a@x", target: "f@y", kind: .email) == w.email)
        #expect(ComposeForwarding.notice("a@x", target: "f@y", kind: .unknown) == w.unknown)
        #expect(ComposeForwarding.unsendableNotice("a@x", target: "f@y") == w.unsendable)
        #expect(ComposeForwarding.forwardedOnlyMessage("a@x", target: "f@y") == w.only)
        #expect(ComposeForwarding.forwardFailedMessage("a@x", target: "f@y") == w.failed)
        #expect(ComposeForwarding.forwardOnlyFailedMessage("a@x", target: "f@y") == w.only_failed)
        #expect(ComposeError.accountClosed("a@x").errorDescription == w.closed)
    }
}

@Suite struct ComposeInteropOut {
    /// What the kit sealed and sent, for the browser's code to open. Skipped unless asked for.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["DMCN_COMPOSE_INTEROP_OUT"] != nil))
    func writeForTheBrowser() async throws {
        let f = try Fixture.load()
        let alice = try f.alice()
        let bob = try f.person("bob@parity.example")
        let deviceID = unhex(f.sender.device_id)

        var seals: [JSONValue] = []
        for seal in f.seals {
            let env = try SplitMessage.seal(seal.draft, from: alice, to: [.init(x25519Public: bob.x25519Public)])
            seals.append(
                .object([
                    "name": .string(seal.name),
                    "envelope": .string(try Canonical.marshal(env).hex),
                    "entry": .string(try Canonical.marshal(Dmcn_Relay_MailboxEntry(filing: env)).hex),
                    "body": .string(try Canonical.marshal(Dmcn_Relay_MailboxBody(filing: env)).hex),
                ]))
        }

        let cy = try f.person("cy@parity.example")
        func answer(_ keys: SoftwareAccountKeys) -> ComposeHost.Answer {
            .init(
                status: 200,
                body: [
                    "address": .string(keys.address), "ed25519_pub": .string(keys.ed25519Public.base64EncodedString()),
                    "x25519_pub": .string(keys.x25519Public.base64EncodedString()),
                ])
        }
        let host = ComposeHost(
            sender: alice.ed25519Public, directory: [bob.address: answer(bob), cy.address: answer(cy)])
        let client = WebHostClient(baseURL: URL(string: "https://host.example")!, transport: host)
        try await client.signIn(alice)
        await host.store.use(directoryKey: alice.ed25519Public)
        let store = PersonalStore(client: client, keys: alice, localDirectory: temporaryDirectory())
        let composer = Composer(
            host: client, account: alice, deviceID: deviceID,
            contacts: ContactStore(
                storage: InMemoryPersonalStorage(), pins: InMemoryPersonalStorage(), owner: alice.address,
                deviceID: deviceID), sent: SentStore(storage: store, keys: alice))
        let file = try ComposeAttachments.adding(
            [.init(name: "notes ✓.txt", contentType: "text/plain", content: Data("hello".utf8))], to: [])
        let inline = try ComposeAttachments.addingInlineImage(
            .init(name: "", contentType: "image/png", content: Data([1, 2, 3])), to: file)
        try await composer.send(
            DraftContent(
                from: "", to: [bob.address], cc: [], bcc: [cy.address], subject: "Sent from Swift ✓",
                text: "Plain first ✓\n\n" + String(repeating: "é", count: 80), attachments: inline.attachments),
            sanitizedHTML: "<p>Rich ✓<img src=\"cid:\(inline.contentID)\"></p>")

        var posts: [JSONValue] = []
        for post in await host.posts {
            posts.append(
                .object([
                    "fields": .object(post.fields),
                    "entry": .string(try Canonical.marshal(Dmcn_Relay_MailboxEntry(filing: post.envelope)).hex),
                    "body": .string(try Canonical.marshal(Dmcn_Relay_MailboxBody(filing: post.envelope)).hex),
                ]))
        }
        let out: [String: JSONValue] = [
            "seals": .array(seals),
            "posts": .array(posts),
            "inline_content_id": .string(inline.contentID),
            "kv": .object(
                await host.store.kv.mapValues {
                    .object(["sealed": .string($0.sealed), "version": .int(Int64($0.version))])
                }),
        ]
        let path = try #require(ProcessInfo.processInfo.environment["DMCN_COMPOSE_INTEROP_OUT"])
        try StoreJSON.encode(out).write(to: URL(fileURLWithPath: path))
    }
}
