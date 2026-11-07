import Foundation
import Testing
@testable import DMCNKit

/// The fixture the browser's real code wrote: see BrowserStoreFixtureTests.
struct BrowserStore: Decodable {
    struct Record: Decodable { let sealed: String; let version: Int }
    struct SnippetCase: Decodable { let text: String; let snippet: String }
    struct ContactIDCase: Decodable { let address: String; let id: String }
    struct SubjectCase: Decodable { let subject: String; let reply: String }

    let address: String
    let ed25519_seed: String
    let x25519_private: String
    let device_id: String
    let other_x25519_private: String
    let blob_plaintext: String
    let blob_one_recipient: SealedBlob
    let blob_two_recipients: SealedBlob
    let kv: [String: Record]
    let snippets: [SnippetCase]
    let contact_ids: [ContactIDCase]
    let reply_subjects: [SubjectCase]

    static func load() throws -> BrowserStore {
        let url = try #require(
            Bundle.module.url(forResource: "browser-store", withExtension: "json", subdirectory: "Fixtures"))
        return try JSONDecoder().decode(BrowserStore.self, from: Data(contentsOf: url))
    }

    func owner() throws -> SoftwareAccountKeys {
        try SoftwareAccountKeys(
            address: address, ed25519Seed: unhex(ed25519_seed), x25519Private: unhex(x25519_private))
    }

    func stranger() throws -> SoftwareAccountKeys {
        try SoftwareAccountKeys(
            address: "other@parity.example", ed25519Seed: fill(32, 0x01), x25519Private: unhex(other_x25519_private))
    }
}

@Suite struct SealedBlobInterop {
    @Test func opensWhatTheBrowserSealed() throws {
        let f = try BrowserStore.load()
        #expect(f.blob_one_recipient.recipients[0].kdf == 2)
        let plain = try f.blob_one_recipient.open(with: f.owner())
        #expect(String(decoding: plain, as: UTF8.self) == f.blob_plaintext)
    }

    @Test func opensWhatTheBrowserSealedToSeveralKeysWithEitherOfThem() throws {
        let f = try BrowserStore.load()
        #expect(f.blob_two_recipients.recipients[1].recipientXPub == (try f.owner().x25519Public))
        for keys in [try f.owner(), try f.stranger()] {
            let plain = try f.blob_two_recipients.open(with: keys)
            #expect(String(decoding: plain, as: UTF8.self) == f.blob_plaintext)
        }
    }

    @Test func opensWhatGoSealed() throws {
        struct GoBlob: Decodable {
            let plaintext: String
            let blob: SealedBlob
        }
        let url = try #require(
            Bundle.module.url(forResource: "go-sealed-blob", withExtension: "json", subdirectory: "Fixtures"))
        let go = try JSONDecoder().decode(GoBlob.self, from: Data(contentsOf: url))
        let plain = try go.blob.open(with: BrowserStore.load().owner())
        #expect(String(decoding: plain, as: UTF8.self) == go.plaintext)
    }

    @Test func refusesAKeyItWasNotSealedTo() throws {
        let f = try BrowserStore.load()
        #expect(throws: SealError.notARecipient) {
            try f.blob_one_recipient.open(with: SoftwareAccountKeys(address: "x@parity.example"))
        }
    }
}

@Suite struct SealedBlobShape {
    let reader = SoftwareAccountKeys(address: "reader@parity.example")
    let bystander = SoftwareAccountKeys(address: "bystander@parity.example")

    private func json(_ blob: SealedBlob) throws -> [String: JSONValue] {
        try StoreJSON.decode([String: JSONValue].self, from: StoreJSON.encode(blob))
    }

