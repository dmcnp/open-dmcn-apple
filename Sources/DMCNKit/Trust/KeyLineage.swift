import Crypto
import Foundation
import SwiftProtobuf

// What happened to a key this device pinned, worked out here from what the directory served.
//
//   replaced        - the pinned key signed the handover to the key in use now. Ordinary re-keying
//                     looks like this. So does a takeover by someone holding the key and an enrolled
//                     device, which is why it's evidence and not a verdict.
//   recovered       - some other key signed the handover. That is how someone who lost every device
//                     gets back in, and also exactly what a forged chain looks like from here.
//   reported-stolen - the owner published a tombstone against the pinned key, signed by the key that
//                     replaced it. Mail already signed by that key is suspect too.
//   unexplained     - nothing signed accounts for the change.
//
// None of them unblocks anything. A stolen key produces a perfectly signed rotation, so the change is
// always put to the person who pinned it; this only changes what they're told while they decide. It
// is all checked here because the fleet is the party a pin exists to catch: a chain that doesn't hold
// up is no explanation, never a bad one. Parity with the browser's lib/trust/lineage.ts and
// lib/crypto/verifyRotation.ts, and with Go's identity.VerifyRotationChain.
//
// Not checked: whether a device credential chains to the domain and clears its tenure minimum. That's
// an admission question about the terminal entry, asked against the rotation's own time. Re-asking it
// on a history walk would fail every past entry the moment its credential expired.

/// What the directory served for an address, all base64.
public struct IdentityRecordAnswer: Decodable, Sendable, Equatable {
    public let record: String
    public let history: String?
    public let removal: String?

    public init(record: String, history: String? = nil, removal: String? = nil) {
        self.record = record
        self.history = history
        self.removal = removal
    }
}

extension WebHostClient {
    /// The signed records for an address. A host that doesn't serve them answers with a failure,
    /// which `KeyLineage.load` reads as nothing to go on.
    public func identityRecord(for address: String, keys: some AccountKeys) async throws -> IdentityRecordAnswer {
        var components = URLComponents()
        components.queryItems = [URLQueryItem(name: "address", value: address)]
        let query = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B") ?? ""
        return try await callRenewing(
            "GET", "/api/v1/identity/record?" + query, Optional<[String: String]>.none, keys: keys)
    }
}

public enum KeyLineage {
    /// Matches Go's identity.MaxRotationChain: a record carrying more is refused outright.
    static let maxChain = 8

    /// Fetches the directory's answer and explains a pinned key against it. An unreachable directory
    /// is evidence of nothing, and the gate stands either way, so the reader is told less, never more.
    public static func load(
        address: String, pinnedEd25519Pub: String, fetch: (String) async throws -> IdentityRecordAnswer
    ) async -> KeyChange {
        guard let served = try? await fetch(address) else { return .unexplained }
        return explain(address: address, pinnedEd25519Pub: pinnedEd25519Pub, served: served)
    }

    /// Explains a pinned key's disappearance from what the directory served.
    public static func explain(address: String, pinnedEd25519Pub: String, served: IdentityRecordAnswer) -> KeyChange {
        guard let bytes = JSText.atob(served.record),
            let record = try? Dmcn_Identity_IdentityRecord(serializedBytes: bytes)
        else { return .unexplained }
        // A record that doesn't verify explains nothing, and neither does one for another address.
        guard JSText.sameIgnoringCase(record.address, address) else { return .unexplained }
        // Checked before anything is read out of it. The chain walk only proves the entries agree with
        // each other and with this record, not that the owner published them.
        guard record.ed25519PublicKey.count == 32, record.selfSignature.count == 64, record.ownerSignatureIsValid(),
            recordChainHolds(record)
        else { return .unexplained }

        // A tombstone outranks a rotation: "this key was stolen" is the heavier statement. One that
        // can't even be read leaves nothing to go on, as it would if the fetch had failed, rather than
        // falling back to the gentler answer: a fleet could otherwise choose that by serving garbage.
        var stolenAt: Int64?
        if let removal = served.removal, !removal.isEmpty {
            guard let bytes = JSText.atob(removal),
                let parsed = try? Dmcn_Identity_AddressRemovalRecord(serializedBytes: bytes)
            else { return .unexplained }
            stolenAt = declaredStolen(address: address, pinned: pinnedEd25519Pub, record: record, removal: parsed)
        }
        if let stolenAt { return .reportedStolen(at: stolenAt) }
        guard
            let handover = retiredInLineage(
                address: address, pinned: pinnedEd25519Pub, record: record, history: served.history)
        else { return .unexplained }
        return handover.byRecoveryKey ? .recovered(at: handover.at) : .replaced(at: handover.at)
    }

