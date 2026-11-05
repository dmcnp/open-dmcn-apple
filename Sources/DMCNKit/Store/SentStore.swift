import Foundation

// Sent keeps a self-copy of each message as the actual sealed split envelope, in the owner-only
// personal store. Because it is a normal envelope it opens with the same code as the inbox: the
// small header for the list row, the body on open, so attachments and HTML cost nothing until then.
// Two namespaces, "sent/" and "sent-body/", so listing Sent never pulls a body. Parity with the
// browser's lib/api/sentStore.ts. Its device-side list cache is a browser optimisation, left out.

/// One Sent row: the shape the inbox's rows have, from a verified header.
public struct SentPreview: Sendable, Equatable {
    /// `sent:<message id hex>`. Never collides with a mailbox hash.
    public let hash: String
    public let messageID: String
    public let threadID: String
    public let senderAddress: String
    public let senderPublicKey: String
    public let senderDisplay: String
    public let recipientAddress: String
    public let to: [String]
    public let cc: [String]
    public let bcc: [String]
    public let subject: String
    public let snippet: String
    /// Unix seconds.
    public let sentAt: Int64
    public let bodySize: UInt64
    public let attachmentCount: UInt32
    /// The header was signed with this account's key. Anyone can seal a value to a public key, so a
    /// relay could plant a row, and a verified signature says only that the key it names signed it.
    /// False for a message sent under another identity, too.
    public let signedByThisAccount: Bool
}

/// A Sent message, opened.
public struct SentMessage: Sendable {
    public let preview: SentPreview
    public let content: Dmcn_Message_MessageContent
    /// Hex of the message this answers, or nil when it answers nothing.
    public let replyToID: String?

    private var parts: [Dmcn_Message_MessageBody] { [content.body] + content.alternatives }
    public var bodyText: String? {
        parts.first { $0.contentType == "text/plain" }.map { String(decoding: $0.content, as: UTF8.self) }
    }
    public var htmlBody: String? {
        parts.first { $0.contentType == "text/html" }.map { String(decoding: $0.content, as: UTF8.self) }
    }
}

public struct SentNotFoundError: Error, Equatable, Sendable {
    public init() {}
}

extension SentNotFoundError: LocalizedError {
    public var errorDescription: String? { "This sent message is no longer here." }
}

/// The envelope's header half, bytes as base64 strings. A hand-written mirror of the wire entry, so
/// a field added to the wire is lost here unless it is added here too.
struct StoredSentHeader: Codable, Sendable {
    struct Recipient: Codable, Sendable {
        var recipientXPub: Data
        var ephemeralXPub: Data
        var wrappedCek: Data
        var cekNonce: Data
        var cekTag: Data
        /// The generation this slot was sealed with. The reader dispatches on it, and a row that
        /// lost it can only be opened by trying each one.
        var kdf: UInt32?
    }

    var recipients: [Recipient]
    var encryptedHeader: Data
    var headerNonce: Data
    var headerTag: Data

    init(_ env: Dmcn_Message_EncryptedEnvelope) {
        recipients = env.recipients.map {
            Recipient(
                recipientXPub: $0.recipientXPub, ephemeralXPub: $0.ephemeralXPub, wrappedCek: $0.wrappedCek,
                cekNonce: $0.cekNonce, cekTag: $0.cekTag, kdf: $0.kdf == 0 ? nil : $0.kdf)
        }
        encryptedHeader = env.encryptedHeader
        headerNonce = env.headerNonce
        headerTag = env.headerTag
    }

    func entry(generation: UInt32?) -> Dmcn_Relay_MailboxEntry {
        var entry = Dmcn_Relay_MailboxEntry()
        entry.recipients = recipients.map { r in
            var rec = Dmcn_Message_RecipientRecord()
            rec.recipientXPub = r.recipientXPub
            rec.ephemeralXPub = r.ephemeralXPub
            rec.wrappedCek = r.wrappedCek
            rec.cekNonce = r.cekNonce
            rec.cekTag = r.cekTag
            rec.kdf = generation ?? r.kdf ?? 0
            return rec
        }
        entry.encryptedHeader = encryptedHeader
        entry.headerNonce = headerNonce
        entry.headerTag = headerTag
        return entry
    }

    /// Opens the header. A row with no generation was written either by a client that sealed with
    /// the current one before this store kept the field, or by one predating it, and nothing in the
    /// row says which, so each is tried, newest first. Both attempts are authenticated, so a wrong
    /// guess fails rather than mis-decrypts.
    func open(with keys: some AccountKeys) throws -> OpenedHeader {
        let candidates: [UInt32?] =
            recipients.allSatisfy { $0.kdf != nil }
            ? [nil] : [SealGeneration.v2.rawValue, SealGeneration.v1.rawValue]
        var lastError: any Error = SealError.notARecipient
        for candidate in candidates {
            do {
                return try SplitMessage.openHeader(entry(generation: candidate), keys: keys)
            } catch {
                lastError = error
            }
        }
        throw lastError
    }
}

