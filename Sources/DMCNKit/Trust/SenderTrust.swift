import Foundation

// Native-sender trust (whitepaper §14). A message reaching here has a verified header signature, so
// its sender controls the key in the header. This answers the second question, whether to trust
// that sender, by anchoring the key to the directory and to the owner's allowlist. Blocklist
// membership is layered on separately. Parity with the browser's lib/crypto/senderTrust.ts.

/// A domain-anchored, countersigned identity: Go's identity.TierDomainDNS.
private let tierDomainDNS = 2

/// The directory's answer for an address a message claims to be from.
///
/// `IdentityLookup` needs a signing key, so a legacy answer fails to decode there. Here it is an
/// answer: what it says is that this address has no identity, which a pin has to be compared with.
public struct DirectoryAnswer: Decodable, Sendable, Equatable {
    /// Standard base64, as served, because that's the form a pin holds. Empty on a legacy answer.
    public let ed25519Pub: String
    public let x25519Pub: String
    public let fingerprint: String
    /// The tier the host verified.
    public let verifiedTier: Int
    /// The record claimed a domain attestation that failed to verify. Distrust it.
    public let identityUnverifiable: Bool
    /// No identity here: an ordinary email address, reached through a bridge.
    public let legacy: Bool
    public let adminKeyCustody: Bool

    public init(
        ed25519Pub: String = "", x25519Pub: String = "", fingerprint: String = "", verifiedTier: Int = 0,
        identityUnverifiable: Bool = false, legacy: Bool = false, adminKeyCustody: Bool = false
    ) {
        self.ed25519Pub = ed25519Pub
        self.x25519Pub = x25519Pub
        self.fingerprint = fingerprint
        self.verifiedTier = verifiedTier
        self.identityUnverifiable = identityUnverifiable
        self.legacy = legacy
        self.adminKeyCustody = adminKeyCustody
    }

    /// From what `MailboxService.lookup` returns. That never carries a legacy answer, which fails
    /// to decode there and so reads as unresolved: the same verdict.
    public init(_ lookup: IdentityLookup) {
        self.init(
            ed25519Pub: lookup.ed25519Public.base64EncodedString(),
            x25519Pub: lookup.x25519Public.base64EncodedString(),
            fingerprint: lookup.fingerprint, verifiedTier: lookup.verifiedTier ?? 0,
            identityUnverifiable: lookup.identityUnverifiable ?? false)
    }

    enum CodingKeys: String, CodingKey {
        case fingerprint, legacy
        case ed25519Pub = "ed25519_pub"
        case x25519Pub = "x25519_pub"
        case verifiedTier = "verified_tier"
        case identityUnverifiable = "identity_unverifiable"
        case adminKeyCustody = "admin_key_custody"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        ed25519Pub = try c.decodeIfPresent(String.self, forKey: .ed25519Pub) ?? ""
        x25519Pub = try c.decodeIfPresent(String.self, forKey: .x25519Pub) ?? ""
        fingerprint = try c.decodeIfPresent(String.self, forKey: .fingerprint) ?? ""
        verifiedTier = try c.decodeIfPresent(Int.self, forKey: .verifiedTier) ?? 0
        identityUnverifiable = try c.decodeIfPresent(Bool.self, forKey: .identityUnverifiable) ?? false
        legacy = try c.decodeIfPresent(Bool.self, forKey: .legacy) ?? false
        adminKeyCustody = try c.decodeIfPresent(Bool.self, forKey: .adminKeyCustody) ?? false
    }
}

extension WebHostClient {
    /// The directory's answer for a sender. Throws when the address doesn't resolve.
    public func directoryAnswer(for address: String, keys: some AccountKeys) async throws -> DirectoryAnswer {
        var components = URLComponents()
        components.queryItems = [URLQueryItem(name: "address", value: address)]
        // URLComponents leaves `+` alone, and a form-decoding host reads that as a space.
        let query = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B") ?? ""
        return try await callRenewing(
            "GET", "/api/v1/identity/lookup?" + query, Optional<[String: String]>.none, keys: keys)
    }
}

/// The verdict on a sender, roughly in descending trust.
public struct SenderTrust: Sendable, Equatable {
    public enum Kind: String, Sendable, CaseIterable {
        /// In the owner's allowlist.
        case allowlisted
        /// Not allowlisted, but countersigned by its domain.
        case domainVerified = "domain_verified"
        /// Valid and registered, with no trust decision yet.
        case unknownPending = "unknown_pending"
        /// The key that signed isn't the one the directory publishes. Danger.
        case keyMismatch = "key_mismatch"
        /// A key differs from the one pinned for this contact. Danger.
        case keyChanged = "key_changed"
        /// The keys hold, but a pinned property of the record changed. A warning.
        case recordChanged = "record_changed"
        /// A claimed countersignature failed: the domain no longer vouches for this. Danger.
        case identityUnverifiable = "identity_unverifiable"
        /// Not resolvable in the directory. A warning.
        case directoryMissing = "directory_missing"
    }

