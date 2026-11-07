import Foundation
import Testing
@testable import DMCNKit

@Suite struct ReaderChecksRules {
    func header(signedBy key: Data, to: [String] = [], cc: [String] = [], recipient: String = "bob@parity.example")
        -> Dmcn_Message_MessageHeader
    {
        var h = Dmcn_Message_MessageHeader()
        h.senderAddress = "alice@parity.example"
        h.senderPublicKey = key
        h.recipientAddress = recipient
        h.to = to
        h.cc = cc
        return h
    }

    @Test func senderBindingComparesTheSigningKeyToTheDirectory() {
        let h = header(signedBy: fill(32, 0x01))
        #expect(ReaderChecks.senderBinding(of: h, directoryKey: fill(32, 0x01)) == .matches)
        #expect(
            ReaderChecks.senderBinding(of: h, directoryKey: fill(32, 0x02)) == .mismatch(directoryKey: fill(32, 0x02)))
        // An outage or a bridged legacy sender is unverified, never rejected.
        #expect(ReaderChecks.senderBinding(of: h, directoryKey: nil) == .unresolved)
    }

    @Test func aRecordTheDomainNoLongerVouchesForIsDisowned() {
        // Disowned means the key matches and the domain's attestation of the address failed. A key
        // that differs comes first, as SPEC_CORE §3 withholds that whatever else is true.
        let h = header(signedBy: fill(32, 0x01))
        #expect(
            ReaderChecks.senderBinding(of: h, directoryKey: fill(32, 0x01), identityUnverifiable: true) == .disowned)
        #expect(
            ReaderChecks.senderBinding(of: h, directoryKey: fill(32, 0x02), identityUnverifiable: true)
                == .mismatch(directoryKey: fill(32, 0x02)))
    }

    @Test func aHeaderCannotBuyUnboundedLookups() async {
        actor Count { var n = 0; func bump() { n += 1 } }
        let count = Count()
        let flood = (0..<5_000).map { "nobody\($0)@parity.example" }
        let h = header(signedBy: fill(32, 0x01), to: flood, recipient: flood[0])
        let result = await ReaderChecks.audience(of: h, sealedTo: fill(32, 0x0a)) { _ in
            await count.bump()
            return nil
        }
        #expect(result == .undetermined)
        #expect(await count.n == ReaderChecks.audienceLookupLimit)
    }

    @Test func theLimitLeavesARealCopyAddressedAndAResealedOneSurfaced() async {
        let others = (0..<50).map { "reader\($0)@parity.example" }
        // Every copy names its own reader first, so a long To list costs one lookup.
        let mine = header(signedBy: fill(32, 0x01), to: others, recipient: "bob@parity.example")
        let addressed = await ReaderChecks.audience(of: mine, sealedTo: fill(32, 0x0a)) {
            $0 == "bob@parity.example" ? fill(32, 0x0a) : fill(32, 0x0c)
        }
        #expect(addressed == .addressedToThisMailbox)
        // A copy re-sealed to someone outside the audience is still reported.
        let resealed = header(signedBy: fill(32, 0x01), to: others, recipient: others[0])
        let surfaced = await ReaderChecks.audience(of: resealed, sealedTo: fill(32, 0x0a)) { _ in fill(32, 0x0c) }
        #expect(surfaced == .misaddressed)
    }

    @Test func audienceIsCheckedOnTheKeyNotTheAddress() async {
        let mine = fill(32, 0x0a)
        // Sealed to the account's key through an alias: a string comparison would call it misaddressed.
        let viaAlias = header(
            signedBy: fill(32, 0x01), to: ["bob.alias@parity.example"], recipient: "bob.alias@parity.example")
        let resolved = await ReaderChecks.audience(of: viaAlias, sealedTo: mine) {
            $0 == "bob.alias@parity.example" ? mine : nil
        }
        #expect(resolved == .addressedToThisMailbox)
    }

    @Test func aCopyResealedToSomeoneElseIsMisaddressed() async {
        let h = header(signedBy: fill(32, 0x01), to: ["carol@parity.example"], recipient: "carol@parity.example")
        let result = await ReaderChecks.audience(of: h, sealedTo: fill(32, 0x0a)) { _ in fill(32, 0x0c) }
        #expect(result == .misaddressed)
    }

    @Test func aDirectoryMissIsNotEvidence() async {
        let h = header(signedBy: fill(32, 0x01), to: ["carol@parity.example"])
        #expect(await ReaderChecks.audience(of: h, sealedTo: fill(32, 0x0a)) { _ in nil } == .undetermined)
        // One miss among the audience is skipped; a later address can still match.
        let mixed = header(
            signedBy: fill(32, 0x01), to: ["gone@parity.example"], cc: ["bob@parity.example"],
            recipient: "gone@parity.example")
        let result = await ReaderChecks.audience(of: mixed, sealedTo: fill(32, 0x0a)) {
            $0 == "bob@parity.example" ? fill(32, 0x0a) : nil
        }
        #expect(result == .addressedToThisMailbox)
    }
}
