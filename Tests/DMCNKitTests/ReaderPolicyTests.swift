import Foundation
import Testing
@testable import DMCNKit

// The grid is the browser's own answer: every row comes from the lines of MessageReader.tsx, cut out
// and run. A row is compared whole, unless one of the kit's deliberate differences applies to it, and
// those are spelled out in `web(…)` below and nowhere else. The table after it is the same logic in a
// form a person can read.

private struct Grid: Decodable {
    let bools: [String]
    let sender_key: String
    let my_key: String
    let ada: String
    let me: String
    let contacts: [ContactRecord?]
    let filters: [FilterList?]
    let attestations: [BridgeAttestation?]
    let receipts: [DeliveryReceiptView?]
    let trusts: [TrustJSON?]
    let bodies: [[Int]]
    let tables: Tables
    let main: [String]
    let ready: [String]
    let own: [String]
    let settings: [String]

    struct Tables: Decodable {
        let copy: [String]
        let label: [String]
        let warning: [String]
        let checks: [String]
    }
}

private let grid: Result<Grid, any Error> = Result { try fixture("browser-reader-grid") }

private struct WebCopy: Decodable { let hiddenTitle, hiddenDetail, plainTitle, plainDetail: String }

/// One row as the browser answered it.
private struct WebRow {
    let flags: [String: Bool]
    let reason: String
    let category: String
    let copy: WebCopy
    let label: String
    let warning: String
    let checks: ViewJSON?

    init(_ code: String, _ grid: Grid) throws {
        let parts = code.split(separator: ".").map(String.init)
        let bits = Int(parts[0], radix: 36)!
        flags = Dictionary(uniqueKeysWithValues: grid.bools.enumerated().map { ($1, bits & (1 << $0) != 0) })
        reason = parts[1]
        category = parts[2]
        copy = try JSONDecoder().decode(WebCopy.self, from: Data(grid.tables.copy[Int(parts[3])!].utf8))
        label = grid.tables.label[Int(parts[4])!]
        warning = grid.tables.warning[Int(parts[5])!]
        checks =
            parts[6] == "-"
            ? nil : try JSONDecoder().decode(ViewJSON.self, from: Data(grid.tables.checks[Int(parts[6])!].utf8))
    }
}

private func input(
    _ grid: Grid, contact: ContactRecord? = nil, filter: FilterList? = nil, attestation: BridgeAttestation? = nil,
    receipt: DeliveryReceiptView? = nil, trust: SenderTrust? = nil, settled: Bool = true, bridgeResolved: Bool = true,
    contactsReady: Bool = true, filterReady: Bool = true, revealed: Bool = false, messageTrusted: Bool = false,
    html: Bool = false, original: Bool = false, remote: Bool = false
) -> ReaderInput {
    ReaderInput(
        senderAddress: grid.ada, senderPublicKey: JSText.atob(grid.sender_key)!, senderDisplay: "Ada from the Wire",
        recipientAddress: grid.me, to: [grid.me, "zed@parity.example"], accountAddress: grid.me,
        accountSigningKeys: [JSText.atob(grid.my_key)!], contact: contact,
        counterpartyContactName: contact?.name ?? "", contactsReady: contactsReady, filter: filter,
        filterReady: filterReady, attestation: attestation, receipt: receipt, bridgeResolved: bridgeResolved,
        hasHTML: html, hasOriginal: original, nativeTrust: trust, nativeTrustSettled: settled, revealed: revealed,
        messageTrusted: messageTrusted, remoteImagesForTrusted: remote, locale: fixtureLocale,
        timeZone: fixtureTimeZone)
}