    private struct Handover {
        let at: Int64
        /// Some key other than the one retired gave the consent: the recovery arm, or a forgery.
        let byRecoveryKey: Bool
    }

    /// When the pinned key handed the address over. The record's own chain is capped, so an older key
    /// may have fallen out of it, which is what the history record is for.
    private static func retiredInLineage(
        address: String, pinned: String, record: Dmcn_Identity_IdentityRecord, history: String?
    ) -> Handover? {
        if let onRecord = retiredAt(record.rotationChain, pinned: pinned) { return onRecord }
        guard let history, !history.isEmpty, let bytes = JSText.atob(history),
            let parsed = try? Dmcn_Identity_AddressHistoryRecord(serializedBytes: bytes),
            historyHolds(parsed, address: address),
            // It has to agree with the record it explains, or it describes some other lineage.
            let last = parsed.chain.last, sameBytes(last.nextEd25519PublicKey, record.ed25519PublicKey)
        else { return nil }
        return retiredAt(parsed.chain, pinned: pinned)
    }

    /// The transition that retired `pinned`, and who authorised it.
    ///
    /// Matching on the retired key alone isn't enough. An entry's consent is checked against the key
    /// the entry itself names, which may legitimately differ from the retired one, so an attacker can
    /// publish a one-entry chain claiming retired = the key you verified and authorising = their own,
    /// and it verifies end to end. What's checkable here is narrower, and gets the reassuring wording:
    /// the pinned key signed its OWN retirement.
    private static func retiredAt(_ chain: [Dmcn_Identity_RotationEntry], pinned: String) -> Handover? {
        for entry in chain where JSText.same(entry.retiredEd25519PublicKey.base64EncodedString(), pinned) {
            return Handover(
                at: entry.rotatedAt,
                byRecoveryKey: !JSText.same(entry.authorizingEd25519PublicKey.base64EncodedString(), pinned))
        }
        return nil
    }

    /// When the owner declared the pinned key stolen.
    ///
    /// The declaration is signed by the key that took the address over, which is what makes it worth
    /// anything: a stolen key is held by both parties and identifies neither. A tombstone signed by
    /// anyone else, a domain root included, isn't verifiable here and is left out of the account.
    private static func declaredStolen(
        address: String, pinned: String, record: Dmcn_Identity_IdentityRecord,
        removal: Dmcn_Identity_AddressRemovalRecord
    ) -> Int64? {
        guard JSText.sameIgnoringCase(removal.address, address),
            let hit = removal.removedBindings.first(where: {
                JSText.same($0.ed25519PublicKey.base64EncodedString(), pinned)
            }),
            let signable = try? removal.signableBytes(),
            verifyEd25519(
                publicKey: record.ed25519PublicKey, message: SignatureContext.addressRemoval.signable(signable),
                signature: removal.selfSignature)
        else { return nil }
        return hit.removedAt
    }

    // MARK: Walking a chain

    /// The chain a record carries, and that it lands on that record: a chain is evidence about one
    /// handover into one record, never a transferable credential.
    static func recordChainHolds(_ record: Dmcn_Identity_IdentityRecord) -> Bool {
        let chain = record.rotationChain
        guard let last = chain.last else { return true }
        return chain.count <= maxChain && linksHold(chain, address: record.address)
            && sameBytes(last.nextEd25519PublicKey, record.ed25519PublicKey)
            && sameBytes(last.nextX25519PublicKey, record.x25519PublicKey)
            && last.nextRevision == record.revision
    }

    /// A complete history. One cut at the front is refused outright: this is exactly where a reader
    /// goes when the capped chain fell short, so one that starts part-way defeats its own purpose.
    static func historyHolds(_ history: Dmcn_Identity_AddressHistoryRecord, address: String) -> Bool {
        guard JSText.sameIgnoringCase(history.address, address) else { return false }
        if let first = history.chain.first, !first.prevSignatureHash.isEmpty { return false }
        return linksHold(history.chain, address: address)
    }

