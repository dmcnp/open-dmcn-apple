import Foundation
import Testing
@testable import DMCNKit

/// A save that waits until the test lets it go.
private actor Gate {
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private(set) var entered = 0

    func enter() async {
        entered += 1
        await withCheckedContinuation { waiting.append($0) }
    }

    func release() {
        if !waiting.isEmpty { waiting.removeFirst().resume() }
    }
}

private actor Counter {
    private(set) var value = 0
    private(set) var peak = 0
    private var running = 0
    func add() { value += 1 }
    func start() {
        running += 1
        peak = max(peak, running)
    }
    func stop() { running -= 1 }
}

private func eventually(_ condition: @Sendable () async -> Bool) async {
    for _ in 0..<2000 {
        if await condition() { return }
        await Task.yield()
    }
    Issue.record("never happened")
}

/// The browser's own draftAutosave.test.ts, case for case.
@Suite struct SaveSchedulerRules {
    private struct Offline: Error {}

    @Test func savesOnceTypingPausesNotPerChange() async {
        let timers = ManualTimers()
        let saves = Counter()
        let s = SaveScheduler(quietMillis: 3000, maxWaitMillis: 15000, timers: timers) { await saves.add() }
        for _ in 0..<5 {
            await s.touch()
            await timers.advance(1000)
        }
        #expect(await saves.value == 0)
        await timers.advance(3000)
        #expect(await saves.value == 1)
        #expect(await s.pending == false)
    }

    @Test func savesAtTheCeilingWhileChangesKeepComing() async {
        let timers = ManualTimers()
        let saves = Counter()
        let s = SaveScheduler(quietMillis: 3000, maxWaitMillis: 15000, timers: timers) { await saves.add() }
        for _ in 0..<16 {
            await s.touch()
            await timers.advance(1000)
        }
        #expect(await saves.value == 1)
    }

    @Test func flushSavesWhatIsPendingAndNothingWhenNothingIs() async throws {
        let timers = ManualTimers()
        let saves = Counter()
        let s = SaveScheduler(quietMillis: 3000, maxWaitMillis: 15000, timers: timers) { await saves.add() }
        try await s.flush()
        #expect(await saves.value == 0)
        await s.touch()
        try await s.flush()
        #expect(await saves.value == 1)
    }

    @Test func aChangeDuringASaveIsSavedByTheNextNeverConcurrently() async throws {
        let timers = ManualTimers()
        let saves = Counter()
        let gate = Gate()
        let s = SaveScheduler(quietMillis: 3000, maxWaitMillis: 15000, timers: timers) {
            await saves.start()
            await gate.enter()
            await saves.stop()
            await saves.add()
        }
        await s.touch()
        let first = Task { try await s.flush() }
        await eventually { await gate.entered == 1 }
        await s.touch()
        let second = Task { try await s.flush() }
        await gate.release()
        try await first.value
        await eventually { await gate.entered == 2 }
        await gate.release()
        try await second.value
        #expect(await saves.value == 2)
        #expect(await saves.peak == 1)
    }

    @Test func aFailedSaveStaysPendingAndIsRetried() async {
        let timers = ManualTimers()
        let attempts = Counter()
        let s = SaveScheduler(quietMillis: 3000, maxWaitMillis: 15000, timers: timers) {
            await attempts.add()
            if await attempts.value == 1 { throw Offline() }
        }
        await s.touch()
        await #expect(throws: Offline.self) { try await s.flush() }
        #expect(await s.pending)
        await timers.advance(15000)
        #expect(await attempts.value == 2)
        #expect(await s.pending == false)
    }

    @Test func abandonDropsWhatIsPendingAndWaitsForASaveInFlight() async throws {
        let timers = ManualTimers()
        let saves = Counter()
        let gate = Gate()
        let s = SaveScheduler(quietMillis: 3000, maxWaitMillis: 15000, timers: timers) {
            await gate.enter()
            await saves.add()
        }
        await s.touch()
        let inFlight = Task { try await s.flush() }
        await eventually { await gate.entered == 1 }
        await s.touch()
        let done = Counter()
        let abandoning = Task {
            await s.abandon()
            await done.add()
        }
        await eventually { await s.pending == false }
        #expect(await done.value == 0)
        await gate.release()
        try await inFlight.value
        await abandoning.value
        await timers.advance(20000)
        #expect(await saves.value == 1)
        #expect(await s.pending == false)
    }

