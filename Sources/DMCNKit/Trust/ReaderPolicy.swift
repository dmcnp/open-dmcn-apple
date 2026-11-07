import Foundation

// What a person may see of an open message, as one pure function of the facts. The browser computes
// this inside components/MessageReader.tsx; here it's the kit's, where a table can test it.
//
// The rule it's built around: the gate holds back the RENDERED message, meaning its HTML, remote
// images and attachment downloads. It doesn't hold back the words, because escaped text can't act on
// the reader, and a warning a reader can see is false teaches them to skip the next one.
//
// Except where SPEC_CORE §3 says otherwise. Where the directory binds the address to a different key
// the message is not from the address it names, and a reader MUST NOT render its body, attachments or
// HTML: no plain-text peek, no override, nothing `revealed` or `messageTrusted` can open. The browser
// gates such a message and offers the peek. This doesn't.
//
// A record the domain disowns while the key still matches isn't that case: the failure can be
// temporary, so its text can be read behind the gate, in both clients. The address stays unattributed.
//
// It differs from the browser in five more places, each with its own tests:
//
// - A message is the reader's own only if its key is too. The browser goes by the address alone, and
//   anyone can name your address and sign with their own key.
// - A verified receipt counts only on a message that isn't bridged mail. See BridgeVerifier.receipt.
// - What's attached to a disowned message isn't believed. The browser reads a stapled attestation.
// - Nothing is decided until the directory verdict is in, for any message but the reader's own. The
//   browser skips that wait for bridged mail and pending senders, but SPEC_CORE §3 has no such
//   exception, and the peek opened on an unsettled verdict could show what the verdict forbids.
// - Nothing is granted before `trustReady`. The browser's downloads unlock a moment early.

public enum GateReason: String, Sendable, Equatable {
    /// The owner's standing decision, lifted by unblocking.
    case blocked
    /// Legacy mail the bridge couldn't authenticate: a doubt about this message that no decision
    /// about the address can settle, because the address is the part anyone can forge.
    case unauthenticated
    /// The directory or a pin says the signing key isn't who this claims to be.
    case impersonation
    /// A question about a person, which trusting them settles for good.
    case unknown
}

public struct GateCopy: Sendable, Equatable {
    /// With the message hidden: nothing rendered.
    public let hiddenTitle: String
    public let hiddenDetail: String
    /// With the message shown as plain text: escaped, so nothing in it can act on the reader.
    public let plainTitle: String
    public let plainDetail: String
}

/// The facts one decision is made from. Everything here is known or unknown, never derived.
public struct ReaderInput: Sendable {
    // The message, from its verified header.
    public var senderAddress: String
    public var senderPublicKey: Data
    public var senderDisplay: String
    public var recipientAddress: String
    public var to: [String]
    public var cc: [String]
    /// Opened from the Sent folder: read back from this account's own sealed store.
    public var sentView: Bool
    /// What the reader checks found when the list was drawn, when this came from one.
    public var listedAs: MessageSummary.Sender?

    // The account reading it.
    public var accountAddress: String?
    /// Every key this account has signed with, current and retired. Leave one out and that mail
    /// reads as someone else's, which fails closed.
    public var accountSigningKeys: [Data]

    // What this device holds.
    /// The sender's contact, from `ContactStore`.
    public var contact: ContactRecord?
    /// `ContactStore.name(for:)` on the counterparty: the sender, or the first recipient in Sent.
    public var counterpartyContactName: String
    public var contactsReady: Bool
    public var filter: FilterList?
    public var filterReady: Bool

    // What the body carried, once it's open.
    public var attestation: BridgeAttestation?
    public var receipt: DeliveryReceiptView?
    /// The body and both attestations have settled, one way or the other.
    public var bridgeResolved: Bool
    public var hasHTML: Bool
    public var hasOriginal: Bool

