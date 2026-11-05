import Crypto
import Foundation

// The per-message content-key wrap, the AEAD the header and body are sealed with, and the
// size-class padding (SPEC_CORE §3). Byte parity with Go internal/core/message/encrypt.go and
// the browser's lib/crypto/{encrypt,decrypt}.ts.

/// An AES-256-GCM sealed value in the wire's split form: nonce, ciphertext and tag are separate
/// protobuf fields everywhere they appear.
public struct SealedBox: Sendable, Equatable {
    public var nonce: Data
    public var ciphertext: Data
    public var tag: Data
}

enum AEAD {
    static func seal(_ plaintext: Data, key: SymmetricKey, aad: Data?) throws -> SealedBox {
        let box =
            if let aad {
                try AES.GCM.seal(plaintext, using: key, authenticating: aad)
            } else {
                try AES.GCM.seal(plaintext, using: key)
            }
        return SealedBox(nonce: Data(box.nonce), ciphertext: box.ciphertext, tag: box.tag)
    }

    static func open(_ sealed: SealedBox, key: SymmetricKey, aad: Data?) throws -> Data {
        guard sealed.nonce.count == 12 else { throw SealError.badNonceLength }
        guard sealed.tag.count == 16 else { throw SealError.badTagLength }
        let box = try AES.GCM.SealedBox(
            nonce: AES.GCM.Nonce(data: sealed.nonce), ciphertext: sealed.ciphertext, tag: sealed.tag)
        if let aad {
            return try AES.GCM.open(box, using: key, authenticating: aad)
        }
        return try AES.GCM.open(box, using: key)
    }
}

enum KeyWrap {
    /// The key-wrapping key for one recipient: HKDF-SHA256 over the X25519 shared secret, with
    /// an empty salt (RFC 5869 §2.2 makes it equal to Go's nil) and the generation's info.
    static func wrappingKey(shared: SharedSecret, info: Data) -> SymmetricKey {
        shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data(), sharedInfo: info, outputByteCount: 32)
    }

    /// Wraps `cek` for one recipient under a fresh ephemeral key.
    static func wrap(
        cek: SymmetricKey, recipientPublic: Data, deviceID: Data, generation: SealGeneration = .producer
    ) throws -> Dmcn_Message_RecipientRecord {
        let recipient = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: recipientPublic)
        let ephemeral = Curve25519.KeyAgreement.PrivateKey()
        let ephemeralPublic = ephemeral.publicKey.rawRepresentation
        let shared = try ephemeral.sharedSecretFromKeyAgreement(with: recipient)
        let info = try generation.wrapInfo(ephemeralPublic: ephemeralPublic, recipientPublic: recipientPublic)
        let wrapped = try AEAD.seal(
            cek.withUnsafeBytes { Data($0) }, key: wrappingKey(shared: shared, info: info), aad: nil)

        var rec = Dmcn_Message_RecipientRecord()
        rec.deviceID = deviceID
        rec.recipientXPub = recipientPublic
        rec.ephemeralXPub = ephemeralPublic
        rec.wrappedCek = wrapped.ciphertext
        rec.cekNonce = wrapped.nonce
        rec.cekTag = wrapped.tag
        // Generation 1 is written as absent, as Go and the browser write it.
        rec.kdf = generation == .v1 ? 0 : generation.rawValue
        return rec
    }

    /// Recovers the CEK from a recipient record.
    ///
    /// The derivation binds to the READER'S OWN public key, never `rec.recipientXPub`: that
    /// field is the sealer's choice, and generation 2 exists to bind the wrap to a key the
    /// reader knows.
    static func unwrap(_ rec: Dmcn_Message_RecipientRecord, with keys: some AccountKeys) throws -> SymmetricKey {
        let generation = try SealGeneration(wire: rec.kdf)
        let info = try generation.wrapInfo(ephemeralPublic: rec.ephemeralXPub, recipientPublic: keys.x25519Public)
        let shared = try keys.sharedSecret(withEphemeral: rec.ephemeralXPub)
        let kwk = wrappingKey(shared: shared, info: info)
        let cek = try AEAD.open(
            SealedBox(nonce: rec.cekNonce, ciphertext: rec.wrappedCek, tag: rec.cekTag), key: kwk, aad: nil)
        guard cek.count == 32 else { throw SealError.badKeyLength }
        return SymmetricKey(data: cek)
    }
}

/// Size-class padding: `[4-byte BE length][payload][zero padding]`, padded to 1 KB / 4 KB /
/// 16 KB / 64 KB / 256 KB / 1 MB, then up to the next whole MB.
public enum Padding {
    static let sizeClasses = [1024, 4096, 16384, 65536, 262_144, 1_048_576]

    /// The bucket a payload is padded to. It must fit the payload AND its 4-byte prefix, so a
    /// payload at a class boundary is not truncated (parity with Go).
    public static func sizeClass(for payloadSize: Int) -> Int {
        let needed = payloadSize + 4
        if let fit = sizeClasses.first(where: { needed <= $0 }) { return fit }
        let mb = 1_048_576
        return (needed + mb - 1) / mb * mb
    }

    public static func pad(_ payload: Data, to size: Int) -> Data {
        var out = Data(count: size)
        withUnsafeBytes(of: UInt32(payload.count).bigEndian) { out.replaceSubrange(0..<4, with: $0) }
        out.replaceSubrange(4..<(4 + payload.count), with: payload)
        return out
    }

    /// Strips the length prefix `pad` wrote. The prefix is inside the AEAD, so a bad value
    /// means the caller opened something `pad` never produced; Go and the browser both throw.
    public static func unpad(_ padded: Data) throws(SealError) -> Data {
        guard padded.count >= 4 else { throw .shortPadding(padded.count) }
        // Read in place: a padded body can be megabytes, and only its first four bytes are needed.
        let len = UInt32(bigEndian: padded.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) })
        guard UInt64(len) + 4 <= UInt64(padded.count) else {
            throw .lengthPrefixOverflow(len, padded.count)
        }
        let start = padded.startIndex + 4
        return Data(padded[start..<(start + Int(len))])
    }
}
