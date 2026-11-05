import Foundation
import SwiftProtobuf

extension Dmcn_Identity_IdentityRecord {
    /// The bytes the owner self-signature covers (before the context tag).
    ///
    /// Built as an ALLOWLIST of the owner-signed fields, as Go identity.signableBytes builds a
    /// fresh message from them: the relay hints, the address and routing credentials, operator
    /// credentials, attestations, the signature itself, and any field this build does not know
    /// are all outside it. Copying the record and clearing fields would let an unknown field
    /// through, and nothing would ever verify the result.
    public func ownerSignableBytes() throws -> Data {
        var pb = Dmcn_Identity_IdentityRecord()
        pb.version = version
        pb.address = address
        pb.ed25519PublicKey = ed25519PublicKey
        pb.x25519PublicKey = x25519PublicKey
        pb.createdAt = createdAt
        pb.expiresAt = expiresAt
        pb.verificationTier = verificationTier
        pb.requireOnion = requireOnion
        pb.revision = revision
        // The chain is signed whole, so its entries are the one place an unknown field could
        // ride in. Go rebuilds each entry and its device credential, which drops them.
        pb.rotationChain = rotationChain.map { entry in
            var entry = entry
            entry.unknownFields = UnknownStorage()
            if entry.hasDeviceCredential { entry.deviceCredential.unknownFields = UnknownStorage() }
            return entry
        }
        pb.recoveryEd25519PublicKey = recoveryEd25519PublicKey
        pb.forwardTo = forwardTo
        return try Canonical.marshal(pb)
    }

    /// Whether the owner self-signature verifies against the record's own Ed25519 key.
    ///
    /// This says the record is internally consistent and nothing more. Whether the address
    /// belongs to that key is the domain's to attest (the address credential, chained to the
    /// DNS-anchored root), and expiry and removal are checked separately.
    public func ownerSignatureIsValid() -> Bool {
        guard let bytes = try? ownerSignableBytes() else { return false }
        return verifyEd25519(
            publicKey: ed25519PublicKey,
            message: SignatureContext.identitySelf.signable(bytes),
            signature: selfSignature)
    }
}
