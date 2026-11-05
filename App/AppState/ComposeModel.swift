import DMCNKit
import Foundation
import Observation

/// One recipient field: the chips, and what's still being typed.
@MainActor
@Observable
final class RecipientList {
    private(set) var recipients: [String]
    var pending = ""
    /// Fires on every change, so the draft keeps up.
    var onChange: () -> Void = {}

    init(_ recipients: [String], pending: String = "") {
        self.recipients = recipients
        self.pending = pending
    }

    func commit() {
        recipients = Composer.committing(pending, into: recipients)
        pending = ""
        onChange()
    }

    func pick(_ address: String) {
        pending = address
        commit()
    }

    func remove(_ address: String) {
        recipients.removeAll { $0 == address }
        onChange()
    }

    /// Who's left to reach after a send that got to only some of them.
    func narrow(to addresses: [String]) {
        recipients = addresses
        pending = ""
        onChange()
    }
}

/// The composer's state. A message is saved as a draft as it's written and on the way out, and
/// sending goes through the kit's `Composer`, which owns who gets what.
@MainActor
@Observable
final class ComposeModel: Identifiable {
    nonisolated let id = UUID()
    let title: String
    let to: RecipientList
    let cc: RecipientList
    let bcc: RecipientList
    var subject: String { didSet { edited() } }
    var body: String { didSet { edited() } }
    private(set) var attachments: [DraftAttachment]
    private(set) var isSending = false
    private(set) var error: String?
    private(set) var sentReport: [SentReport.Item]?
    private(set) var savedContacts: Set<String> = []
    /// What's known about the recipients: who's encrypted, whose key changed, who forwards.
    private(set) var review: ComposeReview?

    private let session: MailSession
    private let opening: DraftContent
    private var retryThreadID: String?
    private let autosave: DraftAutosave

    init(session: MailSession, content: DraftContent, title: String, draft: LoadedDraft? = nil) {
        self.session = session
        self.title = title
        opening = content
        to = RecipientList(content.to, pending: content.pending.to)
        cc = RecipientList(content.cc, pending: content.pending.cc)
        bcc = RecipientList(content.bcc, pending: content.pending.bcc)
        subject = content.subject
        body = content.text
        attachments = content.attachments
        autosave = DraftAutosave(
            store: session.services.drafts, opening: content, untouchedText: content.text, draft: draft,
            onListChanged: { [weak session] in await session?.draftsChanged() })
        for field in [to, cc, bcc] {
            field.onChange = { [weak self] in
                self?.edited()
                Task { await self?.reviewRecipients() }
            }
        }
    }

    /// Warnings only, as on the web: a changed key is the sender's to weigh, not the app's to block.
    func reviewRecipients() async {
        guard let composer = session.services.composer else { return }
        let fetch = session.services.identityRecord
        let found = await composer.review(content) { address, pinned in
            await KeyLineage.load(address: address, pinnedEd25519Pub: pinned, fetch: fetch)
        }
        review = found
    }

    /// Lines to show above the send bar, most serious first.
    var notices: [(text: String, warning: Bool)] {
        guard let review else { return [] }
        var lines = review.changedKeyWarnings.map { ($0, true) }
        if let record = review.changedRecordWarning { lines.append((record, true)) }
        lines += review.forwards.map { ($0.notice, $0.unsendable || $0.kind == .email) }
        if review.hasLegacy {
            lines.append((ComposeReview.legacyNotice, true))
        } else if review.hasEncryptedRecipient {
            lines.append((ComposeReview.encryptedNotice, false))
        }
        return lines
    }

    var content: DraftContent {
        var next = opening
        next.to = to.recipients
        next.cc = cc.recipients
        next.bcc = bcc.recipients
        next.pending = DraftPending(to: to.pending, cc: cc.pending, bcc: bcc.pending)
        next.subject = subject
        next.text = body
        next.rich = false
        next.html = ""
        next.attachments = attachments
        if let retryThreadID {
            var thread = next.replyTo ?? ComposeReplyTo(to: [], subject: subject)
            thread.threadId = retryThreadID
            next.replyTo = thread
        }
        return next
    }

    var canSend: Bool {
        !to.recipients.isEmpty || !cc.recipients.isEmpty || !bcc.recipients.isEmpty || !to.pending.isEmpty
    }

    private func edited() {
        let content = content
        let autosave = autosave
        Task { await autosave.edited(content) }
    }

    func add(_ files: [(name: String, data: Data)]) {
        do {
            attachments = try ComposeAttachments.adding(
                files.map { ComposeAttachments.File(name: $0.name, content: $0.data) }, to: attachments)
            error = nil
            edited()
        } catch {
            self.error = error.localizedDescription
        }
    }

    func remove(_ attachment: DraftAttachment) {
        attachments.removeAll { $0.attachmentID == attachment.attachmentID }
        edited()
    }

    func send() async {
        guard let composer = session.services.composer else {
            error = "Sample mail can't send anything. Sign in to a real account to send."
            return
        }
        isSending = true
        error = nil
        defer { isSending = false }
        do {
            let report = try await composer.send(content, autosave: autosave)
            if report.undelivered.isEmpty {
                sentReport = report.items
            } else {
                keepForRetry(report)
            }
            await session.refresh()
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Some have it and some don't: the draft stays, addressed to the others, with Send ready. The
    /// retry joins this thread as its own message. Reusing the message ID instead would overwrite
    /// the Sent copy of what already went.
    private func keepForRetry(_ report: SentReport) {
        retryThreadID = report.threadID
        to.narrow(to: report.retry.to)
        cc.narrow(to: report.retry.cc)
        bcc.narrow(to: report.retry.bcc)
        let summary = PartialSend.message(delivered: report.delivered, undelivered: report.undelivered)
        error = ([summary] + report.items.map(\.text)).joined(separator: " ")
    }

    /// Closing saves. What's untouched leaves nothing behind. The latest words go over first:
    /// the edit that was just typed may still be waiting its turn, and they'd be lost with it.
    func putAway() async {
        await autosave.edited(content)
        _ = await autosave.putAway()
        session.composing = nil
    }

    func discard() async {
        await autosave.remove()
        session.composing = nil
    }

    // MARK: Who's who

    func name(for address: String) -> String { session.name(for: address) }

    func kind(of address: String) -> SenderKind {
        let local = SenderKind.of(contact: session.contact(for: address))
        if local != .unknown { return local }
        switch review?.recipients.first(where: { $0.address == address })?.kind {
        case .trusted, .identity: return .dmcn
        case .legacy: return .legacy
        default: return .unknown
        }
    }

    func isTrusted(_ address: String) -> Bool { session.contact(for: address) != nil }

    func saveContact(_ offer: SaveContactOffer) async {
        do {
            try await session.services.composer?.saveContact(offer)
            savedContacts.insert(offer.address.lowercased())
            await session.contactsChanged()
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Contacts matching what's typed, leaving out nothing typed at all.
    func suggestions(for text: String) -> [ContactRecord] {
        let wanted = text.trimmingCharacters(in: .whitespaces).lowercased()
        guard !wanted.isEmpty else { return [] }
        return Array(
            session.allContacts.filter {
                $0.address.lowercased().hasPrefix(wanted) || $0.name.lowercased().hasPrefix(wanted)
            }.prefix(5))
    }
}
