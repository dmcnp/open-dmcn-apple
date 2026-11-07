import Foundation

/// What a mail list knows about one message: the browser's `Preview`, with the reader checks' verdict
/// beside it. Everything a list decides reads this, so a row and a search can't disagree with the
/// checks about what may be shown.
public struct MailPreview: Identifiable, Sendable {
    public var id: String { hash }
    public var hash: String
    /// Hex of the header's id, shared by every copy of one compose. Empty on copies from before ids.
    public var messageID: String
    public var threadID: String
    /// What the header claims. Attribution only when `sender` says so: see `attributedAddress`.
    public var senderAddress: String
    /// Hex of the key that signed the header.
    public var senderPublicKey: String
    public var recipientAddress: String
    public var to: [String]
    public var cc: [String]
    public var bcc: [String]
    public var subject: String
    /// Empty when the checks withhold the message.
    public var snippet: String
    /// Asserted, not verified, and blank when the name can't be shown as the sender's.
    public var senderDisplay: String
    /// Unix seconds. Zero for a row that wouldn't open.
    public var sentAt: Int64
    public var bodySize: UInt64
    public var attachmentCount: UInt32
    /// Which of the account's other addresses this copy was sealed to. Always nil in this build:
    /// the kit opens mail with the one account key. The row still shows it when a build sets it.
    public var deliveredTo: String?
    /// The reader checks' verdict on who sent it.
    public var sender: MessageSummary.Sender
    /// Every address in the signed audience names some other key.
    public var misaddressed: Bool
    /// What opens a received message. Nil for Sent, whose rows open through `SentStore`.
    public let summary: MessageSummary?

    /// Whether the checks forbid showing this message's body.
    public var contentsWithheld: Bool {
        switch sender {
        case .verified, .unverified, .disowned: false
        case .mismatch, .unreadable: true
        }
    }

    /// Whether the checks forbid treating the header's address as who this is from.
    public var attributionWithheld: Bool {
        switch sender {
        case .verified, .unverified: false
        case .mismatch, .disowned, .unreadable: true
        }
    }

    /// The sender address as far as the list may treat it as true: empty unless the checks allow
    /// it. A forged header claiming the owner's own address must not read as the owner's mail.
    public var attributedAddress: String {
        attributionWithheld ? "" : senderAddress
    }

    public init(
        hash: String, messageID: String = "", threadID: String = "", senderAddress: String,
        senderPublicKey: String = "", recipientAddress: String = "", to: [String] = [], cc: [String] = [],
        bcc: [String] = [], subject: String = "", snippet: String = "", senderDisplay: String = "",
        sentAt: Int64 = 0, bodySize: UInt64 = 0, attachmentCount: UInt32 = 0, deliveredTo: String? = nil,
        sender: MessageSummary.Sender? = nil, misaddressed: Bool = false
    ) {
        self.hash = hash
        self.messageID = messageID
        self.threadID = threadID
        self.senderAddress = senderAddress
        self.senderPublicKey = senderPublicKey
        self.recipientAddress = recipientAddress
        self.to = to
        self.cc = cc
        self.bcc = bcc
        self.subject = subject
        self.snippet = snippet
        self.senderDisplay = senderDisplay
        self.sentAt = sentAt
        self.bodySize = bodySize
        self.attachmentCount = attachmentCount
        self.deliveredTo = deliveredTo
        self.sender = sender ?? .verified(senderAddress)
        self.misaddressed = misaddressed
        summary = nil
    }

