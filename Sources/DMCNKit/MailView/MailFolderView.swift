import Foundation

// What a mail list shows, as a pure function of what the account holds. Parity with the browser's
// pages/InboxMain.tsx and the rail rules in components/AppLayout.tsx. The phone layout is the one
// ported: a Sent row reads "To: everyone" there, where a wide screen has room for one name.

public enum MailFolder: Hashable, Sendable {
    case inbox, starred, sent, drafts, archive, deleted, search
    case label(String)
    case folder(String)
}

/// The picture above an empty list.
public enum EmptyIcon: Sendable, Equatable {
    case archive, star, trash, inbox, search
}

public struct MailRow: Identifiable, Sendable {
    /// The hash of the message the row draws.
    public let id: String
    /// Every copy the row stands for, so deleting it removes all of them.
    public let hashes: [String]
    public let who: String
    public let subject: String
    /// Withheld for a sender not yet trusted, and nil when cleaning left nothing to show.
    public let snippet: String?
    public let when: String
    public let kind: SenderKind
    /// The counterparty is a contact whose pinned key still holds. A glanceable hint, not an access
    /// decision: the reader still runs the full check on open.
    public let trustedSender: Bool
    public let isUnread: Bool
    public let isStarred: Bool
    /// The sender isn't in the contacts yet. Grants nothing; just a cue.
    public let isNewSender: Bool
    public let isSent: Bool
    public let inArchive: Bool
    public let inDeleted: Bool
    /// Which of the account's other addresses it came to.
    public let deliveredTo: String?
    /// Search results only: where the message lives.
    public let place: String?
}

/// Everything a list is built from.
public struct MailFolderInput {
    public var folder: MailFolder
    public var messages: [MailPreview]
    public var sent: [MailPreview]
    public var flags: [String: FlagRecord]
    public var labels: [LabelDef]
    public var folders: [FolderDef]
    public var contacts: [ContactRecord]
    public var filter: FilterList?
    public var address: String?
    /// Parse the box only in the Search view: every other view leaves the query waiting there.
    public var query: ParsedQuery
    /// What the index found. Nil until it answers: rows match on their headers meanwhile.
    public var hits: SearchHits?
    /// Nil while there's no index.
    public var progress: SearchProgress?
    /// The directory's word on someone who isn't a contact, from their address and the signing key
    /// (empty in Sent). Answer from a cache and say unknown until it lands: a row never claims what
    /// it can't back, and this function stays pure.
    public var kind: (_ address: String, _ messageKeyHex: String) -> SenderKind

    // Which sources have answered. Until they have, a view can't say what belongs in it.
    public var flagsReady: Bool
    public var labelsReady: Bool
    public var filterReady: Bool
    public var mailLoaded: Bool
    public var sentLoaded: Bool

    /// Subjects a build handles in panels of its own. None in the reference build.
    public var control: Set<String>
    /// Days deleted mail waits, from the account's settings.
    public var keepDays: Int
    /// Reading is locked at the relay, so an empty list says nothing about the mailbox.
    public var locked: Bool
    /// A listing failed, which already explains an empty list.
    public var listFailed: Bool
    /// The build has a Getting started page and it hasn't been put away.
    public var gettingStartedVisible: Bool
    public var now: Date
    public var locale: Locale
    public var timeZone: TimeZone

    public init(
        folder: MailFolder, messages: [MailPreview], sent: [MailPreview], flags: [String: FlagRecord],
        labels: [LabelDef], folders: [FolderDef], contacts: [ContactRecord], filter: FilterList?, address: String?,
        query: ParsedQuery = ParsedQuery(), hits: SearchHits? = nil, progress: SearchProgress? = nil,
        kind: @escaping (_ address: String, _ messageKeyHex: String) -> SenderKind = { _, _ in .unknown },
        flagsReady: Bool = true, labelsReady: Bool = true, filterReady: Bool = true, mailLoaded: Bool = true,
        sentLoaded: Bool = true, control: Set<String> = [], keepDays: Int = MailView.trashDaysDefault,
        locked: Bool = false, listFailed: Bool = false, gettingStartedVisible: Bool = false, now: Date = Date(),
        locale: Locale = .current, timeZone: TimeZone = .current
    ) {
        self.folder = folder
        self.messages = messages
        self.sent = sent
        self.flags = flags
        self.labels = labels
        self.folders = folders
        self.contacts = contacts
        self.filter = filter
        self.address = address
        self.query = query
        self.hits = hits
        self.progress = progress
        self.kind = kind
        self.flagsReady = flagsReady
        self.labelsReady = labelsReady
        self.filterReady = filterReady
        self.mailLoaded = mailLoaded
        self.sentLoaded = sentLoaded
        self.control = control
        self.keepDays = keepDays
        self.locked = locked
        self.listFailed = listFailed
        self.gettingStartedVisible = gettingStartedVisible
        self.now = now
        self.locale = locale
        self.timeZone = timeZone
    }
}

