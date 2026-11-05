import Foundation

// The composing and sending flow, with no UI. Parity with handleSend, inspectRecipient and
// inspectForward in the browser's components/ComposeDialog.tsx, and lib/recipientLookup.ts.
//
// Every copy of one compose shares a message id, thread id, timestamp and content, and is sealed on
// its own: the key is wrapped only for that recipient, and the header says which address the copy
// was for. Bcc is on nobody's copy but the sender's, so a reply-all can't leak it.

/// Why a message didn't go, in words to show.
public indirect enum ComposeError: Error, Equatable, Sendable {
    case noRecipients
    case attachmentsTooLarge
    /// Nothing can carry mail to this address from here.
    case notReachable(String)
    /// The directory couldn't be asked, which says nothing about the address.
    case lookupFailed(String)
    case accountClosed(String)
    case mailboxFull(String)
    /// The copy had to go by the private route, and that failed. It never falls back to a direct one.
    case privateRouteFailed(String)
    case notDelivered(String)
}

extension ComposeError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .noRecipients: "Add at least one recipient."
        case .attachmentsTooLarge: ComposeAttachments.capMessage
        case .notReachable(let address):
            "\(address) can't be reached from here, so your message was not sent. Check the address and try again."
        case .lookupFailed(let address):
            "We couldn't look up \(address) just now, so your message was not sent. Check your connection and try "
                + "again."
        case .accountClosed(let address): Self.recipientClosedMessage(address)
        case .mailboxFull(let address): "\(address)'s mailbox is full, so your message was not delivered to them."
        case .privateRouteFailed(let address):
            "Your message has to reach \(address) by a private route, and that route couldn't be used just now, so "
                + "it was not delivered to them. Try again later."
        case .notDelivered(let address):
            "Your message couldn't be delivered to \(address). Check your connection and try again."
        }
    }

    static func recipientClosedMessage(_ address: String) -> String {
        "\(address) has closed their account, so your message was not delivered to them."
    }
}

/// How a build reaches an address its directory has no identity for, if it can. A directory that
/// answers such a lookup with its own bridge needs none of this: the ordinary path already has a key
/// to seal to. One that answers "not found" supplies this. Absent, such an address is unreachable.
///
/// `seal` and `sign` come from the composer, which owns the keys and the content, so a route decides
/// only where a message goes and never what is in it or what signs it.
public protocol LegacyMailRoute: Sendable {
    func deliver(
        to recipient: String, from senderAddress: String,
        seal: @escaping @Sendable (_ x25519Public: Data) throws -> Data,
        sign: @escaping @Sendable (_ bytes: Data) throws -> Data
    ) async throws
}

/// What the composer can say about a recipient, for its chip.
public enum ComposeRecipientKind: Sendable, Equatable {
    /// In the contact list.
    case trusted
    /// An identity, not (yet) a contact.
    case identity
    /// Ordinary email, so not end-to-end encrypted.
    case legacy
    /// The directory couldn't be asked just now. No claim either way.
    case unchecked
}

/// What to tell the person before they press Send. Nothing here stops them.
public struct ComposeReview: Sendable, Equatable {
    public struct Recipient: Sendable, Equatable {
        public let address: String
        public let kind: ComposeRecipientKind
        /// What the directory served, to pass to `confirmChange`. Nil when it couldn't be asked.
        public let observed: PinnedFacts?
        public let pin: ComposePin.Verdict
    }

    public struct Forward: Sendable, Equatable {
        public let copy: ComposeForwarding.Copy
        public let kind: ComposeForwarding.TargetKind
        /// Ordinary email with no way to send it from here: that copy won't go.
        public let unsendable: Bool

        public var notice: String {
            unsendable
                ? ComposeForwarding.unsendableNotice(copy.forAddress, target: copy.target)
                : ComposeForwarding.notice(copy.forAddress, target: copy.target, kind: kind)
        }
    }

    public let recipients: [Recipient]
    public let forwards: [Forward]
    /// One sentence per recipient whose key changed or whose identity went away. The most serious
    /// thing on the screen, and to be shown above everything else with `ComposePin.stillSendable`.
    public let changedKeyWarnings: [String]
    /// The addresses those warnings are about, each of which can be confirmed.
    public let changedKeyRecipients: [String]
    /// Keys hold but a pinned property moved. Nil when nothing did.
    public let changedRecordWarning: String?

