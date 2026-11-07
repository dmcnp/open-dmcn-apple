import Foundation

// Comparing what the directory serves now with what was pinned, for received mail. The comparison
// rules and the sentences are the composer's (ComposePin), used from there so the reader, the
// composer and the contact list say the same thing about the same event. Parity with the browser's
// lib/trust/pinnedKey.ts.

/// What the directory can prove about a key that no longer matches a pin.
public typealias KeyChange = ComposePin.KeyChange

extension PinnedFacts {
    /// A directory answer as facts a pin can be compared with. A legacy answer describes the bridge,
    /// not the correspondent, so it counts as no identity at all.
    public init(directory answer: DirectoryAnswer) {
        if answer.legacy || answer.ed25519Pub.isEmpty {
            self = .absentIdentity
        } else {
            self.init(
                ed25519Pub: answer.ed25519Pub, x25519Pub: answer.x25519Pub, adminKeyCustody: answer.adminKeyCustody)
        }
    }
}

public enum PinnedKey {
    /// Whether a contact carries key-change protection at all.
    public static func hasPin(_ contact: ContactRecord?) -> Bool {
        !(contact?.ed25519Pub ?? "").isEmpty
    }

    /// The softer warning: the keys hold, but something else pinned moved. Worth saying, since it
    /// may mean someone else now holds their keys, but no message is mis-sealed by it.
    public static func recordWarning(address: String, changed: [String]) -> String {
        let what = changed.isEmpty ? "identity record" : changed.joined(separator: " and ")
        return "\(address)'s \(what) changed since you verified them. Their keys are the same, so mail to them can "
            + "still only be read by them. This was not a change they made, so check that it is expected."
    }
}
