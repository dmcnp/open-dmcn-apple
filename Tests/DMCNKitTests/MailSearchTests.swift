// The browser suites' cases for the query language, the tokenizer, the shards, the index and the
// backfill, against the Swift ports.

import Crypto
import DMCNKitSamples
import Foundation
import Testing
@testable import DMCNKit

private let zone = TimeZone(identifier: "America/New_York")!

private func sentAt(_ year: Int, _ month: Int, _ day: Int, _ hour: Int) -> Int64 {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = zone
    return Int64(
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!.timeIntervalSince1970)
}

private func msg(
    subject: String = "Quarterly report", cc: [String] = [], bcc: [String] = [], deliveredTo: String? = nil,
    senderDisplay: String = "", attachmentCount: UInt32 = 0
) -> MailPreview {
    MailPreview(
        hash: "h1", senderAddress: "alice@example.com", recipientAddress: "bob@example.com", to: ["bob@example.com"],
        cc: cc, bcc: bcc, subject: subject, snippet: "Here are the numbers", senderDisplay: senderDisplay,
        sentAt: sentAt(2026, 6, 15, 12), attachmentCount: attachmentCount, deliveredTo: deliveredTo)
}

private func ctx(
    isStarred: Bool = false, labels: [String] = [], places: [String] = ["inbox"]
) -> MatchContext {
    MatchContext(
        nameFor: { $0 == "alice@example.com" ? "Alice Smith" : $0 }, isRead: { _ in false },
        isStarred: { _ in isStarred }, labelNames: { _ in labels }, placeNames: { _ in places })
}

private func hits(_ words: [String: [String]] = [:], files: [String: [String]] = [:]) -> SearchHits {
    SearchHits(words: words.mapValues(Set.init), files: files.mapValues(Set.init))
}

private func q(
    _ text: String, _ m: MailPreview = msg(), _ c: MatchContext = ctx(), _ h: SearchHits? = nil
) -> Bool {
    MailSearch.matches(m, MailSearch.parseQuery(text, timeZone: zone), context: c, hits: h)
}

@Suite struct ParseQuery {
    private func clauses(_ text: String) -> [SearchClause] { MailSearch.parseQuery(text, timeZone: zone).clauses }

    @Test func operatorsQuotedValuesAndNegation() {
        let parsed = MailSearch.parseQuery("from:\"Alice Smith\" -has:attachment report")
        #expect(
            parsed.clauses == [
                SearchClause(.from("alice smith")), SearchClause(negated: true, .hasAttachment),
                SearchClause(.word("report")),
            ])
        #expect(parsed.words == ["report"])
    }

    @Test func unknownOrUnusableOperatorsAreOrdinaryWords() {
        #expect(clauses("re:meeting") == [SearchClause(.word("re:meeting"))])
        #expect(clauses("has:cats") == [SearchClause(.word("has:cats"))])
        #expect(clauses("before:someday") == [SearchClause(.word("before:someday"))])
        #expect(clauses("from: alice") == [SearchClause(.word("from:")), SearchClause(.word("alice"))])
    }

    @Test func aQuoteStillBeingTyped() {
        #expect(clauses("subject:\"quarterly rep") == [SearchClause(.subject("quarterly rep"))])
    }

    @Test func filenamesAreCollectedApartFromWords() {
        let parsed = MailSearch.parseQuery("filename:*.PDF invoice")
        #expect(parsed.filenames == ["*.pdf"])
        #expect(parsed.words == ["invoice"])
    }

    @Test func blankInputIsEmpty() { #expect(clauses("   ").isEmpty) }

    /// In the browser `IN_ALIASES['constructor']` finds Object's own property, so this clause holds
    /// a function and no folder can match it. A folder has every right to that name.
    @Test func aFolderNamedLikeAnObjectPropertyIsJustAFolder() {
        #expect(clauses("in:constructor") == [SearchClause(.place("constructor"))])
    }
}