    /// Some recipient can't get end-to-end encrypted mail.
    public var hasLegacy: Bool { recipients.contains { $0.kind == .legacy } }

    /// Whether to say the message is encrypted: only true with someone to encrypt it to.
    public var hasEncryptedRecipient: Bool { recipients.contains { $0.kind == .identity || $0.kind == .trusted } }

    /// A forward copy leaves end-to-end encryption, so its notice is a warning rather than a note.
    public var forwardLeavesEncryption: Bool { forwards.contains { $0.kind == .email } }

    public static let legacyNotice = "Some recipients use legacy email and can't receive end-to-end encrypted messages."
    public static let encryptedNotice = "End-to-end encrypted. Only your DMCN recipients can read this."
}

/// What happened that the sender should know once the message has gone.
public struct SentReport: Sendable, Equatable {
    public struct Item: Sendable, Equatable {
        public let text: String
        /// A recipient's mail now lives at this address, which can be saved as a contact.
        public let saveContact: SaveContactOffer?
    }

    public let messageID: Data
    /// Empty means there is nothing to tell, and the composer can simply close.
    public let items: [Item]
    /// The message went, but the Sent copy couldn't be kept. That never fails a send.
    public let keptInSent: Bool
    /// Who has this message, forwarding addresses included.
    public let delivered: [String]
    /// Who was tried and doesn't have it. Empty when everyone does.
    public let undelivered: [PartialSend.Undelivered]
    /// Who the draft stays addressed to, when `undelivered` isn't empty.
    public let retry: PartialSend.Audience
    /// Hex: the thread this went out in, for a retry to join.
    public let threadID: String

    public static let heading = "Sent."
    public static let addedToContacts = "Added to your contacts."
}

public struct SaveContactOffer: Sendable, Equatable {
    public let address: String
    public let name: String
    public let lookup: RecipientLookup

    public var buttonTitle: String { "Add \(address) to contacts" }
}

/// One account's composing and sending. Holds no message: each call takes the composer's state.
public struct Composer: Sendable {
    private let host: WebHostClient
    private let account: any AccountKeys
    private let deviceID: Data
    private let contacts: ContactStore
    private let sent: SentStore
    private let identities: [any AccountKeys]
    private let legacyRoute: (any LegacyMailRoute)?
    private let extraFields: SendFields?
    private let now: StoreClock

    /// `identities` are the account's other addresses that can send, with the keys that act as each.
    /// `legacyRoute` and `extraFields` are for a build that has them; see each.
    public init(
        host: WebHostClient, account: any AccountKeys, deviceID: Data, contacts: ContactStore, sent: SentStore,
        identities: [any AccountKeys] = [], legacyRoute: (any LegacyMailRoute)? = nil,
        extraFields: SendFields? = nil, now: @escaping StoreClock = systemClock
    ) {
        self.host = host
        self.account = account
        self.deviceID = deviceID
        self.contacts = contacts
        self.sent = sent
        self.identities = identities
        self.legacyRoute = legacyRoute
        self.extraFields = extraFields
        self.now = now
    }

    // MARK: Recipients

    /// `values` with what was typed in a recipient field made into a chip. A repeat changes nothing.
    public static func committing(_ pending: String, into values: [String]) -> [String] {
        var address = JSText.trim(pending)
        if address.unicodeScalars.last == "," { address = JSText.trim(String(address.unicodeScalars.dropLast())) }
        guard !address.isEmpty, !values.contains(where: { sameBytes($0, address) }) else { return values }
        return values + [address]
    }

    /// Everyone who gets a copy, once each. Only an exact repeat is a repeat, as in the browser.
    public static func uniqueRecipients(to: [String], cc: [String], bcc: [String]) -> [String] {
        var seen = Set<Data>()
        return (to + cc + bcc).filter { seen.insert(Data($0.utf8)).inserted }
    }

    private static func sameBytes(_ a: String, _ b: String) -> Bool { Data(a.utf8) == Data(b.utf8) }

    /// Only a "not found" says there is no identity here. Anything else means the directory couldn't
    /// be asked, and an outage must not read as "their identity is gone".
    private static func isAbsent(_ error: any Error) -> Bool {
        (error as? APIError)?.status == 404
    }

