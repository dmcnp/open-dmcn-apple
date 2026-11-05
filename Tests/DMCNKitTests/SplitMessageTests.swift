import Crypto
import Foundation
import Testing
@testable import DMCNKit

@Suite struct SplitMessageRoundTrip {
    let alice = SoftwareAccountKeys(address: "alice@parity.example")
    let bob = SoftwareAccountKeys(address: "bob@parity.example")

    func draft(body: String = "Hello Bob, this is the body.") -> SplitMessage.Draft {
        .init(
            messageID: pattern(16, from: 1), threadID: pattern(16, from: 17), recipientAddress: bob.address,
            to: [bob.address], subject: "Parity", bodyText: body, sentAt: 1_700_000_000)
    }

    @Test(arguments: [SealGeneration.v1, .v2])
    func opensWhatItSealed(generation: SealGeneration) throws {
        let env = try SplitMessage.seal(
            draft(), from: alice, to: [.init(x25519Public: bob.x25519Public)], generation: generation)
        let opened = try SplitMessage.openHeader(Dmcn_Relay_MailboxEntry(filing: env), keys: bob)
        #expect(opened.generation == generation)
        #expect(opened.header.senderAddress == alice.address)
        #expect(opened.header.senderPublicKey == alice.ed25519Public)
        #expect(opened.header.subject == "Parity")
        #expect(opened.header.snippet == "Hello Bob, this is the body.")
        #expect(opened.header.replyToID == Data(count: 16))

        let content = try SplitMessage.openBody(Dmcn_Relay_MailboxBody(filing: env), of: opened)
        #expect(String(decoding: content.body.content, as: UTF8.self) == "Hello Bob, this is the body.")
    }

    @Test func aReaderItWasNotSealedToCannotOpenIt() throws {
        let env = try SplitMessage.seal(draft(), from: alice, to: [.init(x25519Public: bob.x25519Public)])
        let eve = SoftwareAccountKeys(address: "eve@parity.example")
        #expect(throws: SealError.notARecipient) {
            try SplitMessage.openHeader(Dmcn_Relay_MailboxEntry(filing: env), keys: eve)
        }
    }

    @Test func aHeaderSignedByAnotherKeyIsRefused() throws {
        // Mallory names Alice's key in the header and signs with her own.
        struct Impostor: AccountKeys {
            let signer: SoftwareAccountKeys
            let claimed: SoftwareAccountKeys
            var address: String { claimed.address }
            var ed25519Public: Data { claimed.ed25519Public }
            var x25519Public: Data { claimed.x25519Public }
            func sign(_ m: Data) throws -> Data { try signer.sign(m) }
            func sharedSecret(withEphemeral e: Data) throws -> SharedSecret {
                try signer.sharedSecret(withEphemeral: e)
            }
        }
        let mallory = Impostor(signer: SoftwareAccountKeys(address: "mallory@parity.example"), claimed: alice)
        let env = try SplitMessage.seal(draft(), from: mallory, to: [.init(x25519Public: bob.x25519Public)])
        #expect(throws: SealError.headerSignatureInvalid) {
            try SplitMessage.openHeader(Dmcn_Relay_MailboxEntry(filing: env), keys: bob)
        }
    }

    @Test func theHeaderBlobCannotStandInForTheBody() throws {
        let env = try SplitMessage.seal(draft(), from: alice, to: [.init(x25519Public: bob.x25519Public)])
        let opened = try SplitMessage.openHeader(Dmcn_Relay_MailboxEntry(filing: env), keys: bob)
        var swapped = Dmcn_Relay_MailboxBody(filing: env)
        swapped.encryptedBody = env.encryptedHeader
        swapped.bodyNonce = env.headerNonce
        swapped.bodyTag = env.headerTag
        #expect(throws: (any Error).self) { try SplitMessage.openBody(swapped, of: opened) }
    }

    @Test func aBodyFromAnotherMessageIsRefused() throws {
        let one = try SplitMessage.seal(draft(body: "one"), from: alice, to: [.init(x25519Public: bob.x25519Public)])
        let two = try SplitMessage.seal(draft(body: "two"), from: alice, to: [.init(x25519Public: bob.x25519Public)])
        let opened = try SplitMessage.openHeader(Dmcn_Relay_MailboxEntry(filing: one), keys: bob)
        // Different CEK, so the AEAD refuses it before the hash is reached.
        #expect(throws: (any Error).self) { try SplitMessage.openBody(Dmcn_Relay_MailboxBody(filing: two), of: opened) }
    }

    @Test func theSealedEnvelopeCarriesGosFixedWidthFields() throws {
        let env = try SplitMessage.seal(draft(), from: alice, to: [.init(x25519Public: bob.x25519Public)])
        #expect(env.payloadNonce == Data(count: 12))
        #expect(env.payloadTag == Data(count: 16))
        #expect(env.ratchetPubKey == Data(count: 32))
        #expect(env.recipients.first?.kdf == 2)
    }

    @Test func theStoreSignatureCoversTheEnvelopeHash() throws {
        let env = try SplitMessage.seal(draft(), from: alice, to: [.init(x25519Public: bob.x25519Public)])
        let sig = try env.storeSignature(by: alice)
        let digest = Data(SHA256.hash(data: try Canonical.marshal(env)))
        #expect(verifyEd25519(publicKey: alice.ed25519Public, message: digest, signature: sig))
    }
}

