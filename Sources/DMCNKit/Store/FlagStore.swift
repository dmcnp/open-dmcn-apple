import Foundation

// Per-message mutable state: read, archived, starred, folder, labels, deleted. Each message's state
// is one record under "flags/<messageHash>", sealed to the owner, so concurrent edits to different
// messages never collide and a race on one message resolves last-writer-wins. Parity with the
// browser's lib/api/flagStore.ts and hooks/useFlags.ts.

public struct FlagRecord: Codable, Sendable, Equatable {
    public var v: Int
    public var read: Bool?
    public var archived: Bool?
    public var starred: Bool?
    public var folderId: String?
    public var labelIds: [String]?
    /// When the owner deleted the message, unix ms. It stays in Deleted until this is cleared or
    /// the retention in settings has passed.
    public var trashedAt: Int64?
    /// Unix ms: recency for merging.
    public var updatedAt: Int64
    /// Hex: the tiebreak for equal `updatedAt`.
    public var deviceId: String

    public init(
        read: Bool? = nil, archived: Bool? = nil, starred: Bool? = nil, folderId: String? = nil,
        labelIds: [String]? = nil, trashedAt: Int64? = nil, updatedAt: Int64 = 0, deviceId: String = ""
    ) {
        v = 1
        self.read = read
        self.archived = archived
        self.starred = starred
        self.folderId = folderId
        self.labelIds = labelIds
        self.trashedAt = trashedAt
        self.updatedAt = updatedAt
        self.deviceId = deviceId
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        v = try c.decodeIfPresent(Int.self, forKey: .v) ?? 1
        read = try c.decodeIfPresent(Bool.self, forKey: .read)
        archived = try c.decodeIfPresent(Bool.self, forKey: .archived)
        starred = try c.decodeIfPresent(Bool.self, forKey: .starred)
        folderId = try c.decodeIfPresent(String.self, forKey: .folderId)
        labelIds = try c.decodeIfPresent([String].self, forKey: .labelIds)
        trashedAt = try c.decodeIfPresent(Int64.self, forKey: .trashedAt)
        // The browser reads a record without these fine, so a missing one is no reason to lose
        // what the rest of the record says.
        updatedAt = try c.decodeIfPresent(Int64.self, forKey: .updatedAt) ?? 0
        deviceId = try c.decodeIfPresent(String.self, forKey: .deviceId) ?? ""
    }
}

/// One edit to a flag record. Clearing is its own case: restoring a message from Deleted has to
/// remove `trashedAt`, which "leave it alone" can't say.
public struct FlagDelta: Sendable, Equatable {
    public enum Change<Value: Sendable & Equatable>: Sendable, Equatable {
        case keep
        case set(Value)
        case clear

        func applied(to value: Value?) -> Value? {
            switch self {
            case .keep: return value
            case .set(let new): return new
            case .clear: return nil
            }
        }
    }

    public var read: Change<Bool>
    public var archived: Change<Bool>
    public var starred: Change<Bool>
    public var folderId: Change<String>
    public var labelIds: Change<[String]>
    public var trashedAt: Change<Int64>

    public init(
        read: Change<Bool> = .keep, archived: Change<Bool> = .keep, starred: Change<Bool> = .keep,
        folderId: Change<String> = .keep, labelIds: Change<[String]> = .keep, trashedAt: Change<Int64> = .keep
    ) {
        self.read = read
        self.archived = archived
        self.starred = starred
        self.folderId = folderId
        self.labelIds = labelIds
        self.trashedAt = trashedAt
    }
}

/// The account's message flags. It remembers the last listing, which is the "current" record an
/// edit starts from.
public actor FlagStore {
    private let storage: any PersonalStorage
    private let deviceHex: String
    private let now: StoreClock
    public private(set) var flags: [String: FlagRecord] = [:]

    /// `deviceID` names this install in the records it writes; it only ever breaks a tie.
    public init(storage: any PersonalStorage, deviceID: Data, now: @escaping StoreClock = systemClock) {
        self.storage = storage
        deviceHex = deviceID.hex
        self.now = now
    }

    public static func key(_ messageHash: String) -> String { "flags/" + messageHash }

    /// Every flag record, keyed by message hash.
    @discardableResult
    public func list() async throws -> [String: FlagRecord] {
        var out: [String: FlagRecord] = [:]
        for entry in try await storage.list(prefix: "flags/", as: FlagRecord.self) {
            out[String(entry.key.dropFirst("flags/".count))] = entry.value
        }
        flags = out
        return out
    }

    /// Merges a delta onto `current` and writes the whole record back. Unconditional: for
    /// high-churn per-message state the last write wins.
    public func apply(_ messageHash: String, current: FlagRecord?, delta: FlagDelta) async throws -> FlagRecord {
        let next = FlagRecord(
            read: delta.read.applied(to: current?.read),
            archived: delta.archived.applied(to: current?.archived),
            starred: delta.starred.applied(to: current?.starred),
            folderId: delta.folderId.applied(to: current?.folderId),
            labelIds: delta.labelIds.applied(to: current?.labelIds),
            trashedAt: delta.trashedAt.applied(to: current?.trashedAt),
            updatedAt: now(), deviceId: deviceHex)
        try await storage.put(Self.key(messageHash), next)
        return next
    }

    /// Applies a delta to the record last seen for this message and remembers the result, so the
    /// change shows before the next listing.
    @discardableResult
    public func set(_ messageHash: String, _ delta: FlagDelta) async throws -> FlagRecord {
        let next = try await apply(messageHash, current: flags[messageHash], delta: delta)
        flags[messageHash] = next
        return next
    }

    public func markRead(_ messageHash: String) async throws {
        if flags[messageHash]?.read == true { return }
        try await set(messageHash, FlagDelta(read: .set(true)))
    }

    /// Moves to Deleted. Nothing is removed.
    public func trash(_ messageHash: String) async throws {
        try await set(messageHash, FlagDelta(trashedAt: .set(now())))
    }

    /// Takes out of Deleted, back to wherever its other flags put it.
    public func restore(_ messageHash: String) async throws {
        try await set(messageHash, FlagDelta(trashedAt: .clear))
    }

    public func addLabel(_ messageHash: String, _ labelId: String) async throws {
        let current = flags[messageHash]?.labelIds ?? []
        if current.contains(labelId) { return }
        try await set(messageHash, FlagDelta(labelIds: .set(current + [labelId])))
    }

    public func removeLabel(_ messageHash: String, _ labelId: String) async throws {
        let current = flags[messageHash]?.labelIds ?? []
        guard current.contains(labelId) else { return }
        try await set(messageHash, FlagDelta(labelIds: .set(current.filter { $0 != labelId })))
    }

    public func setFolder(_ messageHash: String, _ folderId: String?) async throws {
        try await set(messageHash, FlagDelta(folderId: folderId.map { .set($0) } ?? .clear))
    }

    /// Reaps a message's record when the message itself is gone for good. Best effort: the message
    /// is already deleted, and a stray flag record is harmless.
    public func remove(_ messageHash: String) async {
        guard flags[messageHash] != nil else { return }
        try? await storage.delete(Self.key(messageHash))
        flags[messageHash] = nil
    }
}
