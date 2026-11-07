// The browser suites' own cases for the rules in MailView, and the rules Swift adds on top: the
// browser has no reader-check verdict on a row, so what a withheld message does to a list is here.

import DMCNKitSamples
import Foundation
import Testing
@testable import DMCNKit

private let me = "me@example.com"
private let day: Int64 = 24 * 60 * 60 * 1000

private func message(
    _ hash: String, sender: String = "alice@example.com", recipient: String = me, to: [String] = [me],
    subject: String = "Hello", verdict: MessageSummary.Sender? = nil
) -> MailPreview {
    MailPreview(
        hash: hash, senderAddress: sender, recipientAddress: recipient, to: to, subject: subject, sender: verdict)
}

private func context(
    _ flags: [String: FlagRecord] = [:], filter: FilterList? = FilterList(), address: String? = me
) -> PlaceContext {
    PlaceContext(address: address, flags: flags, filter: filter, control: ["control"], knownFolderIDs: ["f1"])
}

@Suite struct PlaceOf {
    @Test func receivedMailGoesByItsFlags() {
        #expect(MailView.placeOf(message("a"), context()) == .inbox)
        #expect(MailView.placeOf(message("a"), context(["a": FlagRecord(archived: true)])) == .archive)
        #expect(MailView.placeOf(message("a"), context(["a": FlagRecord(folderId: "f1")])) == .folder("f1"))
    }

    @Test func theFolderBeatsArchiveAndAGoneFolderIsNoFolder() {
        let both = FlagRecord(archived: true, folderId: "f1")
        #expect(MailView.placeOf(message("a"), context(["a": both])) == .folder("f1"))
        #expect(MailView.placeOf(message("a"), context(["a": FlagRecord(folderId: "gone")])) == .inbox)
    }

    @Test func whatTheAccountSentIsSentButMailToItselfIsInbox() {
        #expect(MailView.placeOf(message("sent:m1", sender: me, to: ["bob@example.com"]), context()) == .sent)
        let legacy = message("legacy", sender: me, recipient: "bob@example.com", to: ["bob@example.com"])
        #expect(MailView.placeOf(legacy, context()) == .sent)
        #expect(MailView.placeOf(message("self", sender: me), context()) == .inbox)
    }

    @Test func deletedBeatsEverything() {
        let flag = FlagRecord(archived: true, folderId: "f1", trashedAt: 1)
        #expect(MailView.placeOf(message("a"), context(["a": flag])) == .deleted)
        let sent = message("sent:m1", sender: me)
        #expect(MailView.placeOf(sent, context(["sent:m1": FlagRecord(trashedAt: 1)])) == .deleted)
    }

    @Test func controlMessagesAndBlockedSendersAreLeftOut() {
        let blocked = FilterList(senders: ["alice@example.com"])
        #expect(MailView.placeOf(message("a", subject: "control"), context()) == nil)
        #expect(MailView.placeOf(message("a"), context(filter: blocked)) == nil)
        #expect(MailView.placeOf(message("a"), context(["a": FlagRecord(trashedAt: 1)], filter: blocked)) == nil)
        #expect(MailView.placeOf(message("a", sender: me), context(filter: blocked)) == .inbox)
    }

    /// The browser has no verdict to read here, and would file this under Sent.
    @Test func aForgeryOfTheOwnersAddressIsReceivedMailAndCanBeBlocked() {
        let forged = message(
            "a", sender: me, recipient: "bob@example.com", to: ["bob@example.com"], verdict: .mismatch(claimed: me))
        #expect(MailView.isReceivedForMe(forged, address: me))
        #expect(MailView.placeOf(forged, context()) == .inbox)
        #expect(MailView.placeOf(forged, context(filter: FilterList(senders: [me]))) == nil)
    }
}

@Suite struct Trash {
    @Test func retentionDefaultsToSevenDays() {
        #expect(MailView.trashDays(nil) == 7)
        #expect(MailView.trashDaysDefault == 7)
    }

    @Test func retentionStaysWithinOneToSevenWholeDays() {
        #expect(MailView.trashDays(3) == 3)
        #expect(MailView.trashDays(0) == 1)
        #expect(MailView.trashDays(30) == 7)
        #expect(MailView.trashDays(2.6) == 3)
        #expect(MailView.trashDays(.nan) == 7)
    }

    @Test func aFractionWrittenByABrowserIsReadAsTheBrowserReadsIt() {
        var settings = AppSettings()
        #expect(settings.keepDays == 7)
        settings.fields["trashDays"] = .double(2.5)
        #expect(settings.keepDays == 3)
    }

