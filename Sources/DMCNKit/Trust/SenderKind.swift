import Foundation

/// Which network a correspondent lives on: a DMCN identity, or an ordinary email address reached
/// over a bridge. Deliberately not a trust verdict; `SenderTrust` answers that. Parity with the
/// browser's lib/trust/senderKind.ts.
public enum SenderKind: Sendable, Equatable {
    case dmcn, legacy, unknown

    /// From what's held locally, with no network. A contact resolved in the directory carries a
    /// fingerprint or a pinned key; one with neither was allowlisted as a bare address.
    public static func of(contact: ContactRecord?) -> SenderKind {
        guard let contact else { return .unknown }
        return !contact.fingerprint.isEmpty || !(contact.ed25519Pub ?? "").isEmpty ? .dmcn : .legacy
    }

    /// The hex key the directory publishes, for `fromDirectory`: nil means no DMCN identity. A
    /// record the domain has disowned counts as none.
    public static func directoryKey(_ answer: DirectoryAnswer?) -> String? {
        guard let answer, !answer.identityUnverifiable else { return nil }
        return TrustCategory.hex(ofBase64: answer.ed25519Pub)
    }

    /// A row's kind from the directory's answer. When the message's signing key is known it must
    /// match: a bridged message claiming a DMCN address is signed by the bridge, so it mustn't earn
    /// the shield. That reads as unknown rather than legacy: the reader raises it as a real warning,
    /// and the row claims nothing either way.
    public static func fromDirectory(key directoryKeyHex: String?, messageKeyHex: String) -> SenderKind {
        guard let directoryKeyHex, !directoryKeyHex.isEmpty else { return .legacy }
        if !messageKeyHex.isEmpty, !JSText.same(directoryKeyHex, messageKeyHex.lowercased()) { return .unknown }
        return .dmcn
    }
}
