import Foundation

// What a new account signs on this device, matching src/lib/crypto/enrollment.ts and the
// petition page. The keys are made here and the server only ever sees public halves and
// signatures. Both byte strings below are pinned by vectors from the browser, which Go verified
// (`EnrollmentVectorTests`).

extension KeyPayload {
    /// The identity record for `address`, signed by these keys.
    ///
    /// Version 1 and revision 1 are Go's NewIdentityRecord, and it never expires. `createdAt` is
    /// when the keys were made, so a petition's record, signed days after its keys, keeps that
    /// time as the browser does. Relay hints are advisory and outside the signature: whoever
    /// publishes the record sets the real ones.
    public func selfSignedRecord(address: String, relayHints: [String]) throws -> Dmcn_Identity_IdentityRecord {
        var record = Dmcn_Identity_IdentityRecord()
        record.version = 1
        record.address = address
        record.ed25519PublicKey = ed25519Public
        record.x25519PublicKey = x25519Public
        record.createdAt = createdAt
        record.relayHints = relayHints
        record.revision = 1
        record.selfSignature = try accountKeys(address: address).sign(
            SignatureContext.identitySelf.signable(record.ownerSignableBytes()))
        return record
    }

    /// What a petition signs: both public keys, so neither can be swapped in later. The X25519
    /// key matters most, since mail is sealed to it and it can't sign for itself.
    var petitionSignableBytes: Data {
        // Its own tag, not a `SignatureContext`: this one isn't a core record signature. It must
        // equal open-dmcn's internal/petition sigContext.
        Data("dmcn-petition-v1".utf8) + [0] + ed25519Public + x25519Public
    }
}
