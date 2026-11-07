import Foundation

// The badge vocabulary for a trust signal, kept in one place so contacts and the reader stay in
// step. Parity with the browser's lib/trust/trustView.ts.

public struct TrustBadge: Sendable, Equatable {
    public enum Variant: String, Sendable {
        case warning, danger
        case trustContact = "trust-contact"
        case trustDMCN = "trust-dmcn"
    }
    public enum BadgeIcon: String, Sendable {
        case shieldCheck = "shield-check"
        case alertTriangle = "alert-triangle"
    }

    public let variant: Variant
    public let icon: BadgeIcon
    public let label: String
    public let detail: String
}

extension TrustProvenance {
    /// The badge wording, strongest first. Each is a trusted contact, so they share one colour and
    /// the words carry how the trust was established. "Contact" rather than "sender", because the
    /// same blue marks a recipient too.
    public var label: String {
        switch self {
        case .inPerson: "Verified in person"
        case .fingerprint: "Fingerprint verified"
        case .networkVouched: "Network vouched"
        case .orgVerified: "Organisationally verified"
        case .userApproved: "Trusted contact"
        }
    }
}

extension SenderTrust {
    /// The verdict as a badge and callout. `change` and `address` come from whoever resolved what
    /// the directory can prove about a changed key. They never change a verdict, because a stolen
    /// key produces a perfectly signed rotation, only what the reader is told while they decide.
    public func badge(
        change: KeyChange? = nil, address: String? = nil, locale: Locale = .current, timeZone: TimeZone = .current
    ) -> TrustBadge {
        switch kind {
        case .allowlisted:
            return TrustBadge(
                variant: .trustContact, icon: .shieldCheck, label: provenance?.label ?? "Trusted contact",
                detail: "This is from a trusted contact. Their identity is confirmed.")
        case .domainVerified:
            return TrustBadge(
                variant: .trustDMCN, icon: .shieldCheck, label: "DMCN sender",
                detail:
                    "This sender is a verified DMCN identity (their domain has cryptographically countersigned their address), but you have not added them to your contacts yet."
            )
        case .unknownPending:
            return TrustBadge(
                variant: .warning, icon: .alertTriangle, label: "Unknown sender",
                detail:
                    "You have never confirmed this sender’s identity. Their message is genuine and untampered, but treat unexpected requests with caution."
            )
        case .keyMismatch:
            return TrustBadge(
                variant: .danger, icon: .alertTriangle, label: "Key does not match directory",
                detail:
                    "The key that signed this message is not the one published for this address in the directory. This may be an impersonation attempt. Do not trust it."
            )
        case .keyChanged:
            var stolen = false
            if case .reportedStolen = change { stolen = true }
            return TrustBadge(
                variant: .danger, icon: .alertTriangle,
                label: stolen ? "Sender reported this key stolen" : "Sender’s key changed",
                detail: change.map {
                    ComposePin.keyWarning(address ?? "This sender", change: $0, locale: locale, timeZone: timeZone)
                }
                    ?? "The key for this contact has changed since you verified them. Check with them another way before you trust this message: a phone call, a text message, or something only the two of you would know."
            )
        case .recordChanged:
            // A warning, not danger: the keys hold, so nothing is mis-sealed and no impersonation is
            // implied. What changed is a property nobody signed.
            return TrustBadge(
                variant: .warning, icon: .alertTriangle, label: "Sender’s record changed",
                detail: reason.flatMap { $0.isEmpty ? nil : $0 }.map {
                    "\(capitalizedFirst($0)). Their keys are the same, so this message really is from them. This was not a change they made, so check that it is expected."
                }
                    ?? "Something this contact’s identity record declares has changed since you verified them, without any change to their keys."
            )
        case .identityUnverifiable:
            return TrustBadge(
                variant: .danger, icon: .alertTriangle, label: "Unverifiable identity",
                detail:
                    "The directory reports this identity claimed a domain countersignature that failed to verify (revoked or unauthorized). Do not trust it."
            )
        case .directoryMissing:
            return TrustBadge(
                variant: .warning, icon: .alertTriangle, label: "Sender not in directory",
                detail:
                    "This sender could not be found in the public-key directory, so their identity cannot be independently confirmed right now."
            )
        }
    }
}

/// `${s[0].toUpperCase()}${s.slice(1)}`.
func capitalizedFirst(_ text: String) -> String {
    guard let first = text.unicodeScalars.first else { return text }
    var rest = text.unicodeScalars
    rest.removeFirst()
    return String(first).uppercased() + String(rest)
}