    @Test func noTimerOutlivesDispose() async {
        let timers = ManualTimers()
        let s = SaveScheduler(quietMillis: 3000, maxWaitMillis: 15000, timers: timers) {}
        await s.touch()
        #expect(timers.pendingTimers == 1)
        await s.dispose()
        #expect(timers.pendingTimers == 0)
        await s.touch()
        #expect(timers.pendingTimers == 0)
    }
}

private final class MemoryBackstop: DraftBackstop, @unchecked Sendable {
    private let lock = NSLock()
    private var drafts: [String: LocalDraft] = [:]
    var failing = false

    func get(_ key: String) async throws -> LocalDraft? { lock.withLock { drafts[key] } }
    func put(_ key: String, _ value: LocalDraft) async throws {
        struct Full: Error {}
        if failing { throw Full() }
        lock.withLock { drafts[key] = value }
    }
    func delete(_ key: String) async throws { _ = lock.withLock { drafts.removeValue(forKey: key) } }
    func entries(prefix: String) async throws -> [(key: String, value: LocalDraft)] {
        lock.withLock { drafts.filter { $0.key.hasPrefix(prefix) }.map { ($0.key, $0.value) } }
    }
    var count: Int { lock.withLock { drafts.count } }
}

/// Storage that can refuse, hang, or be overwritten by "another device".
private actor FlakyStorage: PersonalStorage {
    let inner = InMemoryPersonalStorage()
    private var refusal: (any Error)?
    private var hanging = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var writes = 0
    var hungWrites: Int { waiters.count }

    func refuse(_ error: (any Error)?) { refusal = error }
    func hang() { hanging = true }
    func letGo() {
        hanging = false
        waiters.forEach { $0.resume() }
        waiters = []
    }

    func get<T: Decodable & Sendable>(_ key: String, as type: T.Type) async throws -> StorageEntry<T>? {
        try await inner.get(key, as: type)
    }
    func put(_ key: String, _ value: some Encodable & Sendable, expectedVersion: Int) async throws -> Int {
        if hanging { await withCheckedContinuation { waiters.append($0) } }
        if let refusal { throw refusal }
        writes += 1
        return try await inner.put(key, value, expectedVersion: expectedVersion)
    }
    func list<T: Decodable & Sendable>(prefix: String, as type: T.Type) async throws -> [StorageEntry<T>] {
        try await inner.list(prefix: prefix, as: type)
    }
    func listKeys(prefix: String) async throws -> [(key: String, version: Int)] {
        try await inner.listKeys(prefix: prefix)
    }
    func delete(_ key: String) async throws { try await inner.delete(key) }
    func stat() async throws -> StorageUsage { try await inner.stat() }
}

@Suite struct DraftAutosaveRules {
    private let me = "me@parity.example"
    private let timers = ManualTimers()
    private let storage = FlakyStorage()
    private let backstop = MemoryBackstop()

    private var store: DraftStore { DraftStore(storage: storage, address: me, backstop: backstop) }
    private var relayOnly: DraftStore { DraftStore(storage: storage, address: me) }

    private func blank() -> DraftContent { DraftContent(from: me) }
    private func typed(_ text: String = "Hello") -> DraftContent { DraftContent(from: me, text: text) }

    private func autosave(
        _ store: DraftStore? = nil, opening: DraftContent? = nil, untouched: String = "", draft: LoadedDraft? = nil
    ) -> DraftAutosave {
        DraftAutosave(
            store: store ?? self.store, opening: opening ?? blank(), untouchedText: untouched, draft: draft,
            timers: timers)
    }

    @Test func openingAndClosingLeavesNothing() async throws {
        let a = autosave()
        #expect(await a.putAway())
        await timers.advance(60_000)
        #expect(try await store.list().isEmpty)
        #expect(await a.draftID == nil)
    }