/// Go parses a header into a struct and verifies over its re-marshal: fields it doesn't know are
/// gone, and the ids are fixed arrays, so an absent or wrong-width id comes back at full width.
/// A reader has to accept and refuse what Go does (internal/core/message/split.go).
@Suite struct HeadersReadAsGoReadsThem {
    let alice = SoftwareAccountKeys(address: "alice@parity.example")
    let bob = SoftwareAccountKeys(address: "bob@parity.example")

    func header() -> Dmcn_Message_MessageHeader {
        var h = Dmcn_Message_MessageHeader()
        h.version = 1
        h.messageID = pattern(16, from: 1)
        h.threadID = pattern(16, from: 17)
        h.replyToID = Data(count: 16)
        h.senderAddress = alice.address
        h.senderPublicKey = alice.ed25519Public
        h.recipientAddress = bob.address
        h.subject = "Parity"
        h.bodyHash = fill(32, 0x05)
        return h
    }

    /// `header` as it travels, carrying a signature over the canonical `signedOver`.
    func entry(carrying header: Dmcn_Message_MessageHeader, signedOver: Dmcn_Message_MessageHeader) throws
        -> Dmcn_Relay_MailboxEntry
    {
        var signed = Dmcn_Message_SignedHeader()
        signed.header = header
        signed.senderSignature = try alice.sign(SignatureContext.messageHeader.signable(Canonical.marshal(signedOver)))
        let cek = SymmetricKey(size: .bits256)
        let bytes = try Canonical.marshal(signed)
        let sealed = try AEAD.seal(
            Padding.pad(bytes, to: Padding.sizeClass(for: bytes.count)), key: cek, aad: SealGeneration.v2.headerAAD)
        var entry = Dmcn_Relay_MailboxEntry()
        entry.recipients = [
            try KeyWrap.wrap(cek: cek, recipientPublic: bob.x25519Public, deviceID: Data(count: 16), generation: .v2)
        ]
        entry.encryptedHeader = sealed.ciphertext
        entry.headerNonce = sealed.nonce
        entry.headerTag = sealed.tag
        return entry
    }

    func withUnknownField(_ h: Dmcn_Message_MessageHeader) throws -> Dmcn_Message_MessageHeader {
        var wire = try h.serializedData()
        wire.append(contentsOf: [0xc0, 0x3e, 0x01])
        return try Dmcn_Message_MessageHeader(serializedBytes: wire)
    }

    @Test func anUnknownFieldAddedAfterSigningIsDropped() throws {
        let opened = try SplitMessage.openHeader(
            entry(carrying: withUnknownField(header()), signedOver: header()), keys: bob)
        #expect(opened.header.unknownFields.data.isEmpty)
    }

    @Test func anUnknownFieldInsideTheSignatureIsRefused() throws {
        let dirty = try withUnknownField(header())
        #expect(throws: SealError.headerSignatureInvalid) {
            try SplitMessage.openHeader(entry(carrying: dirty, signedOver: dirty), keys: bob)
        }
    }

    @Test func anAbsentIdReadsAsZeros() throws {
        var absent = header()
        absent.replyToID = Data()
        absent.threadID = Data()
        var full = header()
        full.threadID = Data(count: 16)
        let opened = try SplitMessage.openHeader(entry(carrying: absent, signedOver: full), keys: bob)
        #expect(opened.header.replyToID == Data(count: 16))
        #expect(opened.header.threadID == Data(count: 16))
    }

    @Test func aSignatureOverAnAbsentIdIsRefused() throws {
        var absent = header()
        absent.replyToID = Data()
        #expect(throws: SealError.headerSignatureInvalid) {
            try SplitMessage.openHeader(entry(carrying: absent, signedOver: absent), keys: bob)
        }
    }

    @Test func aWrongWidthIdIsCutToWidth() throws {
        var long = header()
        long.messageID = pattern(20, from: 1)
        let opened = try SplitMessage.openHeader(entry(carrying: long, signedOver: header()), keys: bob)
        #expect(opened.header.messageID == pattern(16, from: 1))
    }
}

@Suite struct PaddingRoundTrips {
    @Test(arguments: [0, 1, 1020, 1021, 70_000])
    func whatPadWritesUnpadReturns(size: Int) throws {
        let payload = pattern(size, from: 7)
        #expect(try Padding.unpad(Padding.pad(payload, to: Padding.sizeClass(for: size))) == payload)
    }

    @Test func aSliceIsReadFromItsOwnStart() throws {
        let padded = Data([0xaa, 0xbb]) + Padding.pad(Data([1, 2, 3]), to: 1024)
        #expect(try Padding.unpad(padded.dropFirst(2)) == Data([1, 2, 3]))
    }

    @Test func aBadPrefixIsRefused() {
        #expect(throws: SealError.shortPadding(3)) { try Padding.unpad(Data([0, 0, 0])) }
        #expect(throws: SealError.lengthPrefixOverflow(1, 4)) { try Padding.unpad(Data([0, 0, 0, 1])) }
    }
}