@Suite struct Globs {
    @Test func nilWithoutAWildcard() { #expect(FilenameGlob("report.pdf") == nil) }

    @Test func anchorsThePatternAndTakesEverythingElseLiterally() throws {
        let pdf = try #require(FilenameGlob("*.pdf"))
        #expect(pdf.matches("scan.pdf"))
        #expect(!pdf.matches("scan.pdf.exe"))
        #expect(!pdf.matches("scanxpdf"))
        #expect(try #require(FilenameGlob("invoice-202?(1)*")).matches("invoice-2026(1) final.docx"))
        #expect(try #require(FilenameGlob("a+b*")).matches("aab.txt") == false)
    }

    @Test func foldsTheNameAndMatchesSubstringsWithoutAWildcard() {
        #expect(MailSearch.filenameMatches("Résumé 2026.PDF", value: "resume", glob: nil))
        #expect(MailSearch.filenameMatches("Résumé 2026.PDF", value: "*.pdf", glob: FilenameGlob("*.pdf")))
        #expect(!MailSearch.filenameMatches("notes.txt", value: "*.pdf", glob: FilenameGlob("*.pdf")))
    }
}

@Suite struct Matches {
    @Test func anEmptyQueryMatchesEverything() { #expect(q("")) }

    @Test func fromReadsTheAddressTheHeaderNameAndTheContactName() {
        #expect(q("from:alice@"))
        #expect(q("from:smith"))
        #expect(!q("from:bob"))
        #expect(q("from:ally", msg(senderDisplay: "Ally")))
    }

    @Test func toReadsEveryRecipientField() {
        #expect(q("to:bob"))
        #expect(q("to:carol", msg(cc: ["carol@example.com"])))
        #expect(q("to:dave", msg(bcc: ["dave@example.com"])))
        #expect(q("to:alias", msg(deliveredTo: "alias@example.com")))
        #expect(!q("to:alice"))
    }

    @Test func hasAttachmentReadsTheHeaderCount() {
        #expect(!q("has:attachment"))
        #expect(q("has:attachment", msg(attachmentCount: 2)))
        #expect(q("-has:attachment"))
    }

    @Test func isAndLabelReadTheOwnersFlags() {
        #expect(q("is:unread"))
        #expect(!q("is:read"))
        #expect(q("is:starred", msg(), ctx(isStarred: true)))
        #expect(q("label:work", msg(), ctx(labels: ["Work"])))
        #expect(!q("label:wor", msg(), ctx(labels: ["Work"])))
    }

    @Test func inReadsWhereTheMessageIsListed() {
        #expect(q("in:inbox"))
        #expect(!q("in:sent"))
        #expect(q("-in:sent"))
        let filed = ctx(places: ["Receipts 2026", "archive"])
        #expect(q("in:\"receipts 2026\"", msg(), filed))
        #expect(q("in:archive", msg(), filed))
        #expect(!q("in:receipts", msg(), filed))
    }

    @Test func inTrashAndInBinMeanDeleted() {
        #expect(MailSearch.parseQuery("in:trash").clauses == [SearchClause(.place("deleted"))])
        #expect(q("in:bin", msg(), ctx(places: ["deleted"])))
    }

    @Test func beforeIsExclusiveAndAfterInclusiveOfTheDayNamed() {
        #expect(q("after:2026-06-15"))
        #expect(!q("after:2026-06-16"))
        #expect(!q("before:2026-06-15"))
        #expect(q("before:2026-06-16"))
    }

    @Test func aWordMatchesTheHeaderOrTheBodyOnceTheIndexAnswers() {
        #expect(q("quarterly"))
        #expect(!q("revenue"))
        #expect(q("revenue", msg(), ctx(), hits(["revenue": ["h1"]])))
        #expect(!q("revenue", msg(), ctx(), hits(["revenue": ["other"]])))
    }

    @Test func everyClauseHasToHold() {
        #expect(q("from:alice revenue", msg(), ctx(), hits(["revenue": ["h1"]])))
        #expect(!q("from:bob revenue", msg(), ctx(), hits(["revenue": ["h1"]])))
    }

    @Test func filenameOnlyMatchesOnceTheIndexAnswers() {
        #expect(!q("filename:*.pdf"))
        #expect(q("filename:*.pdf", msg(), ctx(), hits(files: ["*.pdf": ["h1"]])))
    }

    @Test func aNegatedWordExcludesBodyMatchesToo() {
        #expect(!q("-revenue", msg(), ctx(), hits(["revenue": ["h1"]])))
        #expect(!q("-quarterly"))
    }

    @Test func wholeCharactersDoNotHideWhatTheBrowserFinds() {
        #expect(q("👩", msg(subject: "Family 👨‍👩‍👧 photo")))
    }
}

@Suite struct Tokenize {
    @Test func foldDropsCaseAccentsAndCompatibilityForms() {
        #expect(MailSearch.fold("Café Crème") == "cafe creme")
        #expect(MailSearch.fold("ﬁle") == "file")
        #expect(MailSearch.fold("ÅNGSTRÖM") == "angstrom")
    }

