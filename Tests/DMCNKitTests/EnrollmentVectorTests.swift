// What an account signs when it's made, against the browser and Go.
//
// The record and its signature came out of the browser's buildSelfSignedRecord, and the petition
// proof out of the four lines in app/pages/Petition.tsx feeding the browser's sign(). Both were
// then run through open-dmcn's Go: IdentityRecordFromProtoBytes and Verify for the record, and
// petition.VerifyProof for the proof. Ed25519 is deterministic, so the signatures pin exactly.

import Foundation
import Testing
@testable import DMCNKit

/// Ed25519 seed 32x0x21, X25519 private 32x0x42, created 1700000000.
private let keys: KeyPayload = {
    let seed = fill(32, 0x21)
    let edPublic = unhex("884b8857f4eaa1613c61504db34d4beaf346517a0e31de3cddd4d9b4201d9d0b")
    let json = """
        {"ed25519_public":"\(edPublic.base64EncodedString())",\
        "ed25519_private":"\((seed + edPublic).base64EncodedString())",\
        "x25519_public":"\(unhex("132c442be010fbd57e72603328aa76e71fccc1503aae219327d14d9c9993f472").base64EncodedString())",\
        "x25519_private":"\(fill(32, 0x42).base64EncodedString())",\
        "device_id":"\(unhex("a0a1a2a3a4a546a7a8a9aaabacadaeaf").base64EncodedString())",\
        "created_at":1700000000}
        """
    return try! KeyPayload(serialized: Data(json.utf8))
}()

@Suite struct EnrollmentVectorTests {
    static let relayHint =
        "/dns4/relay.parity.example/tcp/7400/p2p/12D3KooWNnU1S2BMncbGpPPqWhPZQQKNtNmH5YnCaHuvti6xzVbL"
    static let recordBytes =
        """
        08011215766563746f72407061726974792e6578616d706c651a20884b8857f4eaa1613c61504db34d4beaf346517a0e\
        31de3cddd4d9b4201d9d0b2220132c442be010fbd57e72603328aa76e71fccc1503aae219327d14d9c9993f4722880e2\
        cfaa063a5c2f646e73342f72656c61792e7061726974792e6578616d706c652f7463702f373430302f7032702f313244\
        334b6f6f574e6e55315332424d6e636247705050715768505a51514b4e744e6d4835596e4361487576746936787a5662\
        4c5240b1ee52108dec9984307fba3f22e9ea5ee68dd58200871923aa3c9f115b341aefd55ce74dae877500806eae5be6\
        23b79c816c37e9489de52aaa1a581c0ca4010fd00101
        """
    static let selfSignature =
        """
        b1ee52108dec9984307fba3f22e9ea5ee68dd58200871923aa3c9f115b341aefd55ce74dae877500806eae5be623b79c\
        816c37e9489de52aaa1a581c0ca4010f
        """
    static let petitionSignable =
        """
        646d636e2d7065746974696f6e2d763100884b8857f4eaa1613c61504db34d4beaf346517a0e31de3cddd4d9b4201d9d\
        0b132c442be010fbd57e72603328aa76e71fccc1503aae219327d14d9c9993f472
        """
    static let petitionProof =
        """
        9ea6258cc22cc39ac8031a7076dd9f6625d1baf7a8119b11412c2ecdecf2a4fd115074c4ae951eb2d6d5649d6ec1edb1\
        30fa71ce2500d79e222126a982137600
        """
    @Test func theRecordIsTheBrowsers() throws {
        let record = try keys.selfSignedRecord(address: "vector@parity.example", relayHints: [Self.relayHint])
        #expect(record.selfSignature.hex == Self.selfSignature)
        #expect(try Canonical.marshal(record).hex == Self.recordBytes)
    }

    @Test func theBrowsersRecordVerifiesHere() throws {
        let record = try Dmcn_Identity_IdentityRecord(serializedBytes: unhex(Self.recordBytes))
        #expect(record.ownerSignatureIsValid())
        #expect(record.version == 1)
        #expect(record.revision == 1)
        #expect(record.createdAt == 1_700_000_000)
        #expect(record.expiresAt == 0)
        #expect(record.verificationTier == .unverified)
    }

    /// The hints are the host's to set, so a different list leaves the signature standing.
    @Test func relayHintsAreOutsideTheSignature() throws {
        let record = try keys.selfSignedRecord(address: "vector@parity.example", relayHints: [])
        #expect(record.selfSignature.hex == Self.selfSignature)
        #expect(record.ownerSignatureIsValid())
    }

    @Test func thePetitionProofIsTheBrowsers() throws {
        #expect(keys.petitionSignableBytes.hex == Self.petitionSignable)
        let proof = try keys.accountKeys(address: "").sign(keys.petitionSignableBytes)
        #expect(proof.hex == Self.petitionProof)
    }
}

/// Every row is what the browser's own validateChosenAddress said.
@Suite struct ChosenAddressTests {
    static let cases: [(String, Int, Bool)] = [
        ("me@example.me", 1, true),
        ("a@b", 1, true),
        ("alice.smith@x.example", 1, true),
        ("a-b_c.d@x", 1, true),
        ("0@x", 1, true),
        ("a1@x", 1, true),
        ("@x", 1, false),
        ("a@", 1, false),
        ("a", 1, false),
        ("", 1, false),
        ("a@b@c", 1, false),
        ("A@x", 1, false),
        ("aB@x", 1, false),
        (".a@x", 1, false),
        ("a.@x", 1, false),
        ("a..b@x", 1, false),
        ("a.-b@x", 1, false),
        ("-a@x", 1, false),
        ("a_@x", 1, false),
        ("a b@x", 1, false),
        ("a+tag@x", 1, false),
        ("é@x", 1, false),
        ("ａ@x", 1, false),
        ("a\n@x", 1, false),
        ("a@x\n", 1, true),
        ("\na@x", 1, false),
        ("🔑@x", 1, false),
        (String(repeating: "a", count: 64) + "@x", 1, false),
        (String(repeating: "a", count: 65) + "@x", 1, false),
        (String(repeating: "f", count: 64) + "@x", 1, false),
        (String(repeating: "f", count: 40) + "@x", 1, false),
        (String(repeating: "f", count: 39) + "@x", 1, true),
        (String(repeating: "f", count: 41) + "@x", 1, true),
        (String(repeating: "0123456789abcdef", count: 4) + "@x", 1, false),
        ("g" + String(repeating: "f", count: 39) + "@x", 1, true),
        (String(repeating: "F", count: 40) + "@x", 1, false),
        ("ab@x", 3, false),
        ("abc@x", 3, true),
        ("ab@x", 2, true),
        ("a-b@x", 3, true),
    ]

    @Test func agreesWithTheBrowser() {
        for (address, minLength, accepted) in Self.cases {
            #expect(
                (validateChosenAddress(address, minLength: minLength) == nil) == accepted,
                "\(address) at \(minLength)")
        }
    }

    @Test func theMessagesAreForPeople() {
        #expect(validateChosenAddress("me@example.me") == nil)
        for bad in [
            "nope", "@x", "A@x", String(repeating: "f", count: 40) + "@x", String(repeating: "a", count: 65) + "@x",
        ] {
            let message = validateChosenAddress(bad) ?? ""
            #expect(!message.isEmpty)
            #expect(!message.contains("\u{2014}"))
            #expect(!message.lowercased().contains("local"))
        }
    }
}