private func expectSame(_ d: ReaderDecision, _ web: WebRow, _ context: String, grants: Bool = true) {
    #expect(d.ownMessage == web.flags["ownMessage"], "\(context)")
    #expect(d.keyChanged == web.flags["keyChanged"], "\(context)")
    #expect(d.trustReady == web.flags["trustReady"], "\(context)")
    #expect(d.gated == web.flags["gated"], "\(context)")
    #expect(d.plainShown == web.flags["plainShown"], "\(context)")
    #expect(d.trustActionable == web.flags["trustActionable"], "\(context)")
    #expect(d.overrideActionable == web.flags["overrideActionable"], "\(context)")
    if grants {
        #expect(d.downloadsUnlocked == web.flags["downloadsUnlocked"], "\(context)")
        #expect(d.htmlAllowed == web.flags["htmlAllowed"], "\(context)")
        #expect(d.remoteImagesAllowed == web.flags["remoteImagesAllowed"], "\(context)")
        #expect(d.showSource == web.flags["showSource"], "\(context)")
    }
    #expect(String(d.gateReason.rawValue.prefix(1)) == web.reason, "\(context)")
    #expect(d.gateCopy.hiddenTitle == web.copy.hiddenTitle, "\(context)")
    #expect(d.gateCopy.hiddenDetail == web.copy.hiddenDetail, "\(context)")
    #expect(d.gateCopy.plainTitle == web.copy.plainTitle, "\(context)")
    #expect(d.gateCopy.plainDetail == web.copy.plainDetail, "\(context)")
    #expect(d.trustLabel == web.label, "\(context)")
    #expect(d.htmlWarning == web.warning, "\(context)")
    #expect(d.checks.map(ViewJSON.init) == web.checks, "\(context)")
}

/// The key matches, but the domain disowns the address: its text can be read behind the gate, and
/// nothing else about it is believed. Only a block outranks this.
private func expectDisowned(_ d: ReaderDecision, _ context: String) {
    #expect(d.disowned && !d.withheld, "\(context)")
    #expect(!d.trustActionable && !d.overrideActionable, "\(context)")
    #expect(!d.remoteImagesAllowed, "\(context)")
    #expect(d.counterpartyName == "Sender not vouched for", "\(context)")
    #expect(d.counterpartyAddress == nil, "\(context)")
    #expect(d.initials == "?", "\(context)")
}

/// SPEC_CORE §3, for a message whose key differs: nothing opens it, whatever else is true.
private func expectWithheld(_ d: ReaderDecision, _ context: String) {
    #expect(d.withheld, "\(context)")
    #expect(d.trustReady && d.gated, "\(context)")
    #expect(!d.plainShown && !d.plainTextOffered, "\(context)")
    #expect(!d.trustActionable && !d.overrideActionable, "\(context)")
    #expect(!d.downloadsUnlocked && !d.htmlAllowed && !d.remoteImagesAllowed && !d.showSource, "\(context)")
    #expect(d.counterpartyAddress == nil, "\(context)")
    #expect(d.counterpartyName == "Possibly forged sender", "\(context)")
    #expect(d.initials == "?", "\(context)")
    let words = "\(d.gateCopy.hiddenDetail) \(d.gateCopy.plainDetail)".lowercased()
    #expect(!words.contains("plain text"), "\(context)")
    #expect(d.checks?.checks.first?.word == .sender && d.checks?.checks.first?.ok == false, "\(context)")
    #expect(d.checks?.source.kind == .dmcn, "\(context)")
}

@Suite struct ReaderPolicyAgainstTheBrowser {
    @Test func everyCombinationOfSenderFilterBodyAndVerdict() throws {
        let g = try grid.get()
        var row = 0
        var compared = 0
        var withheld = 0
        var stapled = 0
        var disownedAttached = 0
        for (ci, contact) in g.contacts.enumerated() {
            for (fi, filter) in g.filters.enumerated() {
                for body in g.bodies {
                    let attestation = g.attestations[body[0]]
                    let receipt = g.receipts[body[1]]
                    for (ti, trust) in g.trusts.enumerated() {
                        for revealed in [false, true] {
                            for messageTrusted in [false, true] {
                                for html in [false, true] {
                                    defer { row += 1 }
                                    let context =
                                        "row \(row): contact \(ci) filter \(fi) body \(body) verdict \(ti) revealed \(revealed) trusted \(messageTrusted) html \(html)"
                                    let d = ReaderPolicy.decide(
                                        input(
                                            g, contact: contact, filter: filter, attestation: attestation,
                                            receipt: receipt,
                                            trust: trust?.trust, revealed: revealed, messageTrusted: messageTrusted,
                                            html: html, original: true, remote: true))
                                    if trust?.trust.kind == .keyMismatch {
                                        // The browser peeks here. SPEC_CORE §3 doesn't allow it.
                                        expectWithheld(d, context)
                                        withheld += 1
                                    } else if trust?.trust.kind == .identityUnverifiable {
                                        expectDisowned(d, context)
                                        if attestation == nil, receipt == nil {
                                            expectSame(d, try WebRow(g.main[row], g), context)
                                            compared += 1
                                        } else {
                                            // The browser believes what's attached to a disowned message.
                                            // The sender attached it, and nothing here speaks for them.
                                            #expect(!d.htmlAllowed || d.ownMessage || messageTrusted, "\(context)")
                                            disownedAttached += 1
                                        }
                                    } else if attestation != nil, receipt != nil {
                                        // A receipt on bridged mail is the outsider's attachment, so the
                                        // answer is the browser's for the same message without one.
                                        let without = row - stapledOffset(g)
                                        expectSame(d, try WebRow(g.main[without], g), context)
                                        stapled += 1
                                    } else {
                                        expectSame(d, try WebRow(g.main[row], g), context)
                                        compared += 1
                                    }
                                    #expect(d.withheld == (trust?.trust.kind == .keyMismatch))
                                }
                            }
                        }
                    }
                }
            }
        }
        #expect(row == g.main.count)
        #expect(compared > 7000 && withheld > 1000 && stapled > 500 && disownedAttached > 500)
    }

