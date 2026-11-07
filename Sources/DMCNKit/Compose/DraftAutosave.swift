import Foundation

// Saving a message while it is written. Parity with the browser's lib/draftAutosave.ts and the draft
// half of components/ComposeDialog.tsx.
//
// Two saves run side by side: to this device about half a second after each change, and to the
// owner's personal store a few seconds after typing pauses, sealed so the same draft opens on their
// other devices. Waiting for a pause keeps a sentence from turning into a save per keystroke, each
// of which is a signed challenge and two writes. The ceiling keeps someone who types for a minute
// without stopping from having a minute to lose.

/// A clock and timers, injected so a test can move time by hand. Milliseconds throughout.
public protocol AutosaveTimers: Sendable {
    func set(after milliseconds: Int64, _ fire: @escaping @Sendable () async -> Void) -> any Sendable
    func clear(_ handle: any Sendable)
    func now() -> Int64
}

public struct SystemAutosaveTimers: AutosaveTimers {
    public init() {}

    public func set(after milliseconds: Int64, _ fire: @escaping @Sendable () async -> Void) -> any Sendable {
        Task {
            try? await Task.sleep(nanoseconds: UInt64(milliseconds) * 1_000_000)
            if !Task.isCancelled { await fire() }
        }
    }

    public func clear(_ handle: any Sendable) {
        (handle as? Task<Void, Never>)?.cancel()
    }

    public func now() -> Int64 { systemClock() }
}

/// When to save: a little after changes stop, and never less often than every so often while they
/// don't. Saves never overlap: a change that arrives during one is picked up by the next.
public actor SaveScheduler {
    private let run: @Sendable () async throws -> Void
    private let quietMillis: Int64
    private let maxWaitMillis: Int64
    private let timers: any AutosaveTimers

    private var timer: (any Sendable)?
    /// When the oldest unsaved change was made; nil while everything is saved.
    private var dirtySince: Int64?
    private var running: Task<Void, any Error>?
    private var disposed = false

    /// `run` saves the current state and throws only when it is worth trying again. A failed save
    /// stays pending and is retried after `maxWaitMillis`.
    public init(
        quietMillis: Int64, maxWaitMillis: Int64, timers: any AutosaveTimers,
        run: @escaping @Sendable () async throws -> Void
    ) {
        self.quietMillis = quietMillis
        self.maxWaitMillis = maxWaitMillis
        self.timers = timers
        self.run = run
    }

    /// Something changed.
    public func touch() {
        guard !disposed else { return }
        let now = timers.now()
        let since = dirtySince ?? now
        dirtySince = since
        schedule(max(0, min(quietMillis, since + maxWaitMillis - now)))
    }

    /// Whether a change is waiting to be saved.
    public var pending: Bool { dirtySince != nil }

    /// Saves now if anything is pending. Throws if that save fails, and it stays pending.
    public func flush() async throws {
        cancel()
        while let running { _ = try? await running.value }
        guard let since = dirtySince else { return }
        dirtySince = nil
        let task = Task { [run] in
            do {
                try await run()
                self.finished()
            } catch {
                self.finished()
                throw error
            }
        }
        running = task
        do {
            try await task.value
        } catch {
            // Still unsaved, and still as old as it was.
            if let later = dirtySince { dirtySince = min(since, later) } else { dirtySince = since }
            if !disposed { schedule(maxWaitMillis) }
            throw error
        }
    }

    /// Stops the timer for good. A `flush` still runs.
    public func dispose() {
        disposed = true
        cancel()
    }

    /// Drops what is pending and waits out a save in flight: what it saves is about to be removed.
    public func abandon() async {
        dispose()
        dirtySince = nil
        while let running { _ = try? await running.value }
    }

    private func finished() { running = nil }

    private func schedule(_ milliseconds: Int64) {
        cancel()
        timer = timers.set(after: milliseconds) { [weak self] in await self?.fire() }
    }

    private func fire() async {
        timer = nil
        try? await flush()
    }

    private func cancel() {
        guard let timer else { return }
        timers.clear(timer)
        self.timer = nil
    }
}

