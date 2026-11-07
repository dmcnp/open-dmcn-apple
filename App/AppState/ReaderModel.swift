import DMCNKit
import Foundation
import Observation

/// One open message. It gathers the facts and hands them to `ReaderPolicy`, which decides what
/// may be shown; nothing here makes that decision.
@MainActor
@Observable
final class ReaderModel: Identifiable {
    enum Body: Equatable {
        case loading
        case failed(String)
        case text(String)
    }

    struct Attachment: Identifiable, Sendable {
        let id: Int
        let name: String
        let detail: String
        let data: Data
        let contentType: String
    }

    nonisolated let id: String
    let message: MailPreview
    let isSentView: Bool
    private let session: MailSession

    private(set) var body = Body.loading
    private(set) var html: String?
    private(set) var inlineImages: [HTMLDocument.InlineImage] = []
    private(set) var attachments: [Attachment] = []
    private(set) var sourceText: String?
    private(set) var isActing = false
    var acknowledged: Set<Int> = []
    var showHTML = true
    var showingSource = false

    private var attestation: BridgeAttestation?
    private var receipt: DeliveryReceiptView?
    private var bridgeResolved = false
    private var hasOriginal = false
    private var nativeTrust: SenderTrust?
    private var nativeTrustSettled = false
    private var keyChange: KeyChange?
    private var revealed = false
    private var messageTrusted = false

    init(session: MailSession, message: MailPreview, sentView: Bool) {
        self.session = session
        self.message = message
        self.isSentView = sentView
        id = message.hash
    }

    var decision: ReaderDecision {
        ReaderPolicy.decide(
            ReaderInput(
                senderAddress: message.senderAddress, senderPublicKey: Data(hex: message.senderPublicKey) ?? Data(),
                senderDisplay: message.senderDisplay, recipientAddress: message.recipientAddress, to: message.to,
                cc: message.cc, sentView: isSentView, listedAs: message.sender, accountAddress: session.address,
                accountSigningKeys: [session.services.keys.ed25519Public], contact: senderContact,
                counterpartyContactName: session.name(for: counterparty), contactsReady: true, filter: session.filter,
                filterReady: true, attestation: attestation, receipt: receipt, bridgeResolved: bridgeResolved,
                hasHTML: html != nil, hasOriginal: hasOriginal, nativeTrust: nativeTrust,
                nativeTrustSettled: nativeTrustSettled, keyChange: keyChange, revealed: revealed,
                messageTrusted: messageTrusted,
                remoteImagesForTrusted: session.settings.remoteImagesForTrusted ?? false))
    }

    private var senderContact: ContactRecord? { session.contact(for: message.senderAddress) }
    private var counterparty: String {
        isSentView ? MailView.recipientsOf(message).first ?? "" : message.senderAddress
    }
    private var toList: [String] { MailView.recipientsOf(message) }

    // MARK: What the header shows

    var subject: String { message.subject.isEmpty ? "(no subject)" : message.subject }
    var counterpartyName: String { decision.counterpartyName }
    var counterpartyAddress: String? { decision.counterpartyAddress }
    var initials: String { decision.initials }

    private var soleRecipientIsMe: Bool {
        guard toList.count == 1, let only = toList.first?.lowercased() else { return false }
        return only == session.address.lowercased() || only == message.deliveredTo?.lowercased()
    }

    private func people(_ addresses: [String]) -> String? {
        addresses.isEmpty ? nil : addresses.map(session.name(for:)).joined(separator: ", ")
    }

    var toLine: String? { isSentView || soleRecipientIsMe ? (isSentView ? people(toList) : nil) : people(toList) }
    var ccLine: String? { people(message.cc) }
    var bccLine: String? { people(message.bcc) }

    var metaLine: String {
        let who =
            decision.ownMessage ? "from me" : message.deliveredTo.map { "to me at \($0)" } ?? "to me"
        return "\(who) · \(MailView.formatDate(message.sentAt)) · \(MailView.formatTime(message.sentAt))"
    }

    // MARK: Filing

