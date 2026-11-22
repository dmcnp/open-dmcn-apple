import DMCNKit
import Foundation
import Observation

/// One signed-in account: its mail, its stores and what's on screen. Anything awaited here
/// checks `isClosed` before it lands, so a sign-out can't leave its mail behind.
@MainActor
@Observable
final class MailSession {
    enum Section: Equatable {
        case mail, contacts, settings
    }

    enum ContactSave {
        case saved, noIdentity
    }

    let services: SessionServices
    var address: String { services.keys.address }
    var host: String { services.host }

    // What's on screen.
    var section = Section.mail
    private(set) var folder = MailFolder.inbox
    private var searchFrom = MailFolder.inbox
    var query = "" {
        didSet { queryChanged() }
    }
    private(set) var openMessage: ReaderModel?
    var composing: ComposeModel?
    var errorMessage: String?

    // What the account holds.
    private(set) var messages: [MailPreview] = []
    private(set) var sent: [MailPreview] = []
    private(set) var flags: [String: FlagRecord] = [:]
    private(set) var labels: [LabelDef] = []
    private(set) var folders: [FolderDef] = []
    private(set) var allContacts: [ContactRecord] = []
    private(set) var filter: FilterList?
    private(set) var settings = AppSettings()
    private(set) var drafts: [DraftSummary] = []
    private(set) var storageIsLocalOnly = false
    private(set) var storageUsage: StorageUsage?

    // What's answered so far.
    private(set) var isLoading = false
    private(set) var loadFailed = false
    private var mailLoaded = false
    private var sentLoaded = false
    private var flagsReady = false
    private var labelsReady = false
    private var filterReady = false
    private var settingsLoaded = false
    private var draftsLoaded = false
    private var isClosed = false
    private var purging: Set<String> = []

    /// Directory keys by lowercased address, for the shield on each row.
    private var directoryKeys: [String: String?] = [:]
    private var hits: SearchHits?
    private var progress: SearchProgress?

    // The current view of the mail, rebuilt whenever anything it reads changes.
    private(set) var view: MailFolderView
    private(set) var unreadCount = 0
    private(set) var hasDeleted = false

