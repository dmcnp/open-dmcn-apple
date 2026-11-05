// Fixtures/browser-mail-view.json was written by the browser client's real code under node: the
// real InboxMain rendered to markup with its state hooks returning a fixed account, and the real
// lib/mailView, trash, unread, format, accounts, trust/displayName and search modules, across
// locales and time zones. These tests read the same account through the Swift path, so a row, a
// title or a piece of copy that differs from the browser's shows up here.

import Foundation
import Testing
@testable import DMCNKit

private struct Fixture: Decodable {
    struct Preview: Decodable {
        let hash, messageId, threadId, senderAddress, senderPublicKey, recipientAddress: String
        let to, cc, bcc: [String]
        let subject, snippet, senderDisplay: String
        let sentAt: Int64
        let bodySize: UInt64
        let attachmentCount: UInt32
        let deliveredTo: String?

        var preview: MailPreview {
            MailPreview(
                hash: hash, messageID: messageId, threadID: threadId, senderAddress: senderAddress,
                senderPublicKey: senderPublicKey, recipientAddress: recipientAddress, to: to, cc: cc, bcc: bcc,
                subject: subject, snippet: snippet, senderDisplay: senderDisplay, sentAt: sentAt, bodySize: bodySize,
                attachmentCount: attachmentCount, deliveredTo: deliveredTo)
        }
    }

    struct Account: Decodable {
        let address: String
        let messages, sent: [Preview]
        let flags: [String: FlagRecord]
        let labels: [LabelDef]
        let folders: [FolderDef]
        let contacts: [ContactRecord]
        let filter: FilterList
    }

    struct Hits: Decodable {
        let words, files: [String: [String]]
    }

    struct Row: Decodable {
        let who, subject, when, kindAsked: String
        let snippet, deliveredTo, place: String?
        let trustedSender, isUnread, isStarred, isNewSender, inDeleted: Bool
        /// Unknown where the row offers no Archive button to read it from.
        let isSent, inArchive: Bool?
    }

    struct Expected: Decodable {
        let title: String
        let count, deletedNote, searchNote, emptyText, emptyIcon: String?
        let firstRun: Bool
        let rows: [Row]
    }

    struct Progress: Decodable {
        let indexed, total: Int
    }

    struct Case: Decodable {
        let name, folder: String
        let query: String?
        let hits: Hits?
        let control: [String]?
        let flagsReady, labelsReady, filterReady, mailLoaded, sentLoaded: Bool?
        let noFilter, empty, keepSent, gettingStartedVisible: Bool?
        let filter: FilterList?
        let trashDays: Int?
        let progress: Progress?
        let accessState: String?
        let expected: Expected
    }

    struct Clause: Decodable {
        let neg: Bool
        let kind: String
        let value: String?
        let glob: Bool?
        let at: Int64?
    }

    struct Query: Decodable {
        let q: String
        let clauses: [Clause]
        let words, filenames: [String]
    }

    struct Shard: Decodable {
        struct Entry: Decodable {
            let token: String
            let docs: [Int]
            init(from decoder: any Decoder) throws {
                var c = try decoder.unkeyedContainer()
                token = try c.decode(String.self)
                docs = try c.decode([Int].self)
            }
        }
        let entries: [Entry]
        let hex: String
    }

    struct PerMessage: Decodable {
        let hash: String
        let recipients: [String]
        let received, shownInDeleted: Bool
        let place: String?
    }

    struct Unread: Decodable {
        let noFilter, noAddress: Bool?
        let n: Int
    }

    struct Stamp: Decodable {
        let sec: Int64
        let date, time, when: String
    }

    struct LocaleRun: Decodable {
        let locale, zone: String
        let now: Int64
        let stamps: [Stamp]
        let days: [[Value]]
        let purge: [[Value]]
        let number: [String]
    }

    /// A cell of a mixed array.
    enum Value: Decodable {
        case int(Int64), double(Double), string(String), null, strings([String])

        init(from decoder: any Decoder) throws {
            let c = try decoder.singleValueContainer()
            if c.decodeNil() {
                self = .null
            } else if let v = try? c.decode(Int64.self) {
                self = .int(v)
            } else if let v = try? c.decode(Double.self) {
                self = .double(v)
            } else if let v = try? c.decode(String.self) {
                self = .string(v)
            } else {
                self = .strings(try c.decode([String].self))
            }
        }

        var string: String? {
            if case .string(let v) = self { return v }
            return nil
        }
        var int: Int64? {
            if case .int(let v) = self { return v }
            return nil
        }
        var double: Double? {
            switch self {
            case .int(let v): Double(v)
            case .double(let v): v
            default: nil
            }
        }
        var strings: [String]? {
            if case .strings(let v) = self { return v }
            return nil
        }
    }

