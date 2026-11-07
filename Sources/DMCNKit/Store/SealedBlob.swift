import Crypto
import Foundation

// Arbitrary plaintext under a random CEK (AES-256-GCM), the CEK wrapped to one or more X25519
// recipients with the same KEM as a message. Everything in personal storage is one of these, sealed
// to the owner alone. Parity with Go internal/core/message.SealedBlob and the browser's
// lib/crypto/sealedBlob.ts; the JSON is Go's encoding/json of that struct.

/// A value sealed to one or more X25519 keys, in the JSON shape Go and the browser share.
public struct SealedBlob: Codable, Sendable, Equatable {
    /// One wrapped copy of the CEK.
    public struct Recipient: Codable, Sendable, Equatable {
        public var recipientXPub: Data
        public var ephemeralXPub: Data
        public var wrappedCEK: Data
        public var cekNonce: Data
        public var cekTag: Data
        /// The derivation generation, as on RecipientRecord: absent means 1. A blob has no
        /// envelope to say so, so the wrap carries it.
        public var kdf: UInt32?

        enum CodingKeys: String, CodingKey {
            case recipientXPub = "recipient_xpub"
            case ephemeralXPub = "ephemeral_xpub"
            case wrappedCEK = "wrapped_cek"
            case cekNonce = "cek_nonce"
            case cekTag = "cek_tag"
            case kdf
        }
    }

    public var nonce: Data
    public var ciphertext: Data
    public var tag: Data
    public var recipients: [Recipient]

    /// Seals `plaintext` to each X25519 public key.
    public static func seal(
        _ plaintext: Data, to recipientKeys: [Data], generation: SealGeneration = .producer
    ) throws -> SealedBlob {
        guard !recipientKeys.isEmpty else { throw SealedBlobError.noRecipients }
        let cek = SymmetricKey(size: .bits256)
        let sealed = try AEAD.seal(plaintext, key: cek, aad: nil)
        let recipients = try recipientKeys.map { key in
            let rec = try KeyWrap.wrap(
                cek: cek, recipientPublic: key, deviceID: Data(count: 16), generation: generation)
            return Recipient(
                recipientXPub: rec.recipientXPub, ephemeralXPub: rec.ephemeralXPub, wrappedCEK: rec.wrappedCek,
                cekNonce: rec.cekNonce, cekTag: rec.cekTag, kdf: rec.kdf == 0 ? nil : rec.kdf)
        }
        return SealedBlob(nonce: sealed.nonce, ciphertext: sealed.ciphertext, tag: sealed.tag, recipients: recipients)
    }

    /// Opens the blob with an account's key: the record naming that key first, then the others,
    /// since a wrong record fails its tag rather than mis-decrypting. `KeyWrap.unwrap` derives from
    /// the reader's own public key, never from `recipientXPub`, which is the sealer's to choose and
    /// is exactly what this loop may be stepping past.
    public func open(with keys: some AccountKeys) throws -> Data {
        let mine = recipients.filter { constantTimeEqual($0.recipientXPub, keys.x25519Public) }
        let others = recipients.filter { !constantTimeEqual($0.recipientXPub, keys.x25519Public) }
        for recipient in mine + others {
            if let plaintext = try? open(recipient, keys: keys) { return plaintext }
        }
        throw SealError.notARecipient
    }

    private func open(_ recipient: Recipient, keys: some AccountKeys) throws -> Data {
        var rec = Dmcn_Message_RecipientRecord()
        rec.ephemeralXPub = recipient.ephemeralXPub
        rec.wrappedCek = recipient.wrappedCEK
        rec.cekNonce = recipient.cekNonce
        rec.cekTag = recipient.cekTag
        rec.kdf = recipient.kdf ?? 0
        let cek = try KeyWrap.unwrap(rec, with: keys)
        return try AEAD.open(SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag), key: cek, aad: nil)
    }
}

public enum SealedBlobError: Error, Equatable, Sendable {
    case noRecipients
}