    @Test func foldKeepsHangulSyllablesWhole() { #expect(MailSearch.fold("한국어") == "한국어") }

    @Test func aCapitalSigmaEndingAWordIsTheFinalForm() { #expect(MailSearch.fold("ΣΑΣ") == "σας") }

    @Test func splitsOnPunctuationAndKeepsEachWordOnce() {
        #expect(
            MailSearch.tokenize("Invoice-123 for the INVOICE, from o'brien")
                == ["invoice", "123", "for", "the", "from", "brien"])
    }

    @Test func dropsOneLetterLatinWordsButKeepsSingleIdeographs() {
        #expect(MailSearch.tokenize("a I x ok") == ["ok"])
        #expect(!MailSearch.tokenize("猫").isEmpty)
    }

    @Test func findsWordsInTextWrittenWithoutSpaces() {
        let tokens = MailSearch.tokenize("東京で会議があります")
        #expect(tokens.count > 1)
        #expect(tokens.joined().contains("東京"))
    }

    @Test func dropsTokensLongerThanAWordCouldBe() {
        #expect(MailSearch.tokenize("short " + String(repeating: "x", count: 41)) == ["short"])
    }

    @Test func indexesOnlyTheFirstStretchOfAMessage() {
        let text = String(repeating: "a ", count: MailSearch.maxIndexChars / 2) + "needle"
        #expect(!MailSearch.tokenize(text).contains("needle"))
    }

    @Test func matchesQueryAndIndexTheSameWay() {
        #expect(MailSearch.tokenize("RÉSUMÉ") == MailSearch.tokenize("resume"))
    }

    @Test func aShardIsTheFirstTwoCharactersByCodePoint() {
        #expect(MailSearch.shardOf("invoice") == "in")
        #expect(MailSearch.shardOf("猫") == "猫")
        #expect(MailSearch.shardOf("😀😃x") == "😀😃")
    }
}

@Suite struct Shards {
    @Test func postingListsStayAscendingAndFreeOfDuplicates() {
        var shard: SearchShard = [:]
        for doc in [1, 5, 5, 3, 9, 0] { MailSearch.addPosting(&shard, token: "invoice", doc: doc) }
        #expect(shard["invoice"] == [0, 1, 3, 5, 9])
    }

    @Test func findsEveryDocHoldingATokenTheTermStarts() {
        let shard: SearchShard = ["invoice": [1, 2], "invite": [3], "index": [4]]
        #expect(MailSearch.prefixDocs(shard, term: "inv") == [1, 2, 3])
        #expect(MailSearch.prefixDocs(shard, term: "invoice") == [1, 2])
        #expect(MailSearch.prefixDocs(shard, term: "invoices").isEmpty)
    }

    @Test func removesDeadPostingsAndTokensLeftEmpty() {
        var shard: SearchShard = ["invoice": [1, 2], "invite": [2]]
        #expect(MailSearch.dropDocs(&shard) { $0 == 2 } == 2)
        #expect(shard == ["invoice": [1]])
    }

    @Test func groupsTokensByTheirFirstTwoCharacters() {
        #expect(MailSearch.byShard(["invoice", "invite", "order"]) == ["in": ["invoice", "invite"], "or": ["order"]])
    }

    @Test func roundTripsLargeDocNumbersAndNonASCIITokens() throws {
        let shard: SearchShard = [
            "invoice": [0, 1, 127, 128, 300, 16384, (1 << 31) + 5], "résumé": [7], "東京": [2, 3],
        ]
        #expect(try MailSearch.decodeShard(MailSearch.encodeShard(shard)) == shard)
    }

    @Test func storesDenseListsInAboutAByteADoc() {
        #expect(MailSearch.encodeShard(["the": Array(0..<10_000)]).count < 10_100)
    }

    @Test func refusesATruncatedShard() {
        let bytes = MailSearch.encodeShard(["invoice": [1, 2, 3]])
        #expect(throws: SearchShardError.self) { try MailSearch.decodeShard(bytes.dropLast(2)) }
    }

    @Test func refusesNonsenseWithoutTrapping() {
        #expect(throws: SearchShardError.self) { try MailSearch.decodeShard(Data(repeating: 0xFF, count: 16)) }
    }
}

/// Storage that fails its next write, as a full disk would.
private final class FlakyStorage: SearchIndexStorage, @unchecked Sendable {
    let inner = InMemorySearchIndexStorage()
    var failNext = false

