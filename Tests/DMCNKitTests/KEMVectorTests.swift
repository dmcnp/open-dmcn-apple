// Swift half of the cross-implementation KEM known-answer vectors.
//
// The Go half is internal/core/message/kemvector_test.go in the product repository, and the
// browser half is cmd/dmcnd/web/src/lib/crypto/kemvector.test.ts in open-dmcn; all three
// carry the same constants. Change a label, a concatenation order, or the HKDF salt on any side
// and that side's suite goes red.
//
// Fixed inputs: ephemeral private = 32x0x01, recipient private = 32x0x02, CEK = 32x0x03,
// CEK nonce = 12x0x04, AEAD key = 32x0x05, AEAD nonce = 12x0x06.

import Crypto
import Foundation
import Testing
@testable import DMCNKit

private enum VEC {
    static let ephPub = "a4e09292b651c278b9772c569f5fa9bb13d906b46ab68c9df9dc2b4409f8a209"
    static let rcptPub = "ce8d3ad1ccb633ec7b70c17814a5c76ecd029685050d344745ba05870e587d59"
    static let shared = "2ed76ab549b1e73c031eb49c9448f0798aea81b698279a0c3dc3e49fbfc4b953"
    static let kwkV1 = "d4289fa1219bc84591141148ac91cb35b2b70c9fe85f541a5d59ef88b42a23ae"
    static let kwkV2 = "3014321754048b6b004d90a76824cd4a85b185d09c409de6953e35179b1fc033"
    static let wrappedV1 = "2b925ba17c7250e6d9d1bcc4e9e5b9f4005eaab1ff0945cef7cb9dc015cd38fc"
    static let tagV1 = "50baf3c9cfc15d33b07b3f85ec3e7852"
    static let wrappedV2 = "3f79601eb4cb4b284265e5da2dbba17b422a0a4c88273aed23e05f7850859250"
    static let tagV2 = "1e82bad41401e8c735b6f0cce60b7958"
    // Header and body ciphertexts are IDENTICAL: same key, nonce and plaintext. Only the tags
    // differ, which is what the AEAD labels buy.
    static let aeadPlain = "dmcn parity vector payload"
    static let hdrCT = "fed6191f79f9837fca198a956849c3c0e7e2e7b28791e2c2a2b4"
    static let hdrTag = "5683e294a2dac2d4dd80de833320579b"
    static let bodyCT = "fed6191f79f9837fca198a956849c3c0e7e2e7b28791e2c2a2b4"
    static let bodyTag = "10d874712fd9a3b9b4b9659158957be1"
}

private func recipientKeys() throws -> SoftwareAccountKeys {
    try SoftwareAccountKeys(
        address: "vector@parity.example", ed25519Seed: fill(32, 0x09), x25519Private: fill(32, 0x02))
}

private func record(_ wrapped: String, _ tag: String, kdf: UInt32) -> Dmcn_Message_RecipientRecord {
    var r = Dmcn_Message_RecipientRecord()
    r.recipientXPub = unhex(VEC.rcptPub)
    r.ephemeralXPub = unhex(VEC.ephPub)
    r.wrappedCek = unhex(wrapped)
    r.cekNonce = fill(12, 0x04)
    r.cekTag = unhex(tag)
    r.kdf = kdf
    return r
}

private func raw(_ key: SymmetricKey) -> Data { key.withUnsafeBytes { Data($0) } }

@Suite struct KEMDerivationVectors {
    @Test func derivesThePinnedPublicKeysAndSharedSecret() throws {
        let eph = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: fill(32, 0x01))
        #expect(eph.publicKey.rawRepresentation.hex == VEC.ephPub)
        let keys = try recipientKeys()
        #expect(keys.x25519Public.hex == VEC.rcptPub)
        let shared = try keys.sharedSecret(withEphemeral: unhex(VEC.ephPub))
        #expect(shared.withUnsafeBytes { Data($0) }.hex == VEC.shared)
    }

    @Test func derivesBothKeyWrappingKeys() throws {
        // The empty salt matches Go's nil: RFC 5869 §2.2 makes both 32 zero bytes.
        let shared = try recipientKeys().sharedSecret(withEphemeral: unhex(VEC.ephPub))
        let v1 = try SealGeneration.v1.wrapInfo(ephemeralPublic: unhex(VEC.ephPub), recipientPublic: unhex(VEC.rcptPub))
        let v2 = try SealGeneration.v2.wrapInfo(ephemeralPublic: unhex(VEC.ephPub), recipientPublic: unhex(VEC.rcptPub))
        #expect(raw(KeyWrap.wrappingKey(shared: shared, info: v1)).hex == VEC.kwkV1)
        #expect(raw(KeyWrap.wrappingKey(shared: shared, info: v2)).hex == VEC.kwkV2)
    }

    @Test func rejectsAContextBuiltFromTheWrongKeyWidth() {
        #expect(throws: SealError.badKeyLength) {
            try SealGeneration.v2.wrapInfo(ephemeralPublic: Data(count: 31), recipientPublic: unhex(VEC.rcptPub))
        }
    }
}