    let now: Int64
    let address: String
    let account: Account
    let cases: [Case]
    let previewText, initials, fold, tokens, cjkWords, shardOf, display: [[Value]]
    let bytes, labels, globs, filenames, trashDays, expired: [[Value]]
    let queries: [Query]
    let shards: [Shard]
    let perMessage: [PerMessage]
    let unread: [Unread]
    let locales: [LocaleRun]

    static func load() throws -> Fixture {
        let url = try #require(
            Bundle.module.url(forResource: "browser-mail-view", withExtension: "json", subdirectory: "Fixtures"))
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }
}

private let newYork = TimeZone(identifier: "America/New_York")!
private let usEnglish = Locale(identifier: "en_US")

private func folder(_ name: String) -> MailFolder {
    if name.hasPrefix("label:") { return .label(String(name.dropFirst(6))) }
    if name.hasPrefix("folder:") { return .folder(String(name.dropFirst(7))) }
    switch name {
    case "inbox": return .inbox
    case "starred": return .starred
    case "sent": return .sent
    case "archive": return .archive
    case "deleted": return .deleted
    case "search": return .search
    default: fatalError("no such folder in the fixture: \(name)")
    }
}

/// Who the list asked the directory about, in order.
private final class Asked: @unchecked Sendable {
    var calls: [String] = []
}

private func view(_ f: Fixture, _ c: Fixture.Case, asked: Asked) -> MailFolderView {
    let empty = c.empty == true
    let hits = c.hits.map { h in
        SearchHits(words: h.words.mapValues(Set.init), files: h.files.mapValues(Set.init))
    }
    let locked = ["suspended", "closed", "unapproved-device"].contains(c.accessState ?? "ok")
    return MailFolderView(
        MailFolderInput(
            folder: folder(c.folder), messages: empty ? [] : f.account.messages.map(\.preview),
            sent: empty && c.keepSent != true ? [] : f.account.sent.map(\.preview),
            flags: empty ? [:] : f.account.flags,
            labels: f.account.labels, folders: f.account.folders, contacts: f.account.contacts,
            filter: c.noFilter == true ? nil : (c.filter ?? f.account.filter), address: f.address,
            query: MailSearch.parseQuery(c.query ?? "", timeZone: newYork), hits: hits,
            progress: c.progress.map { SearchProgress(indexed: $0.indexed, total: $0.total) },
            kind: {
                asked.calls.append("\($0)|\($1)"); return .legacy
            }, flagsReady: c.flagsReady ?? true,
            labelsReady: c.labelsReady ?? true, filterReady: c.filterReady ?? true, mailLoaded: c.mailLoaded ?? true,
            sentLoaded: c.sentLoaded ?? true, control: Set(c.control ?? []),
            keepDays: MailView.trashDays(c.trashDays.map(Double.init)), locked: locked,
            gettingStartedVisible: c.gettingStartedVisible ?? false,
            now: Date(timeIntervalSince1970: TimeInterval(f.now) / 1000), locale: usEnglish, timeZone: newYork))
}

private func icon(_ icon: EmptyIcon) -> String {
    switch icon {
    case .archive: "archive"
    case .star: "star"
    case .trash: "trash"
    case .inbox: "inbox"
    case .search: "search"
    }
}

