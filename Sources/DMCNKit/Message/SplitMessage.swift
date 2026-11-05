import Crypto
import Foundation
import SwiftProtobuf

// The split envelope (SPEC_CORE §3): a small signed header a reader opens to list the inbox,
// and a large body fetched on open, both sealed under one per-message CEK. Parity with Go
// internal/core/message/split.go and the browser's lib/crypto/split.ts.

/// A header that opened under this account's key and whose signature verified.
///
/// A verified signature says the header is internally consistent: `senderPublicKey` signed it.
/// It does not say `senderAddress` belongs to that key. That is the reader checks' job
/// (ReaderChecks.swift), and nothing may present the address as attribution before they ran.
public struct OpenedHeader: Sendable {
    public let header: Dmcn_Message_MessageHeader
    /// The generation the recipient record declared; the body's AEAD label follows it.
    public let generation: SealGeneration
    /// The X25519 key this copy was sealed to (the reader's own, or one of its aliases').
    public let sealedTo: Data
    /// Held so opening the body is not a second private-key operation, which with a
    /// Keychain-held key can mean a second biometric prompt.
    let cek: SymmetricKey
}

public enum SplitMessage {
    /// Unwraps the CEK, opens the header, and verifies the header signature.
    public static func openHeader(_ entry: Dmcn_Relay_MailboxEntry, keys: some AccountKeys) throws -> OpenedHeader {
        guard let rec = entry.recipients.first(where: { constantTimeEqual($0.recipientXPub, keys.x25519Public) }) else {
            throw SealError.notARecipient
        }
        let generation = try SealGeneration(wire: rec.kdf)
        let cek = try KeyWrap.unwrap(rec, with: keys)
        let padded = try AEAD.open(
            SealedBox(nonce: entry.headerNonce, ciphertext: entry.encryptedHeader, tag: entry.headerTag),
            key: cek, aad: generation.headerAAD)
        let signed = try Dmcn_Message_SignedHeader(serializedBytes: try Padding.unpad(padded))

        // Re-marshal what was parsed, as Go does, so both accept and refuse the same headers.
        let header = signed.header.asParsedByGo
        let signable = SignatureContext.messageHeader.signable(try Canonical.marshal(header))
        guard verifyEd25519(publicKey: header.senderPublicKey, message: signable, signature: signed.senderSignature)
        else {
            throw SealError.headerSignatureInvalid
        }
        return OpenedHeader(header: header, generation: generation, sealedTo: keys.x25519Public, cek: cek)
    }

    /// Opens the body and checks it against the verified header's `body_hash` and, when the
    /// header carries one, its body content address.
    public static func openBody(_ body: Dmcn_Relay_MailboxBody, of opened: OpenedHeader) throws
        -> Dmcn_Message_MessageContent
    {
        let padded = try AEAD.open(
            SealedBox(nonce: body.bodyNonce, ciphertext: body.encryptedBody, tag: body.bodyTag),
            key: opened.cek, aad: opened.generation.bodyAAD)
        let contentBytes = try Padding.unpad(padded)
        guard constantTimeEqual(Data(SHA256.hash(data: contentBytes)), opened.header.bodyHash) else {
            throw SealError.bodyHashMismatch
        }
        // Headers that predate the content address carry none.
        if !opened.header.bodyContentAddress.isEmpty {
            let address = bodyContentAddress(nonce: body.bodyNonce, ciphertext: body.encryptedBody, tag: body.bodyTag)
            guard constantTimeEqual(address, opened.header.bodyContentAddress) else {
                throw SealError.bodyContentAddressMismatch
            }
        }
        return try Dmcn_Message_MessageContent(serializedBytes: contentBytes)
    }

    /// What a composer supplies for one copy of a message.
    public struct Draft: Sendable {
        public var messageID: Data  // 16 bytes, shared by every copy of one compose
        public var threadID: Data  // 16 bytes
        public var replyToID: Data?  // 16 bytes; nil for a message that replies to nothing
        public var recipientAddress: String
        public var to: [String]
        public var cc: [String]
        /// Only on the sender's own copy. A recipient copy carries none.
        public var bcc: [String]
        public var subject: String
        public var bodyText: String
        /// The text/html rendering of `bodyText`, when the composer made one. The primary body stays
        /// text/plain, so the snippet and body size keep their meaning and a text-only reader always
        /// has something to show. Sealed as given: sanitizing it is the composer's job.
        public var bodyHTML: String?
        public var attachments: [DraftAttachment]
        public var sentAt: Int64
        /// The address the header names, when it isn't the signing keys' own.
        public var senderAddress: String?

