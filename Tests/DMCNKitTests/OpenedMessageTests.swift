import Foundation
import Testing
@testable import DMCNKit

// Fixtures/browser-trust.json's bodies were sealed by the browser's real primitives and opened by its
// real decryptBody: `expected` is what that returned. Here they're opened from the same wire bytes.

private struct Doc: Decodable {
    struct Owner: Decodable { let x_priv: String; let ed_seed: String }
    struct Attachment: Decodable {
        let filename: String; let contentType: String; let content: String; let contentId: String;
        let disposition: String
    }
    struct Expected: Decodable {
        let bodyText: String
        let htmlBody: String?
        let attachments: [Attachment]
        let user: [String]
        let original: Int
    }
    struct Body: Decodable { let name: String; let entry: String; let body: String; let expected: Expected }
    let owner: Owner
    let bodies: [Body]
}

private let doc: Result<Doc, any Error> = Result { try fixture("browser-trust") }

private func keys(_ d: Doc) throws -> SoftwareAccountKeys {
    try SoftwareAccountKeys(
        address: "me@parity.example", ed25519Seed: try #require(Data(base64Encoded: d.owner.ed_seed)),
        x25519Private: try #require(Data(base64Encoded: d.owner.x_priv)))
}

private func open(_ c: Doc.Body, _ keys: SoftwareAccountKeys) throws -> OpenedMessage {
    let entry = try Dmcn_Relay_MailboxEntry(serializedBytes: try #require(Data(base64Encoded: c.entry)))
    let body = try Dmcn_Relay_MailboxBody(serializedBytes: try #require(Data(base64Encoded: c.body)))
    return try OpenedMessage(body: body, header: try SplitMessage.openHeader(entry, keys: keys))
}

@Suite struct OpenedMessageAgainstTheBrowser {
    @Test func opensWhatTheBrowserOpens() throws {
        let d = try doc.get()
        let keys = try keys(d)
        #expect(d.bodies.count == 15)
        for c in d.bodies {
            let got = try open(c, keys)
            #expect(
                got.bodyText.unicodeScalars.elementsEqual(c.expected.bodyText.unicodeScalars),
                "\(c.name): \(got.bodyText.debugDescription)")
            #expect(
                got.html?.unicodeScalars.elementsEqual((c.expected.htmlBody ?? "").unicodeScalars)
                    ?? (c.expected.htmlBody == nil), "\(c.name)")
            #expect(got.attachments.count == c.expected.attachments.count, "\(c.name)")
            for (mine, theirs) in zip(got.attachments, c.expected.attachments) {
                #expect(mine.filename == theirs.filename)
                #expect(mine.contentType == theirs.contentType)
                #expect(mine.content == Data(base64Encoded: theirs.content))
                #expect(mine.contentID == theirs.contentId)
                #expect(mine.disposition == theirs.disposition)
            }
            #expect(got.userAttachments.map(\.filename) == c.expected.user, "\(c.name)")
            #expect((got.bridgeOriginal != nil) == (c.expected.original >= 0), "\(c.name)")
        }
    }

    @Test func sortsAttachmentsTheWayTheReaderDoes() throws {
        let d = try doc.get()
        let got = try open(try #require(d.bodies.first { $0.name == "attachments" }), try keys(d))
        // Inline parts stay out of the download list. Only one with a Content-ID can be referenced.
        #expect(got.downloads.map(\.filename) == ["fwd.eml", "deck.pdf", "att.png"])
        #expect(got.inlineImages.map(\.contentID) == ["logo"])
        #expect(got.inlineImages.first?.data == fill(5, 0xAB))
        #expect(got.bridgeOriginal?.filename == "original.eml")
        #expect(got.sourcePreview == "From: a\n\nraw" || got.sourcePreview == "From: a\r\n\r\nraw")
    }

    @Test func aBodyTheHeaderDidntCommitToIsRefused() throws {
        let d = try doc.get()
        let keys = try keys(d)
        let one = d.bodies[0]
        let entry = try Dmcn_Relay_MailboxEntry(serializedBytes: try #require(Data(base64Encoded: one.entry)))
        let other = try Dmcn_Relay_MailboxBody(serializedBytes: try #require(Data(base64Encoded: d.bodies[1].body)))
        #expect(throws: (any Error).self) {
            try OpenedMessage(body: other, header: try SplitMessage.openHeader(entry, keys: keys))
        }
    }

    @Test func aSourcePreviewStopsAtItsLimit() {
        var content = Dmcn_Message_MessageContent()
        content.body.contentType = "text/plain"
        var classification = Dmcn_Message_AttachmentRecord()
        classification.contentType = BridgeRecord.classificationContentType
        var original = Dmcn_Message_AttachmentRecord()
        original.contentType = "message/rfc822"
        original.filename = "original.eml"
        original.content = fill(OpenedMessage.sourcePreviewBytes + 10, 0x61)
        content.attachments = [classification, original]
        #expect(OpenedMessage(content: content).sourcePreview?.utf8.count == OpenedMessage.sourcePreviewBytes)
    }
}

/// `Inbox.open` refuses to fetch a withheld body, so this mustn't be a way around it.
@Suite struct OpeningThroughTheInbox {
    actor Counter {
        var bodies = 0
        func bump() { bodies += 1 }
    }

    struct Service: MailboxService {
        let entry: Dmcn_Relay_MailboxEntry
        let body: Dmcn_Relay_MailboxBody
        let directory: IdentityLookup?
        let counter = Counter()

        func list(_ keys: some AccountKeys, limit: Int, cursor: String?) async throws -> MailboxPage {
            MailboxPage(items: [.init(hash: "h", entry: entry)], nextCursor: nil)
        }
        func body(hash: String, keys: some AccountKeys) async throws -> Dmcn_Relay_MailboxBody {
            await counter.bump()
            return body
        }
        func lookup(_ address: String) async throws -> IdentityLookup {
            guard let directory else { throw APIError(status: 404, message: "not found") }
            return directory
        }
        func signOut() async {}
    }

    fileprivate func service(_ d: Doc, directory: IdentityLookup?) throws -> Service {
        let c = d.bodies[0]
        return Service(
            entry: try Dmcn_Relay_MailboxEntry(serializedBytes: try #require(Data(base64Encoded: c.entry))),
            body: try Dmcn_Relay_MailboxBody(serializedBytes: try #require(Data(base64Encoded: c.body))),
            directory: directory)
    }

    @Test func aMismatchedSenderIsNeverFetched() async throws {
        let d = try doc.get()
        let keys = try keys(d)
        let lookup = IdentityLookup(
            address: "ada@parity.example", ed25519Public: fill(32, 0x01), x25519Public: fill(32, 0x02))
        let service = try service(d, directory: lookup)
        let inbox = Inbox(service: service, keys: keys)
        let row = try #require(try await inbox.summaries().summaries.first)
        #expect(row.contentsWithheld)
        #expect(try await inbox.openMessage(row) == nil)
        #expect(await service.counter.bodies == 0)
        #expect(row.senderDisplay == nil)
    }

    @Test func anUnresolvedSenderOpens() async throws {
        let d = try doc.get()
        let service = try service(d, directory: nil)
        let inbox = Inbox(service: service, keys: try keys(d))
        let row = try #require(try await inbox.summaries().summaries.first)
        #expect(!row.contentsWithheld)
        #expect(row.senderPublicKey?.count == 32)
        let opened = try #require(try await inbox.openMessage(row))
        #expect(opened.bodyText == d.bodies[0].expected.bodyText)
        #expect(await service.counter.bodies == 1)
    }
}
