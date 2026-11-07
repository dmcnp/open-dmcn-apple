import Foundation

// Deleting a message marks it, in `trashedAt` on its sealed flag record; the message stays where it
// was. Removal for good is the client's job, because only the owner can read the mark: the relay
// holds it as ciphertext. So the sweep runs when an unlocked client is open, and mail whose time is
// up while none is goes the next time one is. Parity with the browser's lib/trash.ts and
// hooks/useTrashPurge.ts.

/// How one due message goes.
public enum TrashRemoval: Sendable, Equatable {
    /// Delete it from the Sent store, then its flag record.
    case sentStore
    /// Delete it from the mailbox, then its flag record.
    case mailbox
    /// The listing no longer holds it, removed elsewhere: only the flag record is left to clear.
    case flagOnly
}

/// A message whose time in Deleted is up.
public struct TrashPurge: Sendable, Equatable {
    public let hash: String
    public let removal: TrashRemoval

    public init(hash: String, removal: TrashRemoval) {
        self.hash = hash
        self.removal = removal
    }
}

/// What a sweep waits for. A message missing from a listing that hasn't landed isn't a message
/// that's gone, and the retention isn't the default just because settings haven't been read.
public struct TrashSweepState: Sendable {
    public var flagsReady: Bool
    public var mailLoaded: Bool
    public var sentLoaded: Bool
    public var settingsLoaded: Bool
    /// Reading is allowed. A locked mailbox can't be swept.
    public var accessOK: Bool

    public init(flagsReady: Bool, mailLoaded: Bool, sentLoaded: Bool, settingsLoaded: Bool, accessOK: Bool) {
        self.flagsReady = flagsReady
        self.mailLoaded = mailLoaded
        self.sentLoaded = sentLoaded
        self.settingsLoaded = settingsLoaded
        self.accessOK = accessOK
    }
}

extension MailView {
    public static let trashDaysDefault = 7
    public static let trashDaysMin = 1
    public static let trashDaysMax = 7

    /// How often an open client sweeps. Retention is counted in days, so an hour late is the worst
    /// it gets.
    public static let trashSweepInterval: TimeInterval = 60 * 60

    private static let dayMillis: Int64 = 24 * 60 * 60 * 1000

    /// The retention the account asked for, as whole days within the range offered.
    public static func trashDays(_ setting: Double?) -> Int {
        guard let setting, setting.isFinite else { return trashDaysDefault }
        // Math.round: halves go up, whichever side of zero.
        let rounded = (setting + 0.5).rounded(.down)
        return Int(min(Double(trashDaysMax), max(Double(trashDaysMin), rounded)))
    }

    /// When a message deleted at `trashedAt` is removed for good, unix ms.
    public static func purgeAt(_ trashedAt: Int64, days: Int) -> Int64 {
        trashedAt + Int64(days) * dayMillis
    }

    /// The messages whose time in Deleted is up, in a stable order. The retention is read now rather
    /// than when each was deleted, so changing it applies to everything already waiting.
    public static func expiredTrash(_ flags: [String: FlagRecord], days: Int, now: Int64) -> [String] {
        flags.compactMap { hash, flag in
            flag.trashedAt.flatMap { purgeAt($0, days: days) <= now ? hash : nil }
        }
        .sorted()
    }

    /// Whether a message shows in Deleted: it was deleted, and it isn't something the owner never
    /// sees anywhere else either. Those are still removed on schedule, just not listed. The rail and
    /// the view both ask this, so the Deleted row is never there for an empty view.
    public static func shownInDeleted(
        _ m: MailPreview, address: String?, flags: [String: FlagRecord], filter: FilterList?, control: Set<String> = []
    ) -> Bool {
        if flags[m.hash]?.trashedAt == nil || control.contains(m.subject) { return false }
        return isFromOwner(m, address: address) || !blocks(filter, m)
    }

    /// "today", "tomorrow", "in 3 days": when a message in Deleted goes, in calendar days.
    public static func purgeWhen(_ trashedAt: Int64, days: Int, now: Int64, timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        func midnight(_ millis: Int64) -> TimeInterval {
            calendar.startOfDay(for: Date(timeIntervalSince1970: TimeInterval(millis) / 1000)).timeIntervalSince1970
        }
        // Rounded because a day with a clock change isn't 24 hours long.
        let n = Int(((midnight(purgeAt(trashedAt, days: days)) - midnight(now)) / 86400).rounded())
        if n <= 0 { return "today" }
        return n == 1 ? "tomorrow" : "in \(n) days"
    }

    /// What a sweep should remove now: nothing until everything it reads has answered. `inFlight`
    /// is what the last sweep is still removing. A failed removal keeps its flag, so the next sweep
    /// finds it again rather than letting the message reappear where it came from.
    public static func trashDue(
        state: TrashSweepState, flags: [String: FlagRecord], days: Int, messages: [MailPreview], sent: [MailPreview],
        now: Int64, inFlight: Set<String> = []
    ) -> [TrashPurge] {
        guard state.flagsReady, state.mailLoaded, state.sentLoaded, state.settingsLoaded, state.accessOK else {
            return []
        }
        let inMailbox = Set(messages.map(\.hash))
        let inSent = Set(sent.map(\.hash))
        return expiredTrash(flags, days: days, now: now).filter { !inFlight.contains($0) }.map { hash in
            if SentStore.isSentHash(hash) {
                return TrashPurge(hash: hash, removal: inSent.contains(hash) ? .sentStore : .flagOnly)
            }
            return TrashPurge(hash: hash, removal: inMailbox.contains(hash) ? .mailbox : .flagOnly)
        }
    }
}

extension AppSettings {
    /// The stored retention as the browser reads it, fractions included.
    var trashDaysSetting: Double? {
        switch fields["trashDays"] {
        case .int(let v)?: Double(v)
        case .double(let v)?: v
        default: nil
        }
    }

    /// How many days deleted mail waits, as the browser's `trashDays` answers it.
    public var keepDays: Int { MailView.trashDays(trashDaysSetting) }
}