    func read(_ slot: String) throws -> Data? { try inner.read(slot) }
    func write(_ puts: [String: Data], deleting: [String]) throws {
        if failNext {
            failNext = false
            throw CocoaError(.fileWriteOutOfSpace)
        }
        try inner.write(puts, deleting: deleting)
    }
    func removeAll() throws { try inner.removeAll() }
}

/// Keys whose private half is out of reach for now, as a locked keychain's would be.
private struct LockedKeys: AccountKeys {
    let inner: SoftwareAccountKeys
    var address: String { inner.address }
    var ed25519Public: Data { inner.ed25519Public }
    var x25519Public: Data { inner.x25519Public }
    func sign(_ message: Data) throws -> Data { throw CocoaError(.userCancelled) }
    func sharedSecret(withEphemeral ephemeralPublic: Data) throws -> SharedSecret { throw CocoaError(.userCancelled) }
}

@Suite struct Index {
    private let keys = SoftwareAccountKeys(address: "alice@example.com")

    private func open(
        _ storage: any SearchIndexStorage = InMemorySearchIndexStorage(), keys: any AccountKeys
    ) throws -> SearchIndex {
        try SearchIndex.open(keys: keys, storage: storage)
    }

    @Test func findsAMessageByAWordOfItsTextAcrossAReopen() async throws {
        let storage = InMemorySearchIndexStorage()
        let index = try open(storage, keys: keys)
        try await index.add("h1", text: "The quarterly invoice is attached")
        try await index.add("h2", text: "Lunch on Friday?")
        try await index.flush()

        let again = try open(storage, keys: keys)
        #expect(await again.hashes().count == 2)
        #expect(try await again.wordHits("invo") == ["h1"])
        #expect(try await again.wordHits("fri") == ["h2"])
        #expect(try await again.wordHits("nothing").isEmpty)
    }

    @Test func needsEveryWordOfAMultiWordTerm() async throws {
        let index = try open(keys: keys)
        try await index.add("h1", text: "red car")
        try await index.add("h2", text: "red bicycle")
        #expect(try await index.wordHits("red car") == ["h1"])
        #expect(try await index.wordHits("red") == ["h1", "h2"])
    }

