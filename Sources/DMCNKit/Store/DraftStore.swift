import Foundation

// The messages being written, so closing the composer or a second device never costs someone what
// they were halfway through. Parity with the browser's lib/api/draftStore.ts. Three namespaces, so
// what a list needs doesn't drag along what only an open draft needs:
//
//     drafts/<id>             the row: who it is to, the subject, a snippet, when it was saved
//     draft-body/<id>         the text and HTML, the reply it answers, half-typed recipients
//     draft-att/<id>/<attId>  one record per attachment, written once when added
//
// The split is what makes saving every few seconds affordable: a keystroke rewrites the row and the
// body, never the attachments beside them.
//
// Two devices editing one draft is settled by compare-and-swap, never by merging. Each save names
// the versions it last saw, and one that finds something newer stops and throws
// `DraftConflictError`, so the composer can ask which copy to keep.

/// Attachment bytes and what's known about them.
public struct DraftAttachment: Codable, Sendable, Equatable {
    /// 16 bytes.
    public var attachmentID: Data
    public var filename: String
    public var contentType: String
    public var sizeBytes: Int
    /// 32 bytes, SHA-256 of `content`.
    public var contentHash: Data
    public var content: Data
    /// On parts embedded in the HTML: the bare Content-ID the body refers to with `cid:`.
    public var contentID: String?
    public var disposition: String?

    public init(
        attachmentID: Data, filename: String, contentType: String, sizeBytes: Int, contentHash: Data, content: Data,
        contentID: String? = nil, disposition: String? = nil
    ) {
        self.attachmentID = attachmentID
        self.filename = filename
        self.contentType = contentType
        self.sizeBytes = sizeBytes
        self.contentHash = contentHash
        self.content = content
        self.contentID = contentID
        self.disposition = disposition
    }
}

/// What the reader hands the composer to open a reply, kept with the draft.
public struct ComposeReplyTo: Codable, Sendable, Equatable {
    public var to: [String]
    public var cc: [String]?
    /// The raw subject; the `Re:` is the composer's.
    public var subject: String
    /// The addresses the original was sent to. A reply goes out as whichever of these is ours.
    public var sentTo: [String]?
    public var quote: String?
    public var quoteHtml: String?
    /// Hex: the original's message id, and the thread to continue.
    public var replyToId: String?
    public var threadId: String?

    public init(
        to: [String], cc: [String]? = nil, subject: String, sentTo: [String]? = nil, quote: String? = nil,
        quoteHtml: String? = nil, replyToId: String? = nil, threadId: String? = nil
    ) {
        self.to = to
        self.cc = cc
        self.subject = subject
        self.sentTo = sentTo
        self.quote = quote
        self.quoteHtml = quoteHtml
        self.replyToId = replyToId
        self.threadId = threadId
    }
}

/// Text typed into a recipient field but not yet turned into a chip.
public struct DraftPending: Codable, Sendable, Equatable {
    public var to: String
    public var cc: String
    public var bcc: String

    public init(to: String = "", cc: String = "", bcc: String = "") {
        self.to = to
        self.cc = cc
        self.bcc = bcc
    }
}

/// Everything the composer needs to put a draft back the way it was left.
public struct DraftContent: Codable, Sendable, Equatable {
    public var from: String
    public var to: [String]
    public var cc: [String]
    public var bcc: [String]
    public var pending: DraftPending
    public var showCcBcc: Bool
    public var subject: String
    public var rich: Bool
    /// The plain-text body; in rich mode, the text rendering of `html`.
    public var text: String
    /// The editor's HTML with inline images as `cid:` references; empty in plain mode.
    public var html: String
    public var replyTo: ComposeReplyTo?
    public var attachments: [DraftAttachment]