    /// How far back, in rows, the body without the receipt sits. The body with both is last in the
    /// list, and the one with the same attestation alone is third.
    private func stapledOffset(_ g: Grid) -> Int {
        let rowsPerBody = g.trusts.count * 8
        let both = g.bodies.firstIndex { $0[0] != 0 && $0[1] != 0 }!
        let alone = g.bodies.firstIndex { $0[0] == g.bodies[both][0] && $0[1] == 0 }!
        return (both - alone) * rowsPerBody
    }

    @Test func everythingThatMayStillBeLoading() throws {
        let g = try grid.get()
        var row = 0
        for contactsReady in [false, true] {
            for filterReady in [false, true] {
                for bridgeResolved in [false, true] {
                    for settled in [false, true] {
                        for ci in [0, 2, 3] {
                            for ai in [0, 2] {
                                for ri in [0, 2] {
                                    for ti in [1, 3, 4, 7] {
                                        for revealed in [false, true] {
                                            defer { row += 1 }
                                            let trust = settled ? g.trusts[ti]?.trust : nil
                                            let web = try WebRow(g.ready[row], g)
                                            let d = ReaderPolicy.decide(
                                                input(
                                                    g, contact: g.contacts[ci], attestation: g.attestations[ai],
                                                    receipt: g.receipts[ri], trust: trust, settled: settled,
                                                    bridgeResolved: bridgeResolved, contactsReady: contactsReady,
                                                    filterReady: filterReady, revealed: revealed, html: true,
                                                    original: true,
                                                    remote: true))
                                            let context = "ready row \(row)"
                                            if !settled {
                                                // Nothing's decided until the verdict is in, for any sender.
                                                #expect(
                                                    !d.trustReady && !d.gated && !d.plainShown && !d.plainTextOffered,
                                                    "\(context)")
                                                #expect(d.checks == nil, "\(context)")
                                            } else if trust?.kind == .keyMismatch {
                                                #expect(d.withheld, "\(context)")
                                                #expect(
                                                    !d.plainShown && !d.downloadsUnlocked && !d.htmlAllowed,
                                                    "\(context)")
                                            } else if trust?.kind == .identityUnverifiable {
                                                #expect(d.disowned, "\(context)")
                                                #expect(!d.htmlAllowed && !d.downloadsUnlocked, "\(context)")
                                            } else if ai != 0 && ri != 0 {
                                                #expect(
                                                    d.checks == nil || d.checks?.source.kind == .regular, "\(context)")
                                            } else {
                                                expectSame(d, web, context, grants: web.flags["trustReady"] == true)
                                            }
                                            if !d.trustReady {
                                                // The browser's downloads and source unlock a moment early. Nothing does here.
                                                #expect(
                                                    !d.downloadsUnlocked && !d.htmlAllowed && !d.remoteImagesAllowed
                                                        && !d.showSource, "\(context)")
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        #expect(row == g.ready.count)
    }

    @Test func theReadersOwnMail() throws {
        let g = try grid.get()
        var row = 0
        for sentView in [false, true] {
            for upper in [false, true] {
                for ci in [0, 3] {
                    for ai in [0, 2, 3] {
                        for revealed in [false, true] {
                            for html in [false, true] {
                                for remote in [false, true] {
                                    for original in [false, true] {
                                        defer { row += 1 }
                                        var i = input(
                                            g, contact: g.contacts[ci], attestation: g.attestations[ai], settled: true,
                                            revealed: revealed, html: html, original: original, remote: remote)
                                        i.senderAddress = upper ? g.me.uppercased() : g.me
                                        i.senderPublicKey = JSText.atob(g.my_key)!
                                        i.senderDisplay = ""
                                        i.sentView = sentView
                                        i.counterpartyContactName = ""
                                        expectSame(ReaderPolicy.decide(i), try WebRow(g.own[row], g), "own row \(row)")
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        #expect(row == g.own.count)
    }

    @Test func remoteImagesAndSource() throws {
        let g = try grid.get()
        var row = 0
        for ci in [0, 3] {
            for ai in [0, 2, 3] {
                for ti in [1, 3, 5] {
                    for revealed in [false, true] {
                        for messageTrusted in [false, true] {
                            for remote in [false, true] {
                                for original in [false, true] {
                                    for html in [false, true] {
                                        defer { row += 1 }
                                        let d = ReaderPolicy.decide(
                                            input(
                                                g, contact: g.contacts[ci], attestation: g.attestations[ai],
                                                trust: g.trusts[ti]?.trust, revealed: revealed,
                                                messageTrusted: messageTrusted, html: html, original: original,
                                                remote: remote))
                                        expectSame(d, try WebRow(g.settings[row], g), "settings row \(row)")
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        #expect(row == g.settings.count)
    }
}

/// One line per gate state, for people.
@Suite struct ReaderPolicyTable {
    static let key = fill(32, 0x11)
    static let keyB64 = key.base64EncodedString()
    static let ada = "ada@parity.example"

    static func pinned(_ key: Data = key) -> ContactRecord {
        ContactRecord(
            address: ada, name: "Ada Okafor", fingerprint: "fp", provenance: .userApproved,
            ed25519Pub: key.base64EncodedString(), x25519Pub: fill(32, 0x33).base64EncodedString())
    }
    static let legacyContact = ContactRecord(
        address: ada, name: "Ada Okafor", fingerprint: "", provenance: .userApproved)
    static let blockAda = FilterList(senders: [ada])
    static func bridged(_ tier: Dmcn_Bridge_BridgeTrustTier) -> BridgeAttestation {
        BridgeAttestation(verified: true, trustTier: tier, smtpFrom: ada, spf: "pass", dkim: "pass", dmarc: "pass")
    }

    static func facts(
        contact: ContactRecord? = nil, filter: FilterList? = nil, attestation: BridgeAttestation? = nil,
        trust: SenderTrust.Kind? = .unknownPending, revealed: Bool = false, messageTrusted: Bool = false,
        html: Bool = true
    ) -> ReaderInput {
        ReaderInput(
            senderAddress: ada, senderPublicKey: key, senderDisplay: "Forged Name", to: ["me@parity.example"],
            accountAddress: "me@parity.example", accountSigningKeys: [fill(32, 0x55)], contact: contact,
            counterpartyContactName: contact?.name ?? "", contactsReady: true, filter: filter, filterReady: true,
            attestation: attestation, bridgeResolved: true, hasHTML: html, hasOriginal: true,
            nativeTrust: trust.map { SenderTrust(kind: $0) }, nativeTrustSettled: true, revealed: revealed,
            messageTrusted: messageTrusted, remoteImagesForTrusted: true)
    }

    struct Row: Sendable, CustomTestStringConvertible {
        let name: String
        let input: ReaderInput
        let reason: GateReason
        let gated, plain, trust, override, unlocked, remote: Bool
        var testDescription: String { name }
    }

    static let rows: [Row] = [
        // name, facts,                                                      reason,          gated  plain  trust  over   unlock remote
        .init(
            name: "allowlisted contact opens", input: facts(contact: pinned(), trust: .allowlisted), reason: .unknown,
            gated: false, plain: false, trust: true, override: false, unlocked: true, remote: true),
        .init(
            name: "bridge-authenticated legacy contact opens",
            input: facts(contact: legacyContact, attestation: bridged(.verifiedLegacy), trust: .directoryMissing),
            reason: .unknown,
            gated: false, plain: false, trust: true, override: false, unlocked: true, remote: true),
        .init(
            name: "unknown sender, hidden", input: facts(), reason: .unknown,
            gated: true, plain: false, trust: true, override: false, unlocked: false, remote: false),
        .init(
            name: "unknown sender, peeking", input: facts(revealed: true), reason: .unknown,
            gated: true, plain: true, trust: true, override: false, unlocked: false, remote: false),
        .init(
            name: "legacy contact with nothing vouching, hidden",
            input: facts(contact: legacyContact, trust: .directoryMissing), reason: .unknown,
            gated: true, plain: false, trust: false, override: true, unlocked: false, remote: false),
        .init(
            name: "blocked, hidden", input: facts(filter: blockAda), reason: .blocked,
            gated: true, plain: false, trust: false, override: false, unlocked: false, remote: false),
        .init(
            name: "blocked, peeking", input: facts(filter: blockAda, revealed: true), reason: .blocked,
            gated: true, plain: true, trust: false, override: false, unlocked: false, remote: false),
        .init(
            name: "blocked outranks a contact", input: facts(contact: pinned(), filter: blockAda, trust: .allowlisted),
            reason: .blocked,
            gated: true, plain: false, trust: false, override: false, unlocked: false, remote: false),
        .init(
            name: "failed checks open onto text",
            input: facts(attestation: bridged(.suspicious), trust: .directoryMissing), reason: .unauthenticated,
            gated: true, plain: true, trust: false, override: true, unlocked: false, remote: false),
        .init(
            name: "failed checks with no HTML",
            input: facts(attestation: bridged(.unverifiedLegacy), trust: .directoryMissing, html: false),
            reason: .unauthenticated,
            gated: true, plain: true, trust: false, override: false, unlocked: false, remote: false),
        .init(
            name: "failed checks, HTML anyway: no remote images",
            input: facts(attestation: bridged(.suspicious), trust: .directoryMissing, messageTrusted: true),
            reason: .unauthenticated,
            gated: false, plain: false, trust: false, override: true, unlocked: true, remote: false),
        .init(
            name: "a contact's key changed, hidden", input: facts(contact: pinned(fill(32, 0x22)), trust: .keyChanged),
            reason: .impersonation,
            gated: true, plain: false, trust: true, override: true, unlocked: false, remote: false),
        .init(
            name: "a contact's key changed, peeking",
            input: facts(contact: pinned(fill(32, 0x22)), trust: .keyChanged, revealed: true), reason: .impersonation,
            gated: true, plain: true, trust: true, override: true, unlocked: false, remote: false),
        .init(
            name: "a contact's key changed, HTML anyway",
            input: facts(contact: pinned(fill(32, 0x22)), trust: .keyChanged, messageTrusted: true),
            reason: .impersonation,
            gated: false, plain: false, trust: true, override: true, unlocked: true, remote: false),
        .init(
            name: "record changed still opens, warned", input: facts(contact: pinned(), trust: .recordChanged),
            reason: .unknown,
            gated: false, plain: false, trust: true, override: false, unlocked: true, remote: true),
    ]

    @Test(arguments: rows) func gate(_ row: Row) {
        let d = ReaderPolicy.decide(row.input)
        #expect(d.trustReady)
        #expect(d.gateReason == row.reason)
        #expect(d.gated == row.gated)
        #expect(d.plainShown == row.plain)
        #expect(d.trustActionable == row.trust)
        #expect(d.overrideActionable == row.override)
        #expect(d.downloadsUnlocked == row.unlocked)
        #expect(d.htmlAllowed == (row.input.hasHTML && row.unlocked))
        #expect(d.remoteImagesAllowed == row.remote)
        #expect(!d.withheld)
    }

    @Test func aKeyChangeAsksForTheNewKeyAndSaysSo() {
        let d = ReaderPolicy.decide(Self.facts(contact: Self.pinned(fill(32, 0x22)), trust: .keyChanged))
        #expect(d.trustLabel == "Trust new key")
        #expect(d.gateCopy.hiddenDetail.contains("before you trust the new key."))
        #expect(d.htmlWarning.contains("Ada’s new key is still unconfirmed"))
    }

    @Test func aContactTheVerdictCantReachIsToldApartFromAStranger() {
        let known = ReaderPolicy.decide(Self.facts(contact: Self.legacyContact, trust: .directoryMissing))
        #expect(known.gateCopy.hiddenDetail.hasPrefix("ada@parity.example is in your contacts"))
        #expect(ReaderPolicy.decide(Self.facts()).gateCopy.hiddenDetail.hasPrefix("You don’t know this sender yet"))
    }
}

/// SPEC_CORE §3: "a reader MUST NOT render its body, attachments or HTML, and MUST NOT present the
/// claimed address as attribution."
@Suite struct ReaderPolicyWithheld {
    typealias T = ReaderPolicyTable

    @Test func theKeyTheDirectoryDoesNotList() {
        let d = ReaderPolicy.decide(T.facts(trust: .keyMismatch))
        expectWithheld(d, "mismatch")
        #expect(d.gateCopy.hiddenTitle == "Message hidden")
        #expect(
            d.gateCopy.hiddenDetail.hasPrefix("This message says it is from ada@parity.example, but it wasn't signed"))
    }

    @Test func aRecordTheDomainDisowns() {
        let d = ReaderPolicy.decide(T.facts(trust: .identityUnverifiable))
        expectDisowned(d, "disowned")
        #expect(d.gated && d.plainTextOffered)
        #expect(!d.htmlAllowed && !d.downloadsUnlocked)
    }

    @Test func aDisownedContactStaysGatedAndUnnamed() {
        var i = T.facts(trust: .identityUnverifiable)
        i.contact = ContactRecord(address: T.ada, name: "Ada Okafor", fingerprint: "fp")
        let d = ReaderPolicy.decide(i)
        expectDisowned(d, "a contact")
        #expect(d.gated && !d.htmlAllowed)
    }

    @Test func aContactWithNoKeyNeedsTheDirectoryToConfirmIt() {
        let contact = ContactRecord(address: T.ada, name: "Ada Okafor", fingerprint: "")
        var outage = T.facts(trust: .directoryMissing)
        outage.contact = contact
        let held = ReaderPolicy.decide(outage)
        #expect(held.gated && held.plainTextOffered)
        #expect(!held.htmlAllowed && !held.downloadsUnlocked)
        #expect(!held.trustActionable)
        #expect(held.gateCopy.hiddenDetail.contains("could not be checked"))

        var confirmed = T.facts(trust: .allowlisted)
        confirmed.contact = contact
        #expect(!ReaderPolicy.decide(confirmed).gated)
    }

    @Test func aContactHeldForAnUncheckedMessageCanStillOpenIt() {
        var i = T.facts(trust: .directoryMissing)
        i.contact = ContactRecord(address: T.ada, name: "Ada Okafor", fingerprint: "")
        i.hasHTML = true
        #expect(ReaderPolicy.decide(i).overrideActionable)
        i.messageTrusted = true
        let opened = ReaderPolicy.decide(i)
        #expect(!opened.gated && opened.htmlAllowed && !opened.remoteImagesAllowed)
    }

    @Test func nothingTheReaderDoesOpensIt() {
        let d = ReaderPolicy.decide(T.facts(trust: .keyMismatch, revealed: true, messageTrusted: true))
        expectWithheld(d, "revealed and trusted")
    }

    @Test func aContactOrABridgeVerdictDoesntEither() {
        expectWithheld(
            ReaderPolicy.decide(T.facts(contact: T.pinned(), trust: .keyMismatch)), "contact")
        // The address has an identity, so a bridge-carried message claiming it isn't from it, however
        // well it authenticated as legacy mail. The browser's exemption here is the same non-conformance.
        let bridged = ReaderPolicy.decide(T.facts(attestation: T.bridged(.verifiedLegacy), trust: .keyMismatch))
        expectWithheld(bridged, "bridged")
        #expect(bridged.checks?.source.kind == .dmcn)
        #expect(bridged.gateReason == .impersonation)
    }

    @Test func aBlockIsKeptButDoesntPromiseThePeek() {
        let d = ReaderPolicy.decide(T.facts(filter: T.blockAda, trust: .keyMismatch))
        expectWithheld(d, "blocked")
        #expect(d.gateReason == .blocked)
    }

    @Test func theListsCheckCountsEvenWithNoVerdictYet() {
        // `Inbox` won't fetch this body, so the reader must not wait on one.
        var i = T.facts(trust: nil)
        i.nativeTrustSettled = false
        i.bridgeResolved = false
        i.listedAs = .mismatch(claimed: T.ada)
        expectWithheld(ReaderPolicy.decide(i), "from the list")
        i.nativeTrustSettled = true
        i.listedAs = .disowned(claimed: T.ada)
        expectDisowned(ReaderPolicy.decide(i), "from the list")
    }

    @Test func aNameTheForgerChoseIsntRepeated() {
        let d = ReaderPolicy.decide(T.facts(trust: .keyMismatch))
        for text in [d.counterpartyName, d.gateCopy.hiddenDetail, d.checks?.notice?.text ?? ""] {
            #expect(!text.contains("Forged Name"))
        }
    }
}

/// The address isn't proof of anything: the browser takes it as proof of "this is your own mail".
@Suite struct ReaderPolicyForgedOwnAddress {
    func facts(key: Data, trust: SenderTrust.Kind?, settled: Bool = true) -> ReaderInput {
        ReaderInput(
            senderAddress: "ME@parity.example", senderPublicKey: key, senderDisplay: "You", to: ["me@parity.example"],
            accountAddress: "me@parity.example", accountSigningKeys: [fill(32, 0x55), fill(32, 0x56)],
            contactsReady: true,
            filterReady: true, bridgeResolved: true, hasHTML: true, nativeTrust: trust.map { SenderTrust(kind: $0) },
            nativeTrustSettled: settled, remoteImagesForTrusted: true)
    }

    @Test func aKeyOfTheAccountsIsTheirOwn() {
        #expect(ReaderPolicy.decide(facts(key: fill(32, 0x55), trust: nil, settled: false)).ownMessage)
        // A retired key still wrote this mail, before the rotation.
        #expect(ReaderPolicy.decide(facts(key: fill(32, 0x56), trust: nil, settled: false)).ownMessage)
    }

    @Test func anyOtherKeyIsAForgery() {
        let d = ReaderPolicy.decide(facts(key: fill(32, 0x66), trust: .keyMismatch))
        #expect(!d.ownMessage)
        expectWithheld(d, "forged own address")
        #expect(d.checks?.source.kind != .own)
    }

    @Test func andADirectoryOutageDoesntHelpIt() {
        let d = ReaderPolicy.decide(facts(key: fill(32, 0x66), trust: .directoryMissing))
        #expect(!d.ownMessage)
        #expect(d.gated && !d.htmlAllowed && !d.downloadsUnlocked)
        #expect(d.checks?.source.kind == .dmcn)
    }

    @Test func theSentFolderIsTheAccountsOwnStore() {
        var i = facts(key: fill(32, 0x77), trust: nil, settled: false)
        i.sentView = true
        #expect(ReaderPolicy.decide(i).ownMessage)
    }
}

/// A verified receipt opens everything, so what counts as one matters.
@Suite struct ReaderPolicyStapledReceipt {
    typealias T = ReaderPolicyTable
    let receipt = DeliveryReceiptView(verified: true, delivered: false, recipientEmail: "bob@legacy.example")

    @Test func aReceiptOnItsOwnPassesTheGate() {
        var i = T.facts(trust: .directoryMissing)
        i.receipt = receipt
        let d = ReaderPolicy.decide(i)
        #expect(!d.gated && d.checks?.source.kind == .receipt)
    }

    @Test func aReceiptOnBridgedMailIsTheSendersAttachment() {
        // The bridge passes a legacy sender's attachments through, and signs the header either way.
        var i = T.facts(attestation: T.bridged(.suspicious), trust: .directoryMissing)
        i.receipt = receipt
        let d = ReaderPolicy.decide(i)
        #expect(d.gated && d.plainShown && !d.htmlAllowed && !d.downloadsUnlocked)
        #expect(d.gateReason == .unauthenticated)
        #expect(d.checks?.source.kind == .regular)
    }
}

@Suite struct ReaderActionRules {
    typealias T = ReaderPolicyTable
    let directory = DirectoryAnswer(
        ed25519Pub: T.keyB64, x25519Pub: fill(32, 0x33).base64EncodedString(), fingerprint: "dirfp",
        adminKeyCustody: true)
    let handAdded = ContactRecord(address: T.ada, name: "Ada", fingerprint: "")

    @Test func aContactIsPinnedOnceTheirKeyIsConfirmed() {
        for kind in [SenderTrust.Kind.allowlisted, .domainVerified] {
            let trust = SenderTrust(kind: kind)
            #expect(ReaderActions.wantsLazyPin(ownMessage: false, trust: trust, contact: handAdded))
            let facts = ReaderActions.lazyPin(
                ownMessage: false, trust: trust, contact: handAdded, senderPublicKey: T.key, directory: directory)
            #expect(facts == PinnedFacts(directory: directory))
            #expect(facts?.adminKeyCustody == true)
        }
    }

    @Test func nothingElseIsPinned() {
        let confirmed = SenderTrust(kind: .allowlisted)
        func pin(own: Bool = false, trust: SenderTrust? = confirmed, contact: ContactRecord?, key: Data = T.key)
            -> PinnedFacts?
        {
            ReaderActions.lazyPin(
                ownMessage: own, trust: trust, contact: contact, senderPublicKey: key, directory: directory)
        }
        #expect(pin(own: true, contact: handAdded) == nil)
        #expect(pin(contact: nil) == nil)
        #expect(pin(contact: T.pinned()) == nil)  // already pinned
        for kind in SenderTrust.Kind.allCases where kind != .allowlisted && kind != .domainVerified {
            #expect(pin(trust: SenderTrust(kind: kind), contact: handAdded) == nil, "\(kind)")
        }
        #expect(pin(trust: nil, contact: handAdded) == nil)
        // The directory moved between the verdict and the pin: not the key this was about.
        #expect(pin(contact: handAdded, key: fill(32, 0x99)) == nil)
    }

    @Test func onlyAChangedKeyIsWorthExplaining() {
        let changed = SenderTrust(kind: .keyChanged)
        #expect(ReaderActions.keyToExplain(trust: changed, contact: T.pinned()) == T.keyB64)
        #expect(ReaderActions.keyToExplain(trust: SenderTrust(kind: .allowlisted), contact: T.pinned()) == nil)
        #expect(ReaderActions.keyToExplain(trust: changed, contact: handAdded) == nil)
        let absent = ContactRecord(address: T.ada, name: "Ada", fingerprint: "", noIdentity: true)
        #expect(ReaderActions.keyToExplain(trust: changed, contact: absent) == nil)
    }

    @Test func trustingBridgedMailAllowlistsTheAddressAlone() {
        let record = ReaderActions.bridgedTrust(senderAddress: T.ada, senderDisplay: "Ada\u{202E} W", contact: nil)
        #expect(record.address == T.ada)
        #expect(record.name == "Ada W")
        #expect(record.fingerprint == "")
        #expect(record.provenance == .userApproved)
        // The shared bridge key must never be pinned.
        #expect(record.ed25519Pub == nil && record.x25519Pub == nil && record.noIdentity == nil)
        #expect(ReaderActions.bridgedTrust(senderAddress: T.ada, senderDisplay: "", contact: nil).name == T.ada)
        #expect(ReaderActions.bridgedTrust(senderAddress: T.ada, senderDisplay: "W", contact: handAdded).name == "Ada")
    }

    @Test func trustingNativeMailPinsWhatTheDirectoryServes() {
        let record = ReaderActions.nativeTrust(senderAddress: T.ada, contact: nil, directory: directory)
        #expect(record.name == T.ada)
        #expect(record.fingerprint == "dirfp")
        #expect(record.provenance == .userApproved)
        #expect(record.ed25519Pub == T.keyB64)
        #expect(record.adminKeyCustody == true)
        #expect(record.noIdentity == nil)
        #expect(ReaderActions.nativeTrust(senderAddress: T.ada, contact: handAdded, directory: directory).name == "Ada")
    }

    @Test func aLegacyAnswerPinsTheConfirmedAbsenceOfAnIdentity() {
        let record = ReaderActions.nativeTrust(
            senderAddress: T.ada, contact: nil, directory: DirectoryAnswer(x25519Pub: "bridge", legacy: true))
        #expect(record.noIdentity == true)
        #expect(record.ed25519Pub == "")
        #expect(record.x25519Pub == "")
    }

    @Test func blockingBridgedMailNeverNamesTheBridgesKey() {
        let confirmed = SenderTrust(kind: .unknownPending)
        #expect(ReaderActions.blockKey(attestation: nil, trust: confirmed, senderPublicKey: T.key) == T.key.hex)
        #expect(
            ReaderActions.blockKey(attestation: T.bridged(.verifiedLegacy), trust: confirmed, senderPublicKey: T.key)
                == nil)
        #expect(
            ReaderActions.blockKey(
                attestation: BridgeAttestation(verified: false, trustTier: .unspecified, smtpFrom: ""),
                trust: confirmed,
                senderPublicKey: T.key) == T.key.hex)
        #expect(ReaderActions.blockKey(attestation: nil, trust: nil, senderPublicKey: T.key) == nil)
    }
}
