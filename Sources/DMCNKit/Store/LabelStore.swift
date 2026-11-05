import Foundation

// The label and folder DEFINITIONS, one sealed document at "settings/labels". Assignment lives in
// the flag records; an id here with no message, or there with no definition here, is simply
// ignored, so deleting a definition needs no clean-up. Parity with the browser's
// lib/api/labelStore.ts and the mutate loop in hooks/useLabels.ts.

public struct LabelDef: JSONDocument {
    public var fields: [String: JSONValue]
    public init(fields: [String: JSONValue]) { self.fields = fields }

    public init(id: String, name: String, color: String) {
        fields = [:]
        self.id = id
        self.name = name
        self.color = color
    }

    public var id: String {
        get { fields.string("id") ?? "" }
        set { fields.set("id", newValue) }
    }
    public var name: String {
        get { fields.string("name") ?? "" }
        set { fields.set("name", newValue) }
    }
    /// A CSS color for the swatch.
    public var color: String {
        get { fields.string("color") ?? "" }
        set { fields.set("color", newValue) }
    }
}

public struct FolderDef: JSONDocument {
    public var fields: [String: JSONValue]
    public init(fields: [String: JSONValue]) { self.fields = fields }

    public init(id: String, name: String) {
        fields = [:]
        self.id = id
        self.name = name
    }

    public var id: String {
        get { fields.string("id") ?? "" }
        set { fields.set("id", newValue) }
    }
    public var name: String {
        get { fields.string("name") ?? "" }
        set { fields.set("name", newValue) }
    }
}

public struct LabelsDoc: JSONDocument {
    public var fields: [String: JSONValue]

    public init(fields: [String: JSONValue]) {
        self.fields = fields
        self.fields["v"] = .int(1)
        // The browser always writes both lists, and reads a missing one as empty.
        if self.fields["labels"] == nil { self.fields["labels"] = .array([]) }
        if self.fields["folders"] == nil { self.fields["folders"] = .array([]) }
    }

    public init() { self.init(fields: [:]) }

    public var labels: [LabelDef] {
        get { fields.documents("labels") }
        set { fields.set("labels", newValue) }
    }
    public var folders: [FolderDef] {
        get { fields.documents("folders") }
        set { fields.set("folders", newValue) }
    }
}

/// The account's label and folder definitions. Writes go through compare-and-swap with a re-read
/// and retry, because two devices can edit this one document at once.
public actor LabelStore {
    public static let key = "settings/labels"
    /// The palette offered when creating a label.
    public static let colors = ["#ef4444", "#f59e0b", "#10b981", "#3b82f6", "#8b5cf6", "#ec4899", "#64748b"]

    private let storage: any PersonalStorage
    /// The latest document this store has read or written.
    public private(set) var doc = LabelsDoc()
    /// False until the first load settles: before it no folder is known, so mail filed into one
    /// would read as Inbox mail.
    public private(set) var ready = false

    public init(storage: any PersonalStorage) {
        self.storage = storage
    }

    /// The document and its version, 0 when none exists yet.
    public func get() async throws -> (doc: LabelsDoc, version: Int) {
        guard let entry = try await storage.get(Self.key, as: LabelsDoc.self) else { return (LabelsDoc(), 0) }
        return (entry.value, entry.version)
    }

    /// Throws `StorageConflictError` when `expectedVersion` is stale.
    @discardableResult
    public func put(_ doc: LabelsDoc, expectedVersion: Int) async throws -> Int {
        try await storage.put(Self.key, doc, expectedVersion: expectedVersion)
    }

    /// Reads the latest document. A failure keeps the last good one and still counts as settled.
    public func refresh() async {
        if let (latest, _) = try? await get() { doc = latest }
        ready = true
    }

    /// Reads the latest document, applies `change`, writes it with compare-and-swap, and retries if
    /// another device got in between.
    public func mutate(_ change: @Sendable (inout LabelsDoc) -> Void) async throws {
        for _ in 0..<5 {
            let (current, version) = try await get()
            var next = current
            change(&next)
            do {
                try await put(next, expectedVersion: version)
                doc = next
                return
            } catch is StorageConflictError {
                continue
            }
        }
        throw TooManyConflictsError()
    }

    /// Answers with the new id, for a caller about to put the label on something.
    @discardableResult
    public func createLabel(name: String, color: String) async throws -> String {
        let id = Self.newID()
        let label = LabelDef(id: id, name: JSText.trim(name), color: color)
        try await mutate { $0.labels.append(label) }
        return id
    }

    public func renameLabel(id: String, name: String, color: String? = nil) async throws {
        let name = JSText.trim(name)
        try await mutate { doc in
            doc.labels = doc.labels.map { label in
                guard label.id == id else { return label }
                var renamed = label
                renamed.name = name
                if let color { renamed.color = color }
                return renamed
            }
        }
    }

    public func deleteLabel(id: String) async throws {
        try await mutate { $0.labels.removeAll { $0.id == id } }
    }

    @discardableResult
    public func createFolder(name: String) async throws -> String {
        let id = Self.newID()
        let folder = FolderDef(id: id, name: JSText.trim(name))
        try await mutate { $0.folders.append(folder) }
        return id
    }

    public func renameFolder(id: String, name: String) async throws {
        let name = JSText.trim(name)
        try await mutate { doc in
            doc.folders = doc.folders.map { folder in
                guard folder.id == id else { return folder }
                var renamed = folder
                renamed.name = name
                return renamed
            }
        }
    }

    public func deleteFolder(id: String) async throws {
        try await mutate { $0.folders.removeAll { $0.id == id } }
    }

    private static func newID() -> String {
        Data((0..<8).map { _ in UInt8.random(in: 0...255) }).hex
    }
}