    @Test func aPrefilledReplyIsNotADraftUntilSomethingIsWritten() async throws {
        let reply = ComposeReplyTo(to: ["a@x"], subject: "Lunch")
        let scaffold = "\n\nAda\n\n> hi"
        let opening = DraftContent(from: me, to: ["a@x"], subject: "Re: Lunch", text: scaffold, replyTo: reply)
        let a = autosave(opening: opening, untouched: scaffold)
        await a.edited(opening)
        await timers.advance(3000)
        #expect(try await store.list().isEmpty)

        var written = opening
        written.text = "Sure.\n" + scaffold
        await a.edited(written)
        await timers.advance(3000)
        #expect(try await store.list().count == 1)
    }

    @Test func savesToTheDeviceSoonAndTheRelayAfterAPause() async throws {
        let a = autosave()
        await a.edited(typed())
        await timers.advance(500)
        #expect(backstop.count == 1)
        #expect(await storage.writes == 0)
        await timers.advance(2500)
        #expect(await storage.writes == 2)  // the body and the row
        #expect(await a.state == .saved)
        #expect(await a.state.label == "Draft saved")
        // The relay has it, so the device's copy goes.
        #expect(backstop.count == 0)
        let id = try #require(await a.draftID)
        #expect(try await store.load(id)?.content.text == "Hello")
    }

    @Test func theCeilingHolds() async throws {
        let a = autosave()
        for i in 0..<16 {
            await a.edited(typed("Hello \(i)"))
            await timers.advance(1000)
        }
        #expect(await storage.writes == 2)
    }

    @Test func aSecondSaveNamesTheVersionsItSaw() async throws {
        let a = autosave()
        await a.edited(typed("one"))
        await timers.advance(3000)
        await a.edited(typed("two"))
        await timers.advance(3000)
        let id = try #require(await a.draftID)
        #expect(await a.state == .saved)
        #expect(try await store.load(id)?.content.text == "two")
    }

    @Test func offlineIsKeptOnTheDeviceAndRetried() async throws {
        let a = autosave()
        await storage.refuse(APIError(status: 502, message: "down"))
        await a.edited(typed())
        await timers.advance(3000)
        #expect(await a.state == .device)
        #expect(await a.state.label == "Saved on this device")
        #expect(backstop.count == 1)
        await storage.refuse(nil)
        await timers.advance(15000)
        #expect(await a.state == .saved)
        #expect(backstop.count == 0)
    }

    @Test func offlineWithNoDeviceCopySaysSo() async throws {
        let a = autosave(relayOnly)
        await storage.refuse(APIError(status: 502, message: "down"))
        await a.edited(typed())
        await timers.advance(3000)
        #expect(await a.state == .failed)
        #expect(await a.state.label == "Not saved")
    }

    @Test func aFullStoreSaysSo() async throws {
        let a = autosave()
        await storage.refuse(APIError(status: 507, message: "full"))
        await a.edited(typed())
        await timers.advance(3000)
        #expect(await a.state == .full)
        #expect(await a.state.label == "Not saved: your storage is full")
    }

    @Test func anotherDevicesCopyStopsSavingUntilThePersonChooses() async throws {
        let a = autosave()
        await a.edited(typed("mine"))
        await timers.advance(3000)
        let id = try #require(await a.draftID)

        // Another device saves a newer copy.
        let theirs = try #require(try await store.load(id))
        var other = theirs.content
        other.text = "theirs"
        try await store.save(id, content: other, base: theirs.base, updatedAt: 99)

        await a.edited(typed("mine, more"))
        await timers.advance(3000)
        #expect(await a.state == .conflict)
        #expect(
            await a.state.warning == "This draft was changed on another device. Your changes here are not saved yet.")
        let writes = await storage.writes
        await a.edited(typed("mine, even more"))
        await timers.advance(20000)
        #expect(await storage.writes == writes)

