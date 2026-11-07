import Foundation

// Account-level preferences that follow the person between devices, one sealed document at
// "settings/app". Anything per-device (theme, density) stays out of here. Parity with the browser's
// lib/api/settingsStore.ts and the update loop in hooks/useSettings.ts.

public struct AppSettings: JSONDocument {
    public var fields: [String: JSONValue]

    public init(fields: [String: JSONValue]) {
        self.fields = fields
        self.fields["v"] = .int(1)
    }

    public init() { self.init(fields: [:]) }

    /// Deprecated: kept only so a document an older client wrote still round-trips.
    public var displayName: String? {
        get { fields.string("displayName") }
        set { fields.set("displayName", newValue) }
    }
    public var signature: String? {
        get { fields.string("signature") }
        set { fields.set("signature", newValue) }
    }
    /// Overrides the default of rich text for new messages and replies.
    public var composePlainText: Bool? {
        get { fields.bool("composePlainText") }
        set { fields.set("composePlainText", newValue) }
    }
    /// Opts in to images from the sender's own server, for allowlisted senders only. Absent keeps
    /// them blocked everywhere.
    public var remoteImagesForTrusted: Bool? {
        get { fields.bool("remoteImagesForTrusted") }
        set { fields.set("remoteImagesForTrusted", newValue) }
    }
    /// The owner put Getting started away, on every device.
    public var gettingStartedHidden: Bool? {
        get { fields.bool("gettingStartedHidden") }
        set { fields.set("gettingStartedHidden", newValue) }
    }
    /// How many days deleted mail waits before a client removes it for good. Read it through
    /// `retentionDays`.
    public var trashDays: Int64? {
        get { fields.int("trashDays") }
        set { fields.set("trashDays", newValue) }
    }

    /// The retention to act on: the setting within the range offered, or the default.
    public var retentionDays: Int64 {
        min(Self.trashDaysMax, max(Self.trashDaysMin, trashDays ?? Self.trashDaysDefault))
    }

    public static let trashDaysDefault: Int64 = 7
    public static let trashDaysMin: Int64 = 1
    public static let trashDaysMax: Int64 = 7
}

/// The account's synced settings. Writes go through compare-and-swap with a re-read and retry, so a
/// concurrent edit on another device isn't clobbered.
public actor SettingsStore {
    public static let key = "settings/app"

    private let storage: any PersonalStorage
    /// The latest document this store has read or written.
    public private(set) var settings = AppSettings()
    /// True once the account's own document has been read. Before then `settings` is the empty
    /// default, which can't be told from an account that never set anything.
    public private(set) var loaded = false

    public init(storage: any PersonalStorage) {
        self.storage = storage
    }

    /// The settings and their version, 0 when none exist yet.
    public func get() async throws -> (settings: AppSettings, version: Int) {
        guard let entry = try await storage.get(Self.key, as: AppSettings.self) else { return (AppSettings(), 0) }
        return (entry.value, entry.version)
    }

    /// Throws `StorageConflictError` when `expectedVersion` is stale.
    @discardableResult
    public func put(_ settings: AppSettings, expectedVersion: Int) async throws -> Int {
        try await storage.put(Self.key, settings, expectedVersion: expectedVersion)
    }

    /// Reads the latest document. A failure keeps the last good one and leaves `loaded` alone.
    public func refresh() async {
        guard let (latest, _) = try? await get() else { return }
        settings = latest
        loaded = true
    }

    /// Reads the latest document, applies `change`, writes it with compare-and-swap, and retries if
    /// another device got in between. Setting a property to nil removes it.
    public func update(_ change: @Sendable (inout AppSettings) -> Void) async throws {
        for _ in 0..<5 {
            let (current, version) = try await get()
            var next = current
            change(&next)
            do {
                try await put(next, expectedVersion: version)
                settings = next
                return
            } catch is StorageConflictError {
                continue
            }
        }
        throw TooManyConflictsError()
    }
}