    // MARK: Before sending

    /// Asks the directory about everyone on the message and says what the person should know before
    /// pressing Send. A contact with no pin yet is pinned here, on this first confirmed sighting.
    ///
    /// `explainKeyChange` supplies what the directory can prove about a pinned key that went away,
    /// given the address and the pinned key. Without it the warning says there is no record of why,
    /// which is also what a withheld record looks like.
    public func review(
        _ content: DraftContent,
        explainKeyChange: (@Sendable (_ address: String, _ pinnedEd25519Pub: String) async -> ComposePin.KeyChange)? =
            nil,
        locale: Locale = .current, timeZone: TimeZone = .current
    ) async -> ComposeReview {
        let everyone = (content.to + content.cc + content.bcc).map(JSText.trim).filter { !$0.isEmpty }
        var seen = Set<String>()
        let unique = everyone.filter { seen.insert($0.lowercased()).inserted }

        var recipients: [ComposeReview.Recipient] = []
        var forwardTargets: [String: String] = [:]
        for address in unique {
            var kind: ComposeRecipientKind
            var observed: PinnedFacts?
            do {
                let found = try await host.lookupRecipient(address, keys: account)
                kind = found.legacy ? .legacy : .identity
                observed = ComposePin.facts(from: found)
                if !found.legacy {
                    forwardTargets[address.lowercased()] = found.forwardTo
                    if let contact = await contacts.contact(for: address), (contact.ed25519Pub ?? "").isEmpty,
                        let observed
                    {
                        await contacts.pinKey(address, facts: observed)
                    }
                }
            } catch {
                kind = Self.isAbsent(error) ? .legacy : .unchecked
                observed = Self.isAbsent(error) ? .absentIdentity : nil
            }
            let contact = await contacts.contact(for: address)
            // Legacy always wins, since it can't be encrypted, and an unchecked address claims nothing.
            if kind == .identity, contact != nil { kind = .trusted }
            recipients.append(
                .init(
                    address: address, kind: kind, observed: observed,
                    pin: ComposePin.check(contact, observed: observed)))
        }

        var forwards: [ComposeReview.Forward] = []
        let copies = ComposeForwarding.plan(
            forwards: everyone.map { ($0, forwardTargets[$0.lowercased()]) }, recipients: everyone,
            sender: content.from.isEmpty ? account.address : content.from)
        for copy in copies {
            let (kind, unsendable) = await inspectForward(copy.target)
            forwards.append(.init(copy: copy, kind: kind, unsendable: unsendable))
        }

        let changed = recipients.filter { $0.pin == .changed }
        var warnings: [String] = []
        // Swaps first, then disappearances, as the browser's banner has them.
        for recipient in changed where recipient.observed?.noIdentity != true {
            var change: ComposePin.KeyChange?
            let pinned = await contacts.contact(for: recipient.address)?.pinnedFacts?.ed25519Pub ?? ""
            if !pinned.isEmpty { change = await explainKeyChange?(recipient.address, pinned) }
            warnings.append(
                ComposePin.keyWarning(recipient.address, change: change, locale: locale, timeZone: timeZone))
        }
        for recipient in changed where recipient.observed?.noIdentity == true {
            warnings.append(ComposePin.identityGoneWarning(recipient.address))
        }

        let recordChanged = recipients.filter { $0.pin == .recordChanged }
        var recordWarning: String?
        if let first = recordChanged.first {
            let pinned = await contacts.contact(for: first.address)?.pinnedFacts
            let detail = pinned.flatMap { p in
                first.observed.map { ComposePin.changedFacts(pinned: p, observed: $0).joined(separator: " and ") }
            }
            recordWarning = ComposePin.recordWarning(recordChanged.map(\.address), detail: detail ?? "")
        }

        return ComposeReview(
            recipients: recipients, forwards: forwards, changedKeyWarnings: warnings,
            changedKeyRecipients: changed.map(\.address), changedRecordWarning: recordWarning)
    }

    private func inspectForward(_ target: String) async -> (kind: ComposeForwarding.TargetKind, unsendable: Bool) {
        do {
            return (try await host.lookupRecipient(target, keys: account).legacy ? .email : .identity, false)
        } catch {
            return Self.isAbsent(error) ? (.email, legacyRoute == nil) : (.unknown, false)
        }
    }

