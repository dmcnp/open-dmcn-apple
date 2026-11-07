import Foundation

// A message's body as a reader holds it once it's open. Parity with FullBody in the browser's
// lib/api/mailboxRest.ts and decryptBody in lib/crypto/split.ts.

public struct OpenedMessage: Sendable {
    /// The text/plain rendering: what every client can read, and what the gated peek shows.
    public let bodyText: String
    /// The text/html rendering, when the message carries one.
    public let html: String?
    /// Whether there's HTML to show. An empty part is none.
    public var hasHTML: Bool { !(html ?? "").isEmpty }
    /// Every attachment, protocol records included. What the checks read.
    public let attachments: [MessageAttachment]
    /// What the sender attached: what a reader lists, inline parts included.
    public let userAttachments: [MessageAttachment]
    /// The attachments offered for download. Inline parts render inside the HTML instead.
    public let downloads: [MessageAttachment]
    /// The inline parts an HTML body can reference by `cid:`.
    public let inlineImages: [HTMLDocument.InlineImage]
    /// A bridged email's raw source as the bridge received it. Shown only through `sourcePreview`.
    public let bridgeOriginal: MessageAttachment?

    /// How much "View source" renders. A source can run to megabytes of base64, and the headers people
    /// open it for are at the top.
    public static let sourcePreviewBytes = 256 * 1024

    /// `internalTypes` are attachment types this build carries for its own purposes.
    public init(content: Dmcn_Message_MessageContent, internalTypes: [String] = []) {
        let parts = [content.body] + content.alternatives
        let htmlPart = parts.first { $0.contentType == "text/html" }
        let html = htmlPart.map { JSText.decodeUTF8($0.content) }
        self.html = html
        // A blank text part counts as absent. Campaign builders routinely emit multipart/alternative
        // with an empty text half, and the peek exists for a sender whose HTML won't be rendered, so
        // showing nothing, or the markup, there would be useless.
        let text = parts.first { $0.contentType == "text/plain" }.map { JSText.decodeUTF8($0.content) }
        if let text, !JSText.trim(text).isEmpty {
            bodyText = text
        } else if let html {
            bodyText = HTMLPlainText.render(html)
        } else {
            bodyText = text ?? JSText.decodeUTF8(content.body.content)
        }

        let all = content.attachments.map(MessageAttachment.init)
        attachments = all
        let user = UserAttachments.filter(all, internalTypes: internalTypes)
        userAttachments = user
        downloads = user.filter { !$0.isInline }
        inlineImages = user.filter { $0.isInline && !$0.contentID.isEmpty }.map {
            HTMLDocument.InlineImage(contentID: $0.contentID, contentType: $0.contentType, data: $0.content)
        }
        let original = BridgeRecord.originalIndex(
            contentTypes: all.map(\.contentType), filenames: all.map(\.filename))
        bridgeOriginal = original.map { all[$0] }
    }

    /// Opens a body against its verified header: the body hash and content address are checked there.
    public init(body: Dmcn_Relay_MailboxBody, header: OpenedHeader, internalTypes: [String] = []) throws {
        self.init(content: try SplitMessage.openBody(body, of: header), internalTypes: internalTypes)
    }

    /// The start of the bridge's raw source, as escaped-by-the-view text.
    public var sourcePreview: String? {
        bridgeOriginal.map { JSText.decodeUTF8($0.content.prefix(Self.sourcePreviewBytes)) }
    }
}

extension Inbox {
    /// Fetches and opens a message, or nil when the reader checks forbid it, without fetching anything.
    public func openMessage(_ message: MessageSummary, internalTypes: [String] = []) async throws -> OpenedMessage? {
        try await openContent(message).map { OpenedMessage(content: $0, internalTypes: internalTypes) }
    }

    /// The decrypted content itself, for what has to read its attachment records: a bridge's
    /// signed verdict rides among them. nil for a message the checks withhold, which isn't fetched.
    public func openContent(_ message: MessageSummary) async throws -> Dmcn_Message_MessageContent? {
        if message.contentsWithheld { return nil }
        return try await content(of: message.row)
    }
}

extension MessageSummary {
    /// The key that signed this message's verified header. nil on a row that didn't open.
    public var senderPublicKey: Data? {
        guard case .success(let opened) = row.opened else { return nil }
        return opened.header.senderPublicKey
    }

    /// The name the message carries for its sender: asserted, not verified, and nil while withheld.
    public var senderDisplay: String? {
        guard !attributionWithheld, case .success(let opened) = row.opened else { return nil }
        return opened.header.senderDisplay
    }
}
