import Foundation

/// A send that reached some recipients and not others.
///
/// Every recipient is tried, so one failure doesn't stop the rest. What's left afterwards is a Sent
/// copy listing who got it and a draft addressed to who didn't, so pressing Send again can't reach
/// anyone twice. Parity with the browser's lib/partialSend.ts.
public enum PartialSend {
    public struct Audience: Sendable, Equatable {
        public var to: [String]
        public var cc: [String]
        public var bcc: [String]

        public init(to: [String], cc: [String], bcc: [String]) {
            self.to = to
            self.cc = cc
            self.bcc = bcc
        }
    }

    public struct Undelivered: Sendable, Equatable {
        public let address: String
        /// A sentence naming the address, to show as it stands.
        public let reason: String

        public init(address: String, reason: String) {
            self.address = address
            self.reason = reason
        }
    }

    private static func same(_ a: String, _ b: String) -> Bool {
        JSText.normalizedAddress(a) == JSText.normalizedAddress(b)
    }

    /// Who a Sent copy lists: everyone but the addresses that failed.
    public static func reached(_ all: Audience, undelivered: [Undelivered]) -> Audience {
        func reached(_ list: [String]) -> [String] {
            list.filter { address in !undelivered.contains { same($0.address, address) } }
        }
        return Audience(to: reached(all.to), cc: reached(all.cc), bcc: reached(all.bcc))
    }

    /// Who the draft stays addressed to. A failed Cc moves up to To when To would otherwise be empty,
    /// since Cc was visible anyway. A failed Bcc never does: To would show them.
    public static func retry(_ all: Audience, undelivered: [Undelivered]) -> Audience {
        func failed(_ list: [String]) -> [String] {
            list.filter { address in undelivered.contains { same($0.address, address) } }
        }
        let to = failed(all.to)
        let cc = failed(all.cc)
        let bcc = failed(all.bcc)
        return to.isEmpty ? Audience(to: cc, cc: [], bcc: bcc) : Audience(to: to, cc: cc, bcc: bcc)
    }

    /// What happened, and what Send does now.
    public static func message(delivered: [String], undelivered: [Undelivered]) -> String {
        let missed = undelivered.map(\.address).joined(separator: ", ")
        let reasons = undelivered.map(\.reason).joined(separator: " ")
        return
            "This message reached \(delivered.joined(separator: ", ")). \(reasons) Press Send to try again. It will go only to \(missed)."
    }
}