    /// The person checked and accepts what the directory shows now. This moves the pin forward
    /// rather than clearing it: the point of confirming is to keep watching from here.
    public func confirmChange(_ address: String, observed: PinnedFacts) async throws {
        let existing = await contacts.contact(for: address)
        // Confirming a rotation is no reason to forget the key was once checked in person.
        var record = ContactRecord(
            address: address, name: existing?.name ?? "", fingerprint: existing?.fingerprint ?? "",
            provenance: existing?.provenance ?? .userApproved)
        if observed.noIdentity == true {
            record.noIdentity = true
        } else {
            record.ed25519Pub = observed.ed25519Pub
            record.x25519Pub = observed.x25519Pub
            record.adminKeyCustody = observed.adminKeyCustody
        }
        try await contacts.allowlist(record)
    }

    /// Saves the address a report offered as a contact.
    public func saveContact(_ offer: SaveContactOffer) async throws {
        let facts = ComposePin.facts(from: offer.lookup)
        try await contacts.allowlist(
            ContactRecord(
                address: offer.address, name: offer.name, fingerprint: offer.lookup.fingerprint,
                provenance: .userApproved, ed25519Pub: facts.ed25519Pub, x25519Pub: facts.x25519Pub,
                adminKeyCustody: facts.adminKeyCustody))
    }

    // MARK: Sending

    /// Where one recipient's copy goes.
    private enum Route {
        case sealed(RecipientLookup, key: Data)
        case legacy
    }

    /// One compose, ready for its copies.
    private struct Outgoing: Sendable {
        let draft: SplitMessage.Draft
        let sender: any AccountKeys
        let senderAddress: String
        let onion: Bool

        func copy(for recipient: String) -> SplitMessage.Draft {
            var copy = draft
            copy.recipientAddress = recipient
            return copy
        }
    }

