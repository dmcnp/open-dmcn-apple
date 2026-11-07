import Foundation
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

// The client side of a DMCN web host's HTTP API: the `/api/v1` surface open-dmcn's `dmcnd`
// serves for its browser client (internal/web/api), which the hosted product serves too.
//
// The host holds no key material. Signing in is a challenge the account key signs, and every
// mailbox operation is a two-phase challenge/complete in which the device signs the relay's
// nonce; the host relays the signature and never sees a private key. Speaking libp2p to the
// relays directly (SPEC_CORE §5) is the alternative; this path exists because the web host is
// already deployed in front of every fleet, and it keeps the app off a libp2p stack.

/// How the client puts a request on the wire. A seam for tests; the app uses URLSession.
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionTransport: HTTPTransport {
    let session: URLSession
    public init(session: URLSession = .shared) { self.session = session }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw APIError(status: 0, message: "not an HTTP response")
        }
        return (data, http)
    }
}

/// A refusal from the host: its status, its human message, and its machine code when it has one
/// (`access_suspended`, `access_closed`).
public struct APIError: Error, Equatable, Sendable {
    public let status: Int
    public let message: String
    public let code: String?

    public init(status: Int, message: String, code: String? = nil) {
        self.status = status
        self.message = message
        self.code = code
    }
}

extension APIError: LocalizedError {
    public var errorDescription: String? { message }
}

/// The address is bound to a key this device does not hold: it was re-keyed somewhere else.
/// Its own error because no retry will ever succeed, and a client that retried would look
/// broken rather than say what happened.
public struct AccountRekeyedError: Error, Equatable, Sendable {
    public let address: String
}

/// One page of a mailbox listing, newest first.
public struct MailboxPage: Sendable {
    public struct Item: Sendable {
        /// Hex of the envelope hash: the message's name within the mailbox.
        public let hash: String
        public let entry: Dmcn_Relay_MailboxEntry

        public init(hash: String, entry: Dmcn_Relay_MailboxEntry) {
            self.hash = hash
            self.entry = entry
        }
    }
    public let items: [Item]
    /// Pass back to continue; nil when the mailbox is drained.
    public let nextCursor: String?

    public init(items: [Item], nextCursor: String?) {
        self.items = items
        self.nextCursor = nextCursor
    }
}

/// The directory's answer for an address, as the host resolved and verified it.
public struct IdentityLookup: Decodable, Sendable, Equatable {
    public let address: String
    public let ed25519Public: Data
    public let x25519Public: Data
    public let fingerprint: String
    /// The tier the record claims.
    public let verificationTier: Int
    /// The tier the host verified (DAR, DNS, removal), where it ran the check.
    public let verifiedTier: Int?
    /// The record claimed a domain attestation that failed to verify. Distrust it.
    public let identityUnverifiable: Bool?
    public let requireOnion: Bool?
    public let forwardTo: String?

    public init(
        address: String, ed25519Public: Data, x25519Public: Data, fingerprint: String = "", verificationTier: Int = 0,
        verifiedTier: Int? = nil, identityUnverifiable: Bool? = nil, requireOnion: Bool? = nil, forwardTo: String? = nil
    ) {
        self.address = address
        self.ed25519Public = ed25519Public
        self.x25519Public = x25519Public
        self.fingerprint = fingerprint
        self.verificationTier = verificationTier
        self.verifiedTier = verifiedTier
        self.identityUnverifiable = identityUnverifiable
        self.requireOnion = requireOnion
        self.forwardTo = forwardTo
    }

    enum CodingKeys: String, CodingKey {
        case address, fingerprint
        case ed25519Public = "ed25519_pub"
        case x25519Public = "x25519_pub"
        case verificationTier = "verification_tier"
        case verifiedTier = "verified_tier"
        case identityUnverifiable = "identity_unverifiable"
        case requireOnion = "require_onion"
        case forwardTo = "forward_to"
    }
}