    private let now: Int64 = 1_793_275_200_000
    private var flags: [String: FlagRecord] {
        [
            "kept": FlagRecord(), "fresh": FlagRecord(trashedAt: now - 2 * day),
            "due": FlagRecord(trashedAt: now - 7 * day), "overdue": FlagRecord(trashedAt: now - 30 * day),
        ]
    }

    @Test func onlyDeletedMailWhoseTimeIsUp() {
        #expect(MailView.expiredTrash(flags, days: 7, now: now) == ["due", "overdue"])
    }

    @Test func aShorterRetentionAppliesToMailAlreadyWaiting() {
        #expect(MailView.expiredTrash(flags, days: 1, now: now) == ["due", "fresh", "overdue"])
    }

    @Test func mailNotDeletedIsNeverTouched() {
        #expect(!MailView.expiredTrash(flags, days: 1, now: now + 365 * day).contains("kept"))
    }

    @Test func calendarDaysToTheRemoval() {
        let zone = TimeZone(identifier: "America/New_York")!
        let at: Int64 = 1_792_933_200_000  // a morning in late October
        #expect(MailView.purgeWhen(at, days: 7, now: at, timeZone: zone) == "in 7 days")
        #expect(MailView.purgeWhen(at, days: 1, now: at, timeZone: zone) == "tomorrow")
        #expect(MailView.purgeWhen(at, days: 1, now: MailView.purgeAt(at, days: 1) - 60_000, timeZone: zone) == "today")
        #expect(MailView.purgeWhen(at, days: 1, now: MailView.purgeAt(at, days: 1) + day, timeZone: zone) == "today")
    }

    private func sweep(
        flagsReady: Bool = true, mailLoaded: Bool = true, sentLoaded: Bool = true, settingsLoaded: Bool = true,
        accessOK: Bool = true, inFlight: Set<String> = []
    ) -> [TrashPurge] {
        let due: [String: FlagRecord] = [
            "here": FlagRecord(trashedAt: 0), "gone": FlagRecord(trashedAt: 0), "sent:here": FlagRecord(trashedAt: 0),
            "sent:gone": FlagRecord(trashedAt: 0), "waiting": FlagRecord(trashedAt: now),
        ]
        return MailView.trashDue(
            state: TrashSweepState(
                flagsReady: flagsReady, mailLoaded: mailLoaded, sentLoaded: sentLoaded, settingsLoaded: settingsLoaded,
                accessOK: accessOK),
            flags: due, days: 7, messages: [message("here")], sent: [message("sent:here")], now: now,
            inFlight: inFlight)
    }

    @Test func aSweepRoutesEachHashToWhereItLives() {
        #expect(
            sweep() == [
                TrashPurge(hash: "gone", removal: .flagOnly), TrashPurge(hash: "here", removal: .mailbox),
                TrashPurge(hash: "sent:gone", removal: .flagOnly), TrashPurge(hash: "sent:here", removal: .sentStore),
            ])
    }

    @Test func aSweepDecidesNothingUntilEverythingHasAnswered() {
        #expect(sweep(flagsReady: false).isEmpty)
        #expect(sweep(mailLoaded: false).isEmpty)
        #expect(sweep(sentLoaded: false).isEmpty)
        #expect(sweep(settingsLoaded: false).isEmpty)
        #expect(sweep(accessOK: false).isEmpty)
    }

    @Test func aSweepLeavesWhatTheLastOneIsStillRemoving() {
        #expect(!sweep(inFlight: ["here"]).contains { $0.hash == "here" })
    }
}

@Suite struct Formatting {
    @Test func bytesUseBinaryUnitsWithBinaryLabels() {
        #expect(MailView.formatBytes(0) == "0 B")
        #expect(MailView.formatBytes(1023) == "1023 B")
        #expect(MailView.formatBytes(1024) == "1 KiB")
        #expect(MailView.formatBytes(1536) == "1.5 KiB")
        #expect(MailView.formatBytes(Int(8.2 * 1024 * 1024)) == "8.2 MiB")
        #expect(MailView.formatBytes(Int(3.8 * 1024 * 1024 * 1024)) == "3.8 GiB")
        #expect(MailView.formatBytes(150 * 1024 * 1024) == "150 MiB")
    }

    @Test func aTieRoundsUpAsToFixedDoes() {
        #expect(MailView.formatBytes(1280) == "1.3 KiB")
    }