    /// Sends a message, in plain text, as it stands in `content`: what is still half-typed in a
    /// recipient field counts. Every recipient is tried, and one failing doesn't stop the rest: the
    /// report says who has it and who doesn't. It only throws when nobody got it.
    ///
    /// `content.html` is never sent, because a draft comes back from storage and this kit has no
    /// sanitizer. A composer that has run its HTML through one passes it as `sanitizedHTML`, with
    /// `content.text` the plain rendering of it. Inline images it doesn't refer to are left out, so
    /// a plain send carries none.
    ///
    /// Recipients are all looked up before the first copy goes, so an address that can't be resolved
    /// stops the message rather than leaving it half delivered. `autosave`, when given, has its draft
    /// removed once everyone has it.
    @discardableResult
    public func send(
        _ content: DraftContent, sanitizedHTML: String? = nil, autosave: DraftAutosave? = nil
    ) async throws -> SentReport {
        let to = Self.committing(content.pending.to, into: content.to)
        let cc = Self.committing(content.pending.cc, into: content.cc)
        let bcc = Self.committing(content.pending.bcc, into: content.bcc)
        let everyone = Self.uniqueRecipients(to: to, cc: cc, bcc: bcc)
        // Any field will do: a retry for a Bcc alone has an empty To, and moving them there would
        // show them.
        guard !everyone.isEmpty else { throw ComposeError.noRecipients }

        // An empty rich body is just an empty message, not a hollow HTML part.
        var bodyText = content.text
        var bodyHTML: String?
        if let clean = sanitizedHTML {
            if !JSText.trim(content.text).isEmpty || Self.hasImage(clean) {
                bodyHTML = clean
            } else {
                bodyText = ""
            }
        }
        let attachments = ComposeAttachments.forSending(content.attachments, html: bodyHTML)
        guard ComposeAttachments.totalBytes(attachments) <= ComposeAttachments.maxTotalBytes else {
            throw ComposeError.attachmentsTooLarge
        }

        var routes: [Route] = []
        for address in everyone { routes.append(try await route(to: address)) }
        // One recipient needing the private route sends the whole message that way.
        let onion = routes.contains { if case .sealed(let found, _) = $0 { found.requireOnion } else { false } }

        let selfAddress = content.from.isEmpty ? account.address : content.from
        let sender =
            identities.first { $0.address.lowercased() == selfAddress.lowercased() } ?? account
        let messageID = ComposeAttachments.newUUID()
        let outgoing = Outgoing(
            draft: SplitMessage.Draft(
                messageID: messageID, threadID: Self.threadID(continuing: content.replyTo),
                replyToID: content.replyTo?.replyToId.flatMap(Self.messageID), recipientAddress: "", to: to, cc: cc,
                subject: content.subject, bodyText: bodyText, bodyHTML: bodyHTML, attachments: attachments,
                sentAt: now() / 1000, senderAddress: selfAddress),
            sender: sender, senderAddress: selfAddress, onion: onion)

        var items: [SentReport.Item] = []
        var delivered: [String] = []
        var undelivered: [PartialSend.Undelivered] = []
        var firstFailure: ComposeError?
        // Addresses that get this message anyway, so no forward copy duplicates one.
        var reached = Set((everyone + [selfAddress]).map(JSText.normalizedAddress))

        for (address, route) in zip(everyone, routes) {
            do {
                switch route {
                case .legacy:
                    try await deliverLegacy(outgoing, to: address)
                    delivered.append(address)
                case .sealed(let found, let key):
                    let forwardTo = found.forwardTo.map(JSText.trim).flatMap { $0.isEmpty ? nil : $0 }
                    var closed = false
                    do {
                        try await store(outgoing, to: address, sealedTo: key, onion: onion)
                        delivered.append(address)
                    } catch let error as APIError where error.status == 410 {
                        // With a forward, that address is where their mail goes now.
                        guard forwardTo != nil else { throw ComposeError.accountClosed(address) }
                        closed = true
                    }
                    guard let forwardTo else { continue }
                    if reached.insert(forwardTo.lowercased()).inserted {
                        let result = await sendForward(outgoing, to: forwardTo)
                        if result.ok { delivered.append(forwardTo) }
                        if closed, result.ok {
                            var offer: SaveContactOffer?
                            if let target = result.identity, await contacts.contact(for: forwardTo) == nil {
                                let name = await contacts.contact(for: address)?.name ?? ""
                                offer = SaveContactOffer(address: forwardTo, name: name, lookup: target)
                            }
                            items.append(
                                .init(
                                    text: ComposeForwarding.forwardedOnlyMessage(address, target: forwardTo),
                                    saveContact: offer))
                        } else if closed {
                            items.append(
                                .init(
                                    text: ComposeForwarding.forwardOnlyFailedMessage(address, target: forwardTo),
                                    saveContact: nil))
                        } else if !result.ok {
                            items.append(
                                .init(
                                    text: ComposeForwarding.forwardFailedMessage(address, target: forwardTo),
                                    saveContact: nil))
                        }
                    } else if closed {
                        // The forwarding address gets this anyway, as a recipient in its own right.
                        items.append(
                            .init(
                                text: ComposeForwarding.forwardedOnlyMessage(address, target: forwardTo),
                                saveContact: nil))
                    }
                }
            } catch {
                let reason = Self.reason(error, address: address, onion: onion)
                firstFailure = firstFailure ?? reason
                undelivered.append(.init(address: address, reason: reason.errorDescription ?? ""))
            }
        }
        // Nobody has it, so this is simply a failed send, and the draft stays as it was.
        if delivered.isEmpty, let firstFailure { throw firstFailure }

        // The full audience rides on this copy only, and it lists who this send reached, so Sent is
        // true: a retry for the others keeps a Sent copy of its own. Best effort: the message has
        // gone, so a Sent copy that can't be kept must not read as a failed send.
        let audience = PartialSend.Audience(to: to, cc: cc, bcc: bcc)
        let listed = PartialSend.reached(audience, undelivered: undelivered)
        var selfCopy = outgoing.copy(for: selfAddress)
        selfCopy.to = listed.to
        selfCopy.cc = listed.cc
        selfCopy.bcc = listed.bcc
        let kept = (try? await sent.keepCopy(of: selfCopy, from: sender, deviceID: deviceID)) != nil

        if undelivered.isEmpty { await autosave?.remove() }
        return SentReport(
            messageID: messageID, items: items, keptInSent: kept, delivered: delivered, undelivered: undelivered,
            retry: PartialSend.retry(audience, undelivered: undelivered), threadID: outgoing.draft.threadID.hex)
    }

