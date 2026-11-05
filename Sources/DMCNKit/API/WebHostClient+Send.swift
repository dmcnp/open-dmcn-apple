import Crypto
import Foundation

// Delivering one sealed copy through the web host: POST /api/v1/messages/send
// (internal/web/api/messages.go), and the directory lookup a composer does before it.
//
// The host stores what it is given on the recipient's relay. It holds no keys: the envelope is
// sealed and signed here, and it relays the signature.

/// The directory's answer for an address a message is about to be sealed to.
///
/// `IdentityLookup` is the reader's view of the same endpoint and needs a signing key. This one
/// doesn't, because a directory may answer an ordinary email address with its own bridge: a
/// success with `legacy` set, no signing key, and an `x25519Pub` that belongs to the bridge.
public struct RecipientLookup: Decodable, Sendable, Equatable {
    public let address: String
    /// Standard base64, as served, because that is the form a pin holds. Empty on a legacy answer.
    public let ed25519Pub: String
    /// Standard base64. On a legacy answer, the bridge's key.
    public let x25519Pub: String
    public let fingerprint: String
    /// Mailbox or domain policy: mail to this address has to travel by the private route.
    public let requireOnion: Bool
    /// No identity here: an ordinary email address, reached through a bridge.
    public let legacy: Bool
    /// The domain says an admin holds this account's keys.
    public let adminKeyCustody: Bool
    /// The owner-signed address that also gets this address's mail.
    public let forwardTo: String?

    public init(
        address: String, ed25519Pub: String = "", x25519Pub: String, fingerprint: String = "",
        requireOnion: Bool = false, legacy: Bool = false, adminKeyCustody: Bool = false, forwardTo: String? = nil
    ) {
        self.address = address
        self.ed25519Pub = ed25519Pub
        self.x25519Pub = x25519Pub
        self.fingerprint = fingerprint
        self.requireOnion = requireOnion
        self.legacy = legacy
        self.adminKeyCustody = adminKeyCustody
        self.forwardTo = forwardTo
    }

    enum CodingKeys: String, CodingKey {
        case address, fingerprint, legacy
        case ed25519Pub = "ed25519_pub"
        case x25519Pub = "x25519_pub"
        case requireOnion = "require_onion"
        case adminKeyCustody = "admin_key_custody"
        case forwardTo = "forward_to"
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        address = try c.decodeIfPresent(String.self, forKey: .address) ?? ""
        ed25519Pub = try c.decodeIfPresent(String.self, forKey: .ed25519Pub) ?? ""
        x25519Pub = try c.decodeIfPresent(String.self, forKey: .x25519Pub) ?? ""
        fingerprint = try c.decodeIfPresent(String.self, forKey: .fingerprint) ?? ""
        requireOnion = try c.decodeIfPresent(Bool.self, forKey: .requireOnion) ?? false
        legacy = try c.decodeIfPresent(Bool.self, forKey: .legacy) ?? false
        adminKeyCustody = try c.decodeIfPresent(Bool.self, forKey: .adminKeyCustody) ?? false
        forwardTo = try c.decodeIfPresent(String.self, forKey: .forwardTo)
    }

    /// The key to seal to, or nil when the answer carries no usable one.
    public var sealingKey: Data? {
        Data(base64Encoded: x25519Pub).flatMap { $0.count == 32 ? $0 : nil }
    }
}

/// Fields a build adds to each send, given the SHA-256 of the envelope. The reference app adds none.
public typealias SendFields = @Sendable (_ envelopeHash: Data) async throws -> [String: String]

extension Wire {
    struct Sent: Decodable { let envelope_hash: String }
}

extension WebHostClient {
    /// Looks an address up for sending. `keys` signs in again if the session has lapsed.
    public func lookupRecipient(_ address: String, keys: some AccountKeys) async throws -> RecipientLookup {
        try await callRenewing(
            "GET", "/api/v1/identity/lookup?address=" + Self.queryEscaped(address), Optional<[String: String]>.none,
            keys: keys)
    }

    /// Hands one sealed copy to the host and returns the hash of the accepted envelope, in hex.
    ///
    /// `sender` signs: the keys of whichever identity this goes out as, over the hash of these
    /// exact bytes. `account` is who the session belongs to, also when sending as another address.
    /// `recipient` is the address to route to. `messageID` is shared by every copy of one compose,
    /// so a host that counts sends sees one message with several recipients.
    @discardableResult
    public func send(
        _ envelope: Dmcn_Message_EncryptedEnvelope, as sender: some AccountKeys, senderAddress: String,
        to recipient: String, onion: Bool, messageID: Data, account: some AccountKeys, extraFields: SendFields? = nil
    ) async throws -> String {
        let bytes = try Canonical.marshal(envelope)
        let hash = Data(SHA256.hash(data: bytes))
        var body: [String: MailboxOpValue] = [
            "sender_address": .string(senderAddress),
            "sender_signature": .string(try sender.sign(hash).base64EncodedString()),
            "envelope": .string(bytes.base64EncodedString()),
            "recipient_address": .string(recipient),
            "onion": .bool(onion),
            "message_id": .string(messageID.hex),
        ]
        for (name, value) in try await extraFields?(hash) ?? [:] { body[name] = .string(value) }
        let sent: Wire.Sent = try await callRenewing("POST", "/api/v1/messages/send", body, keys: account)
        return sent.envelope_hash
    }
}