    @Test func storesNothingReadable() async throws {
        let storage = InMemorySearchIndexStorage()
        let index = try open(storage, keys: keys)
        try await index.add("h1", text: "confidential merger terms", filenames: ["merger-plan.pdf"])
        try await index.flush()
        let dump = storage.snapshot.values.map { String(decoding: $0, as: UTF8.self) }.joined()
        for secret in ["confidential", "merger", "\"h1\""] { #expect(!dump.contains(secret)) }
    }

    @Test func recordsAreBoundToTheirSlots() async throws {
        let storage = InMemorySearchIndexStorage()
        let index = try open(storage, keys: keys)
        try await index.add("h1", text: "invoice")
        try await index.add("h2", text: "order")
        try await index.flush()
        let records = storage.snapshot
        try storage.write(["s/in": records["s/or"]!, "s/or": records["s/in"]!], deleting: [])
        let again = try open(storage, keys: keys)
        await #expect(throws: (any Error).self) { _ = try await again.wordHits("invoice") }
    }

    @Test func anotherAccountsRecordsDoNotOpen() async throws {
        let storage = InMemorySearchIndexStorage()
        let index = try open(storage, keys: keys)
        try await index.add("h1", text: "invoice")
        try await index.flush()
        // Bob's key can't open Alice's key record, so his index starts empty over the top of it.
        let bob = try open(storage, keys: SoftwareAccountKeys(address: "bob@example.com"))
        #expect(await bob.hashes().isEmpty)
        #expect(try await bob.wordHits("invoice").isEmpty)
    }

    @Test func isWipedWhenTheAccountKeyNoLongerOpensIt() async throws {
        let storage = InMemorySearchIndexStorage()
        let index = try open(storage, keys: keys)
        try await index.add("h1", text: "invoice")
        try await index.flush()
        let rotated = try open(storage, keys: SoftwareAccountKeys(address: keys.address))
        #expect(await rotated.hashes().isEmpty)
        #expect(try await rotated.wordHits("invoice").isEmpty)
        #expect(!storage.snapshot.keys.contains("s/in"))
    }

    @Test func keysThatCannotAnswerRightNowDoNotCostTheIndex() async throws {
        let storage = InMemorySearchIndexStorage()
        let index = try open(storage, keys: keys)
        try await index.add("h1", text: "invoice")
        try await index.flush()
        #expect(throws: (any Error).self) { try open(storage, keys: LockedKeys(inner: keys)) }
        #expect(try await open(storage, keys: keys).wordHits("invoice") == ["h1"])
    }

    @Test func matchesAttachmentNamesByGlobIncludingALeadingWildcard() async throws {
        let storage = InMemorySearchIndexStorage()
        let index = try open(storage, keys: keys)
        try await index.add("h1", text: "see attached", filenames: ["Scan 2026.PDF", "notes.txt"])
        try await index.add("h2", text: "see attached", filenames: ["photo.jpg"])
        try await index.flush()
        let again = try open(storage, keys: keys)
        #expect(try await again.filenameHits("*.pdf", glob: FilenameGlob("*.pdf")) == ["h1"])
        #expect(try await again.filenameHits("photo", glob: nil) == ["h2"])
        // Filenames are not body words.
        #expect(try await again.wordHits("scan").isEmpty)
    }

    @Test func forgetsRemovedMessagesAtOnceAndSweepsThemOnCompaction() async throws {
        let storage = InMemorySearchIndexStorage()
        let index = try open(storage, keys: keys)
        try await index.add("h1", text: "invoice alpha", filenames: ["a.pdf"])
        try await index.add("h2", text: "invoice beta")
        try await index.remove(["h1"])
        try await index.flush()
        #expect(try await index.wordHits("invoice") == ["h2"])
        #expect(try await index.filenameHits("*.pdf", glob: FilenameGlob("*.pdf")).isEmpty)
        #expect(await index.debugState().orphans == 1)

        try await index.compact()
        #expect(await index.debugState().orphans == 0)
        #expect(await index.debugState().shards == ["be", "in"])  // "alpha"'s shard emptied and went
        #expect(!storage.snapshot.keys.contains("s/al"))
        #expect(try await open(storage, keys: keys).wordHits("invoice") == ["h2"])
    }

    @Test func writesAFlushWholeOrNotAtAll() async throws {
        let storage = FlakyStorage()
        let index = try open(storage, keys: keys)
        try await index.add("h1", text: "invoice")
        storage.failNext = true
        await #expect(throws: (any Error).self) { try await index.flush() }
        #expect(await index.hasPending())
        #expect(await (try open(storage, keys: keys)).hashes().isEmpty)
        try await index.flush()
        #expect(await (try open(storage, keys: keys)).hashes().count == 1)
    }

    @Test func doesNotIndexAMessageTwice() async throws {
        let index = try open(keys: keys)
        try await index.add("h1", text: "invoice")
        try await index.add("h1", text: "something else entirely")
        #expect(await index.hashes().count == 1)
        #expect(try await index.wordHits("something").isEmpty)
    }

    @Test func survivesConcurrentAddsTouchingTheSameShards() async throws {
        let storage = InMemorySearchIndexStorage()
        let index = try open(storage, keys: keys)
        await withThrowingTaskGroup(of: Void.self) { group in
            for i in 0..<20 {
                group.addTask { try await index.add("h\(i)", text: "invoice number\(i)") }
            }
        }
        try await index.flush()
        #expect(try await open(storage, keys: keys).wordHits("invoice").count == 20)
    }

    @Test func clearLeavesAnEmptyIndexThatStillOpens() async throws {
        let storage = InMemorySearchIndexStorage()
        let index = try open(storage, keys: keys)
        try await index.add("h1", text: "invoice", filenames: ["a.pdf"])
        try await index.flush()
        try await index.clear()
        #expect(try await index.wordHits("invoice").isEmpty)
        try await index.add("h2", text: "order")
        try await index.flush()
        #expect(try await open(storage, keys: keys).wordHits("order") == ["h2"])
    }
}

@Suite struct FileStorage {
    private let keys = SoftwareAccountKeys(address: "alice@example.com")

