import Crypto
import Foundation

// Personal storage on the owner's home relay, through the web host. Parity with the browser's
// lib/api/personalStore.ts. Every value is sealed to the owner on this device before it leaves it,
// so neither the relay nor the host ever holds plaintext:
//
//     sealed = base64(JSON(SealedBlob(JSON(value))))
//
// A relay isn't obliged to offer storage. One that doesn't answers UNSUPPORTED, and this store falls
// back to files on this device for as long as it lives: a minimal relay stays usable, at the cost
// of the account's state staying on one device. That is surfaced through `isLocalOnly`, because
// state that silently stops following someone looks exactly like lost data when a second device
// comes up empty. Nothing is copied up afterwards: two devices that both went local hold different
// sets, and picking a winner isn't this store's to do.

/// The account's state on its home relay, falling back to `localDirectory` on a relay with none.
///
/// Make one per signed-in account and share it between that account's stores. Its local-only
/// verdict is about the relay being talked to right now, so a new sign-in starts by asking again.
public actor PersonalStore: PersonalStorage {
    private let client: WebHostClient
    private let keys: any AccountKeys
    private let local: LocalPersonalStorage
    private var localOnly = false
    private var waiting: [AsyncStream<Bool>.Continuation] = []

    /// `localDirectory` is shared safely by several accounts: each gets a folder of its own inside it.
    public init(client: WebHostClient, keys: any AccountKeys, localDirectory: URL) {
        self.client = client
        self.keys = keys
        let owner = Data(SHA256.hash(data: Data(JSText.normalizedAddress(keys.address).utf8))).hex
        local = LocalPersonalStorage(directory: localDirectory.appendingPathComponent(owner, isDirectory: true))
    }

    /// True once the relay has said it keeps no storage, so this account's state is on this device
    /// only. Say so to the person using it.
    public var isLocalOnly: Bool { localOnly }

    /// Yields `true` when the store goes local-only, then finishes. If it already has, that happens
    /// at once. The change only ever happens in that one direction.
    public func localOnlyUpdates() -> AsyncStream<Bool> {
        let (stream, continuation) = AsyncStream.makeStream(of: Bool.self)
        if localOnly {
            continuation.yield(true)
            continuation.finish()
        } else {
            waiting.append(continuation)
        }
        return stream
    }

    /// Recognises the relay saying it keeps no storage, and latches the fallback.
    ///
    /// Deliberately narrow: only the definitive answer counts. A timeout or a 502 means ask again
    /// later, and reading those as "no storage here" would strand an account on device-local state
    /// because of one bad minute of network.
    private func latchIfUnsupported(_ error: APIError) -> Bool {
        guard error.code == "storage_unsupported" || error.status == 501 else { return false }
        if !localOnly {
            localOnly = true
            for continuation in waiting {
                continuation.yield(true)
                continuation.finish()
            }
            waiting = []
        }
        return true
    }

    private func seal(_ value: some Encodable) throws -> String {
        let blob = try SealedBlob.seal(StoreJSON.encode(value), to: [keys.x25519Public])
        return try StoreJSON.encode(blob).base64EncodedString()
    }

    // Retired keys belong here: after a rotation a value written earlier opens only with the key it
    // was written under, so the fallback through older generations goes around `blob.open`, as the
    // browser's PersonalStore.open does. Rotation isn't in this kit yet.
    private func unseal<T: Decodable>(_ sealed: String, as type: T.Type) throws -> T {
        guard let bytes = Data(base64Encoded: sealed) else { throw SealError.notARecipient }
        let blob = try StoreJSON.decode(SealedBlob.self, from: bytes)
        return try StoreJSON.decode(type, from: blob.open(with: keys))
    }

    // MARK: PersonalStorage

    public func get<T: Decodable & Sendable>(_ key: String, as type: T.Type) async throws -> StorageEntry<T>? {
        if !localOnly {
            do {
                let res = try await client.kvGet(key, keys: keys)
                guard res.found, let sealed = res.sealed, !sealed.isEmpty else { return nil }
                return StorageEntry(key: key, value: try unseal(sealed, as: type), version: res.version)
            } catch let error as APIError {
                guard latchIfUnsupported(error) else { throw error }
            }
        }
        return try await local.get(key, as: type)
    }

    public func put(_ key: String, _ value: some Encodable & Sendable, expectedVersion: Int) async throws -> Int {
        if !localOnly {
            do {
                return try await client.kvPut(
                    key, sealed: try seal(value), expectedVersion: expectedVersion, keys: keys)
            } catch let error as APIError {
                if error.code == "storage_conflict" { throw StorageConflictError() }
                guard latchIfUnsupported(error) else { throw error }
            }
        }
        return try await local.put(key, value, expectedVersion: expectedVersion)
    }

    public func list<T: Decodable & Sendable>(prefix: String, as type: T.Type) async throws -> [StorageEntry<T>] {
        if !localOnly {
            do {
                var out: [StorageEntry<T>] = []
                for item in try await allItems(prefix: prefix, values: true) {
                    guard let sealed = item.sealed, !sealed.isEmpty else { continue }
                    // One unreadable blob must not take out the whole namespace.
                    if let value = try? unseal(sealed, as: type) {
                        out.append(StorageEntry(key: item.key, value: value, version: item.version))
                    }
                }
                return out
            } catch let error as APIError {
                guard latchIfUnsupported(error) else { throw error }
            }
        }
        return try await local.list(prefix: prefix, as: type)
    }

    public func listKeys(prefix: String) async throws -> [(key: String, version: Int)] {
        if !localOnly {
            do {
                return try await allItems(prefix: prefix, values: false).map { ($0.key, $0.version) }
            } catch let error as APIError {
                guard latchIfUnsupported(error) else { throw error }
            }
        }
        return try await local.listKeys(prefix: prefix)
    }

    /// Paged: a long history has more Sent entries than one page holds, and stopping at the first
    /// would silently truncate the folder.
    private func allItems(prefix: String, values: Bool) async throws -> [Wire.KvItem] {
        var out: [Wire.KvItem] = []
        var cursor = ""
        while true {
            let page = try await client.kvList(prefix: prefix, values: values, cursor: cursor, keys: keys)
            out += page.items ?? []
            guard let next = page.next_cursor, !next.isEmpty else { return out }
            cursor = next
        }
    }

    public func delete(_ key: String) async throws {
        if !localOnly {
            do {
                return try await client.kvDelete(key, keys: keys)
            } catch let error as APIError {
                guard latchIfUnsupported(error) else { throw error }
            }
        }
        try await local.delete(key)
    }

    public func stat() async throws -> StorageUsage {
        if !localOnly {
            do {
                let res = try await client.kvStat(keys: keys)
                return StorageUsage(usedBytes: res.used_bytes, quotaBytes: res.quota_bytes, count: res.count)
            } catch let error as APIError {
                guard latchIfUnsupported(error) else { throw error }
            }
        }
        return try await local.stat()
    }
}
