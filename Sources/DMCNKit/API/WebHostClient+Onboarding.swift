import Foundation

// Getting an account onto this device: bringing in keys it already has, or making a new one.
// Matches src/lib/api/client.ts and app/lib/api/daemonClient.ts, with the handlers in open-dmcn's
// internal/web/api. Registration and petitions are the reference daemon's own routes, and a host
// serves one or the other: POST /api/v1/register exists only where the domain's root key is on
// the machine, and the petition routes only where it isn't.

extension Wire {
    struct ImportChallenge: Decodable { let ed25519_pub: String; let challenge_nonce: String }
    struct RelayHints: Decodable { let relay_hints: [String] }
    struct Signup: Decodable { let mode: String }
    struct PetitionCreated: Decodable { let code: String; let expires_at: String }
    struct PetitionState: Decodable { let status: String; let address: String?; let expires_at: String? }
}

/// How a mailbox is had on this server.
public enum SignupMode: String, Sendable, Equatable {
    /// Anyone can create one here.
    case register
    /// An admin assigns one, from a code the person reads to them.
    case petition
    /// Neither: this server takes no new accounts through this client.
    case closed
}

/// The backup's keys aren't the ones the directory holds for this address: it's an old backup,
/// or one for somewhere else. Its own error because trying again can't help, and it's raised
/// before anything is signed.
public struct IdentityMismatchError: Error, Equatable, Sendable {
    public let address: String
}

extension IdentityMismatchError: LocalizedError {
    public var errorDescription: String? {
        "These keys don't match the account registered for \(address). Check you chose the right backup."
    }
}

/// What this account can do right now, answered by the server from the live fleet.
///
/// It exists for operations a client finishes on its own before the network has agreed, such as
/// re-keying: ask first, and never infer the answer from a version number.
public struct Capabilities: Decodable, Equatable, Sendable {
    public struct Rotation: Decodable, Equatable, Sendable {
        /// Every relay homing this mailbox understands the rotation schema.
        public let fleetReady: Bool
        /// The domain permits self-serve re-keying and is not a custody domain.
        public let domainAllows: Bool
        /// How long a device must have been enrolled before it may authorize a rotation.
        public let minDeviceAgeDays: Int

        enum CodingKeys: String, CodingKey {
            case fleetReady = "fleet_ready"
            case domainAllows = "domain_allows"
            case minDeviceAgeDays = "min_device_age_days"
        }
    }

    public struct Forward: Decodable, Equatable, Sendable {
        /// Every relay homing this mailbox reads forward_to, so a record carrying one is accepted.
        public let fleetReady: Bool
        /// The operator forwards for this account. Needed to set a forward.
        public let eligible: Bool
        /// The forward the account's record carries now, if any.
        public let forwardTo: String?

        enum CodingKeys: String, CodingKey {
            case fleetReady = "fleet_ready"
            case eligible
            case forwardTo = "forward_to"
        }
    }

    public let address: String
    public let rotation: Rotation
    /// Absent on a host without forwarding, the reference daemon's among them.
    public let forward: Forward?

    /// Everything off: the answer when there's no answer. The browser's NO_CAPABILITIES.
    public static let denied = Capabilities(
        address: "", rotation: Rotation(fleetReady: false, domainAllows: false, minDeviceAgeDays: 0), forward: nil)
}

/// What the host said about a new account. It mints no session: sign in next.
public struct Registration: Decodable, Equatable, Sendable {
    /// "active" once the account can be used.
    public let status: String?
    /// The account's address, where the host repeats it.
    public let address: String?
}

/// A filed petition: the code to read to an admin, and when it lapses.
public struct PetitionTicket: Equatable, Sendable {
    public let code: String
    public let expiresAt: Date?
}

public enum PetitionStatus: Equatable, Sendable {
    /// Still with the admin. Check again in a few seconds, as the browser does.
    case pending(expiresAt: Date?)
    /// The admin chose this address. Finish with `completePetition`.
    case assigned(address: String)
}

extension WebHostClient {
    // MARK: Keys this device already has

    /// Brings existing keys onto this device: proves possession of them against the directory
    /// and starts a session. Nothing is published. Call it before storing the keys, so a backup
    /// that's refused leaves nothing behind.
    ///
    /// The host's copy of the key is compared first, because this is the only check on the
    /// address in a backup file, which anyone can edit.
    public func importIdentity(_ keys: some AccountKeys) async throws {
        let challenge: Wire.ImportChallenge = try await call(
            "POST", "/api/v1/import/challenge", ["address": keys.address], authenticated: false)
        // No fallthrough on a missing key, unlike `signIn`: here the comparison is the point.
        guard Data(base64Encoded: challenge.ed25519_pub) == keys.ed25519Public else {
            throw IdentityMismatchError(address: keys.address)
        }
        let session: Wire.Session = try await call(
            "POST", "/api/v1/import",
            [
                "address": keys.address,
                "challenge_signature": try keys.sign(try Self.nonce(challenge.challenge_nonce)).base64EncodedString(),
            ], authenticated: false)
        sessionToken = session.session_token
    }

    // MARK: Capabilities

    /// What this account can do, or `Capabilities.denied` on any failure at all.
    ///
    /// Deliberately doesn't throw. A host that predates the endpoint answers 404, which has to
    /// read as "can't", and a caller handling an error might be tempted to carry on. This uses
    /// the session as it stands: a lapsed one reads as denied.
    public func capabilities() async -> Capabilities {
        (try? await call("GET", "/api/v1/capabilities", Optional<[String: String]>.none)) ?? .denied
    }

    /// The same, signing in again once if the session has lapsed.
    public func capabilities(renewingWith keys: some AccountKeys) async -> Capabilities {
        (try? await callRenewing("GET", "/api/v1/capabilities", Optional<[String: String]>.none, keys: keys))
            ?? .denied
    }