    @Test func whenIsATimeTodayAMonthDayThisYearAndAShortYearBefore() throws {
        let zone = try #require(TimeZone(identifier: "America/New_York"))
        let locale = Locale(identifier: "en_US")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        func seconds(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ min: Int = 0) throws -> Int64 {
            let date = try #require(
                calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min)))
            return Int64(date.timeIntervalSince1970)
        }
        let now = Date(timeIntervalSince1970: TimeInterval(try seconds(2026, 9, 3, 12)))
        func when(_ s: Int64) -> String { MailView.formatWhen(s, now: now, locale: locale, timeZone: zone) }
        #expect(when(try seconds(2026, 9, 3, 9, 41)) == "9:41 AM")
        #expect(when(try seconds(2026, 2, 14)) == "Feb 14")
        #expect(when(try seconds(2025, 2, 14)) == "Feb 14, 25")
    }
}

@Suite struct FirstRun {
    private func fresh(
        mailLoaded: Bool = true, sentLoaded: Bool = true, mailCount: Int = 0, sentCount: Int = 0,
        explained: Bool = false
    ) -> FirstRunInput {
        FirstRunInput(
            mailLoaded: mailLoaded, sentLoaded: sentLoaded, mailCount: mailCount, sentCount: sentCount,
            explained: explained)
    }

    @Test func showsForAMailboxThatHasNeverHadMail() { #expect(MailView.isFirstRun(fresh())) }

    @Test func waitsForBothListings() {
        #expect(!MailView.isFirstRun(fresh(mailLoaded: false)))
        #expect(!MailView.isFirstRun(fresh(sentLoaded: false)))
    }

    @Test func stepsAsideOnceAnyMailExists() {
        #expect(!MailView.isFirstRun(fresh(mailCount: 1)))
        #expect(!MailView.isFirstRun(fresh(sentCount: 1)))
    }

    @Test func leavesTheExplainingToWhateverAlreadyExplains() {
        #expect(!MailView.isFirstRun(fresh(explained: true)))
    }
}

/// What the reader checks do to a list. None of this exists in the browser, which draws the claimed
/// address whatever the directory said.
@Suite struct WithheldRows {
    private func input(
        _ messages: [MailPreview], folder: MailFolder = .inbox, contacts: [ContactRecord] = [],
        query: String = "", kind: @escaping (String, String) -> SenderKind = { _, _ in .dmcn }
    ) -> MailFolderInput {
        MailFolderInput(
            folder: folder, messages: messages, sent: [], flags: [:], labels: [], folders: [], contacts: contacts,
            filter: FilterList(), address: me, query: MailSearch.parseQuery(query), kind: kind,
            now: Date(timeIntervalSince1970: 1_780_000_000), locale: Locale(identifier: "en_US"),
            timeZone: TimeZone(identifier: "UTC")!)
    }

    private let ada = ContactRecord(address: "ada@sample.example", name: "Ada Lovelace", fingerprint: "fp")

    @Test(arguments: [
        (MessageSummary.Sender.mismatch(claimed: "ada@sample.example"), "Possibly forged sender"),
        (MessageSummary.Sender.disowned(claimed: "ada@sample.example"), "Sender not vouched for"),
    ])
    func theClaimedAddressNeverReadsAsWhoItIsFrom(verdict: MessageSummary.Sender, label: String) throws {
        let forged = MailPreview(
            hash: "a", senderAddress: "ada@sample.example", recipientAddress: me, to: [me], subject: "Pay this",
            senderDisplay: "Ada", sentAt: 1_780_000_000, sender: verdict)
        let row = try #require(MailFolderView(input([forged], contacts: [ada])).rows.first)
        #expect(row.who == label)
        #expect(row.subject == "Pay this")
        #expect(row.snippet == nil)
        #expect(!row.trustedSender)
        #expect(row.kind == .unknown)
        #expect(!row.isNewSender)
    }

    @Test func anUnopenedRowIsKeptAndSaysSo() throws {
        let row = try #require(
            MailFolderView(input([MailPreview(hash: "a", senderAddress: "", sender: .unreadable)])).rows.first)
        #expect(row.who == "Couldn't open this message")
        #expect(row.subject == "(no subject)")
        #expect(row.when == "")
        #expect(row.kind == .unknown)
    }

    @Test func aForgeryIsNotFoundByTheNameItClaims() {
        let forged = MailPreview(
            hash: "a", senderAddress: "ada@sample.example", recipientAddress: me, to: [me], subject: "Pay this",
            sender: .mismatch(claimed: "ada@sample.example"))
        #expect(MailFolderView(input([forged], folder: .search, contacts: [ada], query: "from:ada")).rows.isEmpty)
        #expect(MailFolderView(input([forged], folder: .search, contacts: [ada], query: "lovelace")).rows.isEmpty)
        #expect(MailFolderView(input([forged], folder: .search, query: "subject:pay")).rows.count == 1)
    }

