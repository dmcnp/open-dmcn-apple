import Foundation

/// One listed message: its header opened and verified, or the reason it could not be.
///
/// A row that fails to open is kept, not dropped. It is still in the mailbox, and a reader that
/// hid it would make a broken seal look like missing mail.
struct InboxRow: Sendable, Identifiable {
    let id: String
    let opened: Result<OpenedHeader, InboxRowError>
}

struct InboxRowError: Error, Sendable, Equatable {
    let reason: String
}

/// An account's mailbox: lists messages with the reader checks applied, and opens the ones the
/// checks allow. Bodies are fetched only when a message is opened.
public struct Inbox: Sendable {
    public let keys: any AccountKeys
    let service: any MailboxService

    public init(service: any MailboxService, keys: any AccountKeys) {
        self.service = service
        self.keys = keys
    }

    /// One page of the mailbox, newest first, every message checked.
    public func summaries(limit: Int = 50, cursor: String? = nil) async throws -> (
        summaries: [MessageSummary], nextCursor: String?
    ) {
        let (rows, nextCursor) = try await page(limit: limit, cursor: cursor)
        let directory = DirectoryCache(service: service)
        var summaries: [MessageSummary] = []
        for row in rows {
            summaries.append(await MessageSummary(checking: row) { await directory.lookup($0) })
        }
        return (summaries, nextCursor)
    }

    /// Fetches and opens a message's body, unless the reader checks forbid showing it.
    public func open(_ message: MessageSummary) async throws -> OpenedBody {
        if message.contentsWithheld { return .withheld }
        let content = try await content(of: message.row)
        let parts = [content.body] + content.alternatives
        guard let plain = parts.first(where: { $0.contentType == "text/plain" }) else { return .noPlainText }
        return .plainText(String(decoding: plain.content, as: UTF8.self))
    }

    public func signOut() async {
        await service.signOut()
    }

    func page(limit: Int = 50, cursor: String? = nil) async throws -> (rows: [InboxRow], nextCursor: String?) {
        let page = try await service.list(keys, limit: limit, cursor: cursor)
        let rows = page.items.map { item in
            InboxRow(
                id: item.hash,
                opened: Result {
                    try SplitMessage.openHeader(item.entry, keys: keys)
                }.mapError { InboxRowError(reason: String(describing: $0)) })
        }
        return (rows, page.nextCursor)
    }

    func content(of row: InboxRow) async throws -> Dmcn_Message_MessageContent {
        let opened = try row.opened.get()
        return try SplitMessage.openBody(try await service.body(hash: row.id, keys: keys), of: opened)
    }
}

/// Directory answers for one listing, so a sender with ten messages costs one lookup.
actor DirectoryCache {
    private let service: any MailboxService
    private var answers: [String: IdentityLookup?] = [:]

    init(service: any MailboxService) {
        self.service = service
    }

    func lookup(_ address: String) async -> IdentityLookup? {
        let key = address.lowercased()
        if let cached = answers[key] { return cached }
        let answer = try? await service.lookup(address)
        answers[key] = .some(answer)
        return answer
    }
}
