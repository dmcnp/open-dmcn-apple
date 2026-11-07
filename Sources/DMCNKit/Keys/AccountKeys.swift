import Crypto
import Foundation

/// The keys that act as one address: an Ed25519 signing key and an X25519 key-exchange key.
///
/// The kit only ever asks for the two operations below, never for private bytes, so where a
/// key lives is the app's decision. An implementation backed by the Keychain (with biometric
/// access control) keeps the private halves out of reach of the code that uses them; the
/// in-memory `SoftwareAccountKeys` is for tests and short-lived flows.
public protocol AccountKeys: Sendable {
    var address: String { get }
    /// 32-byte Ed25519 public key.
    var ed25519Public: Data { get }
    /// 32-byte X25519 public key: the one the mailbox is keyed by.
    var x25519Public: Data { get }

    /// Ed25519 signature over `message`, exactly as given: callers prepend any context tag.
    func sign(_ message: Data) throws -> Data
    /// X25519 agreement between this account's private key and a sealer's ephemeral key.
    func sharedSecret(withEphemeral ephemeralPublic: Data) throws -> SharedSecret
}

extension AccountKeys {
    /// This account's fingerprint: the first 20 bytes of SHA-256(Ed25519 public || X25519 public), in
    /// upper-case hex, as the web client shows it. Comparing it with someone by phone or in person
    /// is what confirms a key, so it comes from the keys here, never from a server.
    public var fingerprint: String {
        SHA256.hash(data: ed25519Public + x25519Public).prefix(20).map { String(format: "%02X", $0) }.joined()
    }
}

/// Keys held in process memory. Never print one: it has no description on purpose.
public struct SoftwareAccountKeys: AccountKeys {
    public let address: String
    private let signing: Curve25519.Signing.PrivateKey
    private let agreement: Curve25519.KeyAgreement.PrivateKey

    public init(
        address: String,
        signing: Curve25519.Signing.PrivateKey = .init(),
        agreement: Curve25519.KeyAgreement.PrivateKey = .init()
    ) {
        self.address = address
        self.signing = signing
        self.agreement = agreement
    }

    /// From the raw 32-byte Ed25519 seed and X25519 private scalar.
    public init(address: String, ed25519Seed: Data, x25519Private: Data) throws {
        self.init(
            address: address,
            signing: try .init(rawRepresentation: ed25519Seed),
            agreement: try .init(rawRepresentation: x25519Private))
    }

    public var ed25519Public: Data { signing.publicKey.rawRepresentation }
    public var x25519Public: Data { agreement.publicKey.rawRepresentation }

    public func sign(_ message: Data) throws -> Data {
        try signing.signature(for: message)
    }

    public func sharedSecret(withEphemeral ephemeralPublic: Data) throws -> SharedSecret {
        try agreement.sharedSecretFromKeyAgreement(with: .init(rawRepresentation: ephemeralPublic))
    }
}

/// Verifies an Ed25519 signature. False for a malformed key as well as a bad signature.
public func verifyEd25519(publicKey: Data, message: Data, signature: Data) -> Bool {
    guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKey) else { return false }
    return key.isValidSignature(signature, for: message)
}
