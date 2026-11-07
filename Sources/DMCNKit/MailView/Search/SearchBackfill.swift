import Foundation

// Bringing the index level with the mailbox: fetch and index what it lacks, drop what has gone. A
// body can only be read one message at a time, so the first pass over a large mailbox is long, and
// the design is about making it resumable and polite: newest first, so the mail people search most
// is searchable first; two at a time; only while it's appropriate; written out every few hundred
// messages; restarted from what the index holds, never from the beginning. Parity with the browser's
// lib/search/backfill.ts.

/// A message the index could hold.
public struct SearchCandidate: Sendable, Equatable {
    public var hash: String
    public var sentAt: Int64
    /// Never indexed, and dropped if it already was.
    public var blocked: Bool

    public init(hash: String, sentAt: Int64, blocked: Bool = false) {
        self.hash = hash
        self.sentAt = sentAt
        self.blocked = blocked
    }
}

extension MailSearch {
    /// What one pass does. `fetch` is every unblocked candidate not yet indexed, newest first.
    /// `remove` is every indexed message no longer a candidate, or now blocked. It needs `indexed`,
    /// passed only when the candidates are known complete: otherwise a mailbox still loading would
    /// read as a mailbox that was emptied.
    public static func planPass(
        _ candidates: [SearchCandidate], has: (String) -> Bool, indexed: [String]? = nil
    ) -> (fetch: [String], remove: [String]) {
        var keep = Set<String>()
        var fetch: [SearchCandidate] = []
        for candidate in candidates where !candidate.blocked {
            keep.insert(candidate.hash)
            if !has(candidate.hash) { fetch.append(candidate) }
        }
        let remove = (indexed ?? []).filter { !keep.contains($0) }
        return (fetch.stablySorted(descendingBy: \.sentAt).map(\.hash), remove)
    }
}

public actor SearchBackfill {
    public static let concurrency = 2
    public static let flushEvery = 200
    public static let flushAfterMillis: Int64 = 20_000
    /// A message that failed this often is left for the next session rather than retried forever.
    public static let maxFailures = 3
    /// This many failures in a row ends the pass: the network or the relay is having a bad minute.
    public static let failureStreak = 5
    public static let retryAfter: Duration = .seconds(60)

    private let index: any SearchIndexing
    private let fetch: @Sendable (String) async throws -> SearchBody
    private let runnable: @Sendable () async -> Bool
    private let onProgress: @Sendable (_ flushed: Bool) async -> Void
    private let retryLater: (@Sendable (Duration) async -> Void)?
    private let now: StoreClock

    private var candidates: [SearchCandidate] = []
    private var complete = false
    private var running = false
    private var kicked = false
    private var stopped = false
    private var failures: [String: Int] = [:]
    private var idle: Task<Void, Never>?

    // One pass's state. Its two workers share it, each running only between its awaits.
    private var queue: [String] = []
    private var indexed = Set<String>()
    private var sinceFlush = 0
    private var lastFlush: Int64 = 0
    private var streak = 0
    private var gaveUp = false

    /// `fetch` reads a message's text and attachment names. `runnable` says whether fetching is
    /// appropriate right now (in front of someone, online, the mailbox readable). `onProgress` runs
    /// after each message indexed and each write. `retryLater` gets a delay when a pass gave up.
    public init(
        index: any SearchIndexing, fetch: @escaping @Sendable (String) async throws -> SearchBody,
        runnable: @escaping @Sendable () async -> Bool,
        onProgress: @escaping @Sendable (_ flushed: Bool) async -> Void = { _ in },
        retryLater: (@Sendable (Duration) async -> Void)? = nil, now: @escaping StoreClock = systemClock
    ) {
        self.index = index
        self.fetch = fetch
        self.runnable = runnable
        self.onProgress = onProgress
        self.retryLater = retryLater
        self.now = now
    }

    /// The current candidates. `complete` says the lists they came from have loaded in full, which
    /// is what allows a pass to remove anything.
    public func update(_ candidates: [SearchCandidate], complete: Bool) {
        self.candidates = candidates
        self.complete = complete
        kick()
    }

    /// Starts a pass, or has the running one re-plan as soon as its in-flight fetches land.
    public func kick() {
        if stopped { return }
        if running {
            kicked = true
            return
        }
        running = true
        idle = Task { await loop() }
    }

    /// Stops after the fetches in flight, and writes everything added.
    public func stop() async {
        stopped = true
        await idle?.value
        try? await index.flush()
    }

    /// Returns when no pass is running.
    public func settled() async {
        await idle?.value
    }

    private func loop() async {
        defer { running = false }
        repeat {
            kicked = false
            do {
                try await pass()
            } catch {
                return  // the next kick starts again from what the index holds
            }
        } while kicked && !stopped
    }

    private func pass() async throws {
        let held = await index.hashes()
        indexed = Set(held)
        let plan = MailSearch.planPass(candidates, has: indexed.contains, indexed: complete ? held : nil)
        if !plan.remove.isEmpty { try await index.remove(plan.remove) }
        queue = plan.fetch.filter { failures[$0, default: 0] < Self.maxFailures }
        sinceFlush = 0
        lastFlush = now()
        streak = 0
        gaveUp = false

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<Self.concurrency {
                group.addTask { await self.worker() }
            }
        }

        if await index.hasPending() { try await flushNow() }
        if gaveUp {
            await retryLater?(Self.retryAfter)
            return
        }
        if !stopped, !kicked, await index.wantsCompaction(), await runnable() { try await index.compact() }
    }

    private func flushNow() async throws {
        sinceFlush = 0
        lastFlush = now()
        try await index.flush()
        await onProgress(true)
    }

    private func shouldGoOn() async -> Bool {
        if stopped || kicked || gaveUp { return false }
        return await runnable()
    }

    private func worker() async {
        while !queue.isEmpty, await shouldGoOn(), !queue.isEmpty {
            let hash = queue.removeFirst()
            do {
                let body = try await fetch(hash)
                try await index.add(hash, text: body.text, filenames: body.filenames)
                streak = 0
                sinceFlush += 1
                await onProgress(false)
            } catch {
                failures[hash, default: 0] += 1
                streak += 1
                if streak >= Self.failureStreak { gaveUp = true }
            }
            if sinceFlush >= Self.flushEvery || (sinceFlush > 0 && now() - lastFlush >= Self.flushAfterMillis) {
                try? await flushNow()
            }
        }
    }
}