/// The address book, for lookups by address without a trip to the store's actor.
struct ContactBook {
    private let byAddress: [String: ContactRecord]

    init(_ records: [ContactRecord]) {
        byAddress = Dictionary(
            records.map { (JSText.normalizedAddress($0.address), $0) }, uniquingKeysWith: { _, last in last })
    }

    func contact(for address: String) -> ContactRecord? {
        byAddress[JSText.normalizedAddress(address)]
    }

    /// The name the owner chose, else the address. A name that is just the address again is none.
    func name(for address: String) -> String {
        let name = contact(for: address).map { JSText.trim($0.name) } ?? ""
        if name.isEmpty || JSText.same(JSText.normalizedAddress(name), JSText.normalizedAddress(address)) {
            return address
        }
        return name
    }
}

public struct MailFolderView: Sendable {
    public let rows: [MailRow]
    /// Nothing is shown until flags, labels and the block list have answered, rather than every
    /// message followed a moment later by the archived, filed and blocked ones disappearing.
    public let isSorting: Bool
    public let folderTitle: String
    public let emptyText: String
    public let emptyIcon: EmptyIcon
    /// Nil when the list can't honestly claim a count.
    public let rowCountText: String?
    public let deletedNote: String
    /// Said while the index catches up, so a search that misses a message's text doesn't read as
    /// "no such message".
    public let searchProgressNote: String?
    /// The Inbox should point at Getting started instead of its empty text.
    public let isFirstRun: Bool

    public static var firstRunText: String {
        "Nothing here yet. Getting started shows how to try it with an email account you already have."
    }
    public static var firstRunAction: String { "Open Getting started" }

    public init(_ input: MailFolderInput) {
        let builder = Builder(input)
        rows = builder.rows()
        isSorting = builder.sorting
        folderTitle = MailView.folderTitle(input.folder, labels: input.labels, folders: input.folders)
        emptyText = MailView.emptyText(input.folder)
        emptyIcon = MailView.emptyIcon(input.folder)
        rowCountText =
            input.locked && rows.isEmpty ? nil : "\(rows.count) \(rows.count == 1 ? "message" : "messages")"
        deletedNote = MailView.deletedNote(keepDays: input.keepDays)
        searchProgressNote = MailView.searchProgressNote(
            folder: input.folder, query: input.query, progress: input.progress, locale: input.locale)
        isFirstRun =
            input.gettingStartedVisible && input.folder == .inbox
            && MailView.isFirstRun(
                FirstRunInput(
                    mailLoaded: input.mailLoaded, sentLoaded: input.sentLoaded, mailCount: builder.mail.count,
                    sentCount: input.sent.count, explained: input.locked || input.listFailed))
    }

    /// One row-to-be: a message and every hash it stands for.
    private struct Entry {
        var message: MailPreview
        var hashes: [String]
    }

    private struct Builder {
        let input: MailFolderInput
        let mail: [MailPreview]
        let contacts: ContactBook
        let folderIDs: Set<String>
        let sorting: Bool
        let when: WhenFormatter

        init(_ input: MailFolderInput) {
            self.input = input
            mail = input.messages.filter { !input.control.contains($0.subject) }
            contacts = ContactBook(input.contacts)
            folderIDs = Set(input.folders.map(\.id))
            sorting = !input.flagsReady || (input.folder != .sent && !(input.labelsReady && input.filterReady))
            when = WhenFormatter(locale: input.locale, timeZone: input.timeZone)
        }

        private func flag(_ hash: String) -> FlagRecord? { input.flags[hash] }
        private func isTrashed(_ hash: String) -> Bool { flag(hash)?.trashedAt != nil }
        private func isArchived(_ hash: String) -> Bool { flag(hash)?.archived == true }
        private func isStarred(_ hash: String) -> Bool { flag(hash)?.starred == true }

