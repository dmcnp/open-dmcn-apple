import Foundation
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif
@testable import DMCNKit

/// A web host holding one account's personal storage, with the relay's rules: the op/nonce pairing
/// of internal/web/api/mailbox.go and the version arithmetic of internal/relay/personalkv_store.go.
actor StoreHost: HTTPTransport {
    struct Record: Sendable {
        var sealed: String
        var version: Int
    }

    var kv: [String: Record]
    /// Every op the client completed, as sent.
    var ops: [[String: JSONValue]] = []
    var pageSize = 50
    /// Answers every completed op with this instead, as a host with no storage or a bad minute would.
    var refusal: (status: Int, body: [String: String])?
    private var directoryKey: Data?
    private var loginNonce: Data?
    private var pending: [String: (op: [String: JSONValue], nonce: Data)] = [:]

    init(kv: [String: Record] = [:]) {
        self.kv = kv
    }

    func refuse(status: Int, code: String?) {
        var body = ["error": "refused"]
        body["code"] = code
        refusal = (status, body)
    }
    func stopRefusing() { refusal = nil }
    func setPageSize(_ size: Int) { pageSize = size }
    func put(_ key: String, sealed: String, version: Int) { kv[key] = Record(sealed: sealed, version: version) }
    func use(directoryKey key: Data) { directoryKey = key }

    private static func nonce() -> Data { Data((0..<32).map { _ in UInt8.random(in: 0...255) }) }

    private func reply(_ status: Int, _ body: some Encodable, _ request: URLRequest) -> (Data, HTTPURLResponse) {
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        return (try! JSONEncoder().encode(body), response)
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let body = try request.httpBody.map { try JSONDecoder().decode([String: JSONValue].self, from: $0) } ?? [:]
        switch request.url!.path {
        case "/api/v1/login":
            let nonce = Self.nonce()
            loginNonce = nonce
            return reply(200, ["ed25519_pub": "", "challenge_nonce": nonce.base64EncodedString()], request)
        case "/api/v1/login/verify":
            return reply(200, ["session_token": "token"], request)
        case "/api/v1/mailbox/challenge":
            let id = UUID().uuidString
            let nonce = Self.nonce()
            pending[id] = (body, nonce)
            return reply(200, ["correlation_id": id, "nonce": nonce.base64EncodedString()], request)
        case "/api/v1/mailbox/complete":
            guard case .string(let id)? = body["correlation_id"], let p = pending.removeValue(forKey: id) else {
                return reply(502, ["error": "no such op"], request)
            }
            if let refusal { return reply(refusal.status, refusal.body, request) }
            ops.append(p.op)
            return complete(p.op, request)
        default:
            return reply(404, ["error": "not here"], request)
        }
    }

    private func complete(_ op: [String: JSONValue], _ request: URLRequest) -> (Data, HTTPURLResponse) {
        let key = op.string("key") ?? ""
        switch op.string("op") {
        case "kv_get":
            guard let r = kv[key] else {
                return reply(200, ["found": JSONValue.bool(false), "version": .int(0)], request)
            }
            return reply(
                200, ["found": JSONValue.bool(true), "sealed": .string(r.sealed), "version": .int(Int64(r.version))],
                request)
        case "kv_put":
            let current = kv[key]?.version ?? 0
            let expected = Int(op.int("expected_version") ?? 0)
            if expected != 0, expected != current {
                return reply(409, ["error": "version conflict", "code": "storage_conflict"], request)
            }
            kv[key] = Record(sealed: op.string("sealed") ?? "", version: current + 1)
            return reply(200, ["version": current + 1], request)
        case "kv_list":
            let prefix = op.string("prefix") ?? ""
            let cursor = op.string("cursor") ?? ""
            let values = op.bool("values") ?? false
            let keys = kv.keys.filter { $0.hasPrefix(prefix) && (cursor.isEmpty || $0 > cursor) }.sorted()
            let page = keys.prefix(pageSize)
            let items: [JSONValue] = page.map { k in
                // A keys-only listing has no version to report: the relay reads it out of the value.
                values
                    ? .object(
                        ["key": .string(k), "sealed": .string(kv[k]!.sealed), "version": .int(Int64(kv[k]!.version))])
                    : .object(["key": .string(k), "version": .int(0)])
            }
            var out: [String: JSONValue] = ["items": .array(items)]
            if page.count == pageSize, let last = page.last { out["next_cursor"] = .string(last) }
            return reply(200, out, request)
        case "kv_delete":
            kv[key] = nil
            return reply(200, ["deleted": true], request)
        case "kv_stat":
            return reply(200, ["used_bytes": 1234, "quota_bytes": 5678, "count": kv.count], request)
        default:
            return reply(400, ["error": "unknown mailbox op"], request)
        }
    }
}

/// A store talking to a host, over a temporary directory for its fallback.
func signedInStore(
    host: StoreHost, keys: SoftwareAccountKeys = SoftwareAccountKeys(address: "me@parity.example"),
    directory: URL? = nil
) async throws -> PersonalStore {
    let client = WebHostClient(baseURL: URL(string: "https://host.example")!, transport: host)
    try await client.signIn(keys)
    return PersonalStore(client: client, keys: keys, localDirectory: directory ?? temporaryDirectory())
}

func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("dmcnkit-" + UUID().uuidString, isDirectory: true)
}

/// Storage where another device writes in the gap between a read and a compare-and-swap.
actor RacingStorage: PersonalStorage {
    let inner = InMemoryPersonalStorage()
    private var racesLeft: Int
    private let race: @Sendable (InMemoryPersonalStorage, String) async throws -> Void
    private(set) var puts: [(key: String, expectedVersion: Int)] = []

    init(
        races: Int,
        race: @escaping @Sendable (InMemoryPersonalStorage, String) async throws -> Void = { storage, key in
            // Rewrites what is there, which bumps the version under the writer.
            let current = try await storage.get(key, as: JSONValue.self)?.value ?? .object([:])
            try await storage.put(key, current)
        }
    ) {
        racesLeft = races
        self.race = race
    }

    func get<T: Decodable & Sendable>(_ key: String, as type: T.Type) async throws -> StorageEntry<T>? {
        try await inner.get(key, as: type)
    }
    func put(_ key: String, _ value: some Encodable & Sendable, expectedVersion: Int) async throws -> Int {
        puts.append((key, expectedVersion))
        if racesLeft > 0 {
            racesLeft -= 1
            try await race(inner, key)
        }
        return try await inner.put(key, value, expectedVersion: expectedVersion)
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

/// The JSON a store holds under `key`, as a dictionary, to check its shape.
func storedObject(_ storage: some PersonalStorage, _ key: String) async throws -> [String: JSONValue]? {
    guard case .object(let fields)? = try await storage.get(key, as: JSONValue.self)?.value else { return nil }
    return fields
}
