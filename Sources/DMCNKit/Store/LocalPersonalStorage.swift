import Crypto
import Foundation

/// Personal storage in files on this device: the fallback for a relay that keeps none, and the home
/// of state that stays local on purpose.
///
/// Values are written as plain JSON, like the browser's IndexedDB fallback, so pick a directory the
/// platform protects. Nothing here is sealed or leaves the device.
public actor LocalPersonalStorage: DeviceStorage {
    private let directory: URL

    /// `directory` is created on first write.
    public init(directory: URL) {
        self.directory = directory
    }

    private struct Record: Codable {
        let key: String
        let version: Int
        let value: JSONValue
    }

    // Keys hold slashes and can outgrow a filename, so files are named by hash, with the key kept
    // inside. Grouped by namespace so listing flags never reads a draft's attachments.
    private func namespaceDirectory(of key: String) -> URL {
        let namespace = key.split(separator: "/", omittingEmptySubsequences: false).first.map(String.init) ?? ""
        return directory.appendingPathComponent(Self.hash(namespace), isDirectory: true)
    }

    private func file(for key: String) -> URL {
        namespaceDirectory(of: key).appendingPathComponent(Self.hash(key) + ".json")
    }

    private static func hash(_ text: String) -> String {
        Data(SHA256.hash(data: Data(text.utf8))).hex
    }

    private func read(_ url: URL) -> Record? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? StoreJSON.decode(Record.self, from: data)
    }

    private func records(prefix: String) -> [Record] {
        let fm = FileManager.default
        let folders: [URL]
        if prefix.contains("/") {
            folders = [namespaceDirectory(of: prefix)]
        } else {
            folders = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        }
        let files = folders.flatMap { (try? fm.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil)) ?? [] }
        return files.compactMap(read).filter { $0.key.hasPrefix(prefix) }.sorted { $0.key < $1.key }
    }

    private func decoded<T: Decodable>(_ value: JSONValue, as type: T.Type) throws -> T {
        try StoreJSON.decode(type, from: StoreJSON.encode(value))
    }

    public func get<T: Decodable & Sendable>(_ key: String, as type: T.Type) async throws -> StorageEntry<T>? {
        guard let record = read(file(for: key)) else { return nil }
        return StorageEntry(key: key, value: try decoded(record.value, as: type), version: record.version)
    }

    public func put(_ key: String, _ value: some Encodable & Sendable, expectedVersion: Int) async throws -> Int {
        let url = file(for: key)
        let current = read(url)?.version ?? 0
        if expectedVersion > 0, current != expectedVersion { throw StorageConflictError() }
        let json = try StoreJSON.decode(JSONValue.self, from: StoreJSON.encode(value))
        let record = Record(key: key, version: current + 1, value: json)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try StoreJSON.encode(record).write(to: url, options: .atomic)
        return record.version
    }

    public func list<T: Decodable & Sendable>(prefix: String, as type: T.Type) async throws -> [StorageEntry<T>] {
        records(prefix: prefix).compactMap { record in
            guard let value = try? decoded(record.value, as: type) else { return nil }
            return StorageEntry(key: record.key, value: value, version: record.version)
        }
    }

    public func listKeys(prefix: String) async throws -> [(key: String, version: Int)] {
        records(prefix: prefix).map { ($0.key, $0.version) }
    }

    public func delete(_ key: String) async throws {
        let url = file(for: key)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    public func stat() async throws -> StorageUsage {
        let all = records(prefix: "")
        let used = try all.reduce(0) { $0 + (try StoreJSON.encode($1.value)).count }
        return StorageUsage(usedBytes: used, quotaBytes: 0, count: all.count)
    }
}