    public init(
        from: String, to: [String] = [], cc: [String] = [], bcc: [String] = [], pending: DraftPending = DraftPending(),
        showCcBcc: Bool = false, subject: String = "", rich: Bool = false, text: String = "", html: String = "",
        replyTo: ComposeReplyTo? = nil, attachments: [DraftAttachment] = []
    ) {
        self.from = from
        self.to = to
        self.cc = cc
        self.bcc = bcc
        self.pending = pending
        self.showCcBcc = showCcBcc
        self.subject = subject
        self.rich = rich
        self.text = text
        self.html = html
        self.replyTo = replyTo
        self.attachments = attachments
    }
}

/// A Drafts list row.
public struct DraftSummary: Sendable, Equatable {
    public let id: String
    public let from: String
    public let to: [String]
    public let cc: [String]
    public let bcc: [String]
    public let subject: String
    public let snippet: String
    /// Unix ms.
    public let updatedAt: Int64
    public let attachmentCount: Int
}

/// The storage versions a save was based on (0 means not stored yet), and which attachments are
/// stored.
public struct DraftBase: Codable, Sendable, Equatable {
    public var head: Int
    public var body: Int
    public var atts: [String]

    public init(head: Int = 0, body: Int = 0, atts: [String] = []) {
        self.head = head
        self.body = body
        self.atts = atts
    }

    public static let new = DraftBase()
}

public struct LoadedDraft: Sendable, Equatable {
    public let id: String
    public let content: DraftContent
    public let base: DraftBase
    public let updatedAt: Int64
}

/// A save found the draft changed, or gone, on another device since it was opened here.
public struct DraftConflictError: Error, Equatable, Sendable {
    public init() {}
}

extension DraftConflictError: LocalizedError {
    public var errorDescription: String? { "This draft was changed on another device." }
}

/// This device's copy of a draft the relay doesn't have yet.
public struct LocalDraft: Codable, Sendable, Equatable {
    public var id: String
    public var content: DraftContent
    public var base: DraftBase
    public var updatedAt: Int64

    public init(id: String, content: DraftContent, base: DraftBase, updatedAt: Int64) {
        self.id = id
        self.content = content
        self.base = base
        self.updatedAt = updatedAt
    }
}

/// Where this device keeps drafts the relay doesn't have yet: the cover for a dropped network, or an
/// app closed in the seconds before a save. The kit ships none; hand one to `DraftStore`, or leave it
/// out to keep nothing on the device.
public protocol DraftBackstop: Sendable {
    func get(_ key: String) async throws -> LocalDraft?
    func put(_ key: String, _ value: LocalDraft) async throws
    func delete(_ key: String) async throws
    func entries(prefix: String) async throws -> [(key: String, value: LocalDraft)]
}

private struct StoredAttachment: Codable, Sendable {
    var id: String
    var filename: String
    var contentType: String
    var sizeBytes: Int
    /// Base64.
    var contentHash: Data
    var contentId: String?
    var disposition: String?

    init(_ a: DraftAttachment) {
        id = a.attachmentID.hex
        filename = a.filename
        contentType = a.contentType
        sizeBytes = a.sizeBytes
        contentHash = a.contentHash
        contentId = (a.contentID ?? "").isEmpty ? nil : a.contentID
        disposition = (a.disposition ?? "").isEmpty ? nil : a.disposition
    }
}

private struct StoredHead: Codable, Sendable {
    var v = 1
    var from: String
    var to: [String]
    var cc: [String]
    var bcc: [String]
    var subject: String
    var snippet: String
    var updatedAt: Int64
    var attachments: [StoredAttachment]
}

private struct StoredBody: Codable, Sendable {
    var v = 1
    var pending: DraftPending
    var showCcBcc: Bool
    var rich: Bool
    var text: String
    var html: String
    var replyTo: ComposeReplyTo?

    enum CodingKeys: String, CodingKey {
        case v, pending, showCcBcc, rich, text, html, replyTo
    }

    init(_ content: DraftContent) {
        pending = content.pending
        showCcBcc = content.showCcBcc
        rich = content.rich
        text = content.text
        html = content.html
        replyTo = content.replyTo
    }

