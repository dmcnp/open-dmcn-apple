// Swift half of the encoding known-answer vectors.
//
// Each constant is asserted by at least one other implementation too, named beside it. A
// signature is checked by re-marshaling what was parsed, so if the Swift encoder disagrees with
// Go's deterministic marshaling by one byte, every record or header this client verifies
// fails, and every one it signs is refused.

import Foundation
import Testing
@testable import DMCNKit

// Identity record self-signed bytes. Other halves: open-dmcn
// cmd/dmcnd/web/src/lib/crypto/parityvector.test.ts and the product repository's
// internal/core/identity/parityvector_test.go.
//
// Fixed inputs: Ed25519 public = 32x0x07, X25519 public = 32x0x08, created 1700000000,
// expires 1800000000 (full record only).
@Suite struct IdentitySignableBytes {
    static let identityFull =
        "08011215766563746f72407061726974792e6578616d706c651a200707070707070707070707070707070707070707070707070707070707070707222008080808080808080808080808080808080808080808080808080808080808082880e2cfaa063080a4a7da064002b80101d00103"
    static let identityForward =
        "08011215766563746f72407061726974792e6578616d706c651a200707070707070707070707070707070707070707070707070707070707070707222008080808080808080808080808080808080808080808080808080808080808082880e2cfaa06fa0118766563746f7240656c736577686572652e6578616d706c65"
    static let identityMinimal =
        "08011215766563746f72407061726974792e6578616d706c651a200707070707070707070707070707070707070707070707070707070707070707222008080808080808080808080808080808080808080808080808080808080808082880e2cfaa06"

    static func base() -> Dmcn_Identity_IdentityRecord {
        var r = Dmcn_Identity_IdentityRecord()
        r.version = 1
        r.address = "vector@parity.example"
        r.ed25519PublicKey = fill(32, 0x07)
        r.x25519PublicKey = fill(32, 0x08)
        r.createdAt = 1_700_000_000
        return r
    }

    @Test func fullRecordSignsEveryOwnerFieldAndExcludesRelayHints() throws {
        var r = Self.base()
        r.expiresAt = 1_800_000_000
        r.relayHints = ["/dns4/relay.parity.example/tcp/7400/p2p/12D3KooWNnU1S2BMncbGpPPqWhPZQQKNtNmH5YnCaHuvti6xzVbL"]
        r.verificationTier = .init(rawValue: 2)!
        r.requireOnion = true
        r.revision = 3
        #expect(try r.ownerSignableBytes().hex == Self.identityFull)
    }

    @Test func proto3DefaultsAreAbsentFromTheBytes() throws {
        #expect(try Self.base().ownerSignableBytes().hex == Self.identityMinimal)
    }

    @Test func forwardToIsSignedWithItsTwoByteTag() throws {
        var r = Self.base()
        r.forwardTo = "vector@elsewhere.example"
        #expect(try r.ownerSignableBytes().hex == Self.identityForward)
    }

    @Test func excludesEverythingTheOwnerDoesNotSign() throws {
        // A record decoded off the wire carries operator-owned parts; none may reach the bytes.
        var r = Self.base()
        r.relayHints = ["/dns4/relay.parity.example/tcp/7400"]
        r.selfSignature = fill(64, 0x0b)
        r.routingCredential.subject = fill(32, 0x07)
        r.addressCredential.subject = fill(32, 0x07)
        r.operatorCredentials = [Dmcn_Identity_Credential()]
        r.attestations = [Dmcn_Identity_AttestationRecord()]
        #expect(try r.ownerSignableBytes().hex == Self.identityMinimal)
    }

    @Test func survivesTheWire() throws {
        var r = Self.base()
        r.forwardTo = "vector@elsewhere.example"
        r.relayHints = ["/dns4/relay.parity.example/tcp/7400"]
        r.selfSignature = fill(64, 0x05)
        let decoded = try Dmcn_Identity_IdentityRecord(serializedBytes: try r.serializedData())
        #expect(decoded.forwardTo == "vector@elsewhere.example")
        #expect(try decoded.ownerSignableBytes().hex == Self.identityForward)
    }

