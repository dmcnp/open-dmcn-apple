import Crypto
import Foundation

/// An account's raw keys in the browser's JSON shape (keyPairToPayloadJSON in
/// src/lib/crypto/keys.ts): what a backup holds once it's open, and what the app puts in the
/// Keychain.
///
/// This is the one place outside `AccountKeys` that handles private bytes, so it gives them up
/// only through `serialized()` and `accountKeys(address:)`. It has no description, and its
/// mirror is empty, so `print` and `dump` show the type name and nothing else.
public struct KeyPayload: Sendable {
    public let ed25519Public: Data
    public let x25519Public: Data
    /// 16 bytes: this device's UUID. The personal store's flag records carry it.
    public let deviceId: Data
    /// Unix seconds. The identity record is signed over this, so it can't be replaced by "now".
    public let createdAt: Int64

    private let ed25519Seed: Data
    private let x25519Private: Data

    /// Reads a payload and proves its halves belong together.
    ///
    /// The browser takes these fields on trust. Here a backup's public keys go on to name the
    /// account and its mailbox, so a file whose private keys produce something else is refused
    /// rather than found out later, when the mail won't open.
    public init(serialized: Data) throws {
        struct Wire: Decodable {
            let ed25519_public: String
            let ed25519_private: String
            let x25519_public: String
            let x25519_private: String
            let device_id: String
            let created_at: Int64
        }
        // Decoding errors are dropped, not passed on: they can quote what they failed to read.
        guard let wire = try? JSONDecoder().decode(Wire.self, from: serialized),
            let edPublic = Data(base64Encoded: wire.ed25519_public),
            var edPrivate = Data(base64Encoded: wire.ed25519_private),
            let xPublic = Data(base64Encoded: wire.x25519_public),
            let xPrivate = Data(base64Encoded: wire.x25519_private),
            let deviceId = Data(base64Encoded: wire.device_id)
        else { throw KeystoreError.damagedBackup }
        defer { secureZero(&edPrivate) }

        // 64 bytes in Go's layout, seed then public. The browser slices off the seed to sign.
        guard edPrivate.count == 64, edPublic.count == 32, xPublic.count == 32, xPrivate.count == 32,
            deviceId.count == 16
        else { throw KeystoreError.damagedBackup }
        let seed = Data(edPrivate.prefix(32))

        guard Data(edPrivate.suffix(32)) == edPublic,
            let signing = try? Curve25519.Signing.PrivateKey(rawRepresentation: seed),
            signing.publicKey.rawRepresentation == edPublic,
            let agreement = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: xPrivate),
            agreement.publicKey.rawRepresentation == xPublic
        else { throw KeystoreError.keysDoNotMatch }

        self.init(
            ed25519Seed: seed, ed25519Public: edPublic, x25519Private: xPrivate, x25519Public: xPublic,
            deviceId: deviceId, createdAt: wire.created_at)
    }

    /// Fresh keys for a new account, as generateIdentityKeyPair makes them.
    public static func generate() -> KeyPayload {
        let signing = Curve25519.Signing.PrivateKey()
        let agreement = Curve25519.KeyAgreement.PrivateKey()
        // A version 4 UUID: random, with the version and variant bits set.
        var deviceId = randomBytes(16)
        deviceId[6] = (deviceId[6] & 0x0f) | 0x40
        deviceId[8] = (deviceId[8] & 0x3f) | 0x80
        return KeyPayload(
            ed25519Seed: signing.rawRepresentation, ed25519Public: signing.publicKey.rawRepresentation,
            x25519Private: agreement.rawRepresentation, x25519Public: agreement.publicKey.rawRepresentation,
            deviceId: deviceId, createdAt: Int64(Date().timeIntervalSince1970))
    }

    private init(
        ed25519Seed: Data, ed25519Public: Data, x25519Private: Data, x25519Public: Data, deviceId: Data,
        createdAt: Int64
    ) {
        self.ed25519Seed = ed25519Seed
        self.ed25519Public = ed25519Public
        self.x25519Private = x25519Private
        self.x25519Public = x25519Public
        self.deviceId = deviceId
        self.createdAt = createdAt
    }

    /// The JSON the browser writes for these keys, to the byte: same key order, no spaces, and
    /// `/` left alone, none of which `JSONEncoder` promises. The app stores this in the
    /// Keychain, and `init(serialized:)` reads it back. Treat it as you would the keys.
    public func serialized() -> Data {
        let fields = [
            "\"ed25519_public\":\"\(ed25519Public.base64EncodedString())\"",
            "\"ed25519_private\":\"\((ed25519Seed + ed25519Public).base64EncodedString())\"",
            "\"x25519_public\":\"\(x25519Public.base64EncodedString())\"",
            "\"x25519_private\":\"\(x25519Private.base64EncodedString())\"",
            "\"device_id\":\"\(deviceId.base64EncodedString())\"",
            "\"created_at\":\(createdAt)",
        ]
        return Data("{\(fields.joined(separator: ","))}".utf8)
    }

    /// These keys acting as `address`.
    public func accountKeys(address: String) -> SoftwareAccountKeys {
        // Both were built or checked by an initialiser, so neither can fail here.
        guard let signing = try? Curve25519.Signing.PrivateKey(rawRepresentation: ed25519Seed),
            let agreement = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: x25519Private)
        else { preconditionFailure("key lengths were checked when this was made") }
        return SoftwareAccountKeys(address: address, signing: signing, agreement: agreement)
    }
}

extension KeyPayload: CustomReflectable {
    /// Nothing to show: the default mirror would walk the private fields for `dump` and `print`.
    public var customMirror: Mirror { Mirror(self, children: [:]) }
}