@Suite struct UnwrapDispatchesOnTheDeclaredGeneration {
    // kdf 0 is the pre-field encoding. ABSENT MUST MEAN 1: that mapping is what lets stored
    // mail keep opening with no compatibility branch.
    @Test(arguments: [UInt32(0), 1, 2])
    func opens(kdf: UInt32) throws {
        let (wrapped, tag) = kdf == 2 ? (VEC.wrappedV2, VEC.tagV2) : (VEC.wrappedV1, VEC.tagV1)
        let cek = try KeyWrap.unwrap(record(wrapped, tag, kdf: kdf), with: recipientKeys())
        #expect(raw(cek) == fill(32, 0x03))
    }

    @Test func doesNotFallBackAcrossGenerations() throws {
        // No trial decryption: a mislabelled wrap fails rather than being discovered by
        // attempting the other derivation.
        let keys = try recipientKeys()
        #expect(throws: (any Error).self) { try KeyWrap.unwrap(record(VEC.wrappedV2, VEC.tagV2, kdf: 1), with: keys) }
        #expect(throws: (any Error).self) { try KeyWrap.unwrap(record(VEC.wrappedV1, VEC.tagV1, kdf: 2), with: keys) }
    }

    @Test func refusesAnUnknownGenerationOutright() throws {
        #expect(throws: SealError.unknownGeneration(99)) {
            try KeyWrap.unwrap(record(VEC.wrappedV2, VEC.tagV2, kdf: 99), with: recipientKeys())
        }
    }

    @Test func refusesAGeneration2WrapUnderTheWrongRecipientContext() throws {
        // Same private key, a different claimed public half. Generation 2 binds to the reader's
        // own key, so the record's recipient field changing must not matter and a different
        // reader key must not open it.
        struct WrongPublic: AccountKeys {
            let inner: SoftwareAccountKeys
            var address: String { inner.address }
            var ed25519Public: Data { inner.ed25519Public }
            var x25519Public: Data { fill(32, 0x09) }
            func sign(_ m: Data) throws -> Data { try inner.sign(m) }
            func sharedSecret(withEphemeral e: Data) throws -> SharedSecret { try inner.sharedSecret(withEphemeral: e) }
        }
        let keys = WrongPublic(inner: try recipientKeys())
        #expect(throws: (any Error).self) { try KeyWrap.unwrap(record(VEC.wrappedV2, VEC.tagV2, kdf: 2), with: keys) }
    }

    @Test func keysTheBlobLabelsOffTheSameGeneration() {
        #expect(SealGeneration.v1.headerAAD == nil)
        #expect(SealGeneration.v1.bodyAAD == nil)
        #expect(SealGeneration.v2.headerAAD == Data("dmcn-aad-hdr-v1\u{0}".utf8))
        #expect(SealGeneration.v2.bodyAAD == Data("dmcn-aad-body-v1\u{0}".utf8))
    }
}

@Suite struct AEADLabelVectors {
    let key = SymmetricKey(data: fill(32, 0x05))
    let nonce = fill(12, 0x06)

    @Test func opensEachBlobUnderItsOwnLabel() throws {
        let hdr = try AEAD.open(
            SealedBox(nonce: nonce, ciphertext: unhex(VEC.hdrCT), tag: unhex(VEC.hdrTag)), key: key,
            aad: SealGeneration.v2.headerAAD)
        let body = try AEAD.open(
            SealedBox(nonce: nonce, ciphertext: unhex(VEC.bodyCT), tag: unhex(VEC.bodyTag)), key: key,
            aad: SealGeneration.v2.bodyAAD)
        #expect(String(decoding: hdr, as: UTF8.self) == VEC.aeadPlain)
        #expect(String(decoding: body, as: UTF8.self) == VEC.aeadPlain)
    }

    @Test func refusesTheHeaderBlobUnderTheBodyLabelAndUnderNone() {
        let box = SealedBox(nonce: nonce, ciphertext: unhex(VEC.hdrCT), tag: unhex(VEC.hdrTag))
        #expect(throws: (any Error).self) { try AEAD.open(box, key: key, aad: SealGeneration.v2.bodyAAD) }
        #expect(throws: (any Error).self) { try AEAD.open(box, key: key, aad: nil) }
    }
}

