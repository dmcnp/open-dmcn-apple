import Foundation

// Seal-format generations (SPEC_CORE §3). Mirrors Go internal/core/message/encrypt.go and
// split.go, and the browser's lib/crypto/sealVersion.ts. These values feed HKDF and AES-GCM, so
// a divergence shows up as a wrong key or a failed tag rather than a readable error; the
// known-answer vectors in KEMVectorTests pin them.
//
// Every wrap states its own generation in RecipientRecord.kdf, and a reader dispatches on that
// value. It never attempts trial decryption, and it refuses a generation it does not know.

public enum SealGeneration: UInt32, Sendable {
    case v1 = 1
    case v2 = 2

    /// The generation new wraps are written with.
    public static let producer: SealGeneration = .v2

    /// Reads RecipientRecord.kdf. ABSENT (0) MEANS 1: every wrap written before the field
    /// existed used generation 1, and stored envelopes are never re-encrypted.
    public init(wire: UInt32) throws(SealError) {
        guard let g = SealGeneration(rawValue: wire == 0 ? 1 : wire) else {
            throw .unknownGeneration(wire)
        }
        self = g
    }

    /// The HKDF info for this generation. Generation 2 binds the key-wrapping key to the pair
    /// it was derived for (RFC 9180 §4.1 kem_context = enc ‖ pkRm).
    func wrapInfo(ephemeralPublic: Data, recipientPublic: Data) throws(SealError) -> Data {
        switch self {
        case .v1:
            return Data("dmcn-cek-wrap-v1".utf8)
        case .v2:
            guard ephemeralPublic.count == 32, recipientPublic.count == 32 else {
                throw .badKeyLength
            }
            return Data("dmcn-cek-wrap-v2".utf8) + ephemeralPublic + recipientPublic
        }
    }

    /// AEAD additional data for the header blob. Generation 1 predates the labels.
    var headerAAD: Data? {
        self == .v1 ? nil : Data("dmcn-aad-hdr-v1\u{0}".utf8)
    }

    /// AEAD additional data for the body blob. Generation 1 predates the labels.
    var bodyAAD: Data? {
        self == .v1 ? nil : Data("dmcn-aad-body-v1\u{0}".utf8)
    }
}

public enum SealError: Error, Equatable, Sendable {
    case unknownGeneration(UInt32)
    case badKeyLength
    case badNonceLength
    case badTagLength
    case shortPadding(Int)
    case lengthPrefixOverflow(UInt32, Int)
    case notARecipient
    case headerSignatureInvalid
    case bodyHashMismatch
    case bodyContentAddressMismatch
}