    @Test func anIndexSurvivesInFilesAndForgettingRemovesIt() async throws {
        let base = temporaryDirectory()
        let storage = try FileSearchIndexStorage(baseDirectory: base, address: keys.address)
        let index = try SearchIndex.open(keys: keys, storage: storage)
        try await index.add("h1", text: "invoice", filenames: ["a.pdf"])
        try await index.flush()

        let reopened = try FileSearchIndexStorage(baseDirectory: base, address: "Alice@Example.com ")
        #expect(try await SearchIndex.open(keys: keys, storage: reopened).wordHits("invoice") == ["h1"])

        try FileSearchIndexStorage.forget(baseDirectory: base, address: keys.address)
        let gone = try FileSearchIndexStorage(baseDirectory: base, address: keys.address)
        #expect(try gone.read("meta") == nil)
    }

    @Test func accountsHaveDirectoriesOfTheirOwn() throws {
        let base = temporaryDirectory()
        let a = try FileSearchIndexStorage(baseDirectory: base, address: "a@example.com")
        let b = try FileSearchIndexStorage(baseDirectory: base, address: "b@example.com")
        try a.write(["x": Data([1])], deleting: [])
        #expect(try b.read("x") == nil)
    }

    @Test func aBatchCutShortIsFinishedOnTheNextOpen() throws {
        let base = temporaryDirectory()
        let storage = try FileSearchIndexStorage(baseDirectory: base, address: "a@example.com")
        try storage.write(["old": Data([1])], deleting: [])

        // What a crash leaves between the journal landing and the files being written.
        let directory = try #require(
            FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: nil).first)
        let batch = """
            [{"slot":"new","data":"Ag=="},{"slot":"old"}]
            """
        try Data(batch.utf8).write(to: directory.appendingPathComponent("journal"))

        let reopened = try FileSearchIndexStorage(baseDirectory: base, address: "a@example.com")
        #expect(try reopened.read("new") == Data([2]))
        #expect(try reopened.read("old") == nil)
    }
}

@Suite struct PlanPass {
    private func c(_ hash: String, _ sentAt: Int64, _ blocked: Bool = false) -> SearchCandidate {
        SearchCandidate(hash: hash, sentAt: sentAt, blocked: blocked)
    }

    @Test func fetchesWhatIsMissingNewestFirstAndNeverABlockedSender() {
        let plan = MailSearch.planPass(
            [c("old", 1), c("new", 3), c("mid", 2), c("spam", 4, true)], has: { $0 == "mid" })
        #expect(plan.fetch == ["new", "old"])
        #expect(plan.remove.isEmpty)
    }

    @Test func removesOnlyAgainstACompleteList() {
        let candidates = [c("kept", 1), c("now-blocked", 2, true)]
        #expect(MailSearch.planPass(candidates, has: { _ in true }).remove.isEmpty)
        let plan = MailSearch.planPass(candidates, has: { _ in true }, indexed: ["kept", "now-blocked", "deleted"])
        #expect(plan.remove == ["now-blocked", "deleted"])
    }
}

private actor FakeIndex: SearchIndexing {
    var docs: [String: String] = [:]
    var unflushed = 0
    var flushes = 0
    var compactions = 0
    var wantsIt = false

    func want() { wantsIt = true }
    func hashes() -> [String] { Array(docs.keys) }
    func add(_ hash: String, text: String, filenames: [String]) {
        docs[hash] = text
        unflushed += 1
    }
    func remove(_ hashes: [String]) {
        for hash in hashes { docs[hash] = nil }
        unflushed += 1
    }
    func hasPending() -> Bool { unflushed > 0 }
    func flush() {
        if unflushed > 0 { flushes += 1 }
        unflushed = 0
    }
    func wantsCompaction() -> Bool { wantsIt }
    func compact() {
        compactions += 1
        wantsIt = false
    }
    func wordHits(_ term: String) -> Set<String> { [] }
    func filenameHits(_ value: String, glob: FilenameGlob?) -> Set<String> { [] }
    func clear() { docs = [:] }
}

private actor Backfill {
    let index = FakeIndex()
    var fetched: [String] = []
    var retry: Duration?
    var on: Bool
    let fail: @Sendable (String) -> Bool
    private(set) var backfill: SearchBackfill!

    init(fail: @escaping @Sendable (String) -> Bool = { _ in false }, on: Bool = true) {
        self.fail = fail
        self.on = on
    }

    func start() {
        backfill = SearchBackfill(
            index: index,
            fetch: { [self] hash in
                await self.note(hash)
                if self.fail(hash) { throw CocoaError(.fileReadUnknown) }
                return SearchBody(text: "body of \(hash)")
            },
            runnable: { [self] in await self.on },
            retryLater: { [self] delay in await self.noteRetry(delay) })
    }

    func note(_ hash: String) { fetched.append(hash) }
    func noteRetry(_ delay: Duration) { retry = delay }
    func turnOn() { on = true }
}

private func started(fail: @escaping @Sendable (String) -> Bool = { _ in false }, on: Bool = true) async -> (
    Backfill, SearchBackfill
) {
    let b = Backfill(fail: fail, on: on)
    await b.start()
    return (b, await b.backfill)
}

private func cands(_ n: Int) -> [SearchCandidate] {
    (0..<n).map { SearchCandidate(hash: "h\($0)", sentAt: Int64($0)) }
}

@Suite struct Backfiller {
    @Test func indexesEverythingMissingAndWritesItOut() async {
        let (b, backfill) = await started()
        await backfill.update(cands(5), complete: true)
        await backfill.settled()
        #expect(await b.index.docs.count == 5)
        #expect(await !b.index.hasPending())
    }