        /// Compared as typed, where other rules fold case: this is how the browser picks out what
        /// the account itself sent from what merely addresses it.
        private func isOwn(_ m: MailPreview) -> Bool {
            input.address.map { JSText.same(m.attributedAddress, $0) } ?? false
        }

        private func category(_ m: MailPreview) -> SenderCategory {
            if isOwn(m) { return .allowlisted }
            return TrustCategory.categorize(
                senderAddress: m.senderAddress, senderKeyHex: m.senderPublicKey,
                contact: contacts.contact(for: m.senderAddress), filter: input.filter)
        }

        /// Decided by the message, not the view, so a sent message found by search or waiting in
        /// Deleted still reads as one.
        private func isSentRow(_ m: MailPreview) -> Bool {
            input.folder == .sent || SentStore.isSentHash(m.hash)
                || !MailView.isReceivedForMe(m, address: input.address)
        }

        func rows() -> [MailRow] {
            if sorting { return [] }
            switch input.folder {
            case .drafts: return []
            case .search:
                let (entries, placed) = searchEntries()
                return entries.map { row($0, place: placed[$0.message.hash].map(placeLabel)) }
            case .sent: return sentEntries().map { row($0, place: nil) }
            case .deleted: return deletedEntries().map { row($0, place: nil) }
            default: return mail.filter(isListed).map { row(Entry(message: $0, hashes: [$0.hash]), place: nil) }
            }
        }

        /// Folds every copy sharing a message id into one row, keeping the newest as representative
        /// and everyone it went to. A send already writes one self-copy; this collapses legacy ones.
        private func groupSent(_ previews: [MailPreview]) -> [Entry] {
            var order: [String] = []
            var byKey: [String: Entry] = [:]
            for m in previews {
                let key = m.messageID.isEmpty ? m.hash : m.messageID
                guard var existing = byKey[key] else {
                    byKey[key] = Entry(message: m, hashes: [m.hash])
                    order.append(key)
                    continue
                }
                existing.hashes.append(m.hash)
                var base = m.sentAt > existing.message.sentAt ? m : existing.message
                base.to = Self.unique(existing.message.to + m.to)
                base.cc = Self.unique(existing.message.cc + m.cc)
                existing.message = base
                byKey[key] = existing
            }
            return order.compactMap { byKey[$0] }
        }

        private static func unique(_ list: [String]) -> [String] {
            var seen = Set<[UInt8]>()
            return list.filter { seen.insert(Array($0.utf8)).inserted }
        }

        private func sentEntries() -> [Entry] {
            // Sent reads from the personal store; legacy self-copies still in the mailbox fold in, so
            // nothing is lost.
            let stored = Set(input.sent.map(\.messageID))
            let legacy = mail.filter {
                isOwn($0) && !isTrashed($0.hash) && ($0.messageID.isEmpty || !stored.contains($0.messageID))
            }
            let rows = input.sent.filter { !isTrashed($0.hash) }.map { Entry(message: $0, hashes: [$0.hash]) }
            return (rows + groupSent(legacy)).stablySorted(descendingBy: \.message.sentAt)
        }

        private func deletedEntries() -> [Entry] {
            // Most recently deleted first: the one you want back is the one you just threw away.
            let shown = (mail + input.sent).filter {
                MailView.shownInDeleted(
                    $0, address: input.address, flags: input.flags, filter: input.filter, control: input.control)
            }
            return shown.map { Entry(message: $0, hashes: [$0.hash]) }
                .stablySorted(descendingBy: { flag($0.message.hash)?.trashedAt ?? 0 })
        }

        private func isListed(_ m: MailPreview) -> Bool {
            // A message I sent is a Sent item, unless I'm also a recipient.
            guard MailView.isReceivedForMe(m, address: input.address) else { return false }
            if isTrashed(m.hash) { return false }
            switch input.folder {
            case .label(let id): return flag(m.hash)?.labelIds?.contains(id) ?? false
            case .folder(let id): return flag(m.hash)?.folderId == id
            case .archive: return isArchived(m.hash)
            case .starred: return isStarred(m.hash)
            default:
                // Filed only if the folder still exists, so deleting one returns its mail here with
                // no flag clean-up. There's no trust split: trust is decided when a message is read.
                let filed = flag(m.hash)?.folderId.map { !$0.isEmpty && folderIDs.contains($0) } ?? false
                return category(m) != .blocked && !isArchived(m.hash) && !filed
            }
        }