    @Test func aFieldThisBuildDoesNotKnowIsOutsideTheSignature() throws {
        // Field 1000, varint 1: what a record from a newer producer could carry. The allowlist
        // copy drops it, as Go's fresh-message build does.
        var wire = try Self.base().serializedData()
        wire.append(contentsOf: [0xc0, 0x3e, 0x01])
        let decoded = try Dmcn_Identity_IdentityRecord(serializedBytes: wire)
        #expect(!decoded.unknownFields.data.isEmpty)
        #expect(try decoded.ownerSignableBytes().hex == Self.identityMinimal)
    }

    @Test func aFieldThisBuildDoesNotKnowInsideTheRotationChainIsOutsideItToo() throws {
        // Go rebuilds each entry and its device credential from its own struct, so a nested
        // unknown field never reaches the signed bytes there either.
        var entry = Dmcn_Identity_RotationEntry()
        entry.version = 1
        entry.address = "vector@parity.example"
        entry.deviceCredential.subject = fill(32, 0x09)
        var clean = Self.base()
        clean.rotationChain = [entry]

        var credentialWire = try entry.deviceCredential.serializedData()
        credentialWire.append(contentsOf: [0xc0, 0x3e, 0x01])
        entry.deviceCredential = try Dmcn_Identity_Credential(serializedBytes: credentialWire)
        var entryWire = try entry.serializedData()
        entryWire.append(contentsOf: [0xc0, 0x3e, 0x01])
        var dirty = Self.base()
        dirty.rotationChain = [try Dmcn_Identity_RotationEntry(serializedBytes: entryWire)]

        #expect(!dirty.rotationChain[0].unknownFields.data.isEmpty)
        #expect(!dirty.rotationChain[0].deviceCredential.unknownFields.data.isEmpty)
        #expect(try dirty.ownerSignableBytes() == clean.ownerSignableBytes())
    }

    @Test func aSignedRecordVerifiesAndATamperedOneDoesNot() throws {
        let owner = SoftwareAccountKeys(address: "vector@parity.example")
        var r = Self.base()
        r.ed25519PublicKey = owner.ed25519Public
        r.x25519PublicKey = owner.x25519Public
        r.selfSignature = try owner.sign(SignatureContext.identitySelf.signable(r.ownerSignableBytes()))
        #expect(r.ownerSignatureIsValid())

        // Operator-owned fields may change without breaking it ...
        r.relayHints = ["/dns4/elsewhere.example/tcp/7400"]
        #expect(r.ownerSignatureIsValid())
        // ... owner-owned ones may not.
        r.forwardTo = "someone@else.example"
        #expect(!r.ownerSignatureIsValid())
    }
}

// Split-message structures. Other halves: open-dmcn internal/core/message/parity_golden_test.go
// (TestParityGolden, TestParityGoldenSenderDisplay) and the browser's protobuf.ts encoder.
@Suite struct MessageHeaderGolden {
    static let header =
        "080112100102030405060708090a0b0c0d0e0f101a10100f0e0d0c0b0a090807060504030201220d616c69636540646d636e2e6d652a200102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20320b626f6240646d636e2e6d653880e2cfaa06420d48656c6c6f2c20e4b896e7958c480150b9605a0c7072657669657720746578746a20b0b1b2b3b4b5b6b7b8b9babbbcbdbebfb0b1b2b3b4b5b6b7b8b9babbbcbdbebf"
    static let selfCopy =
        "080112100102030405060708090a0b0c0d0e0f101a10100f0e0d0c0b0a090807060504030201220d616c69636540646d636e2e6d652a200102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20320d616c69636540646d636e2e6d653880e2cfaa06420d48656c6c6f2c20e4b896e7958c480150b9605a0c7072657669657720746578746a20b0b1b2b3b4b5b6b7b8b9babbbcbdbebfb0b1b2b3b4b5b6b7b8b9babbbcbdbebf7a0b626f6240646d636e2e6d657a0d6361726f6c40646d636e2e6d6582010c6461766540646d636e2e6d658a010b65766540646d636e2e6d65"
    static let recipientCopy =
        "080112100102030405060708090a0b0c0d0e0f101a10100f0e0d0c0b0a090807060504030201220d616c69636540646d636e2e6d652a200102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20320b626f6240646d636e2e6d653880e2cfaa06420d48656c6c6f2c20e4b896e7958c480150b9605a0c7072657669657720746578746a20b0b1b2b3b4b5b6b7b8b9babbbcbdbebfb0b1b2b3b4b5b6b7b8b9babbbcbdbebf7a0b626f6240646d636e2e6d657a0d6361726f6c40646d636e2e6d6582010c6461766540646d636e2e6d65"
    static let senderDisplay =
        "080112100102030405060708090a0b0c0d0e0f101a10100f0e0d0c0b0a09080706050403020122166e6f7265706c79407265646469746d61696c2e636f6d2a200102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20320b626f6240646d636e2e6d653880e2cfaa06420d48656c6c6f2c20e4b896e7958c480150b9605a0c7072657669657720746578746210000000000000000000000000000000006a20b0b1b2b3b4b5b6b7b8b9babbbcbdbebfb0b1b2b3b4b5b6b7b8b9babbbcbdbebf920106526564646974"
    static let content = "0a1d0a0a746578742f706c61696e120f74686520626f647920e4b896e7958c"