    // What the directory said.
    public var nativeTrust: SenderTrust?
    /// Distinct from `nativeTrust != nil`, which can't tell "still resolving" from "resolved to
    /// nothing". The gate has to fail closed on the first.
    public var nativeTrustSettled: Bool
    public var keyChange: KeyChange?

    // What the reader decided about this message.
    /// Asked for the plain-text peek.
    public var revealed: Bool
    /// "View HTML anyway", or trusting a bridged sender. Scoped to this message.
    public var messageTrusted: Bool

    public var remoteImagesForTrusted: Bool

    /// Where a date in a sentence is formatted.
    public var locale: Locale
    public var timeZone: TimeZone

    public init(
        senderAddress: String, senderPublicKey: Data, senderDisplay: String = "", recipientAddress: String = "",
        to: [String] = [], cc: [String] = [], sentView: Bool = false, listedAs: MessageSummary.Sender? = nil,
        accountAddress: String? = nil, accountSigningKeys: [Data] = [], contact: ContactRecord? = nil,
        counterpartyContactName: String = "", contactsReady: Bool = false, filter: FilterList? = nil,
        filterReady: Bool = false, attestation: BridgeAttestation? = nil, receipt: DeliveryReceiptView? = nil,
        bridgeResolved: Bool = false, hasHTML: Bool = false, hasOriginal: Bool = false, nativeTrust: SenderTrust? = nil,
        nativeTrustSettled: Bool = false, keyChange: KeyChange? = nil, revealed: Bool = false,
        messageTrusted: Bool = false, remoteImagesForTrusted: Bool = false, locale: Locale = .current,
        timeZone: TimeZone = .current
    ) {
        self.senderAddress = senderAddress
        self.senderPublicKey = senderPublicKey
        self.senderDisplay = senderDisplay
        self.recipientAddress = recipientAddress
        self.to = to
        self.cc = cc
        self.sentView = sentView
        self.listedAs = listedAs
        self.accountAddress = accountAddress
        self.accountSigningKeys = accountSigningKeys
        self.contact = contact
        self.counterpartyContactName = counterpartyContactName
        self.contactsReady = contactsReady
        self.filter = filter
        self.filterReady = filterReady
        self.attestation = attestation
        self.receipt = receipt
        self.bridgeResolved = bridgeResolved
        self.hasHTML = hasHTML
        self.hasOriginal = hasOriginal
        self.nativeTrust = nativeTrust
        self.nativeTrustSettled = nativeTrustSettled
        self.keyChange = keyChange
        self.revealed = revealed
        self.messageTrusted = messageTrusted
        self.remoteImagesForTrusted = remoteImagesForTrusted
        self.locale = locale
        self.timeZone = timeZone
    }
}

public struct ReaderDecision: Sendable {
    /// The strip, or nil until every fact it describes has settled.
    public let checks: MessageChecksView?
    /// False on a cold load: show neither the gate nor the body yet.
    public let trustReady: Bool
    public let gated: Bool
    public let plainShown: Bool
    /// Trusting can actually change the outcome. A button that silently does nothing is what made
    /// trusting feel broken on the mail that needed the decision.
    public let trustActionable: Bool
    /// "View HTML anyway" is on offer.
    public let overrideActionable: Bool
    public let gateReason: GateReason
    public let gateCopy: GateCopy
    public let trustLabel: String
    public let htmlWarning: String
    public let downloadsUnlocked: Bool
    public let htmlAllowed: Bool
    public let remoteImagesAllowed: Bool
    public let showSource: Bool

    /// SPEC_CORE §3 forbids showing this message: its body isn't fetched, and nothing opens it.
    public let withheld: Bool
    /// The key matches, but the domain doesn't stand behind the address. Its text can be read behind
    /// the gate, but the address isn't who it's from, so nothing may repeat it as attribution.
    public let disowned: Bool
    /// "View as plain text" is on offer. False while withheld, and until the verdict is in.
    public let plainTextOffered: Bool
    public let ownMessage: Bool
    public let keyChanged: Bool
    /// Who the message is from, as the checks allow it to be shown. Never the address while withheld.
    public let counterpartyName: String
    /// The address beside a name. nil when the name is the address, and while withheld.
    public let counterpartyAddress: String?
    /// The sender's monogram.
    public let initials: String
}