    // `replyTo` is the one field the browser writes as an explicit null rather than leaving out.
    func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(v, forKey: .v)
        try c.encode(pending, forKey: .pending)
        try c.encode(showCcBcc, forKey: .showCcBcc)
        try c.encode(rich, forKey: .rich)
        try c.encode(text, forKey: .text)
        try c.encode(html, forKey: .html)
        try c.encode(replyTo, forKey: .replyTo)
    }
}

private struct StoredBytes: Codable, Sendable {
    /// Base64.
    var content: Data
}

/// How long a device copy must sit untouched before the list uploads it on its own. Anything
/// younger may belong to a composer that is still open and will save it itself.
public let localDraftSettleMillis: Int64 = 60_000

/// The account's drafts.
public struct DraftStore: Sendable {
    private let storage: any PersonalStorage
    private let backstop: (any DraftBackstop)?
    private let prefix: String

    /// Whether this device keeps its own copy until the relay has it.
    public var keepsLocal: Bool { backstop != nil }

    public init(storage: any PersonalStorage, address: String, backstop: (any DraftBackstop)? = nil) {
        self.storage = storage
        self.backstop = backstop
        prefix = "draft::\(JSText.normalizedAddress(address))::"
    }

    private static func headKey(_ id: String) -> String { "drafts/" + id }
    private static func bodyKey(_ id: String) -> String { "draft-body/" + id }
    private static func attPrefix(_ id: String) -> String { "draft-att/\(id)/" }
    private static func attKey(_ id: String, _ attID: String) -> String { attPrefix(id) + attID }

    /// A fresh draft id: 16 random bytes, hex.
    public static func newID() -> String {
        Data((0..<16).map { _ in UInt8.random(in: 0...255) }).hex
    }

    private static let snippetChars = 140

    /// The row's preview line: the start of the text, whitespace folded.
    ///
    /// Counted in UTF-16 units, as the browser counts. It may cut an emoji in half there, leaving a
    /// lone surrogate no Swift string can hold, so here the half is dropped.
    public static func snippet(_ text: String) -> String {
        let flat = JSText.foldedWhitespace(text)
        let units = Array(flat.utf16)
        guard units.count > snippetChars else { return flat }
        var cut = Array(units[..<(snippetChars - 1)])
        if let last = cut.last, UTF16.isLeadSurrogate(last) { cut.removeLast() }
        return String(decoding: cut, as: UTF16.self) + "…"
    }

    /// The subject a reply starts with.
    public static func replySubject(_ subject: String) -> String {
        guard !subject.isEmpty else { return "" }
        var rest = Substring(subject)
        if rest.prefix(3).lowercased() == "re:" {
            rest = rest.dropFirst(3)
            let spaces = rest.unicodeScalars.prefix(while: JSText.isWhitespace).count
            rest = Substring(rest.unicodeScalars.dropFirst(spaces))
        }
        return "Re: " + rest
    }

    /// Whether a draft holds anything worth keeping. `untouchedText` is what the body starts as
    /// before anyone types (the signature, a reply's quote), so a composer opened and closed again
    /// leaves nothing behind. A reply's prefilled recipients count only once something else is written.
    public static func hasContent(_ c: DraftContent, untouchedText: String) -> Bool {
        let pending = !(JSText.trim(c.pending.to) + JSText.trim(c.pending.cc) + JSText.trim(c.pending.bcc)).isEmpty
        let typed = JSText.trim(c.text) != JSText.trim(untouchedText)
        if let reply = c.replyTo {
            let subjectChanged = JSText.trim(c.subject) != JSText.trim(replySubject(reply.subject))
            return typed || subjectChanged || !c.attachments.isEmpty || pending || !c.bcc.isEmpty
        }
        return typed || !JSText.trim(c.subject).isEmpty || !c.attachments.isEmpty || pending || !c.to.isEmpty
            || !c.cc.isEmpty || !c.bcc.isEmpty
    }

