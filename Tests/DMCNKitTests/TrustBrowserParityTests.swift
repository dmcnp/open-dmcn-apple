import Foundation
import Testing
@testable import DMCNKit

private struct Doc: Decodable {
    struct DisplayName: Decodable { let raw: String; let clean: String }
    struct Label: Decodable {
        let address: String; let contact: String; let wire: String?; let primary: String; let secondary: String
    }
    struct FirstName: Decodable { let name: String; let address: String; let first: String }
    struct Initials: Decodable { let name: String; let initials: String }
    struct Domain: Decodable { let address: String; let domain: String }
    struct Block: Decodable { let filter: FilterList?; let address: String; let key: String; let blocked: Bool }
    struct Category: Decodable {
        let contact: ContactRecord?; let filter: FilterList?; let key: String; let category: String
    }
    struct BlockKey: Decodable { let trust: TrustJSON?; let key: String; let blocked: String? }
    struct Directory: Decodable {
        let ed25519_pub: String?; let x25519_pub: String?; let fingerprint: String?; let verified_tier: Int?
        let identity_unverifiable: Bool?; let legacy: Bool?; let admin_key_custody: Bool?
        var answer: DirectoryAnswer {
            DirectoryAnswer(
                ed25519Pub: ed25519_pub ?? "", x25519Pub: x25519_pub ?? "", fingerprint: fingerprint ?? "",
                verifiedTier: verified_tier ?? 0, identityUnverifiable: identity_unverifiable ?? false,
                legacy: legacy ?? false, adminKeyCustody: admin_key_custody ?? false)
        }
    }
    struct SenderTrustCase: Decodable {
        let name: String; let dir: Directory?; let contact: ContactRecord?; let expected: TrustJSON
    }
    struct Facts: Decodable, Equatable {
        let ed25519Pub: String; let x25519Pub: String; let adminKeyCustody: Bool; let noIdentity: Bool?
        var pinned: PinnedFacts {
            PinnedFacts(
                ed25519Pub: ed25519Pub, x25519Pub: x25519Pub, adminKeyCustody: adminKeyCustody, noIdentity: noIdentity)
        }
    }
    struct DirectoryFacts: Decodable { let dir: Directory; let facts: Facts }
    struct ContactFacts: Decodable { let contact: ContactRecord?; let facts: Facts?; let has: Bool }
    struct Changed: Decodable { let pinned: Facts; let observed: Facts; let changed: [String] }
    struct CheckPin: Decodable { let contact: ContactRecord?; let observed: Facts?; let verdict: String }
    struct Warning: Decodable { let change: KeyChangeJSON?; let text: String }
    struct Record: Decodable { let changed: [String]; let text: String }
    struct Provenance: Decodable { let provenance: String; let variant: String; let label: String }
    struct Badge: Decodable { let variant: String; let icon: String; let label: String; let detail: String }
    struct TrustViewCase: Decodable { let trust: TrustJSON; let change: KeyChangeJSON?; let view: Badge }
    struct ContactKind: Decodable { let contact: ContactRecord?; let kind: String }
    struct DirectoryKind: Decodable { let dir: String?; let message: String; let kind: String }
    struct DirectoryKey: Decodable { let dir: Directory?; let key: String? }
    struct CheckInput: Decodable {
        let address: String; let name: String; let recipients: Int; let own: Bool
        let attestation: BridgeAttestation?; let receipt: DeliveryReceiptView?; let trust: TrustJSON?;
        let keyChange: KeyChangeJSON?
    }
    struct ChecksCase: Decodable { let input: CheckInput; let view: ViewJSON }
    struct Attachment: Decodable {
        let contentType: String; let filename: String; let contentId: String?; let disposition: String?
    }
    struct AttachmentCase: Decodable { let list: [Attachment]; let original: Int; let user: [String] }
    struct Filename: Decodable { let name: String; let safe: String }
    struct Plain: Decodable { let html: String; let text: String }
    struct Lineage: Decodable {
        struct Served: Decodable { let record: String; let history: String?; let removal: String? }
        let name: String; let address: String; let pinned: String; let served: Served; let expected: KeyChangeJSON
    }