@Suite struct PaddingRules {
    @Test func roundTrips() throws {
        var padded = Data(count: 16)
        padded.replaceSubrange(0..<6, with: [0, 0, 0, 2, 0xaa, 0xbb])
        #expect(try Padding.unpad(padded).hex == "aabb")
        let payload = Data("hello".utf8)
        #expect(try Padding.unpad(Padding.pad(payload, to: Padding.sizeClass(for: payload.count))) == payload)
    }

    @Test func rejectsALengthPrefixWithTheHighBitSet() {
        // The divergence the browser once had: a signed shift made 0x80000000 negative.
        #expect(throws: (any Error).self) { try Padding.unpad(Data([0x80, 0, 0, 0, 0, 0, 0, 0])) }
    }

    @Test func rejectsAShortBufferAndAnOverlongPrefix() {
        #expect(throws: (any Error).self) { try Padding.unpad(Data([0, 0])) }
        #expect(throws: (any Error).self) { try Padding.unpad(Data([0, 0, 0, 255, 0])) }
    }

    @Test func sizeClassesLeaveRoomForThePrefix() {
        #expect(Padding.sizeClass(for: 1020) == 1024)
        #expect(Padding.sizeClass(for: 1021) == 4096)
        #expect(Padding.sizeClass(for: 1_048_572) == 1_048_576)
        #expect(Padding.sizeClass(for: 1_048_573) == 2 * 1_048_576)
    }
}

// The STORE signature is over SHA-256 of the marshaled EncryptedEnvelope, and the relay
// recomputes that hash from its own re-marshal, so one byte of disagreement makes every send
// fail at the relay. The same constant is asserted by the browser (kemvector.test.ts) and by
// Go (TestKDFv2EnvelopeWireParityWithBrowser in internal/core/message/v1parity_test.go).
@Suite struct EnvelopeWireParity {
    static let kdfV2EnvelopeHex =
        "080212100102030405060708090a0b0c0d0e0f101a9a010a106465666768696a6b6c6d6e6f707172"
        + "7312200a0b0c0d0e0f101112131415161718191a1b1c1d1e1f202122232425262728291a20323334"
        + "35363738393a3b3c3d3e3f404142434445464748494a4b4c4d4e4f50512220c8c9cacbcccdcecfd0"
        + "d1d2d3d4d5d6d7d8d9dadbdcdddedfe0e1e2e3e4e5e6e72a0c464748494a4b4c4d4e4f5051321050"
        + "5152535455565758595a5b5c5d5e5f38022a0c0000000000000000000000003210000000000000"
        + "0000000000000000000040cea4c1b0064a2000000000000000000000000000000000000000000000"
        + "00000000000000000000521805060708090a0b0c0d0e0f101112131415161718191a1b1c5a0c1516"
        + "1718191a1b1c1d1e1f2062101f202122232425262728292a2b2c2d2e6880087228090a0b0c0d0e0f"
        + "101112131415161718191a1b1c1d1e1f202122232425262728292a2b2c2d2e2f307a0c292a2b2c2d"
        + "2e2f3031323334820110333435363738393a3b3c3d3e3f404142880180209201243c3d3e3f404142"
        + "434445464748494a4b4c4d4e4f505152535455565758595a5b5c5d5e5f"

    @Test func encodesAKdf2SplitEnvelopeByteIdentically() throws {
        var rec = Dmcn_Message_RecipientRecord()
        rec.deviceID = pattern(16, from: 100)
        rec.recipientXPub = pattern(32, from: 10)
        rec.ephemeralXPub = pattern(32, from: 50)
        rec.wrappedCek = pattern(32, from: 200)
        rec.cekNonce = pattern(12, from: 70)
        rec.cekTag = pattern(16, from: 80)
        rec.kdf = 2

        var env = Dmcn_Message_EncryptedEnvelope()
        env.version = 2
        env.messageID = pattern(16, from: 1)
        env.createdAt = 1_712_345_678
        env.recipients = [rec]
        env.encryptedHeader = pattern(24, from: 5)
        env.headerNonce = pattern(12, from: 21)
        env.headerTag = pattern(16, from: 31)
        env.headerSizeClass = 1024
        env.encryptedBody = pattern(40, from: 9)
        env.bodyNonce = pattern(12, from: 41)
        env.bodyTag = pattern(16, from: 51)
        env.bodySizeClass = 4096
        env.bodyContentAddress = pattern(36, from: 60)
        env.fillGoFixedWidthFields()

        #expect(try Canonical.marshal(env).hex == Self.kdfV2EnvelopeHex)
    }
}