        private func placeName(_ place: MailPlace) -> String {
            switch place {
            case .inbox: "inbox"
            case .archive: "archive"
            case .sent: "sent"
            case .deleted: "deleted"
            case .folder(let id): input.folders.first { $0.id == id }?.name ?? "Folder"
            }
        }

        /// The tag on a search result: the view's name as the rail shows it, or the folder's own.
        private func placeLabel(_ place: MailPlace) -> String {
            switch place {
            case .inbox: "Inbox"
            case .archive: "Archive"
            case .sent: "Sent"
            case .deleted: "Deleted"
            case .folder: placeName(place)
            }
        }

        private func searchEntries() -> (entries: [Entry], placed: [String: MailPlace]) {
            let context = PlaceContext(
                address: input.address, flags: input.flags, filter: input.filter, control: input.control,
                knownFolderIDs: folderIDs)
            var placed: [String: MailPlace] = [:]
            let match = MatchContext(
                nameFor: contacts.name(for:),
                isRead: { [flags = input.flags] in flags[$0]?.read == true },
                isStarred: isStarred,
                labelNames: { [labels = input.labels, flags = input.flags] hash in
                    (flags[hash]?.labelIds ?? []).compactMap { id in
                        labels.first { $0.id == id }?.name
                    }
                    .filter { !$0.isEmpty }
                },
                placeNames: { _ in [] })
            // A legacy self-copy of a message the Sent store also holds is the same message twice;
            // the remaining legacy copies fold together, as they do in Sent.
            let stored = Set(input.sent.map(\.messageID))
            var found: [Entry] = []
            var legacy: [MailPreview] = []
            for m in mail + input.sent {
                guard let place = MailView.placeOf(m, context) else { continue }
                let legacySent = place == .sent && !SentStore.isSentHash(m.hash)
                if legacySent, !m.messageID.isEmpty, stored.contains(m.messageID) { continue }
                placed[m.hash] = place
                var perMessage = match
                // A filed message that is also archived is listed in both, so in:archive finds it.
                perMessage.placeNames = { [isArchived = isArchived(m.hash), name = placeName(place)] _ in
                    if case .folder = place, isArchived { return [name, "archive"] }
                    return [name]
                }
                guard MailSearch.matches(m, input.query, context: perMessage, hits: input.hits) else { continue }
                if legacySent {
                    legacy.append(m)
                } else {
                    found.append(Entry(message: m, hashes: [m.hash]))
                }
            }
            return ((found + groupSent(legacy)).stablySorted(descendingBy: \.message.sentAt), placed)
        }

        /// A contact answers from what's held here. A withheld row claims nothing: the header's
        /// address is exactly what the checks refused, so it can't earn anyone's shield.
        private func kind(of m: MailPreview, about: String, sent: Bool) -> SenderKind {
            if m.attributionWithheld { return .unknown }
            let local = SenderKind.of(contact: contacts.contact(for: about))
            return local != .unknown ? local : input.kind(about, sent ? "" : m.senderPublicKey)
        }

        private func row(_ entry: Entry, place: String?) -> MailRow {
            let m = entry.message
            let sent = isSentRow(m)
            let unknownSender = !sent && !m.attributionWithheld && category(m) == .pending
            let recipients = MailView.recipientsOf(m)
            let about = sent ? recipients[0] : m.senderAddress

            let who: String
            switch m.sender {
            case _ where sent: who = "To: " + recipients.map(contacts.name(for:)).joined(separator: ", ")
            // Copy the app already uses for these. The claimed address must not read as who it's from.
            case .mismatch: who = "Possibly forged sender"
            case .disowned: who = "Sender not vouched for"
            case .unreadable: who = "Couldn't open this message"
            case .verified, .unverified:
                who =
                    DisplayName.senderLabel(
                        address: about, contactName: contacts.name(for: about), wireDisplay: m.senderDisplay
                    ).primary
            }
            let trusted =
                sent
                ? contacts.contact(for: recipients[0]) != nil
                : !m.attributionWithheld && !isOwn(m) && category(m) == .allowlisted
            let preview = !m.snippet.isEmpty && !unknownSender ? MailView.previewText(m.snippet) : ""
            return MailRow(
                id: m.hash, hashes: entry.hashes, who: who, subject: m.subject.isEmpty ? "(no subject)" : m.subject,
                snippet: preview.isEmpty ? nil : preview,
                when: m.sentAt == 0 && m.sender == .unreadable ? "" : when.string(m.sentAt, now: input.now),
                kind: kind(of: m, about: about, sent: sent),
                trustedSender: trusted, isUnread: !sent && flag(m.hash)?.read != true, isStarred: isStarred(m.hash),
                isNewSender: unknownSender, isSent: sent, inArchive: isArchived(m.hash), inDeleted: isTrashed(m.hash),
                deliveredTo: sent ? nil : m.deliveredTo.flatMap { $0.isEmpty ? nil : $0 }, place: place)
        }
    }
}