    /// Which way a recipient's copy goes, or why it can't.
    private func route(to address: String) async throws -> Route {
        do {
            let found = try await host.lookupRecipient(address, keys: account)
            guard let key = found.sealingKey else { throw ComposeError.notReachable(address) }
            return .sealed(found, key: key)
        } catch let error as ComposeError {
            throw error
        } catch {
            guard Self.isAbsent(error) else { throw ComposeError.lookupFailed(address) }
            // No record for a well-formed email: a legacy recipient, if this build has a way. Someone
            // verified before who now resolves to nothing is disclosed by `review`, not refused.
            guard address.contains("@"), legacyRoute != nil else { throw ComposeError.notReachable(address) }
            return .legacy
        }
    }

    private func store(_ outgoing: Outgoing, to address: String, sealedTo key: Data, onion: Bool) async throws {
        let envelope = try SplitMessage.seal(
            outgoing.copy(for: address), from: outgoing.sender, to: [.init(x25519Public: key)])
        try await host.send(
            envelope, as: outgoing.sender, senderAddress: outgoing.senderAddress, to: address, onion: onion,
            messageID: outgoing.draft.messageID, account: account, extraFields: extraFields)
    }

    private func deliverLegacy(_ outgoing: Outgoing, to address: String) async throws {
        guard let legacyRoute else { throw ComposeError.notReachable(address) }
        let copy = outgoing.copy(for: address)
        let sender = outgoing.sender
        try await legacyRoute.deliver(
            to: address, from: outgoing.senderAddress,
            seal: { key in try Canonical.marshal(SplitMessage.seal(copy, from: sender, to: [.init(x25519Public: key)]))
            },
            sign: { try sender.sign($0) })
    }

    /// A forward copy, built like a Bcc copy: its own routing address and the message's own To and
    /// Cc, so the target's reader passes its audience check. Resolved now, as every send does, so an
    /// address that has gained an identity since the forward was set gets an encrypted copy. Its own
    /// forward is never followed. A failure is reported after the send rather than failing it: the
    /// recipient's own copy is what the sender asked for, and the forward is theirs to arrange.
    private func sendForward(_ outgoing: Outgoing, to target: String) async -> (ok: Bool, identity: RecipientLookup?) {
        do {
            let found: RecipientLookup
            do {
                found = try await host.lookupRecipient(target, keys: account)
            } catch  where Self.isAbsent(error) {
                guard legacyRoute != nil else { return (false, nil) }
                try await deliverLegacy(outgoing, to: target)
                return (true, nil)
            }
            guard let key = found.sealingKey else { return (false, nil) }
            try await store(outgoing, to: target, sealedTo: key, onion: outgoing.onion || found.requireOnion)
            // Only a real identity is offered as a contact afterwards.
            return (true, found.legacy ? nil : found)
        } catch {
            return (false, nil)
        }
    }

    private static func reason(_ error: any Error, address: String, onion: Bool) -> ComposeError {
        if let composed = error as? ComposeError { return composed }
        switch (error as? APIError)?.status {
        case 507: return .mailboxFull(address)
        case 502 where onion: return .privateRouteFailed(address)
        default: return .notDelivered(address)
        }
    }

    /// A reply continues the original's thread. A pre-feature original has an all-zero id, which is
    /// treated as absent, so anything else starts a fresh thread.
    private static func threadID(continuing reply: ComposeReplyTo?) -> Data {
        guard let hex = reply?.threadId, hex.contains(where: { $0 != "0" }), let id = messageID(hex) else {
            return ComposeAttachments.newUUID()
        }
        return id
    }

    private static func messageID(_ hex: String) -> Data? {
        Data(hex: hex).flatMap { $0.count == 16 ? $0 : nil }
    }

    /// `/<img\s/i`: whether the HTML holds an image, which makes it worth sending with no text.
    private static func hasImage(_ html: String) -> Bool {
        var rest = Substring(html.lowercased())
        while let start = rest.range(of: "<img") {
            rest = rest[start.upperBound...]
            if let next = rest.unicodeScalars.first, JSText.isWhitespace(next) { return true }
        }
        return false
    }
}