/// One composer's draft: nothing is saved until someone changes something, and a new message isn't
/// saved until it holds something worth keeping, so opening the composer and closing it again leaves
/// nothing behind. Sending removes the draft; closing keeps it.
public actor DraftAutosave {
    public enum SaveState: Sendable, Equatable {
        case idle
        case saving
        case saved
        /// On this device, not yet on the relay.
        case device
        case failed
        case full
        /// Another device changed it. Saving waits until the person chooses a copy.
        case conflict
        /// It was sent or deleted on another device.
        case gone

        /// The line beside Send. Empty when there is nothing to say, or when `warning` has it.
        public var label: String {
            switch self {
            case .saving: "Saving…"
            case .saved: "Draft saved"
            case .device: "Saved on this device"
            case .failed: "Not saved"
            case .full: "Not saved: your storage is full"
            case .idle, .conflict, .gone: ""
            }
        }

        /// What to tell the person when two copies need settling.
        public var warning: String? {
            switch self {
            case .conflict: "This draft was changed on another device. Your changes here are not saved yet."
            case .gone: "This draft was sent or deleted on another device. Your changes here are not saved yet."
            default: nil
            }
        }
    }

    /// Why a composer stays open after `putAway` returned false.
    public static let notSavedMessage =
        "This draft couldn't be saved. Check your connection and try again, or discard it."

    /// How long putting a draft away waits for the relay before settling for the device copy.
    private static let putAwayWaitMillis: Int64 = 8000

    private let store: DraftStore
    private let timers: any AutosaveTimers
    private let onListChanged: (@Sendable () async -> Void)?
    private var latest: DraftContent
    private var untouchedText: String
    private var base: DraftBase
    /// Set once the person changes anything. Prefills arriving on their own aren't a reason to save.
    private var edited = false
    /// Set once this composer is finished with its draft: sent, discarded, or handed over.
    private var done = false
    /// A save found another device's newer copy; saving waits for the person to choose.
    private var conflict = false

    public private(set) var state: SaveState
    /// Assigned the first time the message holds something.
    public private(set) var draftID: String?

    private lazy var deviceSaver = SaveScheduler(quietMillis: 500, maxWaitMillis: 2000, timers: timers) {
        [weak self] in try await self?.saveToDevice()
    }
    private lazy var relaySaver = SaveScheduler(quietMillis: 3000, maxWaitMillis: 15000, timers: timers) {
        [weak self] in try await self?.saveToRelay()
    }

    /// For a new message, `opening` is what the composer starts with and `untouchedText` its body
    /// before anyone types. To carry a saved draft on, pass it as `draft` as well.
    public init(
        store: DraftStore, opening: DraftContent, untouchedText: String = "", draft: LoadedDraft? = nil,
        timers: any AutosaveTimers = SystemAutosaveTimers(), onListChanged: (@Sendable () async -> Void)? = nil
    ) {
        self.store = store
        self.timers = timers
        self.onListChanged = onListChanged
        latest = draft?.content ?? opening
        self.untouchedText = draft == nil ? untouchedText : ""
        base = draft?.base ?? .new
        draftID = draft?.id
        state = draft == nil ? .idle : .saved
    }

    /// The person changed something, and this is the message now.
    public func edited(_ content: DraftContent) async {
        latest = content
        edited = true
        await deviceSaver.touch()
        await relaySaver.touch()
    }

    /// A late-loading signature moved what the body starts as, before anyone typed.
    public func updateUntouchedText(_ text: String) {
        untouchedText = text
    }

    /// Saves at once rather than on the timer, for the app going to the background.
    public func saveNow() async {
        try? await deviceSaver.flush()
        try? await relaySaver.flush()
    }

    /// Saves and closes. True when the message was kept somewhere it will survive, or held nothing
    /// worth keeping. False when it couldn't be: the composer then stays open with `notSavedMessage`.
    /// `onDeviceCopy` runs as soon as the device has it, so a composer can close without waiting for
    /// the relay; what doesn't reach the relay is uploaded later by `DraftStore.settleLocal`.
    public func putAway(onDeviceCopy: (@Sendable () async -> Void)? = nil) async -> Bool {
        if done || !edited { return true }
        guard DraftStore.hasContent(latest, untouchedText: untouchedText) else {
            await remove()
            return true
        }
        var kept = false
        if store.keepsLocal, (try? await deviceSaver.flush()) != nil {
            kept = true
            await onDeviceCopy?()
        }
        let saver = relaySaver
        let flushed = await within(Self.putAwayWaitMillis) { try await saver.flush() }
        let reached = flushed && !conflict
        guard kept || reached else { return false }
        await deviceSaver.dispose()
        await relaySaver.dispose()
        await onListChanged?()
        return true
    }

    /// Removes the draft: sent or discarded. Saves under way finish first, so none of them lands
    /// after the delete and brings it back.
    public func remove() async {
        done = true
        await deviceSaver.abandon()
        await relaySaver.abandon()
        guard let draftID else { return }
        try? await store.delete(draftID)
        await onListChanged?()
    }

    /// After a conflict: overwrites the other copy with this one, or brings this one back if the
    /// other was sent or deleted.
    public func keepThisCopy() async {
        conflict = false
        guard let snap = snapshot() else { return }
        state = .saving
        do {
            base = try await store.save(snap.id, content: snap.content, base: .new, updatedAt: snap.at, force: true)
            try? await store.clearLocal(snap.id, updatedAt: snap.at)
            state = .saved
            await onListChanged?()
        } catch {
            state = store.keepsLocal ? .device : .failed
            await relaySaver.touch()
        }
    }

    /// After a conflict: gives this copy up. Returns the draft's id, for the composer to open again.
    public func dropThisCopy() async -> String? {
        guard let draftID else { return nil }
        done = true
        await deviceSaver.abandon()
        await relaySaver.abandon()
        try? await store.clearLocal(draftID)
        return draftID
    }

    /// What to save now, or nil when there is nothing to save.
    private func snapshot() -> (id: String, content: DraftContent, at: Int64)? {
        guard edited, !done else { return nil }
        if let draftID { return (draftID, latest, timers.now()) }
        guard DraftStore.hasContent(latest, untouchedText: untouchedText) else { return nil }
        let id = DraftStore.newID()
        draftID = id
        return (id, latest, timers.now())
    }

    private func saveToDevice() async throws {
        guard let snap = snapshot() else { return }
        try await store.saveLocal(snap.id, content: snap.content, base: base, updatedAt: snap.at)
    }

    private func saveToRelay() async throws {
        guard !conflict, let snap = snapshot() else { return }
        let created = base.head == 0
        state = .saving
        do {
            base = try await store.save(snap.id, content: snap.content, base: base, updatedAt: snap.at)
            try? await store.clearLocal(snap.id, updatedAt: snap.at)
            state = .saved
            if created { await onListChanged?() }
        } catch is DraftConflictError {
            conflict = true
            state = (try? await store.isStored(snap.id)) ?? true ? .conflict : .gone
        } catch {
            state = (error as? APIError)?.status == 507 ? .full : store.keepsLocal ? .device : .failed
            throw error
        }
    }

    /// Whether `work` succeeds inside `milliseconds`.
    private func within(_ milliseconds: Int64, _ work: @escaping @Sendable () async throws -> Void) async -> Bool {
        let timers = timers
        return await withCheckedContinuation { continuation in
            let result = OnceOnly(continuation)
            let timer = timers.set(after: milliseconds) { await result.resume(false) }
            Task {
                let finished = (try? await work()) != nil
                timers.clear(timer)
                await result.resume(finished)
            }
        }
    }
}

/// A continuation two things race to resume.
private actor OnceOnly {
    private var continuation: CheckedContinuation<Bool, Never>?

    init(_ continuation: CheckedContinuation<Bool, Never>) {
        self.continuation = continuation
    }

    func resume(_ value: Bool) {
        continuation?.resume(returning: value)
        continuation = nil
    }
}