public enum ReaderPolicy {
    public static func decide(_ input: ReaderInput) -> ReaderDecision {
        let own = isOwnMessage(input)
        // A verdict on own mail is never asked for: nothing about it is in question.
        let verdict = own ? nil : input.nativeTrust
        let withheld = isWithheld(input, verdict: verdict, own: own)
        let disowned = !own && !withheld && isDisowned(input, verdict: verdict)

        // A withheld message has no body to read these from. Neither could speak for one the domain
        // disowns: the sender attached them, and their key isn't the bridge's.
        let attestation = withheld || disowned ? nil : input.attestation
        // A receipt on bridged mail is the legacy sender's attachment. See BridgeVerifier.receipt.
        let receipt = withheld || disowned || attestation != nil ? nil : input.receipt

        // `verified` only proves the bridge credential chains to the anchor. It says nothing about
        // whether the legacy sender passed SPF/DKIM/DMARC: that's the signed tier, and only a
        // VerifiedLegacy tier is an anti-spoof proof.
        let bridgedLegacy = attestation?.verified == true
        let bridgeAuthenticated = bridgedLegacy && attestation?.trustTier == .verifiedLegacy
        let nativeDanger =
            !bridgedLegacy
            && (verdict?.kind == .keyMismatch || verdict?.kind == .keyChanged || disowned)

        // A verified receipt is the bridge's confirmation of your own outbound mail, not an unknown
        // sender, and nobody can forge an anchored bridge's receipt, so it passes the gate.
        let trustBypass = own || receipt?.verified == true
        let base: SenderCategory =
            trustBypass
            ? .allowlisted
            : TrustCategory.categorize(
                senderAddress: input.senderAddress, senderKeyHex: input.senderPublicKey.hex, contact: input.contact,
                filter: input.filter)
        // A keyless allowlist entry is a legacy sender. The address alone is spoofable, so it's
        // honoured only for a message the bridge authenticated. Provenance is read raw: one written
        // by a newer client is unknown to `TrustProvenance` and must count here all the same.
        //
        // A contact typed in by hand has no key and no provenance, and is held to the same rule
        // whenever nothing else vouches for the key: bridged mail, an unreachable directory, or an
        // address with no identity. Only the directory confirming the signing key lets it through.
        let keyVouched = verdict != nil && verdict?.kind != .directoryMissing
        let senderIsLegacyContact =
            input.contact.map { contact in
                (contact.ed25519Pub ?? "").isEmpty
                    && (!(contact.fields.string("provenance") ?? "").isEmpty || bridgedLegacy || !keyVouched)
            } ?? false

        // Own mail has no anchor to wait for, and nor does a header carrying no key.
        let verdictSettled = own || withheld || input.senderPublicKey.isEmpty || input.nativeTrustSettled
        // A withheld body is never fetched, so there's nothing for this to wait on.
        let bridgeSettled = input.bridgeResolved || withheld
        let trustReady = own || (input.contactsReady && input.filterReady && bridgeSettled && verdictSettled)

        let category: SenderCategory
        if withheld {
            category = base == .blocked ? .blocked : .pending
        } else if trustBypass || base != .allowlisted {
            category = base
        } else if senderIsLegacyContact && !bridgeAuthenticated {
            category = .pending  // a legacy address vouched for by nothing the bridge verified
        } else if nativeDanger {
            category = .pending  // the directory disowns the key that signed this header
        } else {
            category = base
        }

        let gateReason: GateReason =
            category == .blocked
            ? .blocked
            : withheld
                ? .impersonation
                : bridgedLegacy && !bridgeAuthenticated ? .unauthenticated : nativeDanger ? .impersonation : .unknown
        // A contact held at the gate because this message couldn't be checked. Trusting them again
        // would change nothing, so the choice is about this message alone.
        let unconfirmedContact = category == .pending && senderIsLegacyContact && gateReason == .unknown
        // A changed key on a native contact: the trust action re-pins rather than introduces.
        let keyChanged = !bridgedLegacy && verdict?.kind == .keyChanged
        // Offered only where it can change the outcome. Where checks failed the address is the part
        // anyone can forge, so an allowlist entry can't stand in for the missing authentication. For
        // a blocked sender the filter decides first. A withheld message stays withheld: the key the
        // directory lists would be pinned, and it isn't the key that signed this.
        let trustActionable =
            !withheld && !disowned && gateReason != .blocked && gateReason != .unauthenticated && !unconfirmedContact
        // Where the doubt is about this message's rendering, and there's HTML to show. Not for
        // blocked, and not where the directory disowns the signing key outright.
        let overrideActionable =
            !withheld && input.hasHTML
            && (gateReason == .unauthenticated || (gateReason == .impersonation && keyChanged) || unconfirmedContact)
        let gated = trustReady && category != .allowlisted && (withheld || !input.messageTrusted)
        // A message whose checks failed opens straight onto its text: the doubt is about its links
        // and formatting, not about whether to read it.
        let plainShown = gated && !withheld && (input.revealed || gateReason == .unauthenticated)
        let plainTextOffered = gated && !withheld
        // On sender trust, or the owner's decision about this message. Independent of `revealed`: the
        // peek is safe because text is escaped, and a binary download isn't.
        let downloadsUnlocked = trustReady && !withheld && (own || category == .allowlisted || input.messageTrusted)
        let htmlAllowed = input.hasHTML && downloadsUnlocked
        // Riding on `htmlAllowed`, opting in changes what a trusted sender's HTML may fetch, never
        // which senders get HTML. "View HTML anyway" doesn't carry it: a remote image is a read
        // receipt, and the override isn't a decision to send one.
        let remoteImagesAllowed =
            htmlAllowed && (own || category == .allowlisted) && input.remoteImagesForTrusted

        // The header's audience, for the Sent view's counterparty.
        let toList = input.to.isEmpty ? (input.recipientAddress.isEmpty ? [] : [input.recipientAddress]) : input.to
        let counterparty = input.sentView ? toList.first ?? "" : input.senderAddress
        // The name a message carries is the signer's to choose, so one the directory contradicts
        // isn't repeated back as who it's from, even in a sentence that warns about them.
        let label = DisplayName.senderLabel(
            address: counterparty, contactName: input.counterpartyContactName,
            wireDisplay: input.sentView || withheld || disowned ? "" : input.senderDisplay)

        // What the list found stands even before the reader's own verdict arrives.
        let forcedVerdict: SenderTrust.Kind? = withheld ? .keyMismatch : disowned ? .identityUnverifiable : nil
        let checksReady = own || (input.contactsReady && input.filterReady && bridgeSettled && verdictSettled)
        let checks =
            checksReady
            ? MessageChecks.view(
                ChecksInput(
                    address: input.senderAddress, name: label.primary, recipients: audienceCount(input), own: own,
                    attestation: attestation, receipt: receipt,
                    trust: forcedVerdict.map { SenderTrust(kind: $0) } ?? verdict, keyChange: input.keyChange,
                    locale: input.locale, timeZone: input.timeZone))
            : nil

        let first = firstName(label.primary, address: counterparty)
        let copy =
            withheld
            ? withheldCopy(claimed: counterparty)
            : gateCopy(
                gateReason, who: counterparty, first: first, known: input.contact != nil, keyChanged: keyChanged,
                hasHTML: input.hasHTML, unconfirmed: unconfirmedContact)
        let htmlWarning =
            gateReason == .unauthenticated
            ? "HTML can hide where links really lead. This message failed its checks. Remote images stay off either way."
            : unconfirmedContact
                ? "HTML can hide where links really lead. This message could not be checked. Remote images stay off either way."
                : "HTML can hide where links really lead. \(JSText.same(first, counterparty) ? "The" : "\(first)’s") new key is still unconfirmed. Remote images stay off either way."

        return ReaderDecision(
            checks: checks, trustReady: trustReady, gated: gated, plainShown: plainShown,
            trustActionable: trustActionable, overrideActionable: overrideActionable, gateReason: gateReason,
            gateCopy: copy, trustLabel: keyChanged ? "Trust new key" : "I trust the sender", htmlWarning: htmlWarning,
            downloadsUnlocked: downloadsUnlocked, htmlAllowed: htmlAllowed, remoteImagesAllowed: remoteImagesAllowed,
            showSource: trustReady && attestation?.verified == true && input.hasOriginal && (!gated || plainShown),
            withheld: withheld, disowned: disowned, plainTextOffered: plainTextOffered, ownMessage: own,
            keyChanged: keyChanged,
            counterpartyName: withheld
                ? "Possibly forged sender" : disowned ? "Sender not vouched for" : label.primary,
            counterpartyAddress: withheld || disowned || label.secondary.isEmpty ? nil : label.secondary,
            initials: withheld || disowned ? "?" : initials(label.primary))
    }

