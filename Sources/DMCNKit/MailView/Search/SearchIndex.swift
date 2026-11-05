import Crypto
import Foundation

// The on-device index over message text. Parity with the browser's lib/search/indexStore.ts, whose
// reasons hold here:
//
//   - It persists, so locking doesn't throw away work. Building it means downloading every body once.
//   - It's sealed, so persisting doesn't undo the lock. The browser derives a key from a handle that
//     exists only while unlocked. The kit never holds private bytes to derive from, so a random key
//     is sealed to the account's X25519 key, like everything in personal storage, and can only be
//     opened while the keys can answer. Every record is bound to its slot and account.
//   - It's split into shards by the first two characters of each token, each sealed separately, so a
//     search opens only the shards its words start with. What this shows someone holding the storage
//     is each shard's size: roughly how many of this mailbox's words start with each pair of letters.
//
// It's a cache of the mailbox, private to this device, and the relay never sees it. So nothing about
// its layout has to match the browser's, and a key that no longer opens it means starting again.
//
// Removing a message doesn't rewrite its shards: its document number leaves the manifest, and a
// posting naming a number the manifest doesn't have is ignored. `compact` sweeps those up.

/// What drives and reads an index. The backfill and lookups work against this, so a test can hand
/// them a stand-in.
public protocol SearchIndexing: Sendable {
    /// Messages indexed so far.
    func hashes() async -> [String]
    /// Indexes one message's text and attachment names. One already indexed is left alone.
    func add(_ hash: String, text: String, filenames: [String]) async throws
    func remove(_ hashes: [String]) async throws
    /// Whether anything has changed since the last flush.
    func hasPending() async -> Bool
    /// Writes every change since the last flush, whole or not at all.
    func flush() async throws
    func wantsCompaction() async -> Bool
    func compact() async throws
    /// Messages whose text holds every word of `term`, each as a prefix of a word there. A term with
    /// nothing indexable in it finds nothing.
    func wordHits(_ term: String) async throws -> Set<String>
    /// Messages with an attachment whose name matches.
    func filenameHits(_ value: String, glob: FilenameGlob?) async throws -> Set<String>
    /// Throws the index away and starts again empty.
    func clear() async throws
}