    var rows: [MailRow] { view.rows }
    var isSorting: Bool { view.isSorting }
    var folderTitle: String { view.folderTitle }
    var emptyText: String { view.emptyText }
    var emptyIcon: EmptyIcon { view.emptyIcon }
    var rowCountText: String? { view.rowCountText }
    var deletedNote: String { view.deletedNote }
    var searchProgressNote: String? { view.searchProgressNote }
    var listError: String? { loadFailed ? "Couldn't load your mail. Pull down to try again." : nil }
    var isLocked: Bool { loadFailed && messages.isEmpty }
    var isReading: Bool { openMessage != nil }
    var hasSearch: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }
    var trashDays: Int { settings.keepDays }
    /// Worked out from this device's keys, never asked of the server: reading it to someone is how
    /// they catch a server handing out the wrong key, so the server can't be what supplies it.
    var fingerprintGrouped: String {
        let fingerprint = services.keys.fingerprint
        return stride(from: 0, to: fingerprint.count, by: 4).map { start in
            let from = fingerprint.index(fingerprint.startIndex, offsetBy: start)
            return String(fingerprint[from...].prefix(4))
        }.joined(separator: "·")
    }
    var blockedSenders: [String] { filter?.senders ?? [] }

    init(services: SessionServices) {
        self.services = services
        view = MailFolderView(
            MailFolderInput(
                folder: .inbox, messages: [], sent: [], flags: [:], labels: [], folders: [], contacts: [], filter: nil,
                address: services.keys.address, flagsReady: false, labelsReady: false, filterReady: false,
                mailLoaded: false, sentLoaded: false))
    }

    // MARK: Loading

    func refresh() async {
        guard !isClosed, !isLoading else { return }
        isLoading = true
        defer { if !isClosed { isLoading = false } }
        let services = services
        async let mail = Self.attempt { try await services.inbox.allPreviews() }
        async let sentList = Self.attempt { try await services.sent.list() }
        async let flagList = Self.attempt { try await services.flags.list() }
        async let draftList = Self.attempt { try await services.drafts.list() }
        async let usage = Self.attempt { try await services.storage.stat() }
        async let contacts = services.contacts.refresh()
        await services.labels.refresh()
        await services.filter.refresh()
        await services.settings.refresh()
        let doc = await services.labels.doc
        let block = await services.filter.filter
        let settings = await services.settings.settings
        let (mailResult, sentResult, flagResult, draftResult) = await (mail, sentList, flagList, draftList)
        let (usageResult, contactList) = await (usage, contacts)
        let localOnly = await services.isLocalOnly()
        guard !isClosed else { return }

        if let mailResult {
            messages = mailResult
            mailLoaded = true
        }
        loadFailed = mailResult == nil
        if let sentResult {
            sent = sentResult.map(MailPreview.init(sent:))
            sentLoaded = true
        }
        if let flagResult {
            flags = flagResult
            flagsReady = true
        }
        if let draftResult {
            drafts = draftResult
            draftsLoaded = true
        }
        labels = doc.labels
        folders = doc.folders
        labelsReady = true
        filter = block
        filterReady = true
        self.settings = settings
        settingsLoaded = true
        allContacts = contactList
        storageUsage = usageResult
        storageIsLocalOnly = localOnly
        rebuild()
        applyFilingRules()
        await resolveKinds()
        await sweepTrash()
        await updateSearch()
    }

    private nonisolated static func attempt<T: Sendable>(_ work: @Sendable () async throws -> T) async -> T? {
        try? await work()
    }

    private func rebuild() {
        let keys = directoryKeys
        let contacts = allContacts
        view = MailFolderView(
            MailFolderInput(
                folder: folder, messages: messages, sent: sent, flags: flags, labels: labels, folders: folders,
                contacts: contacts, filter: filter, address: address,
                query: MailSearch.parseQuery(folder == .search ? query : ""), hits: hits, progress: progress,
                kind: { address, messageKey in
                    let local = SenderKind.of(
                        contact: contacts.first { $0.address.lowercased() == address.lowercased() })
                    if local != .unknown { return local }
                    guard let known = keys[address.lowercased()] else { return .unknown }
                    return SenderKind.fromDirectory(key: known, messageKeyHex: messageKey)
                },
                flagsReady: flagsReady, labelsReady: labelsReady, filterReady: filterReady, mailLoaded: mailLoaded,
                sentLoaded: sentLoaded, keepDays: trashDays, locked: isLocked, listFailed: loadFailed))
        // The Inbox's own unread mail: what rules or the owner filed into a folder no longer counts.
        // The web still counts it (docs/PARITY-WITH-WEB.md).
        unreadCount =
            flagsReady && filterReady
            ? MailView.countUnread(
                messages, address: address, flags: flags, filter: filter, filedIn: Set(folders.map(\.id))) : 0
        hasDeleted = MailView.hasDeleted(
            flagsReady: flagsReady, filterReady: filterReady, mailLoaded: mailLoaded, sentLoaded: sentLoaded,
            messages: messages, sent: sent, address: address, flags: flags, filter: filter)
        let deletedKnown = flagsReady && filterReady && mailLoaded && sentLoaded
        let next = MailView.folderAfterRailChange(
            folder, draftsLoaded: draftsLoaded, draftCount: drafts.count, deletedKnown: deletedKnown,
            hasDeleted: hasDeleted)
        if next != folder {
            folder = next
            rebuild()
        }
    }

    /// Asks the directory about each sender the contacts can't speak for, a few at a time.
    private func resolveKinds() async {
        let wanted = Set((messages.map(\.senderAddress) + sent.flatMap(MailView.recipientsOf)).map { $0.lowercased() })
            .subtracting(directoryKeys.keys)
        let directory = services.directory
        for batch in Array(wanted).chunked(into: 8) {
            guard !isClosed else { return }
            let answers = await withTaskGroup(of: (String, String?).self) { group in
                for address in batch {
                    group.addTask { (address, SenderKind.directoryKey(try? await directory(address))) }
                }
                var found: [(String, String?)] = []
                for await answer in group { found.append(answer) }
                return found
            }
            guard !isClosed else { return }
            for (address, key) in answers { directoryKeys[address] = .some(key) }
            rebuild()
        }
    }

    // MARK: Moving around

    func select(_ next: MailFolder) {
        section = .mail
        openMessage = nil
        folder = next == .search && !hasSearch ? .inbox : next
        rebuild()
    }

    private func queryChanged() {
        if hasSearch, folder != .search {
            searchFrom = folder
            folder = .search
            openMessage = nil
        } else if !hasSearch, folder == .search {
            folder = searchFrom
        }
        rebuild()
        Task { await lookUpQuery() }
    }

    private func updateSearch() async {
        guard let search = services.search, filterReady else { return }
        await search.update(
            messages: messages, sent: sent, filter: filter, address: address, control: [],
            complete: mailLoaded && sentLoaded)
        await search.kick()
    }

    private func lookUpQuery() async {
        guard let search = services.search else { return }
        let asked = query
        let found = await search.lookup(MailSearch.parseQuery(asked))
        let reached = await search.progress()
        guard !isClosed, asked == query else { return }
        hits = found
        progress = reached
        rebuild()
    }

    func open(_ row: MailRow) {
        guard let message = (messages + sent).first(where: { $0.hash == row.id }) else { return }
        if !SentStore.isSentHash(message.hash), MailView.isReceivedForMe(message, address: address) {
            setFlag(message.hash, FlagDelta(read: .set(true)))
        }
        openMessage = ReaderModel(session: self, message: message, sentView: row.isSent)
    }

    func closeMessage() {
        openMessage = nil
    }

    // MARK: Flags

    func flag(_ hash: String) -> FlagRecord? { flags[hash] }

    /// Applies at once and writes behind it, so the list answers the tap. A refused write is said
    /// out loud: on a Sent row the relay refuses every flag, and silently undoing that is how the
    /// web client's Delete came to do nothing there.
    func setFlag(_ hash: String, _ delta: FlagDelta) {
        let current = flags[hash]
        let store = services.flags
        Task {
            do {
                let record = try await store.apply(hash, current: current, delta: delta)
                guard !isClosed else { return }
                flags[hash] = record
                rebuild()
            } catch {
                guard !isClosed else { return }
                errorMessage = "Couldn't save that change. \(error.localizedDescription)"
            }
        }
    }

    func toggleStar(_ hash: String) {
        setFlag(hash, FlagDelta(starred: .set(!(flags[hash]?.starred ?? false))))
    }

    func trash(_ hash: String) {
        setFlag(hash, FlagDelta(trashedAt: .set(systemClock())))
    }

    func restore(_ row: MailRow) {
        row.hashes.forEach(restore)
    }

    func restore(_ hash: String) {
        setFlag(hash, FlagDelta(trashedAt: .clear))
    }

    func deleteForever(_ row: MailRow) {
        Task { for hash in row.hashes { await deleteForever(hash) } }
    }

    func deleteForever(_ hash: String) async {
        do {
            if SentStore.isSentHash(hash), let message = sent.first(where: { $0.hash == hash }) {
                try await services.sent.delete(messageID: message.messageID)
            } else {
                try await services.deleteMessage(hash)
            }
            await services.flags.remove(hash)
            guard !isClosed else { return }
            messages.removeAll { $0.hash == hash }
            sent.removeAll { $0.hash == hash }
            flags[hash] = nil
            rebuild()
        } catch {
            guard !isClosed else { return }
            errorMessage = "Couldn't delete that message. \(error.localizedDescription)"
        }
    }

    /// Deleted mail whose time is up goes for good while the app is open.
    private func sweepTrash() async {
        let due = MailView.trashDue(
            state: TrashSweepState(
                flagsReady: flagsReady, mailLoaded: mailLoaded, sentLoaded: sentLoaded, settingsLoaded: settingsLoaded,
                accessOK: !loadFailed),
            flags: flags, days: trashDays, messages: messages, sent: sent, now: systemClock(), inFlight: purging)
        for item in due {
            purging.insert(item.hash)
            await deleteForever(item.hash)
            purging.remove(item.hash)
        }
    }

    // MARK: Filing

    /// What filing works on: a swiped row, or the open message. Every copy of the message moves.
    struct FilingTarget: Identifiable {
        let id: String
        let hashes: [String]

        init(_ row: MailRow) {
            id = row.id
            hashes = row.hashes
        }

        init(hash: String) {
            id = hash
            hashes = [hash]
        }
    }

    /// Filing asks first, unless the owner turned the question off: this message alone, or the
    /// sender's mail now and from now on. Nothing moves until the owner answers.
    struct FilingOffer: Identifiable, Equatable {
        let id = UUID()
        let sender: String
        let senderName: String
        /// Nil is back to the Inbox, which ends the sender's rule: the Inbox is where unsorted mail
        /// lands anyway.
        let folderID: String?
        let folderName: String
        /// Where the message is now ("the Inbox", or a folder's name): the sender's other mail comes
        /// only from there.
        let fromName: String
        /// The swiped message (every copy of it).
        let hashes: [String]
        /// The sender's other mail that moves too if the owner says always.
        let others: [String]

        var toInbox: Bool { folderID == nil }

        var title: String {
            toInbox
                ? "Move mail from \(senderName) back to the Inbox?"
                : "Move mail from \(senderName) to \(folderName)?"
        }

        var answer: String { toInbox ? "Always use the Inbox" : "Always move to \(folderName)" }

        var summary: String {
            let later =
                toInbox
                ? "new mail from \(senderName) will arrive in the Inbox again."
                : "new mail from \(senderName) will go there automatically."
            let there = "from \(senderName) in \(fromName)"
            switch others.count {
            case 0: return "From now on, \(later)"
            case 1: return "1 other message \(there) will move there now, and \(later)"
            default: return "\(others.count) other messages \(there) will move there now, and \(later)"
            }
        }
    }

    private(set) var filingOffer: FilingOffer?

    var swipeFiling: SwipeFiling { settings.swipeFiling }

    /// A right swipe files where mail is waiting to be sorted: the Inbox and the folders.
    func canFile(_ row: MailRow) -> Bool {
        guard !row.isSent, !row.inDeleted else { return false }
        switch folder {
        case .inbox, .folder: return true
        default: return false
        }
    }

    /// Labels go on any received mail that isn't in Deleted: the relay refuses flags on Sent rows.
    func canLabel(_ row: MailRow) -> Bool { !row.isSent && !row.inDeleted }

    func folderName(_ id: String) -> String {
        folders.first { $0.id == id }?.name ?? "a folder"
    }

    private var placeContext: PlaceContext {
        PlaceContext(address: address, flags: flags, filter: filter, knownFolderIDs: Set(folders.map(\.id)))
    }

    /// Where a message lives now, for the open message's folder button.
    func place(of hash: String) -> MailPlace? {
        guard let message = (messages + sent).first(where: { $0.hash == hash }) else { return nil }
        return MailView.placeOf(message, placeContext)
    }

    func placeName(_ place: MailPlace) -> String {
        switch place {
        case .inbox: "Inbox"
        case .archive: "Archive"
        case .sent: "Sent"
        case .deleted: "Deleted"
        case .folder(let id): folderName(id)
        }
    }

    /// The folder picker's choices for a message: every folder but the one it's in, and the Inbox
    /// unless it's already there (from Archive, the Inbox brings it back).
    func filingChoices(for target: FilingTarget) -> (includeInbox: Bool, folders: [FolderDef]) {
        let here = place(of: target.id)
        return (here != .inbox, folders.filter { MailPlace.folder($0.id) != here })
    }

    func file(_ row: MailRow, in folderID: String?) {
        file(FilingTarget(row), in: folderID)
    }

    /// Files a message in a folder, or back in the Inbox with nil. Asks first whether the rest of
    /// the sender's mail should follow, and moves nothing until answered. Files straight away when
    /// the owner turned the question off, or there's nothing to ask: a sender filing can't follow,
    /// one a rule already files there, or (for the Inbox) no rule and nothing else to move.
    func file(_ target: FilingTarget, in folderID: String?) {
        guard swipeFiling.asksAboutSender, let message = messages.first(where: { $0.hash == target.id }) else {
            return moveWithUndo(target.hashes, to: folderID)
        }
        let others = MailView.sameSenderMail(as: message, into: folderID, among: messages, placeContext)
            .filter { !target.hashes.contains($0) }
        guard let sender = MailView.filingSender(message) else { return moveWithUndo(target.hashes, to: folderID) }
        let rule = swipeFiling.rule(for: sender)
        if let folderID, rule?.folderID == folderID { return moveWithUndo(target.hashes, to: folderID) }
        if folderID == nil, rule == nil, others.isEmpty { return moveWithUndo(target.hashes, to: folderID) }
        let from = MailView.placeOf(message, placeContext)
        filingOffer = FilingOffer(
            sender: sender, senderName: name(for: sender), folderID: folderID,
            folderName: folderID.map(folderName) ?? "the Inbox",
            fromName: from.map { $0 == .inbox ? "the Inbox" : placeName($0) } ?? "the Inbox",
            hashes: target.hashes, others: others)
    }

    /// A folder made from the picker, with the message filed in it straight after.
    func createFolder(name: String, andFile target: FilingTarget) async {
        if let id = await createFolder(name: name) { file(target, in: id) }
    }

    /// Always: this message and the sender's other mail move now, and from here on their new mail is
    /// filed there by a rule, or, for the Inbox, simply isn't filed any more. Takes the offer it
    /// answers, because the dialog closing clears `filingOffer` before this runs.
    func acceptFilingOffer(_ offer: FilingOffer) async {
        if filingOffer == offer { filingOffer = nil }
        let before = UndoNotice.RuleUndo(sender: offer.sender, before: swipeFiling.rule(for: offer.sender))
        moveWithUndo(offer.hashes + offer.others, to: offer.folderID, count: offer.others.count + 1, rule: before)
        let (sender, now) = (offer.sender, Date())
        if let folderID = offer.folderID {
            _ = await change { $0.swipeFiling.setRule(sender: sender, folderID: folderID, now: now) }
        } else {
            await removeFilingRule(sender)
        }
    }

    /// Just this one: the swiped message moves, nothing else does, and no rule is made.
    func fileOnlyThis(_ offer: FilingOffer) {
        if filingOffer == offer { filingOffer = nil }
        moveWithUndo(offer.hashes, to: offer.folderID)
    }

    /// Cancel, or the question went away: nothing moves.
    func dismissFilingOffer() {
        filingOffer = nil
    }

    /// Moves by hand, with Undo: each message goes back to where it was, Archive included.
    /// `count` is how many messages the banner names; `rule` is the sender's rule before an
    /// "always", which Undo puts back.
    private func moveWithUndo(
        _ hashes: [String], to folderID: String?, count: Int = 1, rule: UndoNotice.RuleUndo? = nil
    ) {
        let restore = Dictionary(
            hashes.map { hash in
                let flag = flags[hash]
                return (
                    hash,
                    FlagDelta(
                        archived: flag?.archived.map { .set($0) } ?? .clear,
                        folderId: flag?.folderId.map { .set($0) } ?? .clear)
                )
            }, uniquingKeysWith: { first, _ in first })
        move(hashes, to: folderID)
        let place = folderID.map(folderName) ?? "the Inbox"
        let text = count > 1 ? "Moved \(count) messages to \(place)" : "Moved to \(place)"
        undoNotice = UndoNotice(text: text, restore: restore, rule: rule)
    }

    private func move(_ hashes: [String], to folderID: String?) {
        let delta = MailView.filingDelta(to: folderID)
        for hash in hashes { setFlag(hash, delta) }
    }

    // MARK: Labels

    func labelIDs(of target: FilingTarget) -> [String] { flags[target.id]?.labelIds ?? [] }

    /// Puts the label on every copy of the message, or takes it off.
    func toggleLabel(_ id: String, on target: FilingTarget) {
        let current = labelIDs(of: target)
        let next = current.contains(id) ? current.filter { $0 != id } : current + [id]
        for hash in target.hashes { setFlag(hash, FlagDelta(labelIds: .set(next))) }
    }

    /// A label made from the picker, put on the message straight after.
    func createLabel(name: String, color: String, andApply target: FilingTarget) async {
        if let id = await createLabel(name: name, color: color) { toggleLabel(id, on: target) }
    }

    // MARK: Undo

    /// Deleting or archiving says so for a few seconds, with a way back: a full swipe is easy to do
    /// by accident. `restore` puts each message's changed mark back as it was.
    struct UndoNotice: Identifiable, Equatable {
        let id = UUID()
        let text: String
        let restore: [String: FlagDelta]
        /// Filing with "always" also changed the sender's rule; Undo puts it back.
        var rule: RuleUndo?

        /// A sender's rule as it was before: nil when they had none.
        struct RuleUndo {
            let sender: String
            let before: FilingRule?
        }

        static func == (a: Self, b: Self) -> Bool { a.id == b.id }
    }

    private(set) var undoNotice: UndoNotice?

    /// Moves to Deleted, with Undo.
    func trash(_ row: MailRow) {
        trashWithUndo(row.hashes)
    }

    func trashWithUndo(_ hashes: [String]) {
        let restore = Dictionary(
            uniqueKeysWithValues: hashes.map { hash in
                (hash, FlagDelta(trashedAt: flags[hash]?.trashedAt.map { .set($0) } ?? .clear))
            })
        hashes.forEach(trash)
        undoNotice = UndoNotice(text: "Moved to Deleted", restore: restore)
    }

    /// Archives, or brings back from Archive, with Undo.
    func toggleArchive(_ row: MailRow) {
        setArchived(!(flags[row.id]?.archived ?? false), [row.id])
    }

    func setArchived(_ archived: Bool, _ hashes: [String]) {
        let restore = Dictionary(
            uniqueKeysWithValues: hashes.map { hash in
                (hash, FlagDelta(archived: flags[hash]?.archived.map { .set($0) } ?? .clear))
            })
        for hash in hashes { setFlag(hash, FlagDelta(archived: .set(archived))) }
        undoNotice = UndoNotice(text: archived ? "Archived" : "Moved out of Archive", restore: restore)
    }

    func undo(_ notice: UndoNotice) {
        if undoNotice == notice { undoNotice = nil }
        for (hash, delta) in notice.restore { setFlag(hash, delta) }
        if let rule = notice.rule {
            Task { _ = await change { $0.swipeFiling.restoreRule(rule.before, sender: rule.sender) } }
        }
    }

    /// Its time ran out, or another took its place.
    func dismissUndo(_ notice: UndoNotice) {
        if undoNotice == notice { undoNotice = nil }
    }

    /// Ordinary email in a folder from someone who isn't a contact: filed by its address alone,
    /// which nothing checked, so the row says so.
    ///
    /// DEV NOTE (low priority, first pass): this marks every such row in a folder, whether a rule or
    /// the owner filed it, and a contact's mail never. A better mark would read the bridge's
    /// SPF/DKIM/DMARC verdict (`BridgeAttestation`, in the encrypted body) and warn only when the
    /// checks failed or are missing. See the dev note on `MailView.filingSender`.
    func filedByAddressOnly(_ row: MailRow) -> Bool {
        guard case .folder = folder else { return false }
        return row.kind == .legacy && row.isNewSender
    }

    /// Files new mail the rules cover. Only once every source has answered: with flags missing,
    /// mail the owner already moved back would look untouched.
    private func applyFilingRules() {
        guard flagsReady, labelsReady, filterReady, mailLoaded, settingsLoaded else { return }
        for item in MailView.autoFiling(messages, rules: swipeFiling.rules, placeContext) {
            setFlag(item.hash, MailView.filingDelta(to: item.folderID))
        }
    }

    func setAsksAboutSender(_ on: Bool) async {
        _ = await change { $0.swipeFiling.asksAboutSender = on }
    }

    func setFullSwipeArchives(_ on: Bool) async {
        _ = await change { $0.swipeFiling.fullSwipeArchives = on }
    }

    func removeFilingRule(_ sender: String) async {
        _ = await change { $0.swipeFiling.removeRule(sender: sender) }
    }

    // MARK: Composing

    func compose() {
        start(DraftContent(from: address, text: ComposeReplies.startingText(signature: settings.signature)))
    }

    func start(_ content: DraftContent, title: String = "New message") {
        composing = ComposeModel(session: self, content: content, title: title)
    }

    func putAwayDraft() async {
        await composing?.putAway()
    }

    func draftsChanged() async {
        guard let list = try? await services.drafts.list(), !isClosed else { return }
        drafts = list
        draftsLoaded = true
        rebuild()
    }

    func openDraft(_ draft: DraftSummary) {
        Task {
            guard let loaded = try? await services.drafts.load(draft.id), !isClosed else { return }
            composing = ComposeModel(
                session: self, content: ComposeReplies.resuming(loaded), title: "New message", draft: loaded)
        }
    }

    func discardDraft(_ draft: DraftSummary) {
        Task {
            try? await services.drafts.delete(draft.id)
            await draftsChanged()
        }
    }

    func draftRecipients(_ draft: DraftSummary) -> String {
        let everyone = draft.to + draft.cc + draft.bcc
        return everyone.isEmpty ? "(no recipients)" : "To: " + everyone.map(name(for:)).joined(separator: ", ")
    }

    func draftWhen(_ draft: DraftSummary) -> String {
        MailView.formatWhen(draft.updatedAt / 1000)
    }

    // MARK: Contacts

    func contact(for address: String) -> ContactRecord? {
        allContacts.first { $0.address.lowercased() == address.lowercased() }
    }

    func name(for address: String) -> String {
        guard let name = contact(for: address)?.name, !name.isEmpty else { return address }
        return name
    }

    func contacts(matching query: String) -> [ContactRecord] {
        let wanted = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !wanted.isEmpty else { return allContacts }
        return allContacts.filter { "\($0.name) \($0.address)".lowercased().contains(wanted) }
    }

    func kind(of contact: ContactRecord) -> SenderKind {
        SenderKind.of(contact: contact)
    }

    func hasPinnedKey(_ contact: ContactRecord) -> Bool {
        contact.pinnedFacts != nil
    }

    func contactsChanged() async {
        let list = await services.contacts.refresh()
        guard !isClosed else { return }
        allContacts = list
        rebuild()
    }

    func removeContact(_ contact: ContactRecord) {
        Task {
            do {
                try await services.contacts.remove(contact.address)
                await contactsChanged()
            } catch {
                errorMessage = "Couldn't remove that contact. \(error.localizedDescription)"
            }
        }
    }

    /// A typed address with no identity behind it isn't filed as legacy on the quiet: it may be
    /// a typo. The sheet asks, and `asLegacy` is the answer.
    func saveContact(existing: ContactRecord?, address typed: String, name: String, asLegacy: Bool) async throws
        -> ContactSave
    {
        let target = typed.trimmingCharacters(in: .whitespaces)
        let shown = name.trimmingCharacters(in: .whitespaces)
        let label = shown.isEmpty ? target : shown
        if existing != nil || contact(for: target) != nil {
            _ = try await services.contacts.update(target, name: label)
        } else if asLegacy {
            _ = try await services.contacts.put(ContactRecord(address: target, name: label, fingerprint: ""))
        } else {
            guard let answer = try? await services.directory(target), !answer.legacy else { return .noIdentity }
            _ = try await services.contacts.put(
                ContactRecord(address: target, name: label, fingerprint: answer.fingerprint))
            // Pinned now, so a forgery can't arrive as this contact before their first real message
            // would have pinned it. There's nothing to believe in a disowned record.
            if !answer.identityUnverifiable {
                await services.contacts.pinKey(target, facts: PinnedFacts(directory: answer))
            }
        }
        await contactsChanged()
        return .saved
    }

    // MARK: Settings

    private func change(_ edit: @escaping @Sendable (inout AppSettings) -> Void) async -> Bool {
        do {
            try await services.settings.update(edit)
            let next = await services.settings.settings
            guard !isClosed else { return false }
            settings = next
            rebuild()
            return true
        } catch {
            errorMessage = "Couldn't save that setting. \(error.localizedDescription)"
            return false
        }
    }

    func saveSignature(_ signature: String) async -> Bool {
        await change { $0.signature = signature }
    }

    func setRemoteImages(_ on: Bool) async {
        _ = await change { $0.remoteImagesForTrusted = on }
    }

    func setTrashDays(_ days: Int) async {
        _ = await change { $0.trashDays = Int64(days) }
    }

    func unblock(_ sender: String) async {
        do {
            try await services.filter.removeSender(sender)
            await blockChanged()
        } catch {
            errorMessage = "Couldn't update your blocklist. \(error.localizedDescription)"
        }
    }

    func blockChanged() async {
        await services.filter.refresh()
        let list = await services.filter.filter
        guard !isClosed else { return }
        filter = list
        rebuild()
    }

    private func labelsChanged() async {
        await services.labels.refresh()
        let doc = await services.labels.doc
        guard !isClosed else { return }
        labels = doc.labels
        folders = doc.folders
        rebuild()
    }

    @discardableResult
    func createLabel(name: String, color: String) async -> String? {
        await editLabels { try await self.services.labels.createLabel(name: name, color: color) }
    }

    @discardableResult
    func createFolder(name: String) async -> String? {
        await editLabels { try await self.services.labels.createFolder(name: name) }
    }

    func deleteLabel(_ id: String) async {
        await editLabels { try await self.services.labels.deleteLabel(id: id) }
    }

    func deleteFolder(_ id: String) async {
        await editLabels { try await self.services.labels.deleteFolder(id: id) }
    }

    /// The folders in the order the owner dragged them into: shown at once, then saved for every
    /// device.
    func reorderFolders(_ ids: [String]) {
        folders = LabelStore.reordered(folders, by: ids, id: \.id)
        Task { await editLabels { try await self.services.labels.reorderFolders(ids) } }
    }

    func reorderLabels(_ ids: [String]) {
        labels = LabelStore.reordered(labels, by: ids, id: \.id)
        Task { await editLabels { try await self.services.labels.reorderLabels(ids) } }
    }

    @discardableResult
    private func editLabels<T>(_ edit: () async throws -> T) async -> T? {
        do {
            let result = try await edit()
            await labelsChanged()
            return result
        } catch {
            errorMessage = "Couldn't save that change. \(error.localizedDescription)"
            return nil
        }
    }

    // MARK: Closing

    func close() async {
        isClosed = true
        messages = []
        sent = []
        flags = [:]
        allContacts = []
        drafts = []
        openMessage = nil
        composing = nil
        errorMessage = nil
        loadFailed = false
        isLoading = false
        await services.search?.stop()
        await services.inbox.signOut()
    }

    var closed: Bool { isClosed }
}

extension Array {
    fileprivate func chunked(into size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}
