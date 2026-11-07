import Crypto
import Foundation

/// Keys encrypted under a passphrase, in the browser's JSON shape (src/lib/crypto/keystore.ts).
///
/// AES-256-GCM under an Argon2id key. The bundle names its own cost, so opening one needs no
/// outside knowledge. The fields stay base64 strings because that's what the file holds, and
/// the tag is separate because the browser splits it off what Web Crypto returns.
public struct EncryptedBundle: Codable, Equatable, Sendable {
    public struct KDFParams: Codable, Equatable, Sendable {
        /// Memory cost in KiB.
        public let m: Int
        /// Iterations.
        public let t: Int
        /// Parallelism.
        public let p: Int

        public init(m: Int, t: Int, p: Int) {
            self.m = m
            self.t = t
            self.p = p
        }

        /// The browser's ARGON2_PARAMS: what new bundles use, and what one that names none used.
        public static let standard = KDFParams(m: 19456, t: 2, p: 1)
    }

    public let salt: String
    public let nonce: String
    public let ciphertext: String
    public let tag: String
    /// "argon2id" on a passphrase bundle. Absent on a passkey one.
    public let kdf: String?
    public let kdfParams: KDFParams?

    /// A bundle's cost is whatever the file says, and the file can come from anywhere. These
    /// leave plenty of room over the browser's 19 MiB and two passes, and stop a file from
    /// getting the app killed for its memory or pinning a core for hours.
    private static let maxMemoryKiB = 256 * 1024
    private static let maxWork = 4 * 1024 * 1024

    /// Encrypts `plaintext` under `passphrase`, with a fresh salt and nonce.
    public static func encrypt(_ plaintext: Data, passphrase: String) async throws -> EncryptedBundle {
        try await encrypt(plaintext, passphrase: passphrase, salt: randomBytes(32), nonce: randomBytes(12))
    }

    /// The fixed-salt form is what lets a test hold this to the browser's exact output.
    static func encrypt(
        _ plaintext: Data, passphrase: String, salt: Data, nonce: Data
    ) async throws -> EncryptedBundle {
        guard !passphrase.isEmpty else { throw KeystoreError.passphraseRequired }
        let params = KDFParams.standard
        let sealed = try AES.GCM.seal(
            plaintext, using: try await key(passphrase: passphrase, salt: salt, params: params),
            nonce: try AES.GCM.Nonce(data: nonce))
        return EncryptedBundle(
            salt: salt.base64EncodedString(), nonce: nonce.base64EncodedString(),
            ciphertext: sealed.ciphertext.base64EncodedString(), tag: sealed.tag.base64EncodedString(),
            kdf: "argon2id", kdfParams: params)
    }

    /// Opens the bundle. The caller owns the result, which is usually key material.
    public func decrypt(passphrase: String) async throws -> Data {
        guard !passphrase.isEmpty else { throw KeystoreError.passphraseRequired }
        // A passkey bundle has no salt to derive from: its key comes from the authenticator.
        if salt.isEmpty, kdf == nil { throw KeystoreError.passkeyBackup }
        if let kdf, kdf != "argon2id" { throw KeystoreError.unsupportedBackup }

        let params = kdfParams ?? .standard
        guard params.m <= Self.maxMemoryKiB, params.t <= Self.maxWork / max(params.m, 1) else {
            throw KeystoreError.tooDemanding
        }
        guard let salt = Data(base64Encoded: salt), let nonce = Data(base64Encoded: nonce), nonce.count == 12,
            let ciphertext = Data(base64Encoded: ciphertext), let tag = Data(base64Encoded: tag), tag.count == 16
        else { throw KeystoreError.damagedBackup }

        let key: SymmetricKey
        do {
            key = try await Self.key(passphrase: passphrase, salt: salt, params: params)
        } catch is Argon2id.InvalidParameters {
            throw KeystoreError.damagedBackup
        }
        do {
            let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: nonce), ciphertext: ciphertext, tag: tag)
            return try AES.GCM.open(box, using: key)
        } catch {
            throw KeystoreError.wrongPassphrase
        }
    }

    private static func key(passphrase: String, salt: Data, params: KDFParams) async throws -> SymmetricKey {
        // No normalisation: these are the bytes TextEncoder gives the browser.
        var password = Data(passphrase.utf8)
        defer { secureZero(&password) }
        var bytes = try await Argon2id.derive(
            password: password, salt: salt, memoryKiB: params.m, iterations: params.t, parallelism: params.p,
            length: 32)
        defer { secureZero(&bytes) }
        return SymmetricKey(data: bytes)
    }
}

/// `count` bytes from the system's secure generator.
func randomBytes(_ count: Int) -> Data {
    var generator = SystemRandomNumberGenerator()
    return Data((0..<count).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
}