    @Test func writesEveryFewHundredMessages() async {
        let (b, backfill) = await started()
        await backfill.update(cands(SearchBackfill.flushEvery * 2 + 10), complete: true)
        await backfill.settled()
        #expect(await b.index.flushes == 3)
    }

    @Test func doesNothingWhileNotRunnableAndResumesOnAKick() async {
        let (b, backfill) = await started(on: false)
        await backfill.update(cands(3), complete: true)
        await backfill.settled()
        #expect(await b.index.docs.isEmpty)
        await b.turnOn()
        await backfill.kick()
        await backfill.settled()
        #expect(await b.index.docs.count == 3)
    }

    @Test func givesUpOnAMessageAfterItsFailures() async {
        let (b, backfill) = await started(fail: { $0 == "h1" })
        for _ in 0..<(SearchBackfill.maxFailures + 2) {
            await backfill.update(cands(3), complete: true)
            await backfill.settled()
        }
        #expect(await b.fetched.filter { $0 == "h1" }.count == SearchBackfill.maxFailures)
        #expect(await b.index.docs.count == 2)
    }

    @Test func endsAPassOnAFailureStreakAndAsksToBeRetried() async {
        let (b, backfill) = await started(fail: { _ in true })
        await backfill.update(cands(50), complete: true)
        await backfill.settled()
        #expect(await b.fetched.count < SearchBackfill.failureStreak + 2)
        #expect(await b.retry != nil)
    }

    @Test func rePlansWhenNewMailArrivesMidPass() async {
        let (b, backfill) = await started()
        await backfill.update(cands(10), complete: true)
        await backfill.update(cands(10) + [SearchCandidate(hash: "fresh", sentAt: 999)], complete: true)
        await backfill.settled()
        let fetched = await b.fetched
        #expect(fetched.contains("fresh"))
        #expect((fetched.firstIndex(of: "fresh") ?? .max) < fetched.count - 1)
    }

    @Test func removesMessagesThatLeftTheMailbox() async {
        let (b, backfill) = await started()
        await backfill.update(cands(3), complete: true)
        await backfill.settled()
        await backfill.update(cands(2), complete: true)
        await backfill.settled()
        #expect(await b.index.docs.keys.sorted() == ["h0", "h1"])
    }

    @Test func aListStillLoadingRemovesNothing() async {
        let (b, backfill) = await started()
        await backfill.update(cands(3), complete: true)
        await backfill.settled()
        await backfill.update([], complete: false)
        await backfill.settled()
        #expect(await b.index.docs.count == 3)
    }

    @Test func compactsAfterAPassWhenTheIndexAsks() async {
        let (b, backfill) = await started()
        await b.index.want()
        await backfill.update(cands(1), complete: true)
        await backfill.settled()
        #expect(await b.index.compactions == 1)
    }

    @Test func stopsAndWritesWhatItHas() async {
        let (b, backfill) = await started()
        await backfill.update(cands(3), complete: true)
        await backfill.stop()
        #expect(await !b.index.hasPending())
        let held = await b.index.docs.count
        await backfill.update(cands(10), complete: true)
        await backfill.settled()
        #expect(await b.index.docs.count == held)
    }
}

@Suite struct SearchSession {
    private func session(
        index: any SearchIndexing, runnable: @escaping @Sendable () async -> Bool = { true }
    ) -> MailSearchSession {
        MailSearchSession(
            index: index, read: { SearchBody(text: "the word of \($0.hash)", filenames: ["\($0.hash).pdf"]) },
            runnable: runnable)
    }

