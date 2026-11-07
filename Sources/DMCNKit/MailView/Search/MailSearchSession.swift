import Foundation

// Keeps one account's index level with its mailbox and Sent folder, and answers lookups against it.
// Parity with the browser's lib/search/useSearchIndex.ts, without the half that exists for browser
// tabs: one process owns the index, so there's no lock to hold and no writer to tell the others.
//
// It lives and dies with the unlocked account: hold it while unlocked, `stop` it and let go on lock.
// What was written stays written, so the next unlock picks up where this one stopped.

/// How far the index has caught up, for the "still catching up" note.
public struct SearchProgress: Sendable, Equatable {
    /// Messages searchable by their text.
    public var indexed: Int
    /// Messages that will be, once the index has caught up.
    public var total: Int

    public init(indexed: Int, total: Int) {
        self.indexed = indexed
        self.total = total
    }
}

/// What search reads from an opened message.
public struct SearchBody: Sendable, Equatable {
    public var text: String
    public var filenames: [String]

    public init(text: String, filenames: [String] = []) {
        self.text = text
        self.filenames = filenames
    }

    /// The text a reader would see and the attachments its sender attached. `internalTypes` is what
    /// a build carries for itself; a search for "*.eml" shouldn't find every bridged message by the
    /// raw source it carries.
    public init(_ content: Dmcn_Message_MessageContent, internalTypes: [String] = []) {
        text = Self.bodyText(content)
        filenames = ComposeReplies.userAttachments(content.attachments, internalTypes: internalTypes).map(\.filename)
    }

    /// A blank text part counts as none: campaign builders routinely send one beside the HTML.
    private static func bodyText(_ content: Dmcn_Message_MessageContent) -> String {
        let parts = [content.body] + content.alternatives
        let plain = parts.first { $0.contentType == "text/plain" }.map { JSText.decodeUTF8($0.content) }
        if let plain, !JSText.trim(plain).isEmpty { return plain }
        if let html = parts.first(where: { $0.contentType == "text/html" }) {
            return HTMLPlainText.render(JSText.decodeUTF8(html.content))
        }
        return plain ?? JSText.decodeUTF8(content.body.content)
    }
}

extension MailSearch {
    /// What may be indexed: every message that is mail and not from a blocked sender. A message the
    /// checks withhold counts as blocked: its body must not be fetched at all, and an index of it
    /// would show its words through the search box.
    public static func candidates(
        messages: [MailPreview], sent: [MailPreview], filter: FilterList?, address: String?,
        control: Set<String> = []
    ) -> [SearchCandidate] {
        var list: [SearchCandidate] = []
        for m in messages where !control.contains(m.subject) {
            let blocked = !MailView.isFromOwner(m, address: address) && MailView.blocks(filter, m)
            list.append(SearchCandidate(hash: m.hash, sentAt: m.sentAt, blocked: blocked || m.attributionWithheld))
        }
        for p in sent { list.append(SearchCandidate(hash: p.hash, sentAt: p.sentAt)) }
        return list
    }
}

