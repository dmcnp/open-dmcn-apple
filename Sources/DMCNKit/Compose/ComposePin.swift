import Foundation

// Comparing what the directory serves now against what was pinned when this counterparty was
// confirmed. Everything else in the trust chain is checked against records the fleet itself serves,
// so this comparison is the protection that survives a hostile one.
//
// A change is put to the person, never refused on their behalf: a rotation and a takeover look the
// same here, and the decision belongs to whoever took the pin. Parity with the browser's
// lib/trust/pinnedKey.ts; the send path in ComposeDialog.tsx refuses nothing over it.

public enum ComposePin {
    public enum Verdict: Sendable, Equatable {
        /// Nothing recorded, or nothing to compare yet.
        case unpinned
        case match
        /// The identity itself differs. Warned about, never refused.
        case changed
        /// The keys hold, but a pinned property moved. A quieter warning.
        case recordChanged
    }

    /// What the directory can prove about a changed key. It moves the sentence, not the outcome: a
    /// stolen key produces a perfectly signed rotation, so no evidence decides this for anyone.
    public enum KeyChange: Sendable, Equatable {
        /// `at` is Unix seconds, here and below.
        case replaced(at: Int64)
        case recovered(at: Int64)
        case reportedStolen(at: Int64)
        case unexplained
    }

    /// What a directory answer says, as facts a pin can be compared with. A legacy answer describes
    /// the bridge rather than the correspondent, so it counts as no identity at all.
    public static func facts(from lookup: RecipientLookup) -> PinnedFacts {
        if lookup.legacy || lookup.ed25519Pub.isEmpty { return .absentIdentity }
        return PinnedFacts(
            ed25519Pub: lookup.ed25519Pub, x25519Pub: lookup.x25519Pub, adminKeyCustody: lookup.adminKeyCustody)
    }

    /// The pinned fields that differ, most severe first. A field the pin never recorded is not
    /// reported: "we didn't look" isn't "it changed". Gaining or losing an identity is reported
    /// alone, since every key difference that comes with it is a consequence of that one event.
    public static func changedFacts(pinned: PinnedFacts, observed: PinnedFacts) -> [String] {
        if (pinned.noIdentity == true) != (observed.noIdentity == true) { return ["DMCN identity"] }
        var out: [String] = []
        if !pinned.ed25519Pub.isEmpty, pinned.ed25519Pub != observed.ed25519Pub { out.append("signing key") }
        if !pinned.x25519Pub.isEmpty, pinned.x25519Pub != observed.x25519Pub { out.append("encryption key") }
        if pinned.adminKeyCustody != observed.adminKeyCustody { out.append("key custody by their provider") }
        return out
    }

    /// `observed` is nil while the recipient is unresolved, which is distinct from resolving to
    /// nothing: that is `absentIdentity`, and it is a comparable state.
    public static func check(_ contact: ContactRecord?, observed: PinnedFacts?) -> Verdict {
        guard let pinned = contact?.pinnedFacts, let observed else { return .unpinned }
        // A malformed answer is treated as unresolved rather than inventing a verdict from it.
        if observed.ed25519Pub.isEmpty, observed.noIdentity != true { return .unpinned }
        if changedFacts(pinned: pinned, observed: observed).isEmpty { return .match }
        if (pinned.noIdentity == true) != (observed.noIdentity == true) { return .changed }
        if pinned.ed25519Pub != observed.ed25519Pub { return .changed }
        if !pinned.x25519Pub.isEmpty, pinned.x25519Pub != observed.x25519Pub { return .changed }
        return .recordChanged
    }

    private static let checkFirst =
        "Avoid sending anything sensitive until you have checked with them another way: a phone call, "
        + "a text message, or something only the two of you would know."

    /// The same words the browser shows for the same event, so two clients on one account don't
    /// read as two severities. Dates in `locale` and `timeZone`.
    public static func keyWarning(
        _ address: String, change: KeyChange? = nil, locale: Locale = .current, timeZone: TimeZone = .current
    ) -> String {
        func on(_ at: Int64) -> String { shortDate(at, locale: locale, timeZone: timeZone) }
        switch change {
        case .reportedStolen(let at):
            return "\(address) reported the key you had verified as stolen, on \(on(at)). Mail you already "
                + "received from them may have come from whoever took it, so treat that as suspect too. \(checkFirst)"
        case .replaced(let at):
            return "The key for \(address) changed on \(on(at)). \(checkFirst)"
        case .recovered(let at):
            return "The key for \(address) changed on \(on(at)), and the change was not approved by the key "
                + "you verified. \(checkFirst)"
        case .unexplained, nil:
            return "The key for \(address) has changed since you verified them, and there is no record of why. "
                + checkFirst
        }
    }

    /// An address once verified that now resolves to nothing, so mail would leave as ordinary email.
    public static func identityGoneWarning(_ address: String) -> String {
        "\(address) no longer has a DMCN account, though you verified one before. Mail you send now would go out as "
            + "ordinary email, which every service that handles it on the way can read. \(checkFirst)"
    }

    /// Said once after those warnings: that nothing stops the send, and what confirming does. A
    /// warning that reads like a refusal gets treated as an obstacle, and then stops being read.
    public static let stillSendable =
        "You can still send. Confirm once you have checked with them, and the warning clears until something "
        + "changes again."

    /// The keys match but a pinned property moved, which no message is mis-sealed by.
    public static func recordWarning(_ addresses: [String], detail: String) -> String {
        let what = detail.isEmpty ? "identity record" : detail
        return "The \(what) for \(addresses.joined(separator: ", ")) changed since you verified them. Their keys "
            + "are unchanged, so this message is still sealed to the same person, but the change was not "
            + "something they signed."
    }

    private static func shortDate(_ seconds: Int64, locale: Locale, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.setLocalizedDateFormatFromTemplate("yMMMd")
        return formatter.string(from: Date(timeIntervalSince1970: TimeInterval(seconds)))
    }
}
