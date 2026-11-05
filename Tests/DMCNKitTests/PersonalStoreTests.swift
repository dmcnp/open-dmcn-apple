import Foundation
#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif
import Testing
@testable import DMCNKit

private struct Doc: Codable, Sendable, Equatable {
    var name: String
    var count: Int?
}

/// A transport that fails, as a dropped connection does.
private struct DeadTransport: HTTPTransport {
    struct Dropped: Error {}
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) { throw Dropped() }
}

@Suite struct PersonalStoreWire {
    @Test func aPutSendsTheValueSealedToTheOwnerAlone() async throws {
        let host = StoreHost()
        let keys = SoftwareAccountKeys(address: "me@parity.example")
        let store = try await signedInStore(host: host, keys: keys)
        #expect(try await store.put("settings/app", Doc(name: "é/✓"), expectedVersion: 0) == 1)

        let op = try #require(await host.ops.last)
        #expect(Set(op.keys) == ["op", "key", "sealed", "expected_version"])
        #expect(op.string("op") == "kv_put")
        #expect(op.string("key") == "settings/app")
        #expect(op.int("expected_version") == 0)

        // base64(JSON(SealedBlob(JSON(value)))).
        let sealed = try #require(Data(base64Encoded: op.string("sealed") ?? ""))
        let blob = try JSONDecoder().decode(SealedBlob.self, from: sealed)
        #expect(blob.recipients.map(\.recipientXPub) == [keys.x25519Public])
        let plain = try blob.open(with: keys)
        #expect(String(decoding: plain, as: UTF8.self) == #"{"name":"é/✓"}"#)
    }

    @Test func aReadOpensWhatAPutSealed() async throws {
        let store = try await signedInStore(host: StoreHost())
        try await store.put("contacts/abc", Doc(name: "Ada", count: 2))
        let entry = try #require(try await store.get("contacts/abc", as: Doc.self))
        #expect(entry.key == "contacts/abc")
        #expect(entry.value == Doc(name: "Ada", count: 2))
        #expect(entry.version == 1)
        #expect(try await store.get("contacts/missing", as: Doc.self) == nil)
    }

    @Test func aStaleVersionIsATypedConflict() async throws {
        let store = try await signedInStore(host: StoreHost())
        #expect(try await store.put("settings/app", Doc(name: "a"), expectedVersion: 0) == 1)
        #expect(try await store.put("settings/app", Doc(name: "b"), expectedVersion: 1) == 2)
        await #expect(throws: StorageConflictError()) {
            try await store.put("settings/app", Doc(name: "c"), expectedVersion: 1)
        }
    }

    @Test func aListFollowsEveryPageWithTheCursorItWasGiven() async throws {
        let host = StoreHost()
        let store = try await signedInStore(host: host)
        for i in 0..<5 { try await store.put("flags/\(i)", Doc(name: "\(i)")) }
        await host.setPageSize(2)
        let listed = try await store.list(prefix: "flags/", as: Doc.self)
        #expect(listed.map(\.value.name) == ["0", "1", "2", "3", "4"])

        let ops = await host.ops.filter { $0.string("op") == "kv_list" }
        #expect(ops.map { $0.string("cursor") } == ["", "flags/1", "flags/3"])
        #expect(ops.allSatisfy { $0.bool("values") == true && $0.string("prefix") == "flags/" })
    }

    @Test func oneUnreadableBlobIsSkippedNotFatal() async throws {
        let host = StoreHost()
        let store = try await signedInStore(host: host)
        try await store.put("flags/a", Doc(name: "a"))
        try await store.put("flags/c", Doc(name: "c"))
        // Garbage, sealed to someone else, and sealed fine but not this shape.
        await host.put("flags/b1", sealed: Data("not sealed".utf8).base64EncodedString(), version: 1)
        await host.put("flags/b2", sealed: "@@not base64@@", version: 1)
        let foreign = try SealedBlob.seal(
            StoreJSON.encode(Doc(name: "x")), to: [SoftwareAccountKeys(address: "x@parity.example").x25519Public])
        await host.put("flags/b3", sealed: try StoreJSON.encode(foreign).base64EncodedString(), version: 1)
        try await store.put("flags/b4", ["unexpected": 1])

        #expect(try await store.list(prefix: "flags/", as: Doc.self).map(\.key) == ["flags/a", "flags/c"])
    }

    @Test func listKeysAsksForNoValues() async throws {
        let host = StoreHost()
        let store = try await signedInStore(host: host)
        try await store.put("draft-att/1/a", Doc(name: "a"))
        let keys = try await store.listKeys(prefix: "draft-att/1/")
        #expect(keys.map(\.key) == ["draft-att/1/a"])
        #expect(await host.ops.last?.bool("values") == false)
    }

    @Test func deleteAndStatTakeTheirOwnOps() async throws {
        let host = StoreHost()
        let store = try await signedInStore(host: host)
        try await store.put("flags/a", Doc(name: "a"))
        try await store.delete("flags/a")
        #expect(try await store.get("flags/a", as: Doc.self) == nil)
        #expect(try await store.stat() == StorageUsage(usedBytes: 1234, quotaBytes: 5678, count: 0))
        let names = await host.ops.compactMap { $0.string("op") }
        #expect(names == ["kv_put", "kv_delete", "kv_get", "kv_stat"])
    }

    @Test func aRefusalThatIsNotAboutStorageStaysARefusal() async throws {
        let host = StoreHost()
        let store = try await signedInStore(host: host)
        await host.refuse(status: 507, code: "storage_quota")
        await #expect(throws: APIError(status: 507, message: "refused", code: "storage_quota")) {
            try await store.put("flags/a", Doc(name: "a"))
        }
        #expect(await store.isLocalOnly == false)
    }
}