    public let kind: Kind
    /// Set when `kind` is `.allowlisted`.
    public let provenance: TrustProvenance?
    /// The directory's fingerprint, for display.
    public let fingerprint: String?
    public let reason: String?

    public init(kind: Kind, provenance: TrustProvenance? = nil, fingerprint: String? = nil, reason: String? = nil) {
        self.kind = kind
        self.provenance = provenance
        self.fingerprint = fingerprint
        self.reason = reason
    }

    /// Resolves a sender against the directory and the allowlist. Never throws: a directory failure
    /// is `.directoryMissing`.
    ///
    /// `contact` must come from `ContactStore`, whose pins are already this device's own, so the
    /// comparison below is against what this device saw and not against something the relay could
    /// have rolled back.
    public static func evaluate(
        senderAddress: String, senderPublicKey: Data, contact: ContactRecord?,
        lookup: (String) async throws -> DirectoryAnswer
    ) async -> SenderTrust {
        guard let directory = try? await lookup(senderAddress) else {
            // Still validly signed, but there's nothing to anchor it to.
            return SenderTrust(kind: .directoryMissing, reason: "sender not found in the directory")
        }
        // The lookup resolved this domain's bridge, not a correspondent. What vouches for a legacy
        // sender is the bridge's signed attestation. Comparing the signing key against an absent one
        // would report ordinary bridged mail as impersonation.
        if directory.legacy {
            return SenderTrust(kind: .directoryMissing, reason: "sent from outside DMCN, via a bridge")
        }
        // Comes first: SPEC_CORE §3 forbids showing this whatever else the directory says.
        guard keysEqual(senderPublicKey, directory.ed25519Pub) else {
            return SenderTrust(
                kind: .keyMismatch, fingerprint: directory.fingerprint,
                reason: "signing key does not match the directory")
        }
        // The key matches, but the domain doesn't stand behind the address: revoked, or a chain that
        // failed to verify, which may pass again later.
        if directory.identityUnverifiable {
            return SenderTrust(
                kind: .identityUnverifiable, fingerprint: directory.fingerprint,
                reason: "identity revoked or unverifiable")
        }
        // The directory agrees with the header, but may differ from what was pinned when this
        // contact was confirmed. That's put to the person: a signed rotation and a takeover look the
        // same from here.
        if let pinned = contact?.pinnedFacts {
            guard keysEqual(senderPublicKey, pinned.ed25519Pub) else {
                return SenderTrust(
                    kind: .keyChanged, fingerprint: directory.fingerprint,
                    reason: "this contact’s signing key has changed: re-verify before trusting")
            }
            // A received header carries no X25519 key, so this one is compared with the directory.
            // It's the key replies get sealed to, so a swap here decides who can read them.
            if !pinned.x25519Pub.isEmpty, !JSText.same(pinned.x25519Pub, directory.x25519Pub) {
                return SenderTrust(
                    kind: .keyChanged, fingerprint: directory.fingerprint,
                    reason: "this contact’s encryption key has changed: re-verify before trusting")
            }
            // The keys hold, but something else pinned moved. Notably a domain turning on admin key
            // custody, which no key comparison can see.
            let moved = ComposePin.changedFacts(pinned: pinned, observed: PinnedFacts(directory: directory))
            if !moved.isEmpty {
                return SenderTrust(
                    kind: .recordChanged, fingerprint: directory.fingerprint,
                    reason: "this contact’s \(moved.joined(separator: " and ")) changed since you verified them")
            }
        }
        if let contact {
            return SenderTrust(
                kind: .allowlisted, provenance: contact.provenance ?? .userApproved, fingerprint: directory.fingerprint)
        }
        if directory.verifiedTier >= tierDomainDNS {
            return SenderTrust(kind: .domainVerified, fingerprint: directory.fingerprint)
        }
        return SenderTrust(kind: .unknownPending, fingerprint: directory.fingerprint)
    }

    /// A raw key against a base64 one. A bad encoding simply can't match.
    private static func keysEqual(_ raw: Data, _ base64: String) -> Bool {
        guard !base64.isEmpty, let decoded = JSText.atob(base64) else { return false }
        return constantTimeEqual(raw, decoded)
    }
}