extension MailView {
    public static func folderTitle(_ folder: MailFolder, labels: [LabelDef], folders: [FolderDef]) -> String {
        switch folder {
        case .label(let id): labels.first { $0.id == id }?.name ?? "Label"
        case .folder(let id): folders.first { $0.id == id }?.name ?? "Folder"
        case .sent: "Sent"
        case .archive: "Archive"
        case .starred: "Starred"
        case .deleted: "Deleted"
        case .search: "Search results"
        case .drafts: "Drafts"
        case .inbox: "Inbox"
        }
    }

    public static func emptyText(_ folder: MailFolder) -> String {
        switch folder {
        case .sent: "Nothing sent yet."
        case .archive: "Nothing archived."
        case .starred: "No starred messages."
        case .label: "No messages with this label."
        case .folder: "This folder is empty."
        case .deleted: "Nothing waiting to be deleted."
        case .search: "No messages match your search."
        case .inbox, .drafts: "You're all caught up. Nothing else to read."
        }
    }

    public static func emptyIcon(_ folder: MailFolder) -> EmptyIcon {
        switch folder {
        case .search: .search
        case .archive: .archive
        case .starred: .star
        case .deleted: .trash
        default: .inbox
        }
    }

    public static func deletedNote(keepDays: Int) -> String {
        let wait = keepDays == 1 ? "a day" : "\(keepDays) days"
        return "Messages here are deleted for good \(wait) after you delete them. Restore one to keep it."
    }

    /// Only for words and filename patterns, which are all the index answers.
    public static func searchProgressNote(
        folder: MailFolder, query: ParsedQuery, progress: SearchProgress?, locale: Locale = .current
    ) -> String? {
        guard folder == .search, !query.words.isEmpty || !query.filenames.isEmpty, let progress,
            progress.indexed < progress.total
        else { return nil }
        let numbers = NumberFormatter()
        numbers.numberStyle = .decimal
        numbers.locale = locale
        func text(_ n: Int) -> String { numbers.string(from: NSNumber(value: n)) ?? String(n) }
        return "Search is still catching up on this device: \(text(progress.indexed)) of \(text(progress.total)) "
            + "messages can be found by their text so far."
    }

    /// Drafts is in the rail only while there are drafts.
    public static func hasDrafts(draftsLoaded: Bool, drafts: [DraftSummary]) -> Bool {
        draftsLoaded && !drafts.isEmpty
    }

    /// Deleted is in the rail only while something is waiting there, and isn't decided until the
    /// listings, flags and block list have all answered, so the row doesn't come and go as they load.
    public static func hasDeleted(
        flagsReady: Bool, filterReady: Bool, mailLoaded: Bool, sentLoaded: Bool, messages: [MailPreview],
        sent: [MailPreview], address: String?, flags: [String: FlagRecord], filter: FilterList?,
        control: Set<String> = []
    ) -> Bool {
        guard flagsReady, filterReady, mailLoaded, sentLoaded else { return false }
        return (messages + sent).contains {
            shownInDeleted($0, address: address, flags: flags, filter: filter, control: control)
        }
    }

    /// The view to be on once the rail has changed: the last draft or deleted message going takes
    /// its view back to the Inbox. `deletedKnown` is whether `hasDeleted` had its answers.
    public static func folderAfterRailChange(
        _ folder: MailFolder, draftsLoaded: Bool, draftCount: Int, deletedKnown: Bool, hasDeleted: Bool
    ) -> MailFolder {
        if folder == .drafts, draftsLoaded, draftCount == 0 { return .inbox }
        if folder == .deleted, deletedKnown, !hasDeleted { return .inbox }
        return folder
    }
}