    @Test func aWithheldMessageIsNeverACandidateForTheIndex() {
        let forged = MailPreview(hash: "a", senderAddress: "x@y.z", sentAt: 1, sender: .mismatch(claimed: "x@y.z"))
        let fine = MailPreview(hash: "b", senderAddress: "x@y.z", sentAt: 2)
        let candidates = MailSearch.candidates(messages: [forged, fine], sent: [], filter: nil, address: me)
        #expect(
            candidates == [SearchCandidate(hash: "a", sentAt: 1, blocked: true), SearchCandidate(hash: "b", sentAt: 2)])
    }

    @Test func aContactAnswersKindWithoutTheDirectory() throws {
        let m = MailPreview(hash: "a", senderAddress: "ada@sample.example", recipientAddress: me, to: [me])
        let view = MailFolderView(
            input(
                [m], contacts: [ada],
                kind: { _, _ in
                    Issue.record("a contact shouldn't need the directory")
                    return .unknown
                }))
        #expect(try #require(view.rows.first).kind == .dmcn)
    }
}

@Suite struct DeletedOrder {
    @Test func mostRecentlyDeletedFirstWhateverWasSentFirst() {
        let old = MailPreview(hash: "old", senderAddress: "x@y.z", recipientAddress: me, to: [me], sentAt: 100)
        let new = MailPreview(hash: "new", senderAddress: "x@y.z", recipientAddress: me, to: [me], sentAt: 200)
        let sent = MailPreview(hash: "sent:s", senderAddress: me, recipientAddress: me, to: ["x@y.z"], sentAt: 150)
        let view = MailFolderView(
            MailFolderInput(
                folder: .deleted, messages: [new, old], sent: [sent],
                flags: [
                    "old": FlagRecord(trashedAt: 30), "new": FlagRecord(trashedAt: 10),
                    "sent:s": FlagRecord(trashedAt: 20),
                ],
                labels: [], folders: [], contacts: [], filter: nil, address: me))
        #expect(view.rows.map(\.id) == ["old", "sent:s", "new"])
    }
}

@Suite struct RailRules {
    private let draft = DraftSummary(
        id: "d", from: me, to: [], cc: [], bcc: [], subject: "", snippet: "", updatedAt: 0, attachmentCount: 0)

    @Test func draftsShowsOnlyOnceKnownAndNotEmpty() {
        #expect(!MailView.hasDrafts(draftsLoaded: false, drafts: [draft]))
        #expect(!MailView.hasDrafts(draftsLoaded: true, drafts: []))
        #expect(MailView.hasDrafts(draftsLoaded: true, drafts: [draft]))
    }

    private func hasDeleted(
        flagsReady: Bool = true, filterReady: Bool = true, mailLoaded: Bool = true, sentLoaded: Bool = true,
        filter: FilterList? = nil, control: Set<String> = []
    ) -> Bool {
        MailView.hasDeleted(
            flagsReady: flagsReady, filterReady: filterReady, mailLoaded: mailLoaded, sentLoaded: sentLoaded,
            messages: [message("a")], sent: [], address: me, flags: ["a": FlagRecord(trashedAt: 1)], filter: filter,
            control: control)
    }

    @Test func deletedWaitsForEveryAnswer() {
        #expect(hasDeleted())
        #expect(!hasDeleted(flagsReady: false))
        #expect(!hasDeleted(filterReady: false))
        #expect(!hasDeleted(mailLoaded: false))
        #expect(!hasDeleted(sentLoaded: false))
    }

    @Test func deletedDoesNotShowForAnEmptyView() {
        #expect(!hasDeleted(filter: FilterList(senders: ["alice@example.com"])))
        #expect(!hasDeleted(control: ["Hello"]))
    }

    @Test func theLastOneGoingTakesTheViewBackToTheInbox() {
        func after(_ folder: MailFolder, draftCount: Int = 1, known: Bool = true, deleted: Bool = true) -> MailFolder {
            MailView.folderAfterRailChange(
                folder, draftsLoaded: known, draftCount: draftCount, deletedKnown: known, hasDeleted: deleted)
        }
        #expect(after(.drafts, draftCount: 0) == .inbox)
        #expect(after(.drafts, draftCount: 0, known: false) == .drafts)
        #expect(after(.deleted, deleted: false) == .inbox)
        #expect(after(.deleted, known: false, deleted: false) == .deleted)
        #expect(after(.sent, draftCount: 0, deleted: false) == .sent)
    }
}