    static func header(recipient: String = "bob@dmcn.me") -> Dmcn_Message_MessageHeader {
        var h = Dmcn_Message_MessageHeader()
        h.version = 1
        h.messageID = pattern(16, from: 1)
        h.threadID = Data((1...16).reversed())
        h.senderAddress = "alice@dmcn.me"
        h.senderPublicKey = pattern(32, from: 1)
        h.recipientAddress = recipient
        h.sentAt = 1_700_000_000
        h.subject = "Hello, 世界"
        h.attachmentCount = 1
        h.bodySize = 12345
        h.snippet = "preview text"
        h.bodyHash = Data((0..<32).map { UInt8(0xb0 + $0 % 16) })
        return h
    }

    @Test func header() throws {
        #expect(try Canonical.marshal(Self.header()).hex == Self.header)
    }

    @Test func recipientListsOnTheSelfCopyAndTheRecipientCopy() throws {
        // A recipient copy omits bcc entirely, which is what keeps Bcc recipients hidden.
        var mine = Self.header(recipient: "alice@dmcn.me")
        mine.to = ["bob@dmcn.me", "carol@dmcn.me"]
        mine.cc = ["dave@dmcn.me"]
        mine.bcc = ["eve@dmcn.me"]
        #expect(try Canonical.marshal(mine).hex == Self.selfCopy)

        var theirs = Self.header()
        theirs.to = ["bob@dmcn.me", "carol@dmcn.me"]
        theirs.cc = ["dave@dmcn.me"]
        #expect(try Canonical.marshal(theirs).hex == Self.recipientCopy)
    }

    @Test func senderDisplayWithTheAlwaysEmittedReplyToID() throws {
        var h = Self.header()
        h.senderAddress = "noreply@redditmail.com"
        h.replyToID = Data(count: 16)
        h.senderDisplay = "Reddit"
        #expect(try Canonical.marshal(h).hex == Self.senderDisplay)
    }

    @Test func messageContent() throws {
        var c = Dmcn_Message_MessageContent()
        c.body.contentType = "text/plain"
        c.body.content = Data("the body 世界".utf8)
        #expect(try Canonical.marshal(c).hex == Self.content)
    }
}

// Other halves: Go message.ComputeBodyContentAddress and snippetOf; the browser's split.ts.
@Suite struct BodyCommitments {
    @Test func contentAddressIsCIDv1RawSha256() {
        let cid = bodyContentAddress(nonce: fill(12, 0x04), ciphertext: fill(26, 0x09), tag: fill(16, 0x0a))
        #expect(cid.hex == "015512203946fa8f9480c933c7f5efb0a06254d612940e924ecdebd2e041e2425802d306")
    }

    @Test func snippetMatchesTheGoCases() {
        let u = { (s: String) in Data(s.utf8) }
        #expect(snippet(contentType: "text/plain", content: u("hello, parity")) == "hello, parity")
        // A character straddling byte 140 is dropped whole.
        #expect(
            snippet(contentType: "text/plain", content: u(String(repeating: "a", count: 138) + "€uro"))
                == String(repeating: "a", count: 138))
        // Exactly 140 ASCII bytes are kept whole; the tail is cut.
        #expect(
            snippet(contentType: "text/plain", content: u(String(repeating: "b", count: 140) + "tail"))
                == String(repeating: "b", count: 140))
        // A non-text body has no snippet.
        #expect(snippet(contentType: "text/html", content: u("<b>x</b>")) == "")
        // Multibyte text under the cap is intact.
        #expect(snippet(contentType: "text/plain", content: u("héllo wörld ✓")) == "héllo wörld ✓")
    }
}