    /// Whether the reader wrote this. The Sent view reads this account's own sealed store, so it's
    /// theirs by construction. Anything else has to be signed by a key of theirs as well as name
    /// their address, or a stranger could mail you as yourself and walk through every gate.
    public static func isOwnMessage(_ input: ReaderInput) -> Bool {
        if input.sentView { return true }
        guard let account = input.accountAddress, JSText.sameIgnoringCase(input.senderAddress, account) else {
            return false
        }
        return input.accountSigningKeys.contains { constantTimeEqual($0, input.senderPublicKey) }
    }

    /// Whether this message may not be shown. SPEC_CORE §3 requires it of a key the directory doesn't
    /// list. The list's check counts too: `Inbox` won't have fetched that body.
    private static func isWithheld(_ input: ReaderInput, verdict: SenderTrust?, own: Bool) -> Bool {
        guard !own else { return false }
        if verdict?.kind == .keyMismatch { return true }
        switch input.listedAs {
        case .mismatch, .unreadable: return true
        case .verified, .unverified, .disowned, nil: return false
        }
    }

    /// Whether the domain doesn't stand behind the address, by the reader's verdict or the list's.
    private static func isDisowned(_ input: ReaderInput, verdict: SenderTrust?) -> Bool {
        if verdict?.kind == .identityUnverifiable { return true }
        if case .disowned = input.listedAs { return true }
        return false
    }

