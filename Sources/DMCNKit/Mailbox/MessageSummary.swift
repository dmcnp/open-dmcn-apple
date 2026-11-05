import Foundation

/// One inbox row after the reader checks ran (SPEC_CORE §3). This is what a UI draws: every
/// decision about what may be shown has already been made here, so a view only has to render
/// what it is given.
public struct MessageSummary: Identifiable, Sendable {
    public enum Sender: Sendable, Equatable {
        /// The directory binds this address to the key that signed.
        case verified(String)
        /// The address did not resolve. Shown, but not as confirmed.
        case unverified(String)
        /// The directory binds the claimed address to a different key. The address is never
        /// presented as who the message is from, and the contents are withheld.
        case mismatch(claimed: String)
        /// The key matches, but the address's domain attestation was withdrawn or doesn't check out.
        /// The address is never presented as who the message is from; its text can be read behind
        /// the gate.
        case disowned(claimed: String)
        /// The header did not open or did not verify.
        case unreadable
    }

    public let id: String
    public let sender: Sender
    public let subject: String
    /// Body text, so withheld on the same terms as the body.
    public let snippet: String
    public let sentAt: Date?
    /// Every address that resolved in the signed audience names some other key.
    public let misaddressed: Bool
    let row: InboxRow

    /// Whether the checks forbid showing this message's body. Never fetched while this is true.
    public var contentsWithheld: Bool {
        switch sender {
        case .verified, .unverified, .disowned: false
        case .mismatch, .unreadable: true
        }
    }

    /// Whether the checks forbid treating the header's address as who this is from. Wider than
    /// `contentsWithheld`: a disowned message can be read, but not as coming from that address.
    public var attributionWithheld: Bool {
        switch sender {
        case .verified, .unverified: false
        case .mismatch, .disowned, .unreadable: true
        }
    }

    /// Runs the reader checks on `row`. `directory` answers nil when an address did not resolve
    /// or the lookup failed: either way the message is unverified, never rejected.
    init(checking row: InboxRow, directory: @Sendable (String) async -> IdentityLookup?) async {
        id = row.id
        self.row = row
        guard case .success(let opened) = row.opened else {
            sender = .unreadable
            subject = ""
            snippet = ""
            sentAt = nil
            misaddressed = false
            return
        }

        let header = opened.header
        let listed = await directory(header.senderAddress)
        let binding = ReaderChecks.senderBinding(
            of: header, directoryKey: listed?.ed25519Public,
            identityUnverifiable: listed?.identityUnverifiable ?? false)
        let audience = await ReaderChecks.audience(of: header, sealedTo: opened.sealedTo) {
            await directory($0)?.x25519Public
        }

        sender =
            switch binding {
            case .matches: .verified(header.senderAddress)
            case .unresolved: .unverified(header.senderAddress)
            case .mismatch: .mismatch(claimed: header.senderAddress)
            case .disowned: .disowned(claimed: header.senderAddress)
            }
        subject = header.subject
        snippet =
            switch sender {
            case .verified, .unverified: header.snippet
            default: ""
            }
        sentAt = header.sentAt > 0 ? Date(timeIntervalSince1970: TimeInterval(header.sentAt)) : nil
        misaddressed = audience == .misaddressed
    }
}

/// What opening a message produced.
public enum OpenedBody: Sendable, Equatable {
    case plainText(String)
    /// The message opened but has no text/plain part, and this client renders no HTML.
    case noPlainText
    /// The reader checks forbid showing this message. Its body was not fetched.
    case withheld
}
