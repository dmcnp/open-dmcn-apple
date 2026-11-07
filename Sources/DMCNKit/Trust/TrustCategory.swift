import Foundation

// The pending-queue category of a received message (whitepaper §14.2): a pure, synchronous decision
// over what's held locally, so a whole inbox can be classified without a lookup per row. Parity with
// the browser's lib/trust/category.ts.

public enum SenderCategory: Sendable, Equatable {
    case allowlisted, pending, blocked
}

public enum TrustCategory {
    /// A base64 key as lowercase hex, "" when malformed: it then matches nothing.
    static func hex(ofBase64 text: String) -> String {
        JSText.atob(text)?.hex ?? ""
    }

    public static func categorize(
        senderAddress: String, senderKeyHex: String, contact: ContactRecord?, filter: FilterList?
    ) -> SenderCategory {
        if filter?.blocks(senderAddress: senderAddress, senderKeyHex: senderKeyHex) == true { return .blocked }
        // Any contact is an allowlist entry; provenance only labels its strength. A pinned key that
        // no longer matches demotes them to pending, to be re-verified.
        guard let contact else { return .pending }
        if let pinned = contact.ed25519Pub, !pinned.isEmpty,
            !JSText.same(hex(ofBase64: pinned), senderKeyHex.lowercased())
        {
            return .pending
        }
        return .allowlisted
    }

    /// The key Block adds to the unconditional list, or nil to block by address alone.
    ///
    /// Only a key the directory has just confirmed is the sender's own. Bridged mail is signed by the
    /// bridge, so key-blocking it hides every bridged message from then on, and a missing or failed
    /// attestation looks just like native mail. The directory can tell: it never publishes a bridge
    /// key as anyone's identity.
    public static func blockKey(trust: SenderTrust?, senderKeyHex: String) -> String? {
        guard !senderKeyHex.isEmpty, let trust else { return nil }
        switch trust.kind {
        case .allowlisted, .domainVerified, .unknownPending, .recordChanged, .keyChanged:
            // key_changed included: the header key IS the directory's. It only differs from the pin.
            return senderKeyHex
        case .keyMismatch, .identityUnverifiable, .directoryMissing:
            return nil
        }
    }
}
