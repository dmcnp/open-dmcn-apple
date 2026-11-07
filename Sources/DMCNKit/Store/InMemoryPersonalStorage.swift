import Foundation

/// Personal storage in memory, for tests and samples.
///
/// It keeps the relay's rules (internal/relay/personalkv_store.go) so that code which works here
/// works there: the same key charset, the same version arithmetic, the same compare-and-swap, keys
/// listed in order, and version 0 from a keys-only listing. Values go through JSON, so a shape that
/// wouldn't survive the real thing doesn't survive this either.
public actor InMemoryPersonalStorage: DeviceStorage {
    private var records: [String: (json: Data, version: Int)] = [:]

    public init() {}

    /// The relay's key check. A rejected key is a refusal from the host, with the host's code.
    private static func check(_ key: String) throws {
        let segments = key.split(separator: "/", omittingEmptySubsequences: false)
        let allowed = key.utf8.allSatisfy {
            switch $0 {
            case UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "A")...UInt8(ascii: "Z"),
                UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "_"), UInt8(ascii: "-"), UInt8(ascii: "."),
                UInt8(ascii: "/"):
                return true
            default:
                return false
            }
        }
        guard !key.isEmpty, key.utf8.count <= 512, allowed, !segments.contains(where: { ["", ".", ".."].contains($0) })
        else {
            throw APIError(status: 400, message: "relay: personal kv invalid key", code: "storage_bad_key")
        }
    }

    public func get<T: Decodable & Sendable>(_ key: String, as type: T.Type) async throws -> StorageEntry<T>? {
        try Self.check(key)
        guard let record = records[key] else { return nil }
        return StorageEntry(key: key, value: try StoreJSON.decode(type, from: record.json), version: record.version)
    }

    public func put(_ key: String, _ value: some Encodable & Sendable, expectedVersion: Int) async throws -> Int {
        try Self.check(key)
        let current = records[key]?.version ?? 0
        if expectedVersion != 0, current != expectedVersion { throw StorageConflictError() }
        records[key] = (try StoreJSON.encode(value), current + 1)
        return current + 1
    }

    public func list<T: Decodable & Sendable>(prefix: String, as type: T.Type) async throws -> [StorageEntry<T>] {
        records.filter { $0.key.hasPrefix(prefix) }.sorted { $0.key < $1.key }.compactMap { key, record in
            guard let value = try? StoreJSON.decode(type, from: record.json) else { return nil }
            return StorageEntry(key: key, value: value, version: record.version)
        }
    }

    public func listKeys(prefix: String) async throws -> [(key: String, version: Int)] {
        records.keys.filter { $0.hasPrefix(prefix) }.sorted().map { ($0, 0) }
    }

    public func delete(_ key: String) async throws {
        records[key] = nil
    }

    public func stat() async throws -> StorageUsage {
        StorageUsage(usedBytes: records.values.reduce(0) { $0 + $1.json.count }, quotaBytes: 0, count: records.count)
    }
}