@Suite struct PersonalStoreLocalFallback {
    @Test(arguments: [(501, nil), (501, "storage_unsupported"), (400, "storage_unsupported")] as [(Int, String?)])
    func theDefinitiveAnswerLatches(status: Int, code: String?) async throws {
        let host = StoreHost()
        let store = try await signedInStore(host: host)
        await host.refuse(status: status, code: code)
        #expect(await store.isLocalOnly == false)

        // The call that discovered it still does its job, on this device.
        #expect(try await store.put("settings/app", Doc(name: "here"), expectedVersion: 0) == 1)
        #expect(await store.isLocalOnly == true)
        #expect(try await store.get("settings/app", as: Doc.self)?.value == Doc(name: "here"))
    }

    @Test(arguments: [502, 500, 503, 504, 404, 403])
    func anythingElseMeansAskAgainLater(status: Int) async throws {
        let host = StoreHost()
        let store = try await signedInStore(host: host)
        await host.refuse(status: status, code: nil)
        await #expect(throws: APIError.self) { try await store.get("settings/app", as: Doc.self) }
        await #expect(throws: APIError.self) { try await store.put("settings/app", Doc(name: "x")) }
        await #expect(throws: APIError.self) { try await store.list(prefix: "flags/", as: Doc.self) }
        await #expect(throws: APIError.self) { try await store.stat() }
        #expect(await store.isLocalOnly == false)

        await host.stopRefusing()
        try await store.put("settings/app", Doc(name: "x"))
        #expect(await host.kv["settings/app"] != nil)
    }

    @Test func aDroppedConnectionDoesNotLatch() async throws {
        let keys = SoftwareAccountKeys(address: "me@parity.example")
        let client = WebHostClient(baseURL: URL(string: "https://host.example")!, transport: DeadTransport())
        let store = PersonalStore(client: client, keys: keys, localDirectory: temporaryDirectory())
        await #expect(throws: (any Error).self) { try await store.get("settings/app", as: Doc.self) }
        #expect(await store.isLocalOnly == false)
    }

    @Test func oneAnswerCoversEveryOpAndTheRelayIsNotAskedAgain() async throws {
        let host = StoreHost()
        let store = try await signedInStore(host: host)
        await host.refuse(status: 501, code: "storage_unsupported")
        #expect(try await store.get("flags/a", as: Doc.self) == nil)

        await host.stopRefusing()  // a later success must not silently re-enable a partial sync
        try await store.put("flags/a", Doc(name: "a"))
        try await store.put("flags/b", Doc(name: "b"))
        #expect(try await store.list(prefix: "flags/", as: Doc.self).map(\.value.name) == ["a", "b"])
        #expect(try await store.listKeys(prefix: "flags/").map(\.version) == [1, 1])
        #expect(try await store.stat().count == 2)
        try await store.delete("flags/a")
        #expect(try await store.get("flags/a", as: Doc.self) == nil)
        #expect(await host.ops.isEmpty)
    }

    @Test func theFlipIsObservable() async throws {
        let host = StoreHost()
        let store = try await signedInStore(host: host)
        let updates = await store.localOnlyUpdates()
        await host.refuse(status: 501, code: nil)
        _ = try await store.get("flags/a", as: Doc.self)
        var seen: [Bool] = []
        for await value in updates { seen.append(value) }
        #expect(seen == [true])

        var late: [Bool] = []
        for await value in await store.localOnlyUpdates() { late.append(value) }
        #expect(late == [true])
    }