        public init(
            messageID: Data, threadID: Data, replyToID: Data? = nil, recipientAddress: String,
            to: [String], cc: [String] = [], bcc: [String] = [], subject: String, bodyText: String,
            bodyHTML: String? = nil, attachments: [DraftAttachment] = [], sentAt: Int64, senderAddress: String? = nil
        ) {
            self.messageID = messageID
            self.threadID = threadID
            self.replyToID = replyToID
            self.recipientAddress = recipientAddress
            self.to = to
            self.cc = cc
            self.bcc = bcc
            self.subject = subject
            self.bodyText = bodyText
            self.bodyHTML = bodyHTML
            self.attachments = attachments
            self.sentAt = sentAt
            self.senderAddress = senderAddress
        }
    }

    /// A recipient device to wrap the CEK for.
    public struct Recipient: Sendable {
        public var x25519Public: Data
        public var deviceID: Data
        public init(x25519Public: Data, deviceID: Data = Data(count: 16)) {
            self.x25519Public = x25519Public
            self.deviceID = deviceID
        }
    }

    /// Seals a message as a version 2 split envelope, signed by `sender`.
    public static func seal(
        _ draft: Draft, from sender: some AccountKeys, to recipients: [Recipient],
        generation: SealGeneration = .producer
    ) throws -> Dmcn_Message_EncryptedEnvelope {
        let contentBytes = try contentBytes(of: draft)

        // The body is sealed first so its content address can be committed in the header.
        let cek = SymmetricKey(size: .bits256)
        let bodyClass = Padding.sizeClass(for: contentBytes.count)
        let body = try AEAD.seal(Padding.pad(contentBytes, to: bodyClass), key: cek, aad: generation.bodyAAD)
        let address = bodyContentAddress(nonce: body.nonce, ciphertext: body.ciphertext, tag: body.tag)

        let header = header(of: draft, from: sender, contentBytes: contentBytes, bodyContentAddress: address)

        var signed = Dmcn_Message_SignedHeader()
        signed.header = header
        signed.senderSignature = try sender.sign(SignatureContext.messageHeader.signable(Canonical.marshal(header)))
        let signedBytes = try Canonical.marshal(signed)
        let headerClass = Padding.sizeClass(for: signedBytes.count)
        let sealedHeader = try AEAD.seal(Padding.pad(signedBytes, to: headerClass), key: cek, aad: generation.headerAAD)

        var env = Dmcn_Message_EncryptedEnvelope()
        env.version = 2
        env.messageID = draft.messageID
        env.createdAt = draft.sentAt
        env.recipients = try recipients.map {
            try KeyWrap.wrap(cek: cek, recipientPublic: $0.x25519Public, deviceID: $0.deviceID, generation: generation)
        }
        env.encryptedHeader = sealedHeader.ciphertext
        env.headerNonce = sealedHeader.nonce
        env.headerTag = sealedHeader.tag
        env.headerSizeClass = UInt32(headerClass)
        env.encryptedBody = body.ciphertext
        env.bodyNonce = body.nonce
        env.bodyTag = body.tag
        env.bodySizeClass = UInt32(bodyClass)
        env.bodyContentAddress = address
        env.fillGoFixedWidthFields()
        return env
    }

    /// The canonical bytes `body_hash` commits to, so it covers both renderings and every
    /// attachment: none of them can be swapped without breaking the header.
    static func contentBytes(of draft: Draft) throws -> Data {
        var content = Dmcn_Message_MessageContent()
        content.body.contentType = "text/plain"
        content.body.content = Data(draft.bodyText.utf8)
        content.attachments = draft.attachments.map(Dmcn_Message_AttachmentRecord.init(sealing:))
        // An empty HTML rendering is no rendering, as in the browser.
        if let html = draft.bodyHTML, !html.isEmpty {
            var alternative = Dmcn_Message_MessageBody()
            alternative.contentType = "text/html"
            alternative.content = Data(html.utf8)
            content.alternatives = [alternative]
        }
        return try Canonical.marshal(content)
    }