    private func preview(_ hash: String, _ verdict: MessageSummary.Sender? = nil) -> MailPreview {
        MailPreview(hash: hash, senderAddress: "x@y.z", sentAt: 1, sender: verdict)
    }

    @Test func noIndexMeansNoHitsAndHeadersStillAnswer() async {
        let hits = await session(index: FakeIndex()).lookup(ParsedQuery(words: ["word"]))
        #expect(hits.words["word"] == [])
    }

    @Test func aBackfilledMessageIsFoundByItsText() async throws {
        let index = try SearchIndex.open(
            keys: SoftwareAccountKeys(address: "me@x.y"), storage: InMemorySearchIndexStorage())
        let search = session(index: index)
        await search.update(messages: [preview("h1")], sent: [], filter: nil, address: "me@x.y", complete: true)
        await search.settled()
        let hits = await search.lookup(MailSearch.parseQuery("word filename:*.pdf"))
        #expect(hits.words["word"] == ["h1"])
        #expect(hits.files["*.pdf"] == ["h1"])
    }

    @Test func progressCountsWhatWillBeSearchable() async throws {
        let index = FakeIndex()
        await index.add("h1", text: "x", filenames: [])
        let search = session(index: index, runnable: { false })
        await search.update(
            messages: [preview("h1"), preview("h2"), preview("forged", .mismatch(claimed: "x@y.z"))], sent: [],
            filter: nil, address: "me@x.y", complete: false)
        #expect(await search.progress() == SearchProgress(indexed: 1, total: 2))
    }

    @Test func aBodyTheReaderHoldsIsIndexedUnlessTheMessageIsWithheld() async throws {
        let index = FakeIndex()
        let search = session(index: index, runnable: { false })
        await search.update(
            messages: [preview("h1"), preview("forged", .mismatch(claimed: "x@y.z"))], sent: [], filter: nil,
            address: "me@x.y", complete: false)
        await search.noteBody("h1", SearchBody(text: "opened"))
        await search.noteBody("forged", SearchBody(text: "never"))
        await search.noteBody("unknown", SearchBody(text: "never"))
        #expect(await index.docs == ["h1": "opened"])
    }

    @Test func clearStartsAgain() async throws {
        let index = FakeIndex()
        let search = session(index: index)
        await search.update(messages: [preview("h1")], sent: [], filter: nil, address: "me@x.y", complete: true)
        await search.settled()
        try await search.clear()
        await search.settled()
        #expect(await index.docs.count == 1)
    }
}

@Suite struct SearchBodies {
    private func part(_ type: String, _ text: String) -> Dmcn_Message_MessageBody {
        var body = Dmcn_Message_MessageBody()
        body.contentType = type
        body.content = Data(text.utf8)
        return body
    }

    @Test func thePlainPartWhenItSaysSomething() {
        var content = Dmcn_Message_MessageContent()
        content.body = part("text/plain", "Hello there")
        content.alternatives = [part("text/html", "<p>Other</p>")]
        #expect(SearchBody(content).text == "Hello there")
    }

    @Test func aBlankPlainPartCountsAsNone() {
        var content = Dmcn_Message_MessageContent()
        content.body = part("text/plain", "  \n ")
        content.alternatives = [part("text/html", "<p>Hello&nbsp;<b>there</b></p>")]
        #expect(MailSearch.tokenize(SearchBody(content).text) == ["hello", "there"])
    }

    @Test func markupAndWhatIsNotMessageContentAreNotWords() {
        var content = Dmcn_Message_MessageContent()
        content.body = part(
            "text/html",
            "<html><head><title>t1</title><style>.a{color:red}</style></head><body>Body <script>evil()</script>text</body></html>"
        )
        #expect(MailSearch.tokenize(SearchBody(content).text) == ["body", "text"])
    }

    @Test func protocolAttachmentsAreNotFilenames() {
        var classification = Dmcn_Message_AttachmentRecord()
        classification.contentType = "application/x-dmcn-bridge-classification"
        classification.filename = "classification"
        var original = Dmcn_Message_AttachmentRecord()
        original.contentType = "message/rfc822"
        original.filename = "original.eml"
        var photo = Dmcn_Message_AttachmentRecord()
        photo.contentType = "image/jpeg"
        photo.filename = "photo.jpg"
        var content = Dmcn_Message_MessageContent()
        content.attachments = [classification, original, photo]
        #expect(SearchBody(content).filenames == ["photo.jpg"])
    }
}