    let display_names: [DisplayName]
    let sender_labels: [Label]
    let first_names: [FirstName]
    let initials: [Initials]
    let domain_parts: [Domain]
    let filter_blocks: [Block]
    let categories: [Category]
    let block_keys: [BlockKey]
    let sender_trust: [SenderTrustCase]
    let directory_facts: [DirectoryFacts]
    let contact_facts: [ContactFacts]
    let changed_facts: [Changed]
    let check_pin: [CheckPin]
    let pin_warnings: [Warning]
    let pin_gone: String
    let pin_record: [Record]
    let provenance_views: [Provenance]
    let trust_views: [TrustViewCase]
    let trust_view_no_address: Badge
    let contact_kinds: [ContactKind]
    let directory_kinds: [DirectoryKind]
    let directory_keys: [DirectoryKey]
    let checks: [ChecksCase]
    let attachments: [AttachmentCase]
    let filenames: [Filename]
    let plain_text: [Plain]
    let lineage: [Lineage]
}

private let doc: Result<Doc, any Error> = Result { try fixture("browser-trust") }

private func kind(_ kind: SenderKind) -> String {
    switch kind {
    case .dmcn: "dmcn"
    case .legacy: "legacy"
    case .unknown: "unknown"
    }
}

@Suite struct TrustBrowserParity {
    @Test func theFixtureCarriesWhatTheseTestsLoopOver() throws {
        // A loop over nothing passes, so an emptied fixture has to fail somewhere.
        let d = try doc.get()
        #expect(d.plain_text.count > 100)
        #expect(d.checks.count > 300)
        #expect(d.sender_trust.count > 15)
        #expect(d.lineage.count > 15)
        #expect(d.trust_views.count > 40)
    }

