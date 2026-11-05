import Foundation

// The owner's per-account state: Sent, flags, labels, contacts, settings, drafts. Logical keys are
// "<namespace>/<id>", and list() takes a "<namespace>/" prefix (open-dmcn SPEC_EXT_STORAGE). Stores
// talk to this protocol, so a test or a sample can hand them an in-memory one.

/// A stored value with the version it was read at.
public struct StorageEntry<T: Sendable>: Sendable {
    public let key: String
    public let value: T
    public let version: Int

    public init(key: String, value: T, version: Int) {
        self.key = key
        self.value = value
        self.version = version
    }
}

/// The account's storage use. `quotaBytes` 0 means no cap.
public struct StorageUsage: Sendable, Equatable {
    public let usedBytes: Int
    public let quotaBytes: Int
    public let count: Int

    public init(usedBytes: Int, quotaBytes: Int, count: Int) {
        self.usedBytes = usedBytes
        self.quotaBytes = quotaBytes
        self.count = count
    }
}

/// A compare-and-swap found a newer version stored. Read again and retry.
public struct StorageConflictError: Error, Equatable, Sendable {
    public init() {}
}

extension StorageConflictError: LocalizedError {
    public var errorDescription: String? { "This was changed somewhere else. Try again." }
}

/// A store kept retrying a document another device kept changing, and gave up.
public struct TooManyConflictsError: Error, Equatable, Sendable {
    public init() {}
}

extension TooManyConflictsError: LocalizedError {
    public var errorDescription: String? { "Too many changes at once. Try again." }
}

public protocol PersonalStorage: Sendable {
    func get<T: Decodable & Sendable>(_ key: String, as type: T.Type) async throws -> StorageEntry<T>?

    /// Writes and returns the new version. `expectedVersion` 0 is unconditional; anything else is a
    /// compare-and-swap that throws `StorageConflictError` on a mismatch.
    @discardableResult
    func put(_ key: String, _ value: some Encodable & Sendable, expectedVersion: Int) async throws -> Int

    /// Everything under `prefix`, every page of it. A value that can't be opened or read is left
    /// out, so one bad entry never takes the rest of a folder or address book with it.
    func list<T: Decodable & Sendable>(prefix: String, as type: T.Type) async throws -> [StorageEntry<T>]

    /// The keys under `prefix`, without their values. A relay reports version 0 for each here: it
    /// reads versions out of the values this listing skips, so don't use them for a swap.
    func listKeys(prefix: String) async throws -> [(key: String, version: Int)]

    /// Removes a key. Removing one that isn't there is not an error.
    func delete(_ key: String) async throws

    func stat() async throws -> StorageUsage
}

extension PersonalStorage {
    @discardableResult
    public func put(_ key: String, _ value: some Encodable & Sendable) async throws -> Int {
        try await put(key, value, expectedVersion: 0)
    }
}

/// Storage that stays on this device, for state that must not follow the account through the relay:
/// the key pins a relay could otherwise roll back, and the block list the reference build keeps
/// local. A marker, so a store that needs it can't be handed the relay-backed `PersonalStore`.
public protocol DeviceStorage: PersonalStorage {}

/// Unix milliseconds, the unit every stored timestamp uses. A seam so tests can fix the time.
public typealias StoreClock = @Sendable () -> Int64

public let systemClock: StoreClock = { Int64(Date().timeIntervalSince1970 * 1000) }