/// The envelope's body half.
struct StoredSentBody: Codable, Sendable {
    var encryptedBody: Data
    var bodyNonce: Data
    var bodyTag: Data

    init(_ env: Dmcn_Message_EncryptedEnvelope) {
        encryptedBody = env.encryptedBody
        bodyNonce = env.bodyNonce
        bodyTag = env.bodyTag
    }

    var mailboxBody: Dmcn_Relay_MailboxBody {
        var body = Dmcn_Relay_MailboxBody()
        body.encryptedBody = encryptedBody
        body.bodyNonce = bodyNonce
        body.bodyTag = bodyTag
        return body
    }
}

/// The account's Sent folder.
public actor SentStore {
    public static let hashPrefix = "sent:"

    private struct Row {
        let preview: SentPreview
        let version: Int
        let opened: OpenedHeader
    }

    private let storage: any PersonalStorage
    private let keys: any AccountKeys
    private var rows: [String: Row] = [:]
    private var listed = false

    public init(storage: any PersonalStorage, keys: any AccountKeys) {
        self.storage = storage
        self.keys = keys
    }

    public static func isSentHash(_ hash: String) -> Bool { hash.hasPrefix(hashPrefix) }

    private static func messageID(fromHash hash: String) -> String {
        isSentHash(hash) ? String(hash.dropFirst(hashPrefix.count)) : hash
    }

    /// Seals the sender's own copy of a message and keeps it. `draft` is the same compose as the
    /// copies sent out, with `recipientAddress` the address it went out from and `bcc` filled in:
    /// the full audience rides on this copy only. Sealed to the account's key whichever identity
    /// sent it, because Sent is one list read with one key.
    public func keepCopy(of draft: SplitMessage.Draft, from sender: some AccountKeys, deviceID: Data) async throws {
        let recipient = SplitMessage.Recipient(x25519Public: keys.x25519Public, deviceID: deviceID)
        try await putEnvelope(SplitMessage.seal(draft, from: sender, to: [recipient]))
    }

    /// Stores a self-sealed envelope as a listed header and a lazily read body.
    public func putEnvelope(_ envelope: Dmcn_Message_EncryptedEnvelope) async throws {
        let id = envelope.messageID.hex
        try await storage.put("sent/" + id, StoredSentHeader(envelope))
        try await storage.put("sent-body/" + id, StoredSentBody(envelope))
    }

    /// Every Sent row, newest first. An entry already opened at the same version isn't opened
    /// again, and one that can't be read is skipped rather than failing the list.
    public func list() async throws -> [SentPreview] {
        var next: [String: Row] = [:]
        for entry in try await storage.list(prefix: "sent/", as: StoredSentHeader.self) {
            let id = entry.key.split(separator: "/").last.map(String.init) ?? entry.key
            let hash = Self.hashPrefix + id
            if let had = rows[hash], had.version == entry.version {
                next[hash] = had
            } else if let opened = try? entry.value.open(with: keys) {
                next[hash] = Row(preview: preview(hash: hash, opened), version: entry.version, opened: opened)
            }
        }
        rows = next
        listed = true
        return next.values.map(\.preview).sorted { $0.sentAt > $1.sentAt }
    }

    /// Opens a message's body. The header comes from this session's listing.
    public func open(_ hash: String) async throws -> SentMessage {
        if rows[hash] == nil, !listed { _ = try await list() }
        guard let row = rows[hash],
            let body = try await storage.get(
                "sent-body/" + Self.messageID(fromHash: hash), as: StoredSentBody.self)
        else {
            throw SentNotFoundError()
        }
        let content = try SplitMessage.openBody(body.value.mailboxBody, of: row.opened)
        let replyTo = row.opened.header.replyToID
        return SentMessage(
            preview: row.preview, content: content, replyToID: replyTo.contains { $0 != 0 } ? replyTo.hex : nil)
    }

    public func delete(messageID: String) async throws {
        try await storage.delete("sent/" + messageID)
        try await storage.delete("sent-body/" + messageID)
        rows[Self.hashPrefix + messageID] = nil
    }

    private func preview(hash: String, _ opened: OpenedHeader) -> SentPreview {
        let h = opened.header
        return SentPreview(
            hash: hash, messageID: h.messageID.hex, threadID: h.threadID.hex, senderAddress: h.senderAddress,
            senderPublicKey: h.senderPublicKey.hex, senderDisplay: h.senderDisplay,
            recipientAddress: h.recipientAddress, to: h.to, cc: h.cc, bcc: h.bcc, subject: h.subject,
            snippet: h.snippet, sentAt: h.sentAt, bodySize: h.bodySize, attachmentCount: h.attachmentCount,
            signedByThisAccount: constantTimeEqual(h.senderPublicKey, keys.ed25519Public))
    }
}