    @Test func displayNames() throws {
        for c in try doc.get().display_names {
            #expect(
                DisplayName.sanitize(c.raw).unicodeScalars.elementsEqual(c.clean.unicodeScalars),
                "\(c.raw.debugDescription)")
        }
        #expect(DisplayName.sanitize(nil) == "")
    }

    @Test func senderLabels() throws {
        for c in try doc.get().sender_labels {
            let label = DisplayName.senderLabel(address: c.address, contactName: c.contact, wireDisplay: c.wire)
            #expect(label.primary == c.primary, "\(c)")
            #expect(label.secondary == c.secondary, "\(c)")
        }
    }

    @Test func firstNamesAndInitials() throws {
        for c in try doc.get().first_names {
            #expect(ReaderPolicy.firstName(c.name, address: c.address) == c.first, "\(c.name.debugDescription)")
        }
        for c in try doc.get().initials {
            #expect(ReaderPolicy.initials(c.name) == c.initials, "\(c.name.debugDescription)")
        }
    }

    @Test func domainParts() throws {
        for c in try doc.get().domain_parts { #expect(MessageChecks.domainPart(c.address) == c.domain, "\(c)") }
    }

    @Test func filtersAndCategories() throws {
        for c in try doc.get().filter_blocks {
            let got = c.filter?.blocks(senderAddress: c.address, senderKeyHex: c.key) ?? false
            #expect(got == c.blocked, "\(c)")
        }
        for c in try doc.get().categories {
            let got = TrustCategory.categorize(
                senderAddress: "ada@parity.example", senderKeyHex: c.key, contact: c.contact, filter: c.filter)
            #expect("\(got)" == c.category, "\(c)")
        }
        for c in try doc.get().block_keys {
            #expect(TrustCategory.blockKey(trust: c.trust?.trust, senderKeyHex: c.key) == c.blocked, "\(c)")
        }
    }

    @Test func senderTrust() async throws {
        for c in try doc.get().sender_trust {
            let dir = c.dir?.answer
            let got = await SenderTrust.evaluate(
                senderAddress: "ada@parity.example", senderPublicKey: fill(32, 0x11), contact: c.contact
            ) { _ in
                guard let dir else { throw FixtureError.missing("directory") }
                return dir
            }
            #expect(got.kind == c.expected.trust.kind, "\(c.name)")
            #expect(got.fingerprint == c.expected.fingerprint, "\(c.name)")
            #expect(got.provenance == c.expected.trust.provenance, "\(c.name)")
            #expect(got.reason == c.expected.reason.map(withoutEmDashes), "\(c.name)")
        }
    }

    @Test func pinnedFacts() throws {
        for c in try doc.get().directory_facts { #expect(PinnedFacts(directory: c.dir.answer) == c.facts.pinned) }
        for c in try doc.get().contact_facts {
            #expect(c.contact?.pinnedFacts == c.facts?.pinned, "\(String(describing: c.contact))")
            #expect(PinnedKey.hasPin(c.contact) == c.has)
        }
        for c in try doc.get().changed_facts {
            #expect(ComposePin.changedFacts(pinned: c.pinned.pinned, observed: c.observed.pinned) == c.changed, "\(c)")
        }
        let verdicts: [ComposePin.Verdict: String] = [
            .unpinned: "unpinned", .match: "match", .changed: "changed", .recordChanged: "record_changed",
        ]
        for c in try doc.get().check_pin {
            #expect(verdicts[ComposePin.check(c.contact, observed: c.observed?.pinned)] == c.verdict, "\(c)")
        }
    }

    @Test func pinnedSentences() throws {
        for c in try doc.get().pin_warnings {
            #expect(
                ComposePin.keyWarning(
                    "Ada Okafor", change: c.change?.change, locale: fixtureLocale, timeZone: fixtureTimeZone) == c.text)
        }
        #expect(ComposePin.identityGoneWarning("ada@parity.example") == (try doc.get().pin_gone))
        for c in try doc.get().pin_record {
            #expect(PinnedKey.recordWarning(address: "ada@parity.example", changed: c.changed) == c.text)
        }
    }

    @Test func badges() throws {
        for c in try doc.get().provenance_views {
            #expect(TrustProvenance(rawValue: c.provenance)?.label == c.label)
        }
        for c in try doc.get().trust_views {
            let got = c.trust.trust.badge(
                change: c.change?.change, address: "ada@parity.example", locale: fixtureLocale,
                timeZone: fixtureTimeZone)
            #expect(got.variant.rawValue == c.view.variant, "\(c.trust.kind)")
            #expect(got.icon.rawValue == c.view.icon, "\(c.trust.kind)")
            #expect(got.label == c.view.label, "\(c.trust.kind)")
            #expect(got.detail == withoutEmDashes(c.view.detail), "\(c.trust.kind) \(String(describing: c.change))")
        }
        let bare = try doc.get().trust_view_no_address
        let got = SenderTrust(kind: .keyChanged).badge(
            change: .unexplained, locale: fixtureLocale, timeZone: fixtureTimeZone)
        #expect(got.detail == bare.detail)
    }

    @Test func senderKinds() throws {
        for c in try doc.get().contact_kinds { #expect(kind(SenderKind.of(contact: c.contact)) == c.kind) }
        for c in try doc.get().directory_kinds {
            #expect(kind(SenderKind.fromDirectory(key: c.dir, messageKeyHex: c.message)) == c.kind, "\(c)")
        }
        for c in try doc.get().directory_keys { #expect(SenderKind.directoryKey(c.dir?.answer) == c.key, "\(c)") }
    }

    @Test func messageChecks() throws {
        for c in try doc.get().checks {
            let input = ChecksInput(
                address: c.input.address, name: c.input.name, recipients: c.input.recipients, own: c.input.own,
                attestation: c.input.attestation, receipt: c.input.receipt, trust: c.input.trust?.trust,
                keyChange: c.input.keyChange?.change, locale: fixtureLocale, timeZone: fixtureTimeZone)
            #expect(ViewJSON(MessageChecks.view(input)) == c.view, "\(c.input)")
        }
    }

    @Test func attachments() throws {
        for c in try doc.get().attachments {
            let list = c.list.map {
                MessageAttachment(
                    filename: $0.filename, contentType: $0.contentType, content: Data(), contentID: $0.contentId ?? "",
                    disposition: $0.disposition ?? "")
            }
            let original = BridgeRecord.originalIndex(
                contentTypes: list.map(\.contentType), filenames: list.map(\.filename))
            #expect((original ?? -1) == c.original, "\(c.list)")
            #expect(UserAttachments.filter(list).map(\.filename) == c.user, "\(c.list)")
        }
        for c in try doc.get().filenames {
            #expect(MessageAttachment.safeFilename(c.name) == c.safe, "\(c.name.debugDescription)")
        }
    }

    @Test func plainText() throws {
        for c in try doc.get().plain_text {
            let got = HTMLPlainText.render(c.html)
            #expect(
                got.unicodeScalars.elementsEqual(c.text.unicodeScalars),
                "\(c.html.debugDescription)\n got \(got.debugDescription)\nwant \(c.text.debugDescription)")
        }
    }

    @Test func lineage() throws {
        for c in try doc.get().lineage {
            let served = IdentityRecordAnswer(
                record: c.served.record, history: c.served.history, removal: c.served.removal)
            #expect(
                KeyLineage.explain(address: c.address, pinnedEd25519Pub: c.pinned, served: served) == c.expected.change,
                "\(c.name)")
        }
    }

    @Test func anUnreachableDirectoryExplainsNothing() async {
        let got = await KeyLineage.load(address: "a@b", pinnedEd25519Pub: "x") { _ in
            throw FixtureError.missing("directory")
        }
        #expect(got == .unexplained)
    }

    @Test func aTombstoneThatCantBeReadExplainsNothing() throws {
        // A fleet mustn't be able to pick the gentler sentence by serving garbage next to a real chain.
        let genuine = try #require(try doc.get().lineage.first { $0.name == "signed handover" })
        let served = IdentityRecordAnswer(
            record: genuine.served.record, removal: Data([0xFF, 0xFF, 0xFF]).base64EncodedString())
        #expect(
            KeyLineage.explain(address: genuine.address, pinnedEd25519Pub: genuine.pinned, served: served)
                == .unexplained)
    }
}