    /// The Drafts list: the relay's rows, with this device's newer copies in their place.
    public func list() async throws -> [DraftSummary] {
        var rows: [String: DraftSummary] = [:]
        for entry in try await storage.list(prefix: "drafts/", as: StoredHead.self) {
            let id = Self.id(fromKey: entry.key)
            let h = entry.value
            rows[id] = DraftSummary(
                id: id, from: h.from, to: h.to, cc: h.cc, bcc: h.bcc, subject: h.subject, snippet: h.snippet,
                updatedAt: h.updatedAt, attachmentCount: h.attachments.count)
        }
        for draft in await localDrafts() {
            let had = rows[draft.id]
            // A copy based on a stored row that has since gone was sent or discarded on another
            // device. That decision stands: the copy is dropped by `settleLocal`, not resurrected.
            if had == nil, draft.base.head > 0 { continue }
            if let had, had.updatedAt > draft.updatedAt { continue }
            let c = draft.content
            rows[draft.id] = DraftSummary(
                id: draft.id, from: c.from, to: c.to, cc: c.cc, bcc: c.bcc, subject: c.subject,
                snippet: Self.snippet(c.text), updatedAt: draft.updatedAt, attachmentCount: c.attachments.count)
        }
        return rows.values.sorted { $0.updatedAt > $1.updatedAt }
    }

    private static func id(fromKey key: String) -> String {
        key.firstIndex(of: "/").map { String(key[key.index(after: $0)...]) } ?? key
    }

    /// Opens a draft: this device's copy when it has one, else the relay's. Nil when it's gone.
    public func load(_ id: String) async throws -> LoadedDraft? {
        if let mine = try await backstop?.get(prefix + id) {
            return LoadedDraft(id: id, content: mine.content, base: mine.base, updatedAt: mine.updatedAt)
        }
        return try await loadStored(id)
    }

    private func loadStored(_ id: String) async throws -> LoadedDraft? {
        guard let head = try await storage.get(Self.headKey(id), as: StoredHead.self),
            let body = try await storage.get(Self.bodyKey(id), as: StoredBody.self)
        else { return nil }

        var attachments: [DraftAttachment] = []
        var atts: [String] = []
        for a in head.value.attachments {
            // A part that never made it up is left out rather than failing the draft: the rest is
            // the message, and the composer shows what is attached.
            guard let bytes = try await storage.get(Self.attKey(id, a.id), as: StoredBytes.self),
                let attachmentID = Data(hex: a.id)
            else { continue }
            atts.append(a.id)
            attachments.append(
                DraftAttachment(
                    attachmentID: attachmentID, filename: a.filename, contentType: a.contentType,
                    sizeBytes: a.sizeBytes, contentHash: a.contentHash, content: bytes.value.content,
                    contentID: a.contentId, disposition: a.disposition))
        }
        let h = head.value
        let b = body.value
        return LoadedDraft(
            id: id,
            content: DraftContent(
                from: h.from, to: h.to, cc: h.cc, bcc: h.bcc, pending: b.pending, showCcBcc: b.showCcBcc,
                subject: h.subject, rich: b.rich, text: b.text, html: b.html, replyTo: b.replyTo,
                attachments: attachments),
            base: DraftBase(head: head.version, body: body.version, atts: atts), updatedAt: h.updatedAt)
    }

    /// Whether the relay still holds the draft: after a conflict, changed elsewhere rather than sent
    /// or discarded there.
    public func isStored(_ id: String) async throws -> Bool {
        try await storage.get(Self.headKey(id), as: JSONValue.self) != nil
    }

    /// Keeps the latest state on this device until the relay has it. Does nothing without a backstop.
    public func saveLocal(_ id: String, content: DraftContent, base: DraftBase, updatedAt: Int64) async throws {
        try await backstop?.put(
            prefix + id, LocalDraft(id: id, content: content, base: base, updatedAt: updatedAt))
    }

