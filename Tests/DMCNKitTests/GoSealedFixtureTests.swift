// Opens a message sealed by open-dmcn's Go implementation (Fixtures/go-sealed.json, written by
// dev/go-fixture via `make go-fixture`). The vectors pin encodings one at a time; this pins
// the whole read path against the implementation every relay and bridge runs.

import Foundation
import Testing
@testable import DMCNKit

private struct GoSealed: Decodable {
    let recipient_x25519_private: String
    let sender_ed25519_public: String
    let entry: String
    let body: String

    static func load() throws -> GoSealed {
        let url = try #require(
            Bundle.module.url(forResource: "go-sealed", withExtension: "json", subdirectory: "Fixtures"))
        return try JSONDecoder().decode(GoSealed.self, from: Data(contentsOf: url))
    }
}

@Suite struct GoSealedFixture {
    @Test func swiftOpensWhatGoSealed() throws {
        let f = try GoSealed.load()
        let bob = try SoftwareAccountKeys(
            address: "bob@parity.example", ed25519Seed: fill(32, 0x0b), x25519Private: unhex(f.recipient_x25519_private)
        )
        let entry = try Dmcn_Relay_MailboxEntry(serializedBytes: unhex(f.entry))
        let opened = try SplitMessage.openHeader(entry, keys: bob)

        #expect(opened.generation == .v2)
        let h = opened.header
        #expect(h.senderAddress == "alice@parity.example")
        #expect(h.senderPublicKey.hex == f.sender_ed25519_public)
        #expect(h.senderDisplay == "Alice")
        #expect(h.recipientAddress == "bob@parity.example")
        #expect(h.subject == "Sealed in Go, opened in Swift")
        #expect(h.snippet == "Hello from Go. ünïcödé ✓")
        #expect(h.replyToID == fill(16, 0x33))
        #expect(h.sentAt == 1_700_000_000)

        let content = try SplitMessage.openBody(Dmcn_Relay_MailboxBody(serializedBytes: unhex(f.body)), of: opened)
        #expect(String(decoding: content.body.content, as: UTF8.self) == "Hello from Go. ünïcödé ✓")
        #expect(content.alternatives.first?.contentType == "text/html")
        // The reader's snippet re-derivation (SPEC_CORE §3) agrees with what Go signed.
        #expect(snippet(contentType: content.body.contentType, content: content.body.content) == h.snippet)
    }

    @Test func aFlippedHeaderByteIsRefused() throws {
        let f = try GoSealed.load()
        let bob = try SoftwareAccountKeys(
            address: "bob@parity.example", ed25519Seed: fill(32, 0x0b), x25519Private: unhex(f.recipient_x25519_private)
        )
        var entry = try Dmcn_Relay_MailboxEntry(serializedBytes: unhex(f.entry))
        entry.encryptedHeader[entry.encryptedHeader.startIndex] ^= 0x01
        #expect(throws: (any Error).self) { try SplitMessage.openHeader(entry, keys: bob) }
    }
}