    @Test func localStateOutlivesTheStoreAndStaysPerAccount() async throws {
        let directory = temporaryDirectory()
        let host = StoreHost()
        await host.refuse(status: 501, code: nil)
        let me = SoftwareAccountKeys(address: "me@parity.example")
        let them = SoftwareAccountKeys(address: "them@parity.example")

        let first = try await signedInStore(host: host, keys: me, directory: directory)
        try await first.put("settings/app", Doc(name: "mine"))

        let again = try await signedInStore(host: host, keys: me, directory: directory)
        #expect(try await again.get("settings/app", as: Doc.self)?.value == Doc(name: "mine"))
        let other = try await signedInStore(host: host, keys: them, directory: directory)
        #expect(try await other.get("settings/app", as: Doc.self) == nil)
    }
}

@Suite struct LocalStorage {
    @Test func versionsAndSwapsLikeTheRelay() async throws {
        let store = LocalPersonalStorage(directory: temporaryDirectory())
        #expect(try await store.put("settings/app", Doc(name: "a"), expectedVersion: 0) == 1)
        #expect(try await store.put("settings/app", Doc(name: "b"), expectedVersion: 1) == 2)
        await #expect(throws: StorageConflictError()) {
            try await store.put("settings/app", Doc(name: "c"), expectedVersion: 1)
        }
        #expect(try await store.get("settings/app", as: Doc.self)?.version == 2)
    }

    @Test func aPrefixStopsAtItsNamespaceAndKeysCanBeLong() async throws {
        let store = LocalPersonalStorage(directory: temporaryDirectory())
        let long = "draft-att/" + String(repeating: "a", count: 400) + "/b"
        try await store.put(long, Doc(name: "long"))
        try await store.put("sent/1", Doc(name: "header"))
        try await store.put("sent-body/1", Doc(name: "body"))
        #expect(try await store.list(prefix: "sent/", as: Doc.self).map(\.key) == ["sent/1"])
        #expect(try await store.listKeys(prefix: "draft-att/").map(\.key) == [long])
        #expect(try await store.stat().count == 3)
        try await store.delete("sent/1")
        try await store.delete("sent/1")
        #expect(try await store.list(prefix: "sent/", as: Doc.self).isEmpty)
    }

    @Test func aValueOfTheWrongShapeIsSkippedInAList() async throws {
        let store = LocalPersonalStorage(directory: temporaryDirectory())
        try await store.put("flags/a", Doc(name: "a"))
        try await store.put("flags/b", ["other": 1])
        #expect(try await store.list(prefix: "flags/", as: Doc.self).map(\.key) == ["flags/a"])
    }

    @Test func nothingIsWrittenUntilThereIsSomethingToWrite() async throws {
        let directory = temporaryDirectory()
        let store = LocalPersonalStorage(directory: directory)
        #expect(try await store.list(prefix: "", as: Doc.self).isEmpty)
        #expect(try await store.stat() == StorageUsage(usedBytes: 0, quotaBytes: 0, count: 0))
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }
}

@Suite struct InMemoryStorage {
    @Test func keepsTheRelaysVersionRules() async throws {
        let store = InMemoryPersonalStorage()
        #expect(try await store.put("a/b", Doc(name: "1"), expectedVersion: 0) == 1)
        #expect(try await store.put("a/b", Doc(name: "2"), expectedVersion: 0) == 2)
        await #expect(throws: StorageConflictError()) { try await store.put("a/c", Doc(name: "x"), expectedVersion: 4) }
        try await store.delete("a/b")
        try await store.delete("a/b")
        #expect(try await store.put("a/b", Doc(name: "3"), expectedVersion: 0) == 1)
    }

    @Test(arguments: [
        "", "/a", "a/", "a//b", "a/./b", "a/../b", "a@b", "a:b", "a b", String(repeating: "a", count: 513),
    ])
    func refusesWhatTheRelayRefuses(key: String) async {
        let store = InMemoryPersonalStorage()
        await #expect(throws: APIError(status: 400, message: "relay: personal kv invalid key", code: "storage_bad_key"))
        {
            try await store.put(key, Doc(name: "x"))
        }
    }

    @Test func aKeysOnlyListingHasNoVersions() async throws {
        let store = InMemoryPersonalStorage()
        try await store.put("a/2", Doc(name: "x"))
        try await store.put("a/1", Doc(name: "x"))
        try await store.put("a/1", Doc(name: "y"))
        let keys = try await store.listKeys(prefix: "a/")
        #expect(keys.map(\.key) == ["a/1", "a/2"])
        #expect(keys.map(\.version) == [0, 0])
        #expect(try await store.list(prefix: "a/", as: Doc.self).map(\.version) == [2, 1])
    }
}