/// The host's JSON shapes (internal/web/api in open-dmcn), named as it names them.
enum Wire {
    struct LoginChallenge: Decodable { let ed25519_pub: String; let challenge_nonce: String }
    struct Session: Decodable { let session_token: String }
    struct MailboxChallenge: Decodable { let correlation_id: String; let nonce: String }
    struct Listing: Decodable {
        struct Row: Decodable { let hash: String; let entry: String }
        let entries: [Row]?
        let next_cursor: String?
    }
    struct Body: Decodable { let body: String }
    struct Deleted: Decodable { let hash: String }
    struct Refusal: Decodable { let error: String?; let code: String? }
}

public actor WebHostClient {
    public let baseURL: URL
    private let transport: any HTTPTransport
    var sessionToken: String?

    public init(baseURL: URL, transport: any HTTPTransport = URLSessionTransport()) {
        self.baseURL = baseURL
        self.transport = transport
    }

    public var isSignedIn: Bool { sessionToken != nil }

    // MARK: Session

    /// Signs in as `keys.address`: the host issues a nonce, the account key signs it, and the
    /// host verifies the signature against the directory's record and mints a session.
    public func signIn(_ keys: some AccountKeys) async throws {
        let challenge: Wire.LoginChallenge = try await call(
            "POST", "/api/v1/login", ["address": keys.address], authenticated: false)
        // The challenge names the key the directory binds this address to, so a mismatch is
        // a re-key, said where someone can act on it. A challenge without one falls through.
        if !challenge.ed25519_pub.isEmpty, Data(base64Encoded: challenge.ed25519_pub) != keys.ed25519Public {
            throw AccountRekeyedError(address: keys.address)
        }
        let session: Wire.Session = try await call(
            "POST", "/api/v1/login/verify",
            [
                "address": keys.address,
                "challenge_signature": try keys.sign(try Self.nonce(challenge.challenge_nonce)).base64EncodedString(),
            ], authenticated: false)
        sessionToken = session.session_token
    }

    /// Forgets the session before telling the host, so a call still in flight that comes back
    /// 401 finds nothing to renew.
    public func signOut() async {
        guard let token = sessionToken else { return }
        sessionToken = nil
        _ = try? await callRaw("POST", "/api/v1/logout", body: nil, bearer: token)
    }

    // MARK: Directory

    public func lookup(_ address: String) async throws -> IdentityLookup {
        var components = URLComponents()
        components.queryItems = [URLQueryItem(name: "address", value: address)]
        // URLComponents leaves `+` alone, and a form-decoding host reads that as a space.
        let query = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B") ?? ""
        return try await call("GET", "/api/v1/identity/lookup?" + query, Optional<[String: String]>.none)
    }

    // MARK: Mailbox

    /// One page of the mailbox, newest first. Listing never consumes mail.
    public func list(_ keys: some AccountKeys, limit: Int = 50, cursor: String? = nil) async throws -> MailboxPage {
        var op: [String: MailboxOpValue] = ["op": .string("list"), "limit": .int(limit)]
        if let cursor { op["cursor"] = .string(cursor) }
        let listing: Wire.Listing = try await mailboxOp(op, keys: keys)
        let items = try (listing.entries ?? []).map { row in
            guard let bytes = Data(base64Encoded: row.entry) else {
                throw APIError(status: 0, message: "entry is not base64")
            }
            return MailboxPage.Item(hash: row.hash, entry: try Dmcn_Relay_MailboxEntry(serializedBytes: bytes))
        }
        let next = listing.next_cursor.flatMap { $0.isEmpty ? nil : $0 }
        return MailboxPage(items: items, nextCursor: next)
    }

    /// The sealed body of one message, by the hex hash its listing named.
    public func body(hash: String, keys: some AccountKeys) async throws -> Dmcn_Relay_MailboxBody {
        let resp: Wire.Body = try await mailboxOp(["op": .string("body"), "hash": .string(hash)], keys: keys)
        guard let bytes = Data(base64Encoded: resp.body) else {
            throw APIError(status: 0, message: "body is not base64")
        }
        return try Dmcn_Relay_MailboxBody(serializedBytes: bytes)
    }

    public func delete(hash: String, keys: some AccountKeys) async throws {
        let _: Wire.Deleted = try await mailboxOp(["op": .string("delete"), "hash": .string(hash)], keys: keys)
    }

    enum MailboxOpValue: Encodable {
        case string(String)
        case int(Int)
        case bool(Bool)
        func encode(to encoder: any Encoder) throws {
            var c = encoder.singleValueContainer()
            switch self {
            case .string(let s): try c.encode(s)
            case .int(let i): try c.encode(i)
            case .bool(let b): try c.encode(b)
            }
        }
    }

    /// The challenge/complete pair. The account key signs the relay's nonce as sent, with no
    /// context tag (SPEC_CORE §2). Each op is its own challenge; one nonce never serves two.
    func mailboxOp<T: Decodable>(_ op: [String: MailboxOpValue], keys: some AccountKeys) async throws -> T {
        let challenge: Wire.MailboxChallenge = try await callRenewing(
            "POST", "/api/v1/mailbox/challenge", op, keys: keys)
        return try await call(
            "POST", "/api/v1/mailbox/complete",
            [
                "correlation_id": challenge.correlation_id,
                "signature": try keys.sign(try Self.nonce(challenge.nonce)).base64EncodedString(),
            ])
    }

    /// Decodes a challenge, refusing anything but the 32 bytes a challenge is (SPEC_CORE §2).
    ///
    /// The account key signs a nonce with no context tag, so without this check a host could
    /// pass off a tagged header or record as a nonce and get the account's signature on it.
    /// Nothing tagged fits in 32 bytes. A STORE signature's envelope hash does, and only a
    /// domain-separated challenge in the protocol would rule that out.
    static func nonce(_ base64: String) throws -> Data {
        guard let nonce = Data(base64Encoded: base64), nonce.count == 32 else {
            throw APIError(status: 0, message: "The server sent a sign-in challenge this app won't sign.")
        }
        return nonce
    }

    // MARK: Transport

    /// An authenticated call that signs in again once when the host says the session lapsed.
    /// Only a session that existed is renewed: a client that never signed in is told so.
    func callRenewing<T: Decodable>(
        _ method: String, _ path: String, _ body: (some Encodable)?, keys: some AccountKeys
    ) async throws -> T {
        guard sessionToken != nil else { throw APIError(status: 401, message: "not signed in") }
        do {
            return try await call(method, path, body)
        } catch let error as APIError where error.status == 401 {
            guard sessionToken != nil else { throw error }  // signed out while this was in flight
            try await signIn(keys)
            return try await call(method, path, body)
        }
    }

    func call<T: Decodable>(
        _ method: String, _ path: String, _ body: (some Encodable)?, authenticated: Bool = true
    ) async throws -> T {
        if authenticated, sessionToken == nil { throw APIError(status: 401, message: "not signed in") }
        let data = try await callRaw(
            method, path, body: body.map { try JSONEncoder().encode($0) }, bearer: authenticated ? sessionToken : nil)
        return try JSONDecoder().decode(T.self, from: data)
    }

    func callRaw(_ method: String, _ path: String, body: Data?, bearer: String?) async throws -> Data {
        guard let url = URL(string: path, relativeTo: baseURL) else {
            throw APIError(status: 0, message: "bad path \(path)")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if let bearer { request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
        let (data, response) = try await transport.send(request)
        guard (200..<300).contains(response.statusCode) else {
            let refusal = try? JSONDecoder().decode(Wire.Refusal.self, from: data)
            throw APIError(
                status: response.statusCode, message: refusal?.error ?? "HTTP \(response.statusCode)",
                code: refusal?.code)
        }
        return data
    }
}