    /// `dedupe([...to, ...cc]).length`.
    private static func audienceCount(_ input: ReaderInput) -> Int {
        var seen: [String] = []
        for address in input.to + input.cc where !address.isEmpty {
            let key = address.lowercased()
            if !seen.contains(where: { JSText.same($0, key) }) { seen.append(key) }
        }
        return seen.count
    }

    /// The gate panel for a message that can't be opened. The plain fields repeat the hidden ones: no
    /// plain state exists, so anything reaching for one still reads what is true.
    private static func withheldCopy(claimed: String) -> GateCopy {
        let detail =
            "This message says it is from \(claimed), but it wasn't signed with their key, so it may be forged. Its contents are hidden. If you were expecting it, check with them by phone or text."
        return GateCopy(
            hiddenTitle: "Message hidden", hiddenDetail: detail, plainTitle: "Message hidden", plainDetail: detail)
    }

    /// The gate panel's wording, in both its states. Why the gate closed is said once, in the checks
    /// strip; this says what's held back and what the reader can do about it. `who` is the sender as
    /// displayed, `first` how a sentence names them, `known` whether they're in the address book.
    static func gateCopy(
        _ reason: GateReason, who: String, first: String, known: Bool, keyChanged: Bool, hasHTML: Bool,
        unconfirmed: Bool = false
    ) -> GateCopy {
        let links = "Links show where they really go and cannot be clicked."
        let checkFirst =
            "If you are not sure, contact \(first) another way, such as a phone call, before you trust \(keyChanged ? "the new key" : "them")."
        switch reason {
        case .blocked:
            return GateCopy(
                hiddenTitle: "You blocked this sender",
                hiddenDetail:
                    "\(who) is on your blocklist, so nothing in this message loads. You can still read it as plain text. Manage the list in Settings if the block was a mistake.",
                plainTitle: "Shown as plain text because you blocked this sender",
                plainDetail: links)
        case .unauthenticated:
            // No hidden state in practice: this opens straight onto its text.
            return GateCopy(
                hiddenTitle: "Shown as plain text because the checks failed",
                hiddenDetail: links,
                plainTitle: "Shown as plain text because the checks failed",
                plainDetail: hasHTML
                    ? "\(links) The HTML version can hide where a link leads, so it stays off unless you choose it."
                    : links)
        case .impersonation:
            return GateCopy(
                hiddenTitle: "Message hidden until you decide",
                hiddenDetail: "Nothing in this message loads while it is hidden. \(checkFirst)",
                plainTitle: "Shown as plain text until you decide",
                plainDetail: "\(links) \(checkFirst)")
        case .unknown:
            // `known` isn't redundant: someone on the allowlist still lands here when the verdict
            // that would admit them couldn't be reached, and telling that reader they don't know this
            // sender describes neither the sender nor the problem.
            return GateCopy(
                hiddenTitle: "Message hidden until you decide",
                hiddenDetail: unconfirmed
                    ? "\(who) is in your contacts, but this message could not be checked, so it may not be from them. Nothing in it loads while it is hidden. Reading the plain text is safe if that helps you decide."
                    : known
                        ? "\(who) is in your contacts, but this message does not match what you have on file. Nothing in it loads while it is hidden. Reading the plain text is safe if that helps you decide."
                        : "You don’t know this sender yet. Nothing in this message loads while it is hidden, so its formatting, images and attachments cannot reach you. Reading the plain text is safe if that helps you decide.",
                plainTitle: "Shown as plain text until you decide",
                plainDetail: "\(links) Its formatting, images and attachments stay blocked until you trust \(first).")
        }
    }