    private var flag: FlagRecord? { session.flag(message.hash) }
    var isStarred: Bool { flag?.starred ?? false }
    var isArchived: Bool { flag?.archived ?? false }
    var canArchive: Bool { !isSentView && flag?.trashedAt == nil }
    var labels: [LabelDef] { session.labels }
    var folders: [FolderDef] { session.folders }
    var appliedLabels: [LabelDef] {
        (flag?.labelIds ?? []).compactMap { id in session.labels.first { $0.id == id } }
    }
    var availableLabels: [LabelDef] {
        session.labels.filter { !(flag?.labelIds ?? []).contains($0.id) }
    }
    var currentFolder: FolderDef? { session.folders.first { $0.id == flag?.folderId } }
    var deletedWhen: String? {
        flag?.trashedAt.map { MailView.purgeWhen($0, days: session.trashDays, now: systemClock()) }
    }

    func toggleStar() { session.toggleStar(message.hash) }

    func toggleArchive() {
        session.setFlag(message.hash, FlagDelta(archived: .set(!isArchived)))
        session.closeMessage()
    }

    func addLabel(_ id: String) {
        session.setFlag(message.hash, FlagDelta(labelIds: .set((flag?.labelIds ?? []) + [id])))
    }

    func removeLabel(_ id: String) {
        session.setFlag(message.hash, FlagDelta(labelIds: .set((flag?.labelIds ?? []).filter { $0 != id })))
    }

    func setFolder(_ id: String?) {
        session.setFlag(message.hash, FlagDelta(folderId: id.map { .set($0) } ?? .clear))
    }

    func createLabel(name: String, color: String) async {
        if let id = await session.createLabel(name: name, color: color) { addLabel(id) }
    }

    func createFolder(name: String) async {
        if let id = await session.createFolder(name: name) { setFolder(id) }
    }

    func restore() {
        session.restore(message.hash)
        session.closeMessage()
    }

    /// Delete moves to Deleted; from Deleted it's for good.
    func delete() {
        if flag?.trashedAt != nil {
            let session = session
            let hash = message.hash
            Task { await session.deleteForever(hash) }
        } else {
            session.trash(message.hash)
        }
        session.closeMessage()
    }

    // MARK: Opening

    func load() async {
        let services = session.services
        async let opening: Void = loadBody(services)
        async let trust: Void = evaluateTrust(services)
        _ = await (opening, trust)
    }

    private func loadBody(_ services: SessionServices) async {
        // SPEC_CORE §3: what the checks withhold is never fetched.
        guard !message.contentsWithheld else {
            bridgeResolved = true
            return
        }
        do {
            let opened: OpenedMessage
            let records: [Dmcn_Message_AttachmentRecord]
            if SentStore.isSentHash(message.hash) {
                let stored = try await services.sent.open(message.hash)
                opened = OpenedMessage(content: stored.content)
                records = stored.content.attachments
            } else {
                guard let summary = message.summary,
                    let content = try await services.inbox.openContent(summary)
                else {
                    bridgeResolved = true
                    return
                }
                opened = OpenedMessage(content: content)
                records = content.attachments
            }
            body = .text(opened.bodyText)
            html = opened.html
            inlineImages = opened.inlineImages
            attachments = opened.downloads.enumerated().map { index, file in
                let size = MailView.formatBytes(file.content.count)
                return Attachment(
                    id: index, name: file.filename.isEmpty ? "attachment" : file.filename,
                    detail: file.contentType.isEmpty ? size : "\(size) · \(file.contentType)", data: file.content,
                    contentType: file.contentType)
            }
            sourceText = opened.sourcePreview
            hasOriginal = opened.bridgeOriginal != nil
            let key = Data(hex: message.senderPublicKey)
            attestation = await services.bridge.attestation(of: records, messageSender: key)
            receipt = await services.bridge.receipt(of: records, messageSender: key)
        } catch {
            body = .failed("Couldn't load this message. \(error.localizedDescription)")
        }
        bridgeResolved = true
    }