@Suite struct AllPages {
    /// A relay with a page size, listing oldest first as an older relay does.
    actor Paged: MailboxService {
        let inner: SampleMailbox
        let pageSize: Int
        var fails = false
        var lookups: [String] = []
        init(_ inner: SampleMailbox, pageSize: Int) {
            self.inner = inner
            self.pageSize = pageSize
        }
        func failNextPages() { fails = true }

        func list(_ keys: some AccountKeys, limit: Int, cursor: String?) async throws -> MailboxPage {
            let all = try await inner.list(keys, limit: limit, cursor: nil).items.reversed() as [MailboxPage.Item]
            let start = Int(cursor ?? "0") ?? 0
            if fails, start > 0 { throw APIError(status: 500, message: "boom") }
            let end = min(start + pageSize, all.count)
            return MailboxPage(items: Array(all[start..<end]), nextCursor: end < all.count ? String(end) : nil)
        }
        func body(hash: String, keys: some AccountKeys) async throws -> Dmcn_Relay_MailboxBody {
            try await inner.body(hash: hash, keys: keys)
        }
        func lookup(_ address: String) async throws -> IdentityLookup {
            lookups.append(address)
            return try await inner.lookup(address)
        }
        func signOut() async {}
    }

    /// Collects what `onFirstPage` was handed.
    actor Drawn {
        var pages: [[MailPreview]] = []
        func add(_ page: [MailPreview]) { pages.append(page) }
    }

    @Test func everyPageIsListedNewestFirstWithItsVerdicts() async throws {
        let sample = try SampleMailbox()
        let service = Paged(sample, pageSize: 2)
        let inbox = Inbox(service: service, keys: sample.keys)
        let drawn = Drawn()
        let all = try await inbox.allPreviews(pageSize: 2, onFirstPage: { await drawn.add($0) })

        #expect(all.count == 6)
        let readable = all.filter { $0.sender != .unreadable }
        #expect(readable.map(\.sentAt) == readable.map(\.sentAt).sorted(by: >))
        #expect(all.last?.sender == .unreadable)
        let forged = try #require(all.first { $0.subject == "A forged sender" })
        #expect(forged.contentsWithheld)
        #expect(forged.snippet.isEmpty)
        #expect(forged.sender == .mismatch(claimed: "ada@sample.example"))
        #expect(all.first { $0.subject == "A message written to someone else" }?.misaddressed == true)
        #expect(await drawn.pages.map(\.count) == [2])
        // Ada wrote several of them; the directory is asked once for the whole listing.
        #expect(await service.lookups.filter { $0 == "ada@sample.example" }.count == 1)
    }

    @Test func aPageThatFailsFailsTheListing() async throws {
        let sample = try SampleMailbox()
        let service = Paged(sample, pageSize: 2)
        await service.failNextPages()
        await #expect(throws: APIError.self) {
            _ = try await Inbox(service: service, keys: sample.keys).allPreviews(pageSize: 2)
        }
    }

    @Test func onePageForAPageLimit() async throws {
        let sample = try SampleMailbox()
        let service = Paged(sample, pageSize: 4)
        let (previews, next) = try await Inbox(service: service, keys: sample.keys).previews(limit: 4)
        #expect(previews.count == 4)
        #expect(next == "4")
    }

    @Test func aWithheldBodyIsNotFetchedForSearch() async throws {
        let sample = try SampleMailbox()
        let inbox = Inbox(service: sample, keys: sample.keys)
        let all = try await inbox.allPreviews()
        let forged = try #require(all.first { $0.subject == "A forged sender" })
        await #expect(throws: ContentsWithheldError.self) { _ = try await inbox.searchBody(of: forged) }
        #expect(try await inbox.open(forged) == .withheld)
        let good = try #require(all.first { $0.subject == "A verified sender" })
        #expect(try await inbox.searchBody(of: good).text.hasPrefix("The directory lists"))
    }

    @Test func aSentRowNotSignedByThisAccountReadsAsUnconfirmed() {
        func preview(signed: Bool) -> MailPreview {
            MailPreview(
                sent: SentPreview(
                    hash: "sent:a", messageID: "a", threadID: "t", senderAddress: me, senderPublicKey: "",
                    senderDisplay: "",
                    recipientAddress: me, to: [], cc: [], bcc: [], subject: "", snippet: "", sentAt: 0, bodySize: 0,
                    attachmentCount: 0, signedByThisAccount: signed))
        }
        #expect(preview(signed: true).sender == .verified(me))
        #expect(preview(signed: false).sender == .unverified(me))
    }
}