    // MARK: A new account

    /// The relays a new mailbox at `address` would live on. Fails when the domain has none
    /// reachable, which stops an account being made that could never receive mail.
    public func relayHints(for address: String) async throws -> [String] {
        let hints: Wire.RelayHints = try await call(
            "GET", "/api/v1/relay-hints?address=" + Self.queryEscaped(address), Optional<[String: String]>.none,
            authenticated: false)
        return hints.relay_hints
    }

    /// Creates an account for `address` with these keys: self-signs its record and hands it to
    /// the host to publish. The private keys stay here.
    ///
    /// This starts no session. Store the keys, then `signIn`, in that order: from here on the
    /// address is bound to them, and losing them loses the address. A taken address is an
    /// `APIError` with the code `already_registered` and a message to show.
    public func register(_ keys: KeyPayload, address: String) async throws -> Registration {
        if let problem = validateChosenAddress(address) { throw APIError(status: 0, message: problem) }
        let record = try keys.selfSignedRecord(address: address, relayHints: try await relayHints(for: address))
        do {
            return try await call(
                "POST", "/api/v1/register",
                [
                    "address": address,
                    "ed25519_pub": keys.ed25519Public.base64EncodedString(),
                    "x25519_pub": keys.x25519Public.base64EncodedString(),
                    "identity_record": try Canonical.marshal(record).base64EncodedString(),
                    "self_signature": record.selfSignature.base64EncodedString(),
                ], authenticated: false)
        } catch let error as APIError where error.code == "already_registered" {
            throw APIError(
                status: error.status, message: "That address is already taken. Choose another, or sign in.",
                code: error.code)
        } catch let error as APIError where error.status == 404 {
            // The route doesn't exist on a domain whose root key is offline.
            throw APIError(
                status: error.status,
                message: "This server doesn't create accounts itself. Ask its admin for a mailbox.",
                code: error.code)
        }
    }

    // MARK: Signing up

    /// How to get a mailbox on this server. It says, where it's new enough to. An older `dmcnd` doesn't,
    /// but it serves petitions or registration and never both, and the status route tells them
    /// apart without touching anything: asked for no code, it answers 400 if it's there at all.
    public func signupMode() async throws -> SignupMode {
        do {
            let answer: Wire.Signup = try await call(
                "GET", "/api/v1/signup", Optional<[String: String]>.none, authenticated: false)
            return SignupMode(rawValue: answer.mode) ?? .closed
        } catch let error as APIError where error.status == 404 {
            // Older than the route.
        }
        do {
            let _: Wire.PetitionState = try await call(
                "GET", "/api/v1/petition/status", Optional<[String: String]>.none, authenticated: false)
            return .petition
        } catch let error as APIError where error.status == 400 {
            return .petition
        } catch let error as APIError where error.status == 404 {
            return .register
        }
    }

    // MARK: Petitions

    /// Asks for a mailbox on a domain whose root key is offline: proves possession of both keys
    /// and gets a code for the person to read to their admin. Nothing is created yet, and there's
    /// no address to choose, because the admin picks it.
    ///
    /// Store the keys before showing the code. The admin may take days, and the address will be
    /// bound to these keys.
    public func createPetition(_ keys: KeyPayload) async throws -> PetitionTicket {
        let proof = try keys.accountKeys(address: "").sign(keys.petitionSignableBytes)
        let created: Wire.PetitionCreated = try await call(
            "POST", "/api/v1/petition",
            [
                "ed25519_pub": keys.ed25519Public.base64EncodedString(),
                "x25519_pub": keys.x25519Public.base64EncodedString(),
                "proof": proof.base64EncodedString(),
            ], authenticated: false)
        return PetitionTicket(code: created.code, expiresAt: Self.date(created.expires_at))
    }

    /// Where a petition stands. An `APIError` with status 404 means this code is spent: it
    /// expired, or it was finished elsewhere. The host won't say which.
    public func petitionStatus(code: String) async throws -> PetitionStatus {
        let state: Wire.PetitionState
        do {
            state = try await call(
                "GET", "/api/v1/petition/status?code=" + Self.queryEscaped(code), Optional<[String: String]>.none,
                authenticated: false)
        } catch let error as APIError where error.status == 404 {
            throw APIError(
                status: error.status, message: "That request expired. You can ask for a new one.", code: error.code)
        }
        // As the browser reads it: "assigned" without an address isn't anything to act on yet.
        if state.status == "assigned", let address = state.address { return .assigned(address: address) }
        return .pending(expiresAt: state.expires_at.flatMap(Self.date))
    }

    /// Claims the address an admin assigned: self-signs a record for it, now that it's known, and
    /// the host attaches the credentials the admin left. Starts no session, so `signIn` next.
    public func completePetition(code: String, address: String, keys: KeyPayload) async throws -> Registration {
        let record = try keys.selfSignedRecord(address: address, relayHints: try await relayHints(for: address))
        return try await call(
            "POST", "/api/v1/petition/complete",
            ["code": code, "identity_record": try Canonical.marshal(record).base64EncodedString()],
            authenticated: false)
    }

    // MARK: Helpers

    /// A query value as encodeURIComponent writes it, near enough for the host to read it back.
    static func queryEscaped(_ value: String) -> String {
        var components = URLComponents()
        components.queryItems = [URLQueryItem(name: "v", value: value)]
        // URLComponents leaves `+` alone, and a form-decoding host reads that as a space.
        let query = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B") ?? ""
        return String(query.dropFirst(2))
    }

    /// The host's RFC 3339 times. Nil rather than a failure: the date is only ever shown.
    private static func date(_ text: String) -> Date? {
        try? Date(text, strategy: .iso8601)
    }
}