        await a.keepThisCopy()
        #expect(await a.state == .saved)
        #expect(try await store.load(id)?.content.text == "mine, even more")
    }

    @Test func aCopyDeletedElsewhereCanBeBroughtBack() async throws {
        let a = autosave()
        await a.edited(typed("mine"))
        await timers.advance(3000)
        let id = try #require(await a.draftID)
        try await store.delete(id)

        await a.edited(typed("mine, more"))
        await timers.advance(3000)
        #expect(await a.state == .gone)

        await a.keepThisCopy()
        #expect(try await store.load(id)?.content.text == "mine, more")
    }

    @Test func givingUpThisCopyHandsTheIdBack() async throws {
        let a = autosave()
        await a.edited(typed("mine"))
        await timers.advance(500)
        let id = await a.dropThisCopy()
        #expect(id != nil)
        #expect(backstop.count == 0)
        await a.edited(typed("after"))
        await timers.advance(20000)
        #expect(await storage.writes == 0)
    }

    @Test func removingWaitsOutASaveSoItCantBringTheDraftBack() async throws {
        let a = autosave()
        await a.edited(typed())
        await timers.advance(2999)
        await storage.hang()
        let saving = Task { await timers.advance(1) }
        await eventually { await a.state == .saving }
        let removing = Task { await a.remove() }
        await Task.yield()
        await storage.letGo()
        await saving.value
        await removing.value
        #expect(try await store.list().isEmpty)
        #expect(backstop.count == 0)
    }

    @Test func aCarriedOnDraftStartsSavedAndKeepsItsVersions() async throws {
        let first = autosave()
        await first.edited(typed("one"))
        await timers.advance(3000)
        let id = try #require(await first.draftID)
        let loaded = try #require(try await store.load(id))

        let second = autosave(draft: loaded)
        #expect(await second.state == .saved)
        #expect(await second.draftID == id)
        await second.edited(typed("two"))
        await timers.advance(3000)
        #expect(await second.state == .saved)
        #expect(try await store.load(id)?.content.text == "two")
    }

    @Test func puttingAwayAnEmptiedDraftDiscardsIt() async throws {
        let a = autosave()
        await a.edited(typed())
        await timers.advance(3000)
        await a.edited(blank())
        #expect(await a.putAway())
        #expect(try await store.list().isEmpty)
    }

    @Test func puttingAwaySavesAtOnce() async throws {
        let a = autosave()
        await a.edited(typed())
        #expect(await a.putAway())
        let id = try #require(await a.draftID)
        #expect(try await store.load(id)?.content.text == "Hello")
        #expect(await storage.writes == 2)
        #expect(timers.pendingTimers == 0)
    }

    @Test func aDeviceCopyIsEnoughWhenTheRelayIsDown() async throws {
        let a = autosave()
        await storage.refuse(APIError(status: 502, message: "down"))
        await a.edited(typed())
        let told = Counter()
        #expect(await a.putAway(onDeviceCopy: { await told.add() }))
        #expect(await told.value == 1)
        #expect(backstop.count == 1)
    }

    @Test func nowhereToKeepItSaysSoAndStaysOpen() async throws {
        let a = autosave(relayOnly)
        await storage.refuse(APIError(status: 502, message: "down"))
        await a.edited(typed())
        #expect(await a.putAway() == false)
        #expect(
            DraftAutosave.notSavedMessage
                == "This draft couldn't be saved. Check your connection and try again, or discard it.")
    }

    @Test func aRelayThatHangsIsWaitedForOnlySoLong() async throws {
        let a = autosave()
        await storage.hang()
        await a.edited(typed())
        let result = Task { await a.putAway() }
        // Advancing before the save is under way would run its timer, and wait on it with the rest.
        await eventually { await storage.hungWrites == 1 }
        await timers.advance(8000)
        #expect(await result.value)
        await storage.letGo()
    }

    @Test func aSignatureThatLoadsLateIsNotAnEdit() async throws {
        let a = autosave()
        await a.updateUntouchedText("\n\nAda")
        await a.edited(DraftContent(from: me, text: "\n\nAda"))
        await timers.advance(3000)
        #expect(try await store.list().isEmpty)
    }
}
