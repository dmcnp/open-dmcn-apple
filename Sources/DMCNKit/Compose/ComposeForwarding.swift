import Foundation

// Forwarding, as the composer honours it. An address's owner may sign a forward_to into its identity
// record (SPEC_CORE §1): another address that also gets its mail. The sender's client sends that
// address its own copy, sealed to it when it has an identity and as ordinary email otherwise, and
// says so before Send. One hop only. Parity with the browser's lib/forwarding.ts.

public enum ComposeForwarding {
    /// What a forwarding address turned out to be when it was looked up.
    public enum TargetKind: Sendable, Equatable {
        /// An identity, so the copy is end-to-end encrypted.
        case identity
        /// Ordinary email, so it isn't.
        case email
        case unknown
    }

    public struct Copy: Sendable, Equatable {
        /// The recipient whose forward this is.
        public let forAddress: String
        /// Where the copy goes.
        public let target: String
    }

    /// The forward copies a message needs: one per distinct forwarding address, and none for an
    /// address that already gets the message or is the sender. Only recipients' forwards are read,
    /// which is what keeps it to one hop.
    public static func plan(
        forwards: [(address: String, forwardTo: String?)], recipients: [String], sender: String
    ) -> [Copy] {
        var taken = Set((recipients + [sender]).map(JSText.normalizedAddress))
        var copies: [Copy] = []
        for (address, forwardTo) in forwards {
            let target = JSText.trim(forwardTo ?? "")
            guard !target.isEmpty, taken.insert(target.lowercased()).inserted else { continue }
            copies.append(Copy(forAddress: address, target: target))
        }
        return copies
    }

    /// The notice before Send, which names the address because the sender is the one deciding.
    public static func notice(_ address: String, target: String, kind: TargetKind) -> String {
        switch kind {
        case .identity: "Mail to \(address) also goes to \(target). That copy is end-to-end encrypted too."
        case .email:
            "Mail to \(address) also goes to \(target) as ordinary email, so that copy is not end-to-end encrypted."
        case .unknown: "Mail to \(address) also goes to \(target)."
        }
    }

    /// The notice where the forwarding address is ordinary email and none can be sent from here.
    public static func unsendableNotice(_ address: String, target: String) -> String {
        "Mail to \(address) also goes to \(target) as ordinary email, which can't be sent from here, so "
            + "\(target) won't get a copy."
    }

    /// After sending: the account is closed, and the forward was the only copy.
    public static func forwardedOnlyMessage(_ address: String, target: String) -> String {
        "\(address) has closed their account. Your message went to their forwarding address, \(target)."
    }

    /// After sending: the recipient got it, the forward copy did not go out.
    public static func forwardFailedMessage(_ address: String, target: String) -> String {
        "\(address) has your message, but the copy to their forwarding address, \(target), could not be sent."
    }

    /// After sending: the account is closed and the forward failed, so this recipient got nothing.
    public static func forwardOnlyFailedMessage(_ address: String, target: String) -> String {
        "\(address) has closed their account, and the copy to their forwarding address, \(target), could not be "
            + "sent. They have not received your message."
    }
}
