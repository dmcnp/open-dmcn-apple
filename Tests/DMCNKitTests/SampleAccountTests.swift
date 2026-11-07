// The sample account, read through the real stores and the real list code, so a state that stops
// showing is caught here rather than by someone noticing a screen is empty.

import DMCNKitSamples
import Foundation
import Testing
@testable import DMCNKit

private typealias Subject = SampleAccount.Subject

private struct Loaded {
    let account: SampleAccount
    let messages: [MailPreview]
    let sent: [MailPreview]
    let flags: [String: FlagRecord]
    let doc: LabelsDoc
    let contacts: [ContactRecord]
    let filter: FilterList?
    let address: String

    static func load() async throws -> Loaded {
        let account = try await SampleAccount()
        await account.labels.refresh()
        await account.filter.refresh()
        return Loaded(
            account: account, messages: try await account.inbox.allPreviews(),
            sent: try await account.sent.list().map(MailPreview.init(sent:)), flags: try await account.flags.list(),
            doc: await account.labels.doc, contacts: await account.contacts.refresh(),
            filter: await account.filter.filter, address: account.keys.address)
    }

    func view(_ folder: MailFolder, query: String = "", hits: SearchHits? = nil) -> MailFolderView {
        MailFolderView(
            MailFolderInput(
                folder: folder, messages: messages, sent: sent, flags: flags, labels: doc.labels, folders: doc.folders,
                contacts: contacts, filter: filter, address: address, query: MailSearch.parseQuery(query), hits: hits))
    }

    func row(_ folder: MailFolder, _ subject: String) -> MailRow? {
        view(folder).rows.first { $0.subject == subject }
    }
}

@Suite struct TheSampleAccount {
    @Test func theBareMailboxStillHasOneMessagePerSenderState() async throws {
        let sample = try SampleMailbox()
        #expect(try await Inbox(service: sample, keys: sample.keys).summaries().summaries.count == 6)
    }

    @Test func everyReaderCheckStateIsThere() async throws {
        let a = try await Loaded.load()
        let verdicts = a.messages.map(\.sender)
        #expect(verdicts.contains(.unreadable))
        #expect(verdicts.contains(.mismatch(claimed: "ada@sample.example")))
        #expect(verdicts.contains(.disowned(claimed: "former@sample.example")))
        #expect(verdicts.contains(.unverified("someone@elsewhere.example")))
        #expect(verdicts.contains(.verified("ada@sample.example")))
        #expect(a.messages.contains { $0.misaddressed })
    }

    @Test func theInboxShowsEachKindOfRow() async throws {
        let a = try await Loaded.load()
        let read = try #require(a.row(.inbox, Subject.read))
        #expect(!read.isUnread)
        #expect(read.trustedSender)
        #expect(read.who == "Ada Lovelace")
        #expect(read.snippet != nil)
        #expect(a.row(.inbox, Subject.starred)?.isStarred == true)
        #expect(a.row(.inbox, Subject.starred)?.isUnread == true)
        #expect(a.row(.inbox, Subject.labelled) != nil)

        let stranger = try #require(a.row(.inbox, Subject.newSender))
        #expect(stranger.isNewSender)
        #expect(stranger.snippet == nil)

        let changed = try #require(a.row(.inbox, Subject.changedKey))
        #expect(changed.isNewSender)
        #expect(!changed.trustedSender)

        let legacy = try #require(a.row(.inbox, Subject.legacyContact))
        #expect(legacy.who == "Pen Friend")
        #expect(legacy.kind == .legacy)

        #expect(a.row(.inbox, Subject.toYourself) != nil)
        #expect(a.row(.inbox, "(no subject)") != nil)
        let chrome = try #require(a.row(.inbox, Subject.newsletter)?.snippet)
        #expect(chrome.hasPrefix("This week What's new"))
        #expect(a.row(.inbox, "A forged sender")?.who == "Possibly forged sender")
        #expect(a.row(.inbox, "(no subject)")?.who != nil)
    }

    @Test func whatIsFiledElsewhereIsNotInTheInbox() async throws {
        let a = try await Loaded.load()
        for subject in [Subject.archived, Subject.filed, Subject.deleted, Subject.blocked, Subject.olderSent] {
            #expect(a.row(.inbox, subject) == nil, "\(subject)")
        }
    }

    @Test func foldersAndLabels() async throws {
        let a = try await Loaded.load()
        let projects = try #require(a.doc.folders.first { $0.name == SampleAccount.folderName })
        let empty = try #require(a.doc.folders.first { $0.name == SampleAccount.emptyFolderName })
        let work = try #require(a.doc.labels.first { $0.name == SampleAccount.labelName })
        #expect(a.view(.folder(projects.id)).rows.map(\.subject) == [Subject.filed])
        #expect(a.view(.folder(projects.id)).folderTitle == "Projects")
        #expect(a.view(.folder(empty.id)).rows.isEmpty)
        #expect(a.view(.folder(empty.id)).emptyText == "This folder is empty.")
        #expect(a.view(.label(work.id)).rows.map(\.subject) == [Subject.labelled])
        #expect(a.view(.archive).rows.map(\.subject) == [Subject.archived])
        #expect(a.view(.starred).rows.map(\.subject) == [Subject.starred])
    }

