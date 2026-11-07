import Foundation

// What the reader does about a sender, as small functions the app calls. Each answers what to write;
// the app writes it. Parity with the effects and handlers in the browser's
// components/MessageReader.tsx (§14.1.2 lazy pin, §14.2.1 per-message actions).

public enum ReaderActions {
    /// The facts to pin the first time a contact's key can be confirmed, so a later change is
    /// detectable, or nil when there's nothing to do. Pass to `ContactStore.pinKey`.
    ///
    /// It takes `allowlisted` and `domainVerified`: a contact added by hand has no provenance and no
    /// key, and would otherwise never gain key-change protection however much mail passed. Both
    /// verdicts establish that the header key is the directory's, the only thing a pin needs.
    /// Allowlisting is a statement about the person, not about the key.
    ///
    /// `directory` is checked against the key that signed. The browser looks the address up afresh
    /// here and pins whatever comes back, which needn't be the key the verdict was about.
    public static func lazyPin(
        ownMessage: Bool, trust: SenderTrust?, contact: ContactRecord?, senderPublicKey: Data,
        directory: DirectoryAnswer
    ) -> PinnedFacts? {
        guard !ownMessage, let contact, (contact.ed25519Pub ?? "").isEmpty,
            trust?.kind == .allowlisted || trust?.kind == .domainVerified,
            JSText.same(directory.ed25519Pub, senderPublicKey.base64EncodedString())
        else { return nil }
        return PinnedFacts(directory: directory)
    }

    /// Whether the app should look the sender up for `lazyPin` at all.
    public static func wantsLazyPin(ownMessage: Bool, trust: SenderTrust?, contact: ContactRecord?) -> Bool {
        !ownMessage && contact != nil && (contact?.ed25519Pub ?? "").isEmpty
            && (trust?.kind == .allowlisted || trust?.kind == .domainVerified)
    }

    /// The pinned key to ask the directory about, or nil when there's nothing to explain. Asked only
    /// once the verdict is already a changed key: the answer can't unblock anything, so it's worth a
    /// round trip exactly when there's something to tell the reader. See `KeyLineage.load`.
    public static func keyToExplain(trust: SenderTrust?, contact: ContactRecord?) -> String? {
        guard trust?.kind == .keyChanged, let pinned = contact?.pinnedFacts?.ed25519Pub, !pinned.isEmpty else {
            return nil
        }
        return pinned
    }

    /// "I trust the sender" on bridged legacy mail. There's no directory entry and no key: the
    /// bridge's key must never be pinned. So this is a keyless allowlist by address, which opens this
    /// message once the app sets `messageTrusted`, and no other: unauthenticated mail is gated anew.
    ///
    /// The name defaults to the one the message carried, because the owner chose this on a screen
    /// showing that name and the address together. It's an owner-given name from here on.
    public static func bridgedTrust(
        senderAddress: String, senderDisplay: String, contact: ContactRecord?
    ) -> ContactRecord {
        let existing = contact?.name ?? ""
        let display = DisplayName.sanitize(senderDisplay)
        return ContactRecord(
            address: senderAddress,
            name: !existing.isEmpty ? existing : !display.isEmpty ? display : senderAddress,
            fingerprint: "", provenance: .userApproved)
    }

    /// "I trust the sender" or "Trust new key" on native mail. Pins the directory's facts: if they
    /// disagree with the header key the sender stays pending rather than being trusted in. Pass to
    /// `ContactStore.allowlist`, which replaces any pin this device holds, the "re-verify after a
    /// rotation" path.
    public static func nativeTrust(
        senderAddress: String, contact: ContactRecord?, directory: DirectoryAnswer
    ) -> ContactRecord {
        let existing = contact?.name ?? ""
        let facts = PinnedFacts(directory: directory)
        return ContactRecord(
            address: senderAddress, name: existing.isEmpty ? senderAddress : existing,
            fingerprint: directory.fingerprint, provenance: .userApproved, ed25519Pub: facts.ed25519Pub,
            x25519Pub: facts.x25519Pub, adminKeyCustody: facts.adminKeyCustody, noIdentity: facts.noIdentity)
    }

    /// The key Block adds, or nil to block by address alone. Pass to `MailFilterStore.blockSender`.
    /// Bridged mail blocks by address: key-blocking the bridge would hide all of it.
    public static func blockKey(attestation: BridgeAttestation?, trust: SenderTrust?, senderPublicKey: Data) -> String?
    {
        attestation?.verified == true
            ? nil : TrustCategory.blockKey(trust: trust, senderKeyHex: senderPublicKey.hex)
    }
}