public actor SearchIndex: SearchIndexing {
    private static let version = 1
    /// Decoded shards kept in memory, by encoded size. Past this, clean shards are dropped.
    private static let cacheBudget = 16 * 1024 * 1024

    private struct Meta: Codable {
        let v: Int
        let key: SealedBlob
    }

    private struct Manifest: Codable {
        var next = 0
        var docs: [String: Int] = [:]
        var shards: Set<String> = []
        var orphans = 0
    }

    private struct Cached {
        var shard: SearchShard
        var bytes: Int
        var lastUse: Int
    }

    private let namespace: String
    private let key: SymmetricKey
    private let storage: any SearchIndexStorage
    private var manifest: Manifest
    private var byDoc: [Int: String]
    private var cache: [String: Cached] = [:]
    private var clock = 0
    private var dirty = Set<String>()
    private var files: [Int: [String]]?
    private var filesDirty = false
    private var manifestDirty = false

    private init(
        namespace: String, key: SymmetricKey, storage: any SearchIndexStorage, manifest: Manifest
    ) {
        self.namespace = namespace
        self.key = key
        self.storage = storage
        self.manifest = manifest
        byDoc = Dictionary(manifest.docs.map { ($0.value, $0.key) }, uniquingKeysWith: { first, _ in first })
    }

    /// Opens an account's index, or starts one. Throws if the account's keys can't answer right now,
    /// which must not cost the index: a locked keychain isn't a rotated key. An index they answer for
    /// but can't open was written under a previous key, and is wiped.
    public static func open(keys: any AccountKeys, storage: any SearchIndexStorage) throws -> SearchIndex {
        let namespace = JSText.normalizedAddress(keys.address) + "::"
        if let bytes = try storage.read("meta"), let meta = try? StoreJSON.decode(Meta.self, from: bytes),
            meta.v == version, let recipient = meta.key.recipients.first
        {
            _ = try keys.sharedSecret(withEphemeral: recipient.ephemeralXPub)
            if var raw = try? meta.key.open(with: keys) {
                defer { secureZero(&raw) }
                let key = SymmetricKey(data: raw)
                let manifest = try readManifest(namespace: namespace, key: key, storage: storage)
                return SearchIndex(namespace: namespace, key: key, storage: storage, manifest: manifest)
            }
        }
        let key = try start(storage: storage, keys: keys)
        return SearchIndex(namespace: namespace, key: key, storage: storage, manifest: Manifest())
    }

    private static func start(storage: any SearchIndexStorage, keys: any AccountKeys) throws -> SymmetricKey {
        try storage.removeAll()
        let key = SymmetricKey(size: .bits256)
        var raw = key.withUnsafeBytes { Data($0) }
        defer { secureZero(&raw) }
        let meta = Meta(v: version, key: try SealedBlob.seal(raw, to: [keys.x25519Public]))
        try storage.write(["meta": try StoreJSON.encode(meta)], deleting: [])
        return key
    }

    private static func aad(_ namespace: String, _ slot: String) -> Data { Data((namespace + slot).utf8) }

    private static func unseal(
        _ data: Data, slot: String, namespace: String, key: SymmetricKey
    ) throws -> Data {
        guard data.count >= 28 else { throw SearchShardError() }
        let box = SealedBox(
            nonce: data.prefix(12), ciphertext: data.dropFirst(12).dropLast(16), tag: data.suffix(16))
        return try AEAD.open(box, key: key, aad: aad(namespace, slot))
    }

    private static func readManifest(
        namespace: String, key: SymmetricKey, storage: any SearchIndexStorage
    ) throws -> Manifest {
        guard let sealed = try storage.read("manifest") else { return Manifest() }
        let plain = try unseal(sealed, slot: "manifest", namespace: namespace, key: key)
        return try StoreJSON.decode(Manifest.self, from: plain)
    }

    private func seal(_ slot: String, _ plain: Data) throws -> Data {
        let box = try AEAD.seal(plain, key: key, aad: Self.aad(namespace, slot))
        return box.nonce + box.ciphertext + box.tag
    }

    private func open(_ slot: String, _ sealed: Data) throws -> Data {
        try Self.unseal(sealed, slot: slot, namespace: namespace, key: key)
    }

    private static func shardSlot(_ id: String) -> String { "s/" + id }

    public func hashes() -> [String] { Array(manifest.docs.keys) }

    /// A term's shards come through here, so a read of one touches its place in the eviction order.
    private func withShard<T>(_ id: String, _ body: (inout SearchShard) throws -> T) throws -> T {
        clock += 1
        if cache[id] == nil {
            var shard: SearchShard = [:]
            var bytes = 0
            if manifest.shards.contains(id), let sealed = try storage.read(Self.shardSlot(id)) {
                let plain = try open(Self.shardSlot(id), sealed)
                bytes = plain.count
                shard = try MailSearch.decodeShard(plain)
            }
            cache[id] = Cached(shard: shard, bytes: bytes, lastUse: clock)
        }
        cache[id]?.lastUse = clock
        return try body(&cache[id]!.shard)
    }

    private func loadFiles() throws -> [Int: [String]] {
        if let files { return files }
        var loaded: [Int: [String]] = [:]
        if let sealed = try storage.read("files") {
            loaded = try StoreJSON.decode([Int: [String]].self, from: open("files", sealed))
        }
        files = loaded
        return loaded
    }

    public func add(_ hash: String, text: String, filenames: [String] = []) throws {
        if manifest.docs[hash] != nil { return }
        let doc = manifest.next
        manifest.next += 1
        for (id, tokens) in MailSearch.byShard(MailSearch.tokenize(text)) {
            try withShard(id) { shard in
                for token in tokens { MailSearch.addPosting(&shard, token: token, doc: doc) }
            }
            manifest.shards.insert(id)
            dirty.insert(id)
        }
        let names = filenames.filter { !$0.isEmpty }
        if !names.isEmpty {
            files = try loadFiles()
            files?[doc] = names
            filesDirty = true
        }
        manifest.docs[hash] = doc
        byDoc[doc] = hash
        manifestDirty = true
    }

    public func remove(_ hashes: [String]) throws {
        for hash in hashes {
            guard let doc = manifest.docs.removeValue(forKey: hash) else { continue }
            byDoc[doc] = nil
            manifest.orphans += 1
            manifestDirty = true
            files = try loadFiles()
            if files?.removeValue(forKey: doc) != nil { filesDirty = true }
        }
    }

    public func hasPending() -> Bool { manifestDirty || filesDirty || !dirty.isEmpty }

    public func flush() throws {
        guard hasPending() else { return }
        var puts: [String: Data] = [:]
        for id in dirty {
            guard let shard = cache[id]?.shard else { continue }
            let bytes = MailSearch.encodeShard(shard)
            cache[id]?.bytes = bytes.count
            puts[Self.shardSlot(id)] = try seal(Self.shardSlot(id), bytes)
        }
        if filesDirty, let files { puts["files"] = try seal("files", try StoreJSON.encode(files)) }
        puts["manifest"] = try seal("manifest", try StoreJSON.encode(manifest))
        try storage.write(puts, deleting: [])
        dirty = []
        filesDirty = false
        manifestDirty = false
        evict()
    }

    private func evict() {
        var total = cache.values.reduce(0) { $0 + $1.bytes }
        guard total > Self.cacheBudget else { return }
        for (id, entry) in cache.sorted(by: { $0.value.lastUse < $1.value.lastUse }) {
            if total <= Self.cacheBudget { break }
            if dirty.contains(id) { continue }
            cache[id] = nil
            total -= entry.bytes
        }
    }

    public func wantsCompaction() -> Bool {
        Double(manifest.orphans) > max(500, Double(manifest.docs.count) / 4)
    }

    /// Rewrites every shard without the postings of removed messages, a few at a time so memory
    /// stays bounded. Stopped part way it's merely unfinished: those postings are ignored either
    /// way, and the orphan count only resets once every shard is clean.
    public func compact() throws {
        try flush()
        let ids = manifest.shards.sorted()
        for start in stride(from: 0, to: ids.count, by: 32) {
            var puts: [String: Data] = [:]
            var deletes: [String] = []
            for id in ids[start..<min(start + 32, ids.count)] {
                let (removed, empty, bytes) = try withShard(id) { shard in
                    let removed = MailSearch.dropDocs(&shard) { byDoc[$0] == nil }
                    return (removed, shard.isEmpty, removed > 0 ? MailSearch.encodeShard(shard) : Data())
                }
                if removed == 0 { continue }
                if empty {
                    manifest.shards.remove(id)
                    cache[id] = nil
                    deletes.append(Self.shardSlot(id))
                } else {
                    cache[id]?.bytes = bytes.count
                    puts[Self.shardSlot(id)] = try seal(Self.shardSlot(id), bytes)
                }
            }
            if !puts.isEmpty || !deletes.isEmpty { try storage.write(puts, deleting: deletes) }
            evict()
        }
        manifest.orphans = 0
        try storage.write(["manifest": try seal("manifest", try StoreJSON.encode(manifest))], deleting: [])
    }

    public func clear() throws {
        let meta = try storage.read("meta")
        try storage.removeAll()
        if let meta { try storage.write(["meta": meta], deleting: []) }
        manifest = Manifest()
        byDoc = [:]
        cache = [:]
        dirty = []
        files = [:]
        filesDirty = false
        manifestDirty = false
    }

    public func wordHits(_ term: String) throws -> Set<String> {
        let tokens = MailSearch.tokenize(term)
        if tokens.isEmpty { return [] }
        var docs: Set<Int>?
        for token in tokens {
            let ids =
                token.unicodeScalars.count >= 2
                ? [MailSearch.shardOf(token)]
                : manifest.shards.filter { JSText.startsWith($0, token) }
            var found = Set<Int>()
            for id in ids where manifest.shards.contains(id) {
                found.formUnion(try withShard(id) { MailSearch.prefixDocs($0, term: token) })
            }
            docs = docs?.intersection(found) ?? found
            if docs?.isEmpty == true { break }
        }
        return toHashes(docs ?? [])
    }

    /// Names are kept whole rather than tokenized so a pattern can start with a wildcard (`*.pdf`),
    /// which a prefix index can't answer.
    public func filenameHits(_ value: String, glob: FilenameGlob?) throws -> Set<String> {
        var docs = Set<Int>()
        for (doc, names) in try loadFiles()
        where names.contains(where: { MailSearch.filenameMatches($0, value: value, glob: glob) }) {
            docs.insert(doc)
        }
        return toHashes(docs)
    }

    private func toHashes(_ docs: Set<Int>) -> Set<String> {
        Set(docs.compactMap { byDoc[$0] })
    }

    /// For tests: every shard stored, and how many removed messages still linger in them.
    func debugState() -> (shards: [String], orphans: Int) {
        (manifest.shards.sorted(), manifest.orphans)
    }
}