@Suite struct JSStringRules {
    @Test func atobIsForgivingAndTheRestIsNot() {
        #expect(JSText.atob("AQID") == Data([1, 2, 3]))
        #expect(JSText.atob("AQ") == Data([1]))
        #expect(JSText.atob("AQ==") == Data([1]))
        #expect(JSText.atob(" A Q I D\n") == Data([1, 2, 3]))
        #expect(JSText.atob("A") == nil)
        #expect(JSText.atob("A=") == nil)
        #expect(JSText.atob("###") == nil)
        #expect(JSText.atob("") == Data())
    }

    @Test func comparesScalarsWhereSwiftComparesCharacters() {
        // Composed and decomposed é are equal to Swift, and they're two different addresses.
        #expect("é" == "e\u{301}")
        #expect(!JSText.same("é", "e\u{301}"))
        #expect(!"x@\u{301}y".contains("@"))
        #expect(JSText.contains("x@\u{301}y", "@"))
    }

    @Test func aDisplayNameCantHideAnAddressBehindACombiningMark() {
        let label = DisplayName.senderLabel(address: "a@b", contactName: "", wireDisplay: "pay@\u{301}evil.example")
        #expect(label.primary == "a@b")
    }

    @Test func cutsWhereJavaScriptWouldAndDropsWhatTheCutOrphans() {
        #expect(JSText.prefixUTF16("ab😀c", 3) == "ab")
        #expect(JSText.prefixUTF16("ab😀c", 4) == "ab😀")
    }
}
