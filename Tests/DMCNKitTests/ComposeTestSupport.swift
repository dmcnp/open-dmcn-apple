import Crypto
import Foundation
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif
@testable import DMCNKit

/// A web host with a directory and the send endpoint, checking what internal/web/api/messages.go and
/// the relay check: the sender matches the session, and the STORE signature covers the SHA-256 of the
/// envelope as the host re-marshals it. Everything else goes to the personal store behind it.
actor ComposeHost: HTTPTransport {
    struct Post: Sendable {
        let fields: [String: JSONValue]
        let envelope: Dmcn_Message_EncryptedEnvelope
        var recipient: String { fields.string("recipient_address") ?? "" }
        var onion: Bool { fields.bool("onion") ?? false }
    }

    struct Answer: Sendable {
        var status: Int
        var body: [String: JSONValue]
    }

    let store = StoreHost()
    var directory: [String: Answer]
    var sendStatus: [String: Int]
    var posts: [Post] = []
    var lookups: [String] = []
    var expiredSession = false
    /// Every send that reached the point of being stored or refused.
    var attempts = 0
    private var sender: Data

    init(sender: Data, directory: [String: Answer] = [:], sendStatus: [String: Int] = [:]) {
        self.sender = sender
        self.directory = directory
        self.sendStatus = sendStatus
    }

    func expireSessionOnce() { expiredSession = true }
    func setDirectory(_ address: String, _ answer: Answer) { directory[address] = answer }
    func refuse(_ address: String, status: Int) { sendStatus[address] = status }
    func accept(_ address: String) { sendStatus[address] = nil }
    func expectSender(_ key: Data) { sender = key }

    private func reply(_ status: Int, _ body: some Encodable, _ request: URLRequest) -> (Data, HTTPURLResponse) {
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        return (try! JSONEncoder().encode(body), response)
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        switch request.url!.path {
        case "/api/v1/identity/lookup":
            if expiredSession {
                expiredSession = false
                return reply(401, ["error": "not authenticated"], request)
            }
            let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems
            let address = items?.first { $0.name == "address" }?.value ?? ""
            lookups.append(address)
            let answer = directory[address] ?? Answer(status: 404, body: ["error": .string("identity not found")])
            return reply(answer.status, answer.body, request)
        case "/api/v1/messages/send":
            let body = try JSONDecoder().decode([String: JSONValue].self, from: request.httpBody ?? Data())
            let bytes = Data(base64Encoded: body.string("envelope") ?? "") ?? Data()
            let envelope = try Dmcn_Message_EncryptedEnvelope(serializedBytes: bytes)
            let signature = Data(base64Encoded: body.string("sender_signature") ?? "") ?? Data()
            guard try Canonical.marshal(envelope) == bytes,
                verifyEd25519(publicKey: sender, message: Data(SHA256.hash(data: bytes)), signature: signature)
            else {
                return reply(400, ["error": "INVALID_SIGNATURE"], request)
            }
            attempts += 1
            if let status = sendStatus[body.string("recipient_address") ?? ""] {
                return reply(status, ["error": "refused"], request)
            }
            posts.append(Post(fields: body, envelope: envelope))
            return reply(200, ["envelope_hash": String(repeating: "ab", count: 32)], request)
        default:
            return try await store.send(request)
        }
    }
}

/// Storage whose writes fail, as a relay in a bad minute.
struct RefusingStorage: PersonalStorage {
    let inner = InMemoryPersonalStorage()

    func get<T: Decodable & Sendable>(_ key: String, as type: T.Type) async throws -> StorageEntry<T>? {
        try await inner.get(key, as: type)
    }
    func put(_ key: String, _ value: some Encodable & Sendable, expectedVersion: Int) async throws -> Int {
        throw APIError(status: 502, message: "offline")
    }
    func list<T: Decodable & Sendable>(prefix: String, as type: T.Type) async throws -> [StorageEntry<T>] {
        try await inner.list(prefix: prefix, as: type)
    }
    func listKeys(prefix: String) async throws -> [(key: String, version: Int)] {
        try await inner.listKeys(prefix: prefix)
    }
    func delete(_ key: String) async throws { try await inner.delete(key) }
    func stat() async throws -> StorageUsage { try await inner.stat() }
}

/// A bridge route: seals to its own key, and keeps what it was given.
actor FakeLegacyRoute: LegacyMailRoute {
    struct Delivery: Sendable {
        let recipient: String
        let senderAddress: String
        let bytes: Data
    }

    private let bridge: Data
    private(set) var deliveries: [Delivery] = []

    init(bridge: Data) {
        self.bridge = bridge
    }

    func deliver(
        to recipient: String, from senderAddress: String, seal: @escaping @Sendable (Data) throws -> Data,
        sign: @escaping @Sendable (Data) throws -> Data
    ) async throws {
        let bytes = try seal(bridge)
        _ = try sign(Data(SHA256.hash(data: bytes)))
        deliveries.append(Delivery(recipient: recipient, senderAddress: senderAddress, bytes: bytes))
    }
}

/// A clock and timers the test moves by hand.
final class ManualTimers: AutosaveTimers, @unchecked Sendable {
    private struct Due {
        let at: Int64
        let fire: @Sendable () async -> Void
    }

    private let lock = NSLock()
    private var current: Int64 = 0
    private var next = 0
    private var due: [Int: Due] = [:]

    func set(after milliseconds: Int64, _ fire: @escaping @Sendable () async -> Void) -> any Sendable {
        lock.withLock {
            next += 1
            due[next] = Due(at: current + milliseconds, fire: fire)
            return next
        }
    }

    func clear(_ handle: any Sendable) {
        _ = lock.withLock { due.removeValue(forKey: handle as! Int) }
    }

    func now() -> Int64 { lock.withLock { current } }

    var pendingTimers: Int { lock.withLock { due.count } }

    /// Moves time on, running each timer that falls due, in order, to completion.
    func advance(_ milliseconds: Int64) async {
        let until = lock.withLock { current + milliseconds }
        while let (id, timer) = takeNext(until: until) {
            _ = id
            await timer.fire()
        }
        lock.withLock { current = until }
    }

    private func takeNext(until: Int64) -> (Int, Due)? {
        lock.withLock {
            guard let (id, timer) = due.filter({ $0.value.at <= until }).min(by: { $0.value.at < $1.value.at }) else {
                return nil
            }
            due[id] = nil
            current = timer.at
            return (id, timer)
        }
    }
}