    /// How a sentence addresses the sender: the first word of a name, or the whole address when
    /// there's no name to take one from.
    public static func firstName(_ name: String, address: String) -> String {
        if name.isEmpty || JSText.same(name, address) || JSText.contains(name, "@") { return address }
        let first = JSText.splitOnWhitespace(name)[0]
        return first.isEmpty ? address : first
    }

    /// The sender's monogram: the first letters of a name's first two words, or the first two letters
    /// of an address. Its separators and digits are noise: leo-5msr@… is "LE", not "L5".
    public static func initials(_ name: String) -> String {
        func letters(_ text: some StringProtocol) -> [Unicode.Scalar] {
            text.unicodeScalars.filter { scalar in
                switch scalar.properties.generalCategory {
                case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter: true
                default: false
                }
            }
        }
        func joined(_ scalars: some Sequence<Unicode.Scalar>) -> String {
            var view = String.UnicodeScalarView()
            view.append(contentsOf: scalars)
            return String(view)
        }
        let scalars = name.unicodeScalars
        if let at = scalars.firstIndex(of: "@") {
            let local = joined(letters(String(scalars[..<at])).prefix(2))
            return (local.isEmpty ? "?" : local).uppercased()
        }
        let words = JSText.splitOnWhitespace(name).map { letters($0) }.filter { !$0.isEmpty }
        if words.count > 1 { return joined([words[0][0], words[1][0]]).uppercased() }
        return (words.first.map { joined($0.prefix(2)) } ?? "?").uppercased()
    }
}