@Suite struct BrowserMailViewFixture {
    @Test func everyListMatchesTheBrowsersRows() throws {
        let f = try Fixture.load()
        for c in f.cases {
            let asked = Asked()
            let got = view(f, c, asked: asked)
            let book = ContactBook(f.account.contacts)
            let want = c.expected
            let comment = Comment(rawValue: c.name)
            #expect(got.folderTitle == want.title, comment)
            #expect(got.rowCountText == want.count, comment)
            #expect(got.searchProgressNote == want.searchNote, comment)
            #expect(got.isFirstRun == want.firstRun, comment)
            if let note = want.deletedNote { #expect(got.deletedNote == note, comment) }
            if let text = want.emptyText {
                #expect(got.emptyText == text, comment)
                #expect(want.emptyIcon == icon(got.emptyIcon), comment)
            }
            try #require(got.rows.count == want.rows.count, comment)
            for (row, expected) in zip(got.rows, want.rows) {
                let about = Comment(rawValue: "\(c.name): \(expected.subject)")
                #expect(row.who == expected.who, about)
                #expect(row.subject == expected.subject, about)
                #expect(row.snippet == expected.snippet, about)
                #expect(row.when == expected.when, about)
                // The browser's hook takes the contact's word first, and only then the directory's.
                let person = String(expected.kindAsked.prefix { $0 != "|" })
                if let contact = book.contact(for: person), SenderKind.of(contact: contact) != .unknown {
                    #expect(row.kind == SenderKind.of(contact: contact), about)
                } else {
                    #expect(row.kind == .legacy, about)
                    #expect(asked.calls.contains(expected.kindAsked), about)
                }
                #expect(row.trustedSender == expected.trustedSender, about)
                #expect(row.isUnread == expected.isUnread, about)
                #expect(row.isStarred == expected.isStarred, about)
                #expect(row.isNewSender == expected.isNewSender, about)
                if let sent = expected.isSent { #expect(row.isSent == sent, about) }
                if let archived = expected.inArchive { #expect(row.inArchive == archived, about) }
                #expect(row.inDeleted == expected.inDeleted, about)
                #expect(row.deliveredTo == expected.deliveredTo, about)
                #expect(row.place == expected.place, about)
            }
        }
    }

    @Test func placesRecipientsAndCounts() throws {
        let f = try Fixture.load()
        let context = PlaceContext(
            address: f.address, flags: f.account.flags, filter: f.account.filter, control: ["dmcn-control"],
            knownFolderIDs: ["f1", "f2", "f3"])
        let all = (f.account.messages + f.account.sent).map(\.preview)
        for (m, want) in zip(all, f.perMessage) {
            #expect(m.hash == want.hash)
            #expect(MailView.recipientsOf(m) == want.recipients, "\(m.subject)")
            #expect(MailView.isReceivedForMe(m, address: f.address) == want.received, "\(m.subject)")
            let place = MailView.placeOf(m, context).map { (p: MailPlace) -> String in
                switch p {
                case .inbox: "inbox"
                case .archive: "archive"
                case .sent: "sent"
                case .deleted: "deleted"
                case .folder(let id): "folder:" + id
                }
            }
            #expect(place == want.place, "\(m.subject)")
            let shown = MailView.shownInDeleted(
                m, address: f.address, flags: f.account.flags, filter: f.account.filter, control: ["dmcn-control"])
            #expect(shown == want.shownInDeleted, "\(m.subject)")
        }
        let mail = f.account.messages.map(\.preview)
        for want in f.unread {
            let count = MailView.countUnread(
                mail, address: want.noAddress == true ? nil : f.address, flags: f.account.flags,
                filter: want.noFilter == true ? nil : f.account.filter)
            #expect(count == want.n)
        }
    }

    @Test func text() throws {
        let f = try Fixture.load()
        for pair in f.previewText {
            #expect(MailView.previewText(pair[0].string!) == pair[1].string, "\(pair[0].string!)")
        }
        for pair in f.initials { #expect(MailView.initialsOf(pair[0].string!) == pair[1].string) }
        for pair in f.display { #expect(DisplayName.sanitize(pair[0].string!) == pair[1].string) }
        for row in f.labels {
            let got = DisplayName.senderLabel(
                address: row[0].string!, contactName: row[1].string!, wireDisplay: row[2].string!)
            #expect(got.primary == row[3].string)
        }
    }

    @Test func bytes() throws {
        for pair in try Fixture.load().bytes {
            let n = Int(pair[0].int!)
            #expect(MailView.formatBytes(n) == pair[1].string, "\(n)")
        }
    }

    @Test func retention() throws {
        let f = try Fixture.load()
        for pair in f.trashDays { #expect(MailView.trashDays(pair[0].double) == Int(pair[1].int!)) }
        for pair in f.expired {
            #expect(MailView.expiredTrash(f.account.flags, days: Int(pair[0].int!), now: f.now) == pair[1].strings)
        }
    }

    @Test func datesAcrossLocalesAndZones() throws {
        for run in try Fixture.load().locales {
            let locale = Locale(identifier: run.locale)
            let zone = TimeZone(identifier: run.zone)!
            let now = Date(timeIntervalSince1970: TimeInterval(run.now) / 1000)
            let label = "\(run.locale) \(run.zone)"
            for stamp in run.stamps {
                let date = MailView.formatDate(stamp.sec, locale: locale, timeZone: zone)
                let time = MailView.formatTime(stamp.sec, locale: locale, timeZone: zone)
                let when = MailView.formatWhen(stamp.sec, now: now, locale: locale, timeZone: zone)
                #expect(time == stamp.time, "\(label)")
                // Node's CLDR writes "Sept" for en_GB and a comma after the German weekday; the one
                // under Foundation here doesn't. Each platform renders with its own data, so those
                // two locales can only be held to the time.
                if !["en_GB", "de_DE"].contains(run.locale) {
                    #expect(date == stamp.date, "\(label)")
                    #expect(when == stamp.when, "\(label)")
                }
            }
            for day in run.days {
                let parsed = MailSearch.parseQuery("after:" + day[0].string!, timeZone: zone).clauses[0].kind
                if let at = day[1].int {
                    #expect(parsed == .after(at), "\(label) \(day[0].string!)")
                } else {
                    guard case .word = parsed else {
                        Issue.record("\(day[0].string!) should be a word in \(label)")
                        continue
                    }
                }
            }
            for row in run.purge {
                let got = MailView.purgeWhen(
                    row[0].int!, days: Int(row[1].int!), now: row[2].int!, timeZone: zone)
                #expect(got == row[3].string, "\(label) \(row[0].int!) \(row[2].int!)")
            }
            let note = MailView.searchProgressNote(
                folder: .search, query: ParsedQuery(words: ["x"]),
                progress: SearchProgress(indexed: 1234, total: 5_678_901),
                locale: locale)
            #expect(note?.contains("\(run.number[0]) of \(run.number[1]) ") == true, "\(label)")
        }
    }

    @Test func foldAndTokens() throws {
        let f = try Fixture.load()
        for pair in f.fold { #expect(MailSearch.fold(pair[0].string!) == pair[1].string, "\(pair[0].string!)") }
        for pair in f.tokens { #expect(MailSearch.tokenize(pair[0].string!) == pair[1].strings, "\(pair[0].string!)") }
        for pair in f.shardOf { #expect(MailSearch.shardOf(pair[0].string!) == pair[1].string) }
    }

    /// The browser's dictionary and this tokenizer cut unspaced text differently, on purpose. What
    /// must hold is that anything a browser search would find here, this one finds too.
    @Test func everyDictionaryWordIsFoundInTextWithoutSpaces() async throws {
        let f = try Fixture.load()
        let index = try SearchIndex.open(
            keys: SoftwareAccountKeys(address: "cjk@sample.example"), storage: InMemorySearchIndexStorage())
        for (i, pair) in f.cjkWords.enumerated() { try await index.add("h\(i)", text: pair[0].string!) }
        for (i, pair) in f.cjkWords.enumerated() {
            for word in pair[1].strings! {
                #expect(try await index.wordHits(word).contains("h\(i)"), "\(word) in \(pair[0].string!)")
            }
        }
    }

    @Test func queries() throws {
        for query in try Fixture.load().queries {
            let parsed = MailSearch.parseQuery(query.q, timeZone: newYork)
            let got = parsed.clauses.map { clause -> String in
                let body: String
                switch clause.kind {
                case .from(let v): body = "from \(v)"
                case .to(let v): body = "to \(v)"
                case .subject(let v): body = "subject \(v)"
                case .label(let v): body = "label \(v)"
                case .place(let v): body = "in \(v)"
                case .word(let v): body = "word \(v)"
                case .filename(let v, let glob): body = "filename \(v) \(glob != nil)"
                case .hasAttachment: body = "has attachment"
                case .isUnread: body = "is unread"
                case .isRead: body = "is read"
                case .isStarred: body = "is starred"
                case .before(let at): body = "before \(at)"
                case .after(let at): body = "after \(at)"
                }
                return "\(clause.negated) \(body)"
            }
            let want = query.clauses.map { c -> String in
                let body =
                    switch c.kind {
                    case "filename": "filename \(c.value ?? "") \(c.glob ?? false)"
                    case "before", "after": "\(c.kind) \(c.at ?? 0)"
                    default: "\(c.kind) \(c.value ?? "")"
                    }
                return "\(c.neg) \(body)"
            }
            #expect(got == want, "\(query.q)")
            #expect(parsed.words == query.words, "\(query.q)")
            #expect(parsed.filenames == query.filenames, "\(query.q)")
        }
    }

    @Test func globsAndFilenames() throws {
        let f = try Fixture.load()
        for row in f.globs {
            let glob = FilenameGlob(row[0].string!)
            if case .null = row[2] {
                #expect(glob == nil)
            } else {
                #expect(glob?.matches(row[1].string!) == (row[2].int == 1), "\(row[0].string!) \(row[1].string!)")
            }
        }
        for row in f.filenames {
            let value = row[1].string!
            let got = MailSearch.filenameMatches(row[0].string!, value: value, glob: FilenameGlob(value))
            #expect(got == (row[2].int == 1), "\(value)")
        }
    }

    @Test func shardBytes() throws {
        for shard in try Fixture.load().shards {
            let table = Dictionary(uniqueKeysWithValues: shard.entries.map { ($0.token, $0.docs) })
            let bytes = unhex(shard.hex)
            #expect(try MailSearch.decodeShard(bytes) == table)
            // The browser's order is insertion; the fixture inserted in byte order.
            #expect(MailSearch.encodeShard(table) == bytes)
        }
    }
}
