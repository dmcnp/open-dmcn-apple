import Foundation

// The checks a reader owes every message before it presents one (SPEC_CORE §3). A verified
// header signature proves only that the header is internally consistent: `sender_public_key`
// signed it. These bind it to the directory. Nothing here decides what the UI shows; it reports
// what was established, and the app gates on it.

public enum SenderBinding: Sendable, Equatable {
    /// The directory binds the sender address to the key that signed.
    case matches
    /// The directory binds the address to a different key. The message is not from the address
    /// it names: do not render its body, attachments or HTML, and do not present the address
    /// as attribution. Keep it retrievable; without a signed rotation lineage a legitimate key
    /// change looks the same.
    case mismatch(directoryKey: Data)
    /// The key matches, but the record's domain attestation failed to verify: revoked, or a broken
    /// chain, which may pass again later. The address isn't attribution, but the text can be read
    /// behind the gate, so a person's past mail doesn't vanish on a DNS fault. SPEC_CORE §3.
    case disowned
    /// The address did not resolve (outage, or legacy mail via a bridge). Unverified, NOT
    /// rejected: a directory outage must not empty a mailbox.
    case unresolved
}

public enum Audience: Sendable, Equatable {
    /// Some address in the signed audience resolves to the key this copy was sealed to.
    case addressedToThisMailbox
    /// Every address that resolved names some other key: the copy may have been re-sealed to
    /// this mailbox by someone who held it. Must be surfaced.
    case misaddressed
    /// Nothing in the audience resolved, so there is no evidence either way.
    case undetermined
}

public enum ReaderChecks {
    /// How many audience addresses one message may have resolved. The audience is the sender's
    /// to write, so without a limit one header could ask for thousands of lookups. A real copy
    /// names its reader first, and a copy re-sealed to someone else is still reported, because
    /// the addresses before the limit resolve to other keys.
    public static let audienceLookupLimit = 16

    /// Compares the header's signing key to the key the directory binds the sender address to.
    /// A key that differs comes first: SPEC_CORE §3 withholds it whatever else the directory says.
    /// `identityUnverifiable` is the directory's own verdict on a record whose key does match.
    public static func senderBinding(
        of header: Dmcn_Message_MessageHeader, directoryKey: Data?, identityUnverifiable: Bool = false
    ) -> SenderBinding {
        guard let directoryKey else { return .unresolved }
        guard constantTimeEqual(directoryKey, header.senderPublicKey) else {
            return .mismatch(directoryKey: directoryKey)
        }
        return identityUnverifiable ? .disowned : .matches
    }

    /// Whether the sender addressed this message to the mailbox reading it.
    ///
    /// Compared on the KEY, not the address string: several addresses may share one mailbox,
    /// and string comparison would report an account's own alias mail as misaddressed. An
    /// address that does not resolve is skipped, since a directory miss is not evidence of
    /// misaddressing. `resolveX25519` answers nil for an address that did not resolve.
    public static func audience(
        of header: Dmcn_Message_MessageHeader, sealedTo: Data, resolveX25519: @Sendable (String) async -> Data?
    ) async -> Audience {
        var seen = Set<String>()
        var anyResolved = false
        for address in [header.recipientAddress] + header.to + header.cc
        where seen.insert(address.lowercased()).inserted {
            guard seen.count <= audienceLookupLimit else { break }
            guard let key = await resolveX25519(address) else { continue }
            if constantTimeEqual(key, sealedTo) { return .addressedToThisMailbox }
            anyResolved = true
        }
        return anyResolved ? .misaddressed : .undetermined
    }
}