    /// Drops this device's copy, unless a newer state has been written there since `updatedAt`.
    public func clearLocal(_ id: String, updatedAt: Int64? = nil) async throws {
        guard let backstop else { return }
        if let updatedAt, let current = try await backstop.get(prefix + id), current.updatedAt > updatedAt { return }
        try await backstop.delete(prefix + id)
    }

    /// Stores a draft on the relay and returns the versions it is now at.
    ///
    /// Attachments first, then the body, then the row: the row is what makes a draft appear in the
    /// list, so it is written last and never points at a body that isn't there. The body and row are
    /// compare-and-swap against `base`, so a save that would overwrite another device's newer copy
    /// throws `DraftConflictError`; `force` overwrites, for "keep this copy".
    @discardableResult
    public func save(
        _ id: String, content: DraftContent, base: DraftBase, updatedAt: Int64, force: Bool = false
    ) async throws -> DraftBase {
        var stored = base.atts
        for attachment in content.attachments {
            let attID = attachment.attachmentID.hex
            if stored.contains(attID) { continue }
            try await storage.put(Self.attKey(id, attID), StoredBytes(content: attachment.content))
            stored.append(attID)
        }

        let head = StoredHead(
            from: content.from, to: content.to, cc: content.cc, bcc: content.bcc, subject: content.subject,
            snippet: Self.snippet(content.text), updatedAt: updatedAt,
            attachments: content.attachments.map(StoredAttachment.init))
        let bodyVersion: Int
        let headVersion: Int
        do {
            bodyVersion = try await storage.put(
                Self.bodyKey(id), StoredBody(content), expectedVersion: force ? 0 : base.body)
            headVersion = try await storage.put(Self.headKey(id), head, expectedVersion: force ? 0 : base.head)
        } catch is StorageConflictError {
            throw DraftConflictError()
        }

        // Parts taken out of the message since the last save. After the row, so a row never names a
        // part already deleted; a failure only leaves an orphan the next save retries.
        let wanted = Set(content.attachments.map(\.attachmentID.hex))
        for attID in stored where !wanted.contains(attID) {
            if (try? await storage.delete(Self.attKey(id, attID))) != nil {
                stored.removeAll { $0 == attID }
            }
        }
        return DraftBase(head: headVersion, body: bodyVersion, atts: stored)
    }

    /// Removes a draft everywhere: sent, or discarded. The row goes first, so it leaves the list at
    /// once.
    public func delete(_ id: String) async throws {
        try await clearLocal(id)
        try await storage.delete(Self.headKey(id))
        try await storage.delete(Self.bodyKey(id))
        for item in try await storage.listKeys(prefix: Self.attPrefix(id)) {
            try await storage.delete(item.key)
        }
    }

    /// Uploads what this device kept and no composer is going to save. Copies younger than
    /// `localDraftSettleMillis` are left to the composer that may own them, and a copy whose draft was
    /// removed elsewhere meanwhile is dropped. Returns whether anything changed.
    @discardableResult
    public func settleLocal(skip: Set<String> = [], now: Int64) async throws -> Bool {
        var changed = false
        for draft in await localDrafts() {
            if skip.contains(draft.id) || now - draft.updatedAt < localDraftSettleMillis { continue }
            do {
                try await save(draft.id, content: draft.content, base: draft.base, updatedAt: draft.updatedAt)
                try await clearLocal(draft.id, updatedAt: draft.updatedAt)
                changed = true
            } catch is DraftConflictError {
                // Otherwise both copies changed: kept and listed, and its next save asks which to keep.
                if draft.base.head > 0, try await !isStored(draft.id) {
                    try await clearLocal(draft.id, updatedAt: draft.updatedAt)
                    changed = true
                }
            } catch {
                continue  // offline, still: try again next time
            }
        }
        return changed
    }

    private func localDrafts() async -> [LocalDraft] {
        guard let backstop, let entries = try? await backstop.entries(prefix: prefix) else { return [] }
        return entries.map(\.value)
    }
}