    /// The header the signature covers.
    static func header(
        of draft: Draft, from sender: some AccountKeys, contentBytes: Data, bodyContentAddress: Data
    ) -> Dmcn_Message_MessageHeader {
        let bodyText = Data(draft.bodyText.utf8)
        var header = Dmcn_Message_MessageHeader()
        header.version = 1
        header.messageID = draft.messageID
        header.threadID = draft.threadID
        // Go holds the ids as fixed 16-byte arrays and re-marshals from them when it verifies,
        // so an omitted reply_to_id would come back as 16 zero bytes and the signature fail.
        header.replyToID = draft.replyToID ?? Data(count: 16)
        header.senderAddress = draft.senderAddress ?? sender.address
        header.senderPublicKey = sender.ed25519Public
        header.recipientAddress = draft.recipientAddress
        header.sentAt = draft.sentAt
        header.subject = draft.subject
        header.attachmentCount = UInt32(draft.attachments.count)
        header.bodySize = UInt64(bodyText.count)
        header.snippet = snippet(contentType: "text/plain", content: bodyText)
        header.bodyHash = Data(SHA256.hash(data: contentBytes))
        header.bodyContentAddress = bodyContentAddress
        header.to = draft.to
        header.cc = draft.cc
        header.bcc = draft.bcc
        return header
    }
}

extension Dmcn_Message_AttachmentRecord {
    fileprivate init(sealing attachment: DraftAttachment) {
        self.init()
        attachmentID = attachment.attachmentID
        filename = attachment.filename
        contentType = attachment.contentType
        // A draft comes back from storage, so a size in it isn't trusted not to trap here.
        sizeBytes = UInt64(clamping: attachment.sizeBytes)
        contentHash = attachment.contentHash
        content = attachment.content
        contentID = attachment.contentID ?? ""
        disposition = attachment.disposition ?? ""
    }
}

extension Dmcn_Message_MessageHeader {
    /// This header as Go holds it after parsing. Go copies a header into a struct, which keeps
    /// no field it doesn't know and holds the ids and body hash as fixed arrays, so an absent id
    /// comes back as zeros and a wrong-width one is cut or zero-filled. SwiftProtobuf keeps all
    /// of that as it arrived, so verifying without this would disagree with Go on crafted mail.
    var asParsedByGo: Self {
        var header = self
        header.unknownFields = UnknownStorage()
        header.messageID = messageID.goFixedArray(16)
        header.threadID = threadID.goFixedArray(16)
        header.replyToID = replyToID.goFixedArray(16)
        header.bodyHash = bodyHash.goFixedArray(32)
        return header
    }
}

private extension Data {
    /// What Go's `copy` into a `[width]byte` leaves.
    func goFixedArray(_ width: Int) -> Data {
        Data(prefix(width)) + Data(count: Swift.max(0, width - count))
    }
}

extension Dmcn_Message_EncryptedEnvelope {
    /// Writes the fixed-width fields Go always encodes, as zeros where they are unused.
    ///
    /// Go holds the non-split payload nonce and tag and the reserved ratchet key as fixed-size
    /// arrays, so its encoding of a split envelope always carries them, zero-filled. The relay
    /// checks the STORE signature over the SHA-256 of ITS re-marshal of the envelope; an
    /// envelope that omits them hashes differently there and every send is refused as
    /// INVALID_SIGNATURE. Pinned by the envelope vector in KEMVectorTests.
    public mutating func fillGoFixedWidthFields() {
        if payloadNonce.isEmpty { payloadNonce = Data(count: 12) }
        if payloadTag.isEmpty { payloadTag = Data(count: 16) }
        if ratchetPubKey.isEmpty { ratchetPubKey = Data(count: 32) }
    }

    /// The STORE `sender_signature`: Ed25519 over the 32-byte SHA-256 of the serialised
    /// envelope, with no context tag (one of the four exceptions in SPEC_CORE §2).
    public func storeSignature(by sender: some AccountKeys) throws -> Data {
        try sender.sign(Data(SHA256.hash(data: Canonical.marshal(self))))
    }
}

extension Dmcn_Relay_MailboxEntry {
    /// The listing row a relay would file for `envelope`. Used by tests and by a client's own
    /// Sent copy; a relay builds the real one.
    public init(filing envelope: Dmcn_Message_EncryptedEnvelope) {
        self.init()
        recipients = envelope.recipients
        encryptedHeader = envelope.encryptedHeader
        headerNonce = envelope.headerNonce
        headerTag = envelope.headerTag
        headerSizeClass = envelope.headerSizeClass
        bodyContentAddress = envelope.bodyContentAddress
    }
}

extension Dmcn_Relay_MailboxBody {
    public init(filing envelope: Dmcn_Message_EncryptedEnvelope) {
        self.init()
        encryptedBody = envelope.encryptedBody
        bodyNonce = envelope.bodyNonce
        bodyTag = envelope.bodyTag
        bodySizeClass = envelope.bodySizeClass
        bodyContentAddress = envelope.bodyContentAddress
    }
}