    @Test func writesGoFieldNamesWithBase64Strings() throws {
        let blob = try SealedBlob.seal(Data("hi".utf8), to: [reader.x25519Public])
        let top = try json(blob)
        #expect(Set(top.keys) == ["nonce", "ciphertext", "tag", "recipients"])
        #expect(Data(base64Encoded: top.string("nonce") ?? "")?.count == 12)
        #expect(Data(base64Encoded: top.string("tag") ?? "")?.count == 16)
        guard case .array(let recipients)? = top["recipients"], case .object(let r)? = recipients.first else {
            Issue.record("recipients is not an array of objects")
            return
        }
        #expect(
            Set(r.keys) == ["recipient_xpub", "ephemeral_xpub", "wrapped_cek", "cek_nonce", "cek_tag", "kdf"])
        #expect(r.int("kdf") == 2)
        #expect(Data(base64Encoded: r.string("recipient_xpub") ?? "") == reader.x25519Public)
        #expect(Data(base64Encoded: r.string("wrapped_cek") ?? "")?.count == 32)
    }

    @Test func leavesOutKdfForGenerationOne() throws {
        let blob = try SealedBlob.seal(Data("hi".utf8), to: [reader.x25519Public], generation: .v1)
        guard case .array(let recipients)? = try json(blob)["recipients"], case .object(let r)? = recipients.first
        else {
            Issue.record("recipients is not an array of objects")
            return
        }
        #expect(r["kdf"] == nil)
        #expect(try blob.open(with: reader) == Data("hi".utf8))
    }

    @Test func aRecordsDeclaredGenerationDecidesTheDerivation() throws {
        var blob = try SealedBlob.seal(Data("hi".utf8), to: [reader.x25519Public])
        blob.recipients[0].kdf = nil  // says generation 1 over a generation 2 wrap
        #expect(throws: SealError.notARecipient) { try blob.open(with: reader) }
        blob.recipients[0].kdf = 3  // a generation this build doesn't know
        #expect(throws: SealError.notARecipient) { try blob.open(with: reader) }
    }

    @Test func noRecipientsIsRefused() {
        #expect(throws: SealedBlobError.noRecipients) { try SealedBlob.seal(Data(), to: []) }
    }

    @Test func theReadersOwnKeyFeedsTheDerivationNotTheRecord() throws {
        // A sealer's recipient_xpub is only a hint. A wrap really made for the reader opens under
        // any label, because the v2 info is built from the key the reader holds...
        var relabelled = try SealedBlob.seal(Data("hi".utf8), to: [reader.x25519Public])
        relabelled.recipients[0].recipientXPub = bystander.x25519Public
        #expect(try relabelled.open(with: reader) == Data("hi".utf8))

        // ...and a wrap made for someone else doesn't open just because it names the reader.
        var misnamed = try SealedBlob.seal(Data("hi".utf8), to: [bystander.x25519Public])
        misnamed.recipients[0].recipientXPub = reader.x25519Public
        #expect(throws: SealError.notARecipient) { try misnamed.open(with: reader) }
    }

    @Test func aFlippedByteIsRefused() throws {
        var blob = try SealedBlob.seal(Data("hi".utf8), to: [reader.x25519Public])
        blob.ciphertext[blob.ciphertext.startIndex] ^= 0x01
        #expect(throws: SealError.notARecipient) { try blob.open(with: reader) }
    }
}

@Suite struct JSONValues {
    @Test func aDocumentRoundTripsWithNumbersIntact() throws {
        let text = #"{"big":9007199254740991,"flag":true,"half":2.5,"list":[1,null,"x",{"deep":false}],"none":null}"#
        let value = try StoreJSON.decode(JSONValue.self, from: Data(text.utf8))
        #expect(String(decoding: try StoreJSON.encode(value), as: UTF8.self) == text)
    }

    @Test func slashesAreNotEscaped() throws {
        #expect(String(decoding: try StoreJSON.encode(["a": "b/c"]), as: UTF8.self) == #"{"a":"b/c"}"#)
    }

    @Test func aLoneSurrogateDoesNotCostTheDocument() throws {
        // What JSON.stringify writes for a string cut in the middle of an emoji.
        let value = try StoreJSON.decode([String: String].self, from: Data(#"{"s":"a\ud83d…"}"#.utf8))
        #expect(value["s"] == "a\u{FFFD}…")
    }

    @Test func onlyUnpairedSurrogatesAreTouched() throws {
        // Spelled out with `esc`, since the escapes themselves are what is being tested.
        let esc = "\\u"
        func repaired(_ text: String) -> String? {
            StoreJSON.replacingLoneSurrogates(in: Data(text.utf8)).map { String(decoding: $0, as: UTF8.self) }
        }
        #expect(repaired("\(esc)d83d\(esc)de42 \\n \(esc)00e9") == nil)
        #expect(repaired("\(esc)de42") == "\(esc)fffd")
        #expect(repaired("\(esc)d83d\(esc)0041") == "\(esc)fffd\(esc)0041")
        #expect(repaired("\(esc)d83d\(esc)d83d\(esc)de42") == "\(esc)fffd\(esc)d83d\(esc)de42")
        // An escaped backslash, so what follows is text and not an escape.
        #expect(repaired(#""\\ud83d""#) == nil)
    }
}
