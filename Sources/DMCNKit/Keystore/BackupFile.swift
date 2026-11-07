import Foundation

/// The backup file a person keeps for themselves, matching the browser's
/// src/lib/crypto/exportFile.ts, so one written here opens there and the other way round.
///
/// Only `bundle` is encrypted. The address and public key sit in the clear so a person can tell
/// their files apart, which also means nothing vouches for them: a hostile file can name any
/// address. That's why signing in with what comes out still has to pass `importIdentity`.
public struct BackupFile: Sendable {
    public enum Protection: String, Sendable {
        /// Opens with a passphrase: `read` handles it.
        case passphrase = "password"
        /// Opens with a passkey, in a browser only.
        case passkey
    }

    /// What's inside a backup once it's open.
    public struct Contents: Sendable {
        public let address: String
        public let keys: KeyPayload
    }

    private static let format = "dmcn-keystore-export"

    public let address: String
    public let protection: Protection
    public let bundle: EncryptedBundle
    /// Base64, as the file has it. The browser doesn't need it and may not have written it.
    private let ed25519Public: String?

    /// Reads the outside of a backup without opening it, so an app can tell a passkey backup
    /// from a passphrase one before asking for anything.
    public init(parsing data: Data) throws {
        struct Wire: Decodable {
            let format: String?
            let version: Int?
            let address: String?
            let ed25519Public: String?
            let authMethod: String?
            let bundle: EncryptedBundle?
        }
        // The format is read on its own first: a wrongly typed field in a file that isn't ours
        // says "not a backup", and in one that is ours says "damaged".
        struct Format: Decodable { let format: String? }
        guard (try? JSONDecoder().decode(Format.self, from: data))?.format == Self.format else {
            throw KeystoreError.notABackup
        }
        guard let wire = try? JSONDecoder().decode(Wire.self, from: data), let address = wire.address else {
            throw KeystoreError.damagedBackup
        }
        // The browser doesn't look at the version. There's only ever been 1, and a 2 would mean
        // the layout changed, so this says so instead of failing as a wrong passphrase.
        if let version = wire.version, version != 1 { throw KeystoreError.unsupportedBackup }
        guard let bundle = wire.bundle else {
            // A passkey backup is reported as one even with its bundle gone: same advice.
            if wire.authMethod == Protection.passkey.rawValue { throw KeystoreError.passkeyBackup }
            throw KeystoreError.damagedBackup
        }
        self.address = address
        self.protection = wire.authMethod == Protection.passkey.rawValue ? .passkey : .passphrase
        self.bundle = bundle
        self.ed25519Public = wire.ed25519Public
    }

    /// Opens a backup. A passkey backup throws `KeystoreError.passkeyBackup`, whose message tells
    /// the person what to do instead.
    public static func read(data: Data, passphrase: String) async throws -> Contents {
        let file = try BackupFile(parsing: data)
        guard file.protection == .passphrase else { throw KeystoreError.passkeyBackup }

        var plaintext = try await file.bundle.decrypt(passphrase: passphrase)
        defer { secureZero(&plaintext) }
        let keys = try KeyPayload(serialized: plaintext)
        // Stricter than the browser, which ignores this field. A label that disagrees with the
        // keys means the file was edited, and the address beside it can't be believed either.
        if let label = file.ed25519Public, Data(base64Encoded: label) != keys.ed25519Public {
            throw KeystoreError.keysDoNotMatch
        }
        return Contents(address: file.address, keys: keys)
    }

    /// Writes a passphrase backup, ready to save. Takes as long as one Argon2id run.
    public static func make(address: String, keys: KeyPayload, passphrase: String) async throws -> Data {
        var payload = keys.serialized()
        defer { secureZero(&payload) }
        let bundle = try await EncryptedBundle.encrypt(payload, passphrase: passphrase)
        return render(address: address, ed25519Public: keys.ed25519Public, bundle: bundle)
    }

    /// The file as `JSON.stringify(export, null, 2)` writes it, key order included.
    static func render(address: String, ed25519Public: Data, bundle: EncryptedBundle) -> Data {
        let params = bundle.kdfParams ?? .standard
        return Data(
            """
            {
              "format": "\(format)",
              "version": 1,
              "address": \(jsonString(address)),
              "ed25519Public": "\(ed25519Public.base64EncodedString())",
              "authMethod": "\(Protection.passphrase.rawValue)",
              "bundle": {
                "salt": "\(bundle.salt)",
                "nonce": "\(bundle.nonce)",
                "ciphertext": "\(bundle.ciphertext)",
                "tag": "\(bundle.tag)",
                "kdf": "argon2id",
                "kdfParams": {
                  "m": \(params.m),
                  "t": \(params.t),
                  "p": \(params.p)
                }
              }
            }
            """.utf8)
    }

    /// An address is the one value here that isn't ours, so it's the one that needs escaping.
    private static func jsonString(_ value: String) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        guard let data = try? encoder.encode(value), let quoted = String(data: data, encoding: .utf8) else {
            preconditionFailure("a string always encodes")
        }
        return quoted
    }
}