    private func evaluateTrust(_ services: SessionServices) async {
        defer { nativeTrustSettled = true }
        guard let key = Data(hex: message.senderPublicKey), !key.isEmpty, !isSentView else { return }
        let verdict = await SenderTrust.evaluate(
            senderAddress: message.senderAddress, senderPublicKey: key, contact: senderContact,
            lookup: services.directory)
        nativeTrust = verdict
        if let pinned = ReaderActions.keyToExplain(trust: verdict, contact: senderContact) {
            keyChange = await KeyLineage.load(
                address: message.senderAddress, pinnedEd25519Pub: pinned, fetch: services.identityRecord)
        }
        // A contact who verified but has no pin yet gets one, so a later key change is noticed.
        let own = decision.ownMessage
        if ReaderActions.wantsLazyPin(ownMessage: own, trust: verdict, contact: senderContact),
            let answer = try? await services.directory(message.senderAddress),
            let facts = ReaderActions.lazyPin(
                ownMessage: own, trust: verdict, contact: senderContact, senderPublicKey: key, directory: answer)
        {
            await services.contacts.pinKey(message.senderAddress, facts: facts)
            await session.contactsChanged()
        }
    }

    // MARK: The gate's actions

    func reveal() { revealed = true }

    func trustThisMessage() { messageTrusted = true }

    func trustSender() async {
        isActing = true
        defer { isActing = false }
        let services = session.services
        do {
            if attestation?.verified == true {
                try await services.contacts.allowlist(
                    ReaderActions.bridgedTrust(
                        senderAddress: message.senderAddress, senderDisplay: message.senderDisplay,
                        contact: senderContact))
                // This opens this message, even though the next one claiming the address is gated again.
                messageTrusted = true
            } else {
                let answer = try await services.directory(message.senderAddress)
                try await services.contacts.allowlist(
                    ReaderActions.nativeTrust(
                        senderAddress: message.senderAddress, contact: senderContact, directory: answer))
            }
            await session.contactsChanged()
            nativeTrustSettled = false
            await evaluateTrust(services)
        } catch {
            session.errorMessage = "Couldn't trust this sender. \(error.localizedDescription)"
        }
    }

    func blockSender() async {
        isActing = true
        defer { isActing = false }
        do {
            try await session.services.filter.blockSender(
                message.senderAddress,
                senderKeyHex: ReaderActions.blockKey(
                    attestation: attestation, trust: nativeTrust,
                    senderPublicKey: Data(hex: message.senderPublicKey) ?? Data()))
            await session.blockChanged()
            // Into Deleted, so a block made in haste can be walked back with the message intact.
            if flag?.trashedAt == nil { session.trash(message.hash) }
        } catch {
            session.errorMessage = "Couldn't block this sender. \(error.localizedDescription)"
        }
        session.closeMessage()
    }

    // MARK: Replying

    private var original: ReplyOriginal {
        // A record the domain disowns isn't attribution, so nothing is quoted under its address.
        var text: String?
        if case .text(let shown) = body, !decision.disowned { text = shown }
        return ReplyOriginal(
            senderAddress: message.senderAddress, to: message.to, cc: message.cc, subject: message.subject,
            messageID: message.messageID, threadID: message.threadID, sentAt: message.sentAt, bodyText: text)
    }

    var canReplyAll: Bool { ComposeReplies.offersReplyAll(original, me: session.address) }

    func reply(all: Bool) {
        let reply = ComposeReplies.reply(
            to: original, all: all, me: session.address, senderName: senderContact?.name)
        session.closeMessage()
        session.start(
            ComposeReplies.opening(
                reply, from: session.address, ours: [session.address], signature: session.settings.signature),
            title: "Reply")
    }

    /// A forward's header names who a message is from, in new mail signed by this account. For a
    /// withheld or disowned message that's the attribution SPEC_CORE §3 forbids.
    var canForward: Bool { decision.trustReady && !decision.withheld && !decision.disowned }

    func forward() {
        guard canForward else { return }
        let content = ComposeReplies.forward(
            original, from: session.address, senderName: senderContact?.name, signature: session.settings.signature)
        session.closeMessage()
        session.start(content, title: "Forward")
    }
}