public actor MailSearchSession {
    private static let noteFlushDelay: Duration = .seconds(2)

    private let index: any SearchIndexing
    private let read: @Sendable (MailPreview) async throws -> SearchBody
    private let runnable: @Sendable () async -> Bool
    private let onChange: @Sendable () async -> Void
    private var writer: SearchBackfill?
    private var candidates: [SearchCandidate] = []
    private var previews: [String: MailPreview] = [:]
    private var noteFlush: Task<Void, Never>?
    private var retry: Task<Void, Never>?

    /// `read` opens a message for indexing. `runnable` says whether fetching is appropriate right
    /// now. `onChange` runs whenever the index has written something a lookup should ask again about.
    public init(
        index: any SearchIndexing, read: @escaping @Sendable (MailPreview) async throws -> SearchBody,
        runnable: @escaping @Sendable () async -> Bool, onChange: @escaping @Sendable () async -> Void = {}
    ) {
        self.index = index
        self.read = read
        self.runnable = runnable
        self.onChange = onChange
    }

    /// Reads received mail through `inbox` and Sent through `sent`.
    public init(
        index: any SearchIndexing, inbox: Inbox, sent: SentStore, internalTypes: [String] = [],
        runnable: @escaping @Sendable () async -> Bool, onChange: @escaping @Sendable () async -> Void = {}
    ) {
        self.init(
            index: index,
            read: { preview in
                guard SentStore.isSentHash(preview.hash) else { return try await inbox.searchBody(of: preview) }
                return SearchBody(try await sent.open(preview.hash).content, internalTypes: internalTypes)
            }, runnable: runnable, onChange: onChange)
    }

    private func backfill() -> SearchBackfill {
        if let writer { return writer }
        let made = SearchBackfill(
            index: index,
            fetch: { [weak self] hash in
                guard let self else { throw CancellationError() }
                return try await self.body(of: hash)
            },
            runnable: runnable,
            onProgress: { [onChange] flushed in if flushed { await onChange() } },
            retryLater: { [weak self] delay in await self?.retry(after: delay) })
        writer = made
        return made
    }

    private func body(of hash: String) async throws -> SearchBody {
        guard let preview = previews[hash] else { throw CancellationError() }
        return try await read(preview)
    }

    private func retry(after delay: Duration) {
        retry?.cancel()
        retry = Task { [weak self] in
            try? await Task.sleep(for: delay)
            if !Task.isCancelled { await self?.kick() }
        }
    }

    /// Hands over the current lists. Call it only once the block list has answered: before then a
    /// blocked sender looks like any other, and indexing their mail to remove it later is the wrong
    /// way round. `complete` says both listings have landed in full, which is what lets a pass drop
    /// anything.
    public func update(
        messages: [MailPreview], sent: [MailPreview], filter: FilterList?, address: String?,
        control: Set<String> = [], complete: Bool
    ) async {
        candidates = MailSearch.candidates(
            messages: messages, sent: sent, filter: filter, address: address, control: control)
        previews = Dictionary((messages + sent).map { ($0.hash, $0) }, uniquingKeysWith: { first, _ in first })
        await backfill().update(candidates, complete: complete)
    }

    /// Runs the backfill again: the app came back to the front, or went online.
    public func kick() async {
        await backfill().kick()
    }

    /// Returns when no backfill pass is running.
    public func settled() async {
        await backfill().settled()
    }

    /// The numbers for the "still catching up" note.
    public func progress() async -> SearchProgress {
        let indexed = Set(await index.hashes())
        let wanted = candidates.filter { !$0.blocked }
        return SearchProgress(indexed: wanted.count { indexed.contains($0.hash) }, total: wanted.count)
    }

    /// What the index says about a query's words and filename patterns. A record that won't open
    /// costs that one term its body matches, never the search: the header part still answers.
    public func lookup(_ query: ParsedQuery) async -> SearchHits {
        var hits = SearchHits()
        for word in query.words {
            var found = (try? await index.wordHits(word)) ?? []
            found.formUnion((try? await index.filenameHits(word, glob: nil)) ?? [])
            hits.words[word] = found
        }
        for file in query.filenames {
            hits.files[file] = (try? await index.filenameHits(file, glob: FilenameGlob(file))) ?? []
        }
        return hits
    }

    /// Indexes a message the reader has just opened, without fetching it again. Not a withheld one:
    /// the reader never has its body, and this is the one door that doesn't go through a candidate.
    public func noteBody(_ hash: String, _ body: SearchBody) async {
        guard candidates.contains(where: { $0.hash == hash && !$0.blocked }) else { return }
        guard (try? await index.add(hash, text: body.text, filenames: body.filenames)) != nil else { return }
        noteFlush?.cancel()
        noteFlush = Task { [weak self, index, onChange] in
            try? await Task.sleep(for: Self.noteFlushDelay)
            guard !Task.isCancelled, self != nil else { return }
            if (try? await index.flush()) != nil { await onChange() }
        }
    }

    /// Throws this device's index away and builds it again.
    public func clear() async throws {
        try await index.clear()
        await onChange()
        await kick()
    }

    /// Stops fetching and writes what was indexed: the account is locking.
    public func stop() async {
        noteFlush?.cancel()
        retry?.cancel()
        await backfill().stop()
    }
}
