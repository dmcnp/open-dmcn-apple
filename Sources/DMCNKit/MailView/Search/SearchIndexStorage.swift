import Crypto
import Foundation

/// Where an account's sealed index records live. The index only ever hands it ciphertext.
///
/// Synchronous on purpose: the index is an actor, and an actor is only atomic between awaits. With
/// no await inside an edit, an add can't interleave with a flush and lose its postings.
public protocol SearchIndexStorage: Sendable {
    func read(_ slot: String) throws -> Data?
    /// Writes and deletes together, whole or not at all. The shards and the manifest that explains
    /// them must never disagree: a manifest behind its shards would hand out document numbers those
    /// shards already use, and mail would match words it doesn't contain.
    func write(_ puts: [String: Data], deleting: [String]) throws
    func removeAll() throws
}

/// Records in memory, for tests and samples.
public final class InMemorySearchIndexStorage: SearchIndexStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var records: [String: Data] = [:]

    public init() {}

    public func read(_ slot: String) throws -> Data? {
        lock.withLock { records[slot] }
    }

    public func write(_ puts: [String: Data], deleting: [String]) throws {
        lock.withLock {
            records.merge(puts) { _, new in new }
            for slot in deleting { records[slot] = nil }
        }
    }

    public func removeAll() throws {
        lock.withLock { records = [:] }
    }

    /// Everything stored, for a test to look at.
    public var snapshot: [String: Data] {
        lock.withLock { records }
    }
}

/// Records as files in one directory per account.
///
/// The files are sealed already, so what the app has to pick is where: somewhere that can be lost,
/// like Library/Caches, because this is a cache of the mailbox and rebuilds from it.
public struct FileSearchIndexStorage: SearchIndexStorage {
    private let directory: URL
    private var journal: URL { directory.appendingPathComponent("journal") }

    private struct Entry: Codable {
        let slot: String
        /// Nil to delete it.
        let data: Data?
    }

    /// `baseDirectory` holds every account's index. A write that was cut short is finished here.
    public init(baseDirectory: URL, address: String) throws {
        directory = Self.directory(in: baseDirectory, address: address)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let pending = try? Data(contentsOf: journal) {
            try apply(try JSONDecoder().decode([Entry].self, from: pending))
        }
    }

    private static func directory(in base: URL, address: String) -> URL {
        base.appendingPathComponent(hashed(JSText.normalizedAddress(address)), isDirectory: true)
    }

    /// Slots hold slashes and any script, so files are named by hash.
    private static func hashed(_ text: String) -> String {
        Data(SHA256.hash(data: Data(text.utf8))).hex
    }

    /// Removes an account's index from this device.
    public static func forget(baseDirectory: URL, address: String) throws {
        let directory = directory(in: baseDirectory, address: address)
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
    }

    private func file(_ slot: String) -> URL {
        directory.appendingPathComponent(Self.hashed(slot))
    }

    public func read(_ slot: String) throws -> Data? {
        let url = file(slot)
        return FileManager.default.fileExists(atPath: url.path) ? try Data(contentsOf: url) : nil
    }

    /// One atomic rename makes the whole batch real. A crash before it leaves the old state, and a
    /// crash after it leaves a journal the next open finishes. Applying it twice is harmless.
    public func write(_ puts: [String: Data], deleting: [String]) throws {
        let entries =
            puts.map { Entry(slot: $0.key, data: $0.value) } + deleting.map { Entry(slot: $0, data: nil) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(entries).write(to: journal, options: .atomic)
        try apply(entries)
    }

    private func apply(_ entries: [Entry]) throws {
        for entry in entries {
            let url = file(entry.slot)
            if let data = entry.data {
                try data.write(to: url, options: .atomic)
            } else if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
        }
        try FileManager.default.removeItem(at: journal)
    }

    public func removeAll() throws {
        if FileManager.default.fileExists(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
}