    @Test func sentFoldsInTheLegacyCopy() async throws {
        let a = try await Loaded.load()
        let rows = a.view(.sent).rows
        #expect(
            rows.contains { $0.subject == Subject.sentToContact && $0.who == "To: Ada Lovelace" && $0.trustedSender })
        let several = try #require(rows.first { $0.subject == Subject.sentToSeveral })
        #expect(several.who == "To: Ada Lovelace, someone@elsewhere.example, Grace Hopper")
        #expect(rows.contains { $0.subject == Subject.olderSent })
        #expect(rows.allSatisfy { $0.isSent })
    }

    /// The relay's key check refuses the colon in `flags/sent:<id>`, so no client can mark a Sent
    /// message, and the sample can't show one in Deleted. The browser swallows this refusal. When
    /// open-dmcn settles a key that works, this fails, and the sample should add that state.
    @Test func aSentMessageCannotBeFlaggedOnARelay() async throws {
        let a = try await Loaded.load()
        let sent = try #require(a.sent.first)
        await #expect(throws: APIError.self) { try await a.account.flags.trash(sent.hash) }
    }

    @Test func deletedHoldsTheDeletedMessage() async throws {
        let a = try await Loaded.load()
        let rows = a.view(.deleted).rows
        #expect(rows.map(\.subject) == [Subject.deleted])
        #expect(rows.allSatisfy { $0.inDeleted })
        #expect(
            MailView.hasDeleted(
                flagsReady: true, filterReady: true, mailLoaded: true, sentLoaded: true, messages: a.messages,
                sent: a.sent, address: a.address, flags: a.flags, filter: a.filter))
    }

    @Test func nothingDeletedIsDueYet() async throws {
        let a = try await Loaded.load()
        let due = MailView.expiredTrash(a.flags, days: 7, now: Int64(Date().timeIntervalSince1970 * 1000))
        #expect(due.isEmpty)
    }

    @Test func theDraftIsThereAndOpens() async throws {
        let a = try await Loaded.load()
        let drafts = try await a.account.drafts.list()
        #expect(drafts.map(\.subject) == [Subject.draft])
        #expect(MailView.hasDrafts(draftsLoaded: true, drafts: drafts))
        let loaded = try #require(try await a.account.drafts.load(drafts[0].id))
        #expect(loaded.content.to == ["ada@sample.example"])
    }

    @Test func theUnreadBadgeLeavesOutWhatIsNotWaiting() async throws {
        let a = try await Loaded.load()
        let count = MailView.countUnread(a.messages, address: a.address, flags: a.flags, filter: a.filter)
        let inbox = a.view(.inbox).rows.filter(\.isUnread).count
        #expect(count == inbox + a.view(.folder(a.doc.folders[0].id)).rows.filter(\.isUnread).count)
    }

    @Test func searchFindsHeadersWithNoIndexAndBodiesWithOne() async throws {
        let a = try await Loaded.load()
        #expect(a.view(.search, query: "from:ada subject:starred").rows.map(\.subject) == [Subject.starred])
        #expect(a.view(.search, query: SampleAccount.bodyOnlyWord).rows.isEmpty)

        let index = try SearchIndex.open(keys: a.account.keys, storage: InMemorySearchIndexStorage())
        let search = MailSearchSession(
            index: index, inbox: a.account.inbox, sent: a.account.sent, runnable: { true })
        await search.update(
            messages: a.messages, sent: a.sent, filter: a.filter, address: a.address, complete: true)
        await search.settled()
        let progress = await search.progress()
        #expect(progress.total == a.messages.count + a.sent.count - 4)  // forged, disowned, unreadable, blocked
        #expect(progress.indexed == progress.total)

        let query = MailSearch.parseQuery(SampleAccount.bodyOnlyWord)
        let hits = await search.lookup(query)
        #expect(
            a.view(.search, query: SampleAccount.bodyOnlyWord, hits: hits).rows.map(\.subject) == [Subject.attachment])
        let pdf = await search.lookup(MailSearch.parseQuery("filename:*.pdf"))
        #expect(a.view(.search, query: "filename:*.pdf", hits: pdf).rows.map(\.subject) == [Subject.attachment])
        await search.stop()
    }

    @Test func aForgedBodyNeverReachesTheIndex() async throws {
        let a = try await Loaded.load()
        let index = try SearchIndex.open(keys: a.account.keys, storage: InMemorySearchIndexStorage())
        let search = MailSearchSession(index: index, inbox: a.account.inbox, sent: a.account.sent, runnable: { true })
        await search.update(messages: a.messages, sent: a.sent, filter: a.filter, address: a.address, complete: true)
        await search.settled()
        #expect(try await index.wordHits("never").isEmpty)
        await search.stop()
    }
}
