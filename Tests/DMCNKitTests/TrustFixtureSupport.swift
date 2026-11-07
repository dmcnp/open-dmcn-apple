// Fixtures/browser-trust.json, browser-reader-grid.json and bridge-attestations.json hold what the
// browser's real code answered, run under node over a real DOM parser. The decision grid comes from
// the lines of components/MessageReader.tsx itself, cut out and evaluated rather than read and
// rewritten. bridge-attestations.json holds records signed by Go's internal/bridge, with Go's verdict
// and the browser's beside each.

import Foundation
@testable import DMCNKit

func fixture<T: Decodable>(_ name: String, as type: T.Type = T.self) throws -> T {
    guard let url = Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: "json") else {
        throw FixtureError.missing(name)
    }
    return try JSONDecoder().decode(T.self, from: Data(contentsOf: url))
}

enum FixtureError: Error { case missing(String) }

extension BridgeAttestation: Decodable {
    enum Keys: String, CodingKey { case verified, trustTier, smtpFrom, spf, dkim, dmarc, reason }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        self.init(
            verified: try c.decode(Bool.self, forKey: .verified),
            trustTier: Dmcn_Bridge_BridgeTrustTier(rawValue: try c.decode(Int.self, forKey: .trustTier))
                ?? .unspecified,
            smtpFrom: try c.decodeIfPresent(String.self, forKey: .smtpFrom) ?? "",
            spf: try c.decodeIfPresent(String.self, forKey: .spf),
            dkim: try c.decodeIfPresent(String.self, forKey: .dkim),
            dmarc: try c.decodeIfPresent(String.self, forKey: .dmarc),
            reason: try c.decodeIfPresent(String.self, forKey: .reason))
    }
}

extension DeliveryReceiptView: Decodable {
    enum Keys: String, CodingKey { case verified, delivered, recipientEmail, errorDetail, reason }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        self.init(
            verified: try c.decode(Bool.self, forKey: .verified),
            delivered: try c.decode(Bool.self, forKey: .delivered),
            recipientEmail: try c.decodeIfPresent(String.self, forKey: .recipientEmail) ?? "",
            errorDetail: try c.decodeIfPresent(String.self, forKey: .errorDetail),
            reason: try c.decodeIfPresent(String.self, forKey: .reason))
    }
}

/// A verdict as the fixtures write one.
struct TrustJSON: Decodable {
    let kind: String
    let provenance: String?
    let fingerprint: String?
    let reason: String?

    var trust: SenderTrust {
        SenderTrust(
            kind: SenderTrust.Kind(rawValue: kind)!, provenance: provenance.flatMap(TrustProvenance.init(rawValue:)),
            fingerprint: fingerprint, reason: reason)
    }
}

/// What the directory can prove, as the fixtures write it.
struct KeyChangeJSON: Decodable {
    let kind: String
    let at: Int64?

    var change: KeyChange {
        switch kind {
        case "replaced": .replaced(at: at!)
        case "recovered": .recovered(at: at!)
        case "reported-stolen": .reportedStolen(at: at!)
        default: .unexplained
        }
    }
}

struct ViewJSON: Decodable, Equatable {
    struct Source: Decodable, Equatable { let kind: String; let label: String; let tip: String }
    struct Check: Decodable, Equatable { let word: String; let ok: Bool; let tip: String }
    struct Notice: Decodable, Equatable { let tone: String; let text: String }
    let source: Source
    let checks: [Check]
    let notice: Notice?

    init(_ view: MessageChecksView) {
        source = Source(kind: view.source.kind.rawValue, label: view.source.label, tip: view.source.tip)
        checks = view.checks.map { Check(word: $0.word.rawValue, ok: $0.ok, tip: $0.tip) }
        notice = view.notice.map { Notice(tone: $0.tone.rawValue, text: $0.text) }
    }
}

/// Every fixture sentence is in US English, on UTC, as the generator ran.
let fixtureLocale = Locale(identifier: "en_US")
let fixtureTimeZone = TimeZone(identifier: "UTC")!

/// The one place the copy differs from the browser's on purpose: no em-dashes (CONTRIBUTING).
func withoutEmDashes(_ text: String) -> String {
    text.replacingOccurrences(of: "trusted contact — their", with: "trusted contact. Their")
        .replacingOccurrences(of: "attempt — do not trust", with: "attempt. Do not trust")
        .replacingOccurrences(of: "changed — re-verify", with: "changed: re-verify")
}
