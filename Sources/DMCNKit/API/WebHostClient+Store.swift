import Foundation

// The personal-storage ops on the web host (internal/web/api/mailbox.go), each its own
// challenge/complete pair like every other mailbox op. The sealed value is opaque here: sealing and
// opening it is PersonalStore's.

extension Wire {
    struct KvGet: Decodable { let found: Bool; let sealed: String?; let version: Int }
    struct KvPut: Decodable { let version: Int }
    struct KvItem: Decodable { let key: String; let sealed: String?; let version: Int }
    struct KvList: Decodable { let items: [KvItem]?; let next_cursor: String? }
    struct KvDeleted: Decodable { let deleted: Bool? }
    struct KvStat: Decodable { let used_bytes: Int; let quota_bytes: Int; let count: Int }
}

extension WebHostClient {
    func kvGet(_ key: String, keys: some AccountKeys) async throws -> Wire.KvGet {
        try await mailboxOp(["op": .string("kv_get"), "key": .string(key)], keys: keys)
    }

    func kvPut(_ key: String, sealed: String, expectedVersion: Int, keys: some AccountKeys) async throws -> Int {
        let res: Wire.KvPut = try await mailboxOp(
            [
                "op": .string("kv_put"), "key": .string(key), "sealed": .string(sealed),
                "expected_version": .int(expectedVersion),
            ], keys: keys)
        return res.version
    }

    /// One page. `cursor` is empty for the first and otherwise the `next_cursor` of the last,
    /// passed back exactly as it came.
    func kvList(prefix: String, values: Bool, cursor: String, keys: some AccountKeys) async throws -> Wire.KvList {
        try await mailboxOp(
            ["op": .string("kv_list"), "prefix": .string(prefix), "values": .bool(values), "cursor": .string(cursor)],
            keys: keys)
    }

    func kvDelete(_ key: String, keys: some AccountKeys) async throws {
        let _: Wire.KvDeleted = try await mailboxOp(["op": .string("kv_delete"), "key": .string(key)], keys: keys)
    }

    func kvStat(keys: some AccountKeys) async throws -> Wire.KvStat {
        try await mailboxOp(["op": .string("kv_stat")], keys: keys)
    }
}