    /// A received message, from its header and the checks' verdict. The snippet comes from the
    /// summary, never the header, because the summary is what withheld it.
    public init(_ summary: MessageSummary) {
        self.summary = summary
        hash = summary.id
        sender = summary.sender
        misaddressed = summary.misaddressed
        snippet = summary.snippet
        subject = summary.subject
        deliveredTo = nil
        guard case .success(let opened) = summary.row.opened else {
            messageID = ""
            threadID = ""
            senderAddress = ""
            senderPublicKey = ""
            recipientAddress = ""
            to = []
            cc = []
            bcc = []
            senderDisplay = ""
            sentAt = 0
            bodySize = 0
            attachmentCount = 0
            return
        }
        let header = opened.header
        messageID = header.messageID.hex
        threadID = header.threadID.hex
        senderAddress = header.senderAddress
        senderPublicKey = header.senderPublicKey.hex
        recipientAddress = header.recipientAddress
        to = header.to
        cc = header.cc
        bcc = header.bcc
        senderDisplay = summary.attributionWithheld ? "" : header.senderDisplay
        sentAt = header.sentAt
        bodySize = header.bodySize
        attachmentCount = header.attachmentCount
    }

    /// A Sent row. Its header verified, but one not signed by this account could have been planted
    /// by whoever serves the store, so it reads as unconfirmed rather than as the owner's own word.
    public init(sent preview: SentPreview) {
        self.init(
            hash: preview.hash, messageID: preview.messageID, threadID: preview.threadID,
            senderAddress: preview.senderAddress, senderPublicKey: preview.senderPublicKey,
            recipientAddress: preview.recipientAddress, to: preview.to, cc: preview.cc, bcc: preview.bcc,
            subject: preview.subject, snippet: preview.snippet, senderDisplay: preview.senderDisplay,
            sentAt: preview.sentAt, bodySize: preview.bodySize, attachmentCount: preview.attachmentCount,
            sender: preview.signedByThisAccount ? .verified(preview.senderAddress) : .unverified(preview.senderAddress))
    }
}

/// A list wanted a message's body and the reader checks forbid it.
public struct ContentsWithheldError: Error, Equatable, Sendable {
    public init() {}
}

extension ContentsWithheldError: LocalizedError {
    public var errorDescription: String? { "This message can't be shown." }
}

extension Inbox {
    /// How many entries one listing asks for. The relay also caps a page by bytes, so this is an
    /// upper bound, set to make a large mailbox a few round trips rather than hundreds.
    public static let listPageSize = 500

    /// One page of the mailbox as the relay ordered it, every message checked.
    public func previews(limit: Int = 50, cursor: String? = nil) async throws -> (
        previews: [MailPreview], nextCursor: String?
    ) {
        let (summaries, nextCursor) = try await summaries(limit: limit, cursor: cursor)
        return (summaries.map(MailPreview.init), nextCursor)
    }

    /// The whole mailbox, newest first. A page that fails fails the listing, so a mailbox that
    /// didn't finish loading can't read as one that shrank. `onFirstPage` draws what a relay listing
    /// newest first has just handed over, without waiting for the rest; it only ever adds rows.
    public func allPreviews(
        pageSize: Int = Inbox.listPageSize, onFirstPage: (@Sendable ([MailPreview]) async -> Void)? = nil
    ) async throws -> [MailPreview] {
        let directory = DirectoryCache(service: service)
        var previews: [MailPreview] = []
        var cursor: String?
        var firstPage = true
        repeat {
            let (rows, next) = try await page(limit: pageSize, cursor: cursor)
            for row in rows {
                let summary = await MessageSummary(checking: row) { await directory.lookup($0) }
                previews.append(MailPreview(summary))
            }
            cursor = next
            if firstPage, next != nil { await onFirstPage?(MailView.newestFirst(previews)) }
            firstPage = false
        } while cursor != nil
        return MailView.newestFirst(previews)
    }

    /// Fetches and opens a message's body, unless the reader checks forbid showing it.
    public func open(_ message: MailPreview) async throws -> OpenedBody {
        guard let summary = message.summary else { return .withheld }
        return try await open(summary)
    }

    /// What search reads from a message. Refuses a withheld message without fetching it, like
    /// `open`: an index is another way of showing a body.
    public func searchBody(of message: MailPreview) async throws -> SearchBody {
        guard let summary = message.summary, !message.attributionWithheld else { throw ContentsWithheldError() }
        return SearchBody(try await content(of: summary.row))
    }
}