    /// Entries form one unbroken line for one address: each retires the key its predecessor handed
    /// over, names that predecessor by the hash of its signature, and advances in time and revision.
    static func linksHold(_ chain: [Dmcn_Identity_RotationEntry], address: String) -> Bool {
        for (index, entry) in chain.enumerated() {
            guard entry.holdsUp, JSText.sameIgnoringCase(entry.address, address) else { return false }
            guard index > 0 else { continue }
            let previous = chain[index - 1]
            guard sameBytes(entry.retiredEd25519PublicKey, previous.nextEd25519PublicKey),
                sameBytes(entry.retiredX25519PublicKey, previous.nextX25519PublicKey),
                sameBytes(entry.prevSignatureHash, Data(SHA256.hash(data: previous.signature))),
                entry.rotatedAt > previous.rotatedAt, entry.nextRevision > previous.nextRevision
            else { return false }
        }
        return true
    }

    private static func sameBytes(_ a: Data, _ b: Data) -> Bool { constantTimeEqual(a, b) }
}

/// The three contexts a rotation entry's signatures carry (SPEC_EXT_ROTATION), distinct so a signature
/// made for one can't verify as another.
private enum RotationContext: String {
    case consent = "dmcn-identity-rotation-v1"
    case accept = "dmcn-identity-rotation-accept-v1"
    case device = "dmcn-identity-rotation-device-v1"

    func signable(_ canonical: Data) -> Data { Data(rawValue.utf8) + [0] + canonical }
}

extension Dmcn_Identity_RotationEntry {
    /// One entry's own shape and signatures. Three signatures nest, each covering the ones before it:
    /// the device attests, the outgoing key consents to a transition already naming that device, and
    /// the incoming key accepts the whole thing. That nesting stops one being lifted onto another
    /// handover, so all three are re-derived here rather than trusted as a set.
    fileprivate var holdsUp: Bool {
        guard version != 0, !address.isEmpty, retiredEd25519PublicKey.count == 32, nextEd25519PublicKey.count == 32,
            authorizingEd25519PublicKey.count == 32,
            // A transition to the key already held isn't one, and could replay as a no-op.
            retiredEd25519PublicKey != nextEd25519PublicKey, retiredX25519PublicKey != nextX25519PublicKey,
            rotatedAt != 0, nextRevision != 0, prevSignatureHash.isEmpty || prevSignatureHash.count == 32
        else { return false }

        var unsigned = self
        unsigned.unknownFields = UnknownStorage()
        if unsigned.hasDeviceCredential { unsigned.deviceCredential.unknownFields = UnknownStorage() }
        unsigned.nextSignature = Data()
        guard let accept = try? Canonical.marshal(unsigned) else { return false }
        unsigned.signature = Data()
        guard let consent = try? Canonical.marshal(unsigned) else { return false }
        unsigned.deviceSignature = Data()
        guard let device = try? Canonical.marshal(unsigned) else { return false }

        guard signed(by: authorizingEd25519PublicKey, .consent, consent, signature) else { return false }
        if hasDeviceCredential {
            guard signed(by: deviceCredential.subject, .device, device, deviceSignature) else { return false }
        } else if !deviceSignature.isEmpty {
            return false  // a device signature with no credential names no device
        }
        return signed(by: nextEd25519PublicKey, .accept, accept, nextSignature)
    }

    private func signed(by key: Data, _ context: RotationContext, _ body: Data, _ signature: Data) -> Bool {
        !key.isEmpty && !signature.isEmpty
            && verifyEd25519(publicKey: key, message: context.signable(body), signature: signature)
    }
}

extension Dmcn_Identity_AddressRemovalRecord {
    /// What `self_signature` covers: fields 1 to 6, each binding rebuilt so nothing unknown rides in.
    fileprivate func signableBytes() throws -> Data {
        var pb = Self()
        pb.version = version
        pb.domain = domain
        pb.address = address
        pb.removedBindings = removedBindings.map { binding in
            var clean = Dmcn_Identity_RemovedBinding()
            clean.ed25519PublicKey = binding.ed25519PublicKey
            clean.removedAt = binding.removedAt
            return clean
        }
        pb.revision = revision
        pb.createdAt = createdAt
        return try Canonical.marshal(pb)
    }
}
