import Foundation

// The reader's checks strip: what was established about a received message, as four plain words with
// a tick or a cross, and one sentence underneath when something did not hold.
//
// The words are the same for both kinds of mail so a reader learns them once, but what stands behind
// each differs, and the tip on every word says which:
//
//               regular email (via a bridge)              dmcn mail
//   Origin      SPF: a server the domain allows sent it    sent over dmcn, no regular email hop
//   Domain      DKIM: signed, and unchanged since          the domain lists the key that signed it
//   Sender      DMARC: the From address is the domain's    the key is the one you have on file
//   Encrypted   sealed to you by a bridge you trust        end to end
//
// This only describes. What is gated is `ReaderPolicy`'s decision, from the same facts. Parity with
// the browser's lib/trust/checks.ts.

public struct MessageChecksView: Sendable, Equatable {
    public enum SourceKind: String, Sendable, Equatable {
        case regular, dmcn, contact, own, receipt
    }
    public struct Source: Sendable, Equatable {
        public let kind: SourceKind
        public let label: String
        public let tip: String
    }
    public struct Check: Sendable, Equatable {
        public let word: CheckWord
        public let ok: Bool
        public let tip: String
    }
    public enum CheckWord: String, Sendable, Equatable {
        case origin = "Origin"
        case domain = "Domain"
        case sender = "Sender"
        case encrypted = "Encrypted"
    }
    public struct Notice: Sendable, Equatable {
        public enum Tone: String, Sendable, Equatable {
            case danger, warning, neutral
        }
        public let tone: Tone
        public let text: String
    }

    public let source: Source
    public let checks: [Check]
    /// The one sentence a failed check earns. Danger for anything that may be forged.
    public let notice: Notice?
}

/// What the strip is drawn from.
public struct ChecksInput: Sendable {
    /// The sender's address as the reader displays it.
    public var address: String
    /// How a sentence names the sender.
    public var name: String
    /// Everyone the message was addressed to besides the sender.
    public var recipients: Int
    public var own: Bool
    public var attestation: BridgeAttestation?
    public var receipt: DeliveryReceiptView?
    public var trust: SenderTrust?
    public var keyChange: KeyChange?
    /// Where a date in a sentence is formatted.
    public var locale: Locale
    public var timeZone: TimeZone

    public init(
        address: String, name: String, recipients: Int, own: Bool = false, attestation: BridgeAttestation? = nil,
        receipt: DeliveryReceiptView? = nil, trust: SenderTrust? = nil, keyChange: KeyChange? = nil,
        locale: Locale = .current, timeZone: TimeZone = .current
    ) {
        self.address = address
        self.name = name
        self.recipients = recipients
        self.own = own
        self.attestation = attestation
        self.receipt = receipt
        self.trust = trust
        self.keyChange = keyChange
        self.locale = locale
        self.timeZone = timeZone
    }
}

public enum MessageChecks {
    /// The domain of an address, lowercased, or "" when it has none.
    public static func domainPart(_ address: String) -> String {
        guard let at = address.unicodeScalars.lastIndex(of: "@") else { return "" }
        return String(address.unicodeScalars[address.unicodeScalars.index(after: at)...]).lowercased()
    }

    public static func view(_ input: ChecksInput) -> MessageChecksView {
        if input.own { return own(recipients: input.recipients) }
        if let receipt = input.receipt { return receiptChecks(receipt) }
        if let attestation = input.attestation { return bridged(attestation, address: input.address) }
        return native(input)
    }

    private static func own(recipients: Int) -> MessageChecksView {
        MessageChecksView(
            source: .init(kind: .own, label: "Sent by you", tip: "You sent this message."),
            checks: [
                .init(
                    word: .encrypted, ok: true,
                    tip: recipients > 0
                        ? "Your copy is encrypted so only you can read it." : "Encrypted so only you can read it.")
            ],
            notice: nil)
    }

    private static func receiptChecks(_ receipt: DeliveryReceiptView) -> MessageChecksView {
        let source = MessageChecksView.Source(
            kind: .receipt, label: "Delivery receipt", tip: "A receipt for mail you sent to a regular email address.")
        let who = receipt.recipientEmail.isEmpty ? "the recipient" : receipt.recipientEmail
        guard receipt.verified else {
            let reason = nonEmpty(receipt.reason).map { " (\($0))" } ?? ""
            return MessageChecksView(
                source: source,
                checks: [.init(word: .sender, ok: false, tip: "This receipt could not be verified\(reason).")],
                notice: .init(
                    tone: .warning,
                    text: "This receipt could not be verified, so it may not say what really happened to your message."
                ))
        }
        let detail = nonEmpty(receipt.errorDetail).map { ": \($0)" } ?? "."
        return MessageChecksView(
            source: source,
            checks: [.init(word: .sender, ok: true, tip: "Signed by a dmcn bridge you trust.")],
            notice: receipt.delivered
                ? .init(tone: .neutral, text: "The bridge delivered your message to \(who).")
                : .init(tone: .danger, text: "The bridge could not deliver your message to \(who)\(detail)"))
    }

    private static func bridged(_ a: BridgeAttestation, address: String) -> MessageChecksView {
        let source = MessageChecksView.Source(
            kind: .regular, label: "Regular email",
            tip: "Regular email. It reached dmcn through a bridge, which checked it on arrival.")
        guard a.verified else {
            // Nothing the record claims can be relied on, including which checks it says passed.
            let reason = nonEmpty(a.reason).map { " (\($0))" } ?? ""
            let tip = "The bridge that carried this could not be verified\(reason), so its checks cannot be relied on."
            let named = address.isEmpty ? "the sender" : address
            return MessageChecksView(
                source: source,
                checks: [
                    .init(word: .origin, ok: false, tip: tip),
                    .init(word: .domain, ok: false, tip: tip),
                    .init(word: .sender, ok: false, tip: tip),
                    .init(word: .encrypted, ok: true, tip: "Encrypted to you, by a bridge that could not be verified."),
                ],
                notice: .init(
                    tone: .danger,
                    text:
                        "This came through a bridge that could not be verified, so nothing confirms it is from \(named). Do not click links or reply until you have checked with them another way."
                ))
        }

        let from = orElse(domainPart(address), domainPart(a.smtpFrom))
        // SPF checks the envelope sender, which bulk mail routes through its provider. Name the
        // domain that was actually asked, and say on whose behalf.
        let envelope = orElse(domainPart(a.smtpFrom), from)
        let via = !envelope.isEmpty && !from.isEmpty && !JSText.same(envelope, from) ? ", on behalf of \(from)" : ""
        let spf = (a.spf ?? "").lowercased()
        let dkim = (a.dkim ?? "").lowercased()
        let dmarc = (a.dmarc ?? "").lowercased()

        let originTip: String
        switch spf {
        case "pass": originTip = "Sent from a mail server that \(envelope) allows\(via). (SPF)"
        case "fail", "softfail": originTip = "Sent from a mail server that \(envelope) does not allow. (SPF)"
        case "neutral": originTip = "\(envelope) does not say whether this mail server may send for it. (SPF)"
        default:
            originTip =
                "\(orElse(envelope, "The sending domain")) does not list which mail servers may send for it. (SPF)"
        }
        // The bridge accepts a valid signature from any domain here. Alignment with the From address
        // is DMARC's question, which is the Sender check, so this says "signed and unchanged".
        let domainTip: String
        switch dkim {
        case "pass": domainTip = "Signed by the mail system that sent it, and unchanged since. (DKIM)"
        case "fail": domainTip = "Its signature does not match, so it may have been changed on the way. (DKIM)"
        default: domainTip = "Not signed, so nothing shows it is unchanged since it was sent. (DKIM)"
        }
        let senderTip: String
        switch dmarc {
        case "pass": senderTip = "The From address really belongs to \(from). (DMARC)"
        case "fail": senderTip = "The From address does not belong to whoever sent this. (DMARC)"
        default:
            senderTip =
                "\(orElse(from, "The sending domain")) does not publish a way to confirm its From addresses. (DMARC)"
        }
        let checks: [MessageChecksView.Check] = [
            .init(word: .origin, ok: spf == "pass", tip: originTip),
            .init(word: .domain, ok: dkim == "pass", tip: domainTip),
            .init(word: .sender, ok: dmarc == "pass", tip: senderTip),
            .init(
                word: .encrypted, ok: true,
                tip:
                    "A trusted dmcn bridge checked this email and encrypted it to you. Before the bridge it travelled as regular email."
            ),
        ]

        // The notice follows the bridge's signed tier, as the gate does. A single cross under a
        // verified tier (SPF failing on a forwarded message whose aligned DKIM carried DMARC) shows
        // on its word but isn't a reason to alarm anybody.
        if a.trustTier == .verifiedLegacy { return MessageChecksView(source: source, checks: checks, notice: nil) }
        // Only a DMARC failure says the From address isn't theirs. A broken DKIM signature or a hard
        // SPF fail can make the tier Suspicious too, and neither proves who sent it.
        if dmarc == "fail" {
            return MessageChecksView(
                source: source, checks: checks,
                notice: .init(
                    tone: .danger,
                    text:
                        "This did not come from \(orElse(from, "the domain it names")). Someone used their address. Do not click links or reply."
                ))
        }
        return MessageChecksView(
            source: source, checks: checks,
            notice: .init(
                tone: .danger,
                text:
                    "\(orElse(from, "The sending domain")) could not confirm this came from them, so anyone could have put \(orElse(address, "this address")) on it. Do not click links or reply until you have checked with them another way."
            ))
    }

    private static func native(_ input: ChecksInput) -> MessageChecksView {
        let address = input.address
        let name = input.name
        let domain = orElse(domainPart(address), "their domain")
        let origin = MessageChecksView.Check(
            word: .origin, ok: true, tip: "Sent directly over dmcn, with no regular email involved.")
        let encrypted = MessageChecksView.Check(
            word: .encrypted, ok: true,
            tip: input.recipients > 1
                ? "Encrypted end to end. Only you and the other recipients can read it."
                : "Encrypted end to end. Only you can read it.")
        func dmcnSource(_ tip: String) -> MessageChecksView.Source { .init(kind: .dmcn, label: "dmcn mail", tip: tip) }
        // True for every verdict that got as far as comparing with a pin: the directory check is first.
        let listed = MessageChecksView.Check(word: .domain, ok: true, tip: "\(domain) lists this key for \(address).")

        switch input.trust?.kind {
        case .allowlisted:
            let label = input.trust?.provenance?.label ?? "Trusted contact"
            return MessageChecksView(
                source: .init(kind: .contact, label: label, tip: "\(label). \(name) is one of your contacts."),
                checks: [
                    .init(word: .sender, ok: true, tip: "Signed with the key you have on file for \(address)."),
                    listed, origin, encrypted,
                ],
                notice: nil)
        case .domainVerified:
            return MessageChecksView(
                source: dmcnSource("dmcn mail. \(name) is not in your contacts yet."),
                checks: [
                    .init(
                        word: .sender, ok: true,
                        tip:
                            "Signed with the key \(domain) vouches for. You have not added \(name) to your contacts yet."
                    ),
                    listed, origin, encrypted,
                ],
                notice: nil)
        case .unknownPending:
            return MessageChecksView(
                source: dmcnSource("dmcn mail. \(name) is not in your contacts yet."),
                checks: [
                    .init(word: .sender, ok: true, tip: "Signed with the key listed for \(address)."),
                    .init(word: .domain, ok: false, tip: "\(domain) has not vouched for \(address)."),
                    origin, encrypted,
                ],
                notice: .init(
                    tone: .warning,
                    text: "\(domain) has not vouched for \(address), so the address alone does not show who runs it."))
        case .recordChanged:
            let reason = nonEmpty(input.trust?.reason)
            return MessageChecksView(
                source: .init(
                    kind: .contact, label: "Trusted contact", tip: "Trusted contact. \(name) is one of your contacts."),
                checks: [
                    .init(word: .sender, ok: true, tip: "Signed with the key you have on file for \(address)."),
                    listed, origin, encrypted,
                ],
                notice: .init(
                    tone: .warning,
                    text: reason.map {
                        "\(capitalizedFirst($0)). Their keys are the same, so this really is from them. This was not a change they made, so check that it is expected."
                    }
                        ?? "Something about \(name)’s account changed since you verified them, though their keys are the same."
                ))
        case .keyChanged:
            return MessageChecksView(
                source: dmcnSource(
                    "dmcn mail. \(name) is one of your contacts. Their new key is waiting for your decision, so they show as a dmcn sender until you trust it."
                ),
                checks: [
                    .init(
                        word: .sender, ok: false,
                        tip: "Signed with a new key, different from the one you have on file for \(address)."),
                    .init(word: .domain, ok: true, tip: "\(domain) lists this new key for \(address)."),
                    origin, encrypted,
                ],
                // The same sentence the composer and the contact list show for the same event.
                notice: .init(
                    tone: .danger,
                    text: ComposePin.keyWarning(
                        name, change: input.keyChange, locale: input.locale, timeZone: input.timeZone)))
        case .keyMismatch:
            return MessageChecksView(
                source: dmcnSource("dmcn mail, but not signed with \(address)’s key."),
                checks: [
                    .init(word: .sender, ok: false, tip: "Signed with a key \(domain) does not list for \(address)."),
                    .init(word: .domain, ok: false, tip: "\(domain) lists a different key for \(address)."),
                    origin, encrypted,
                ],
                notice: .init(
                    tone: .danger,
                    text:
                        "This was not signed with the key \(domain) lists for \(address). Someone may be using their address. Do not click links or reply until you have checked with them another way."
                ))
        case .identityUnverifiable:
            return MessageChecksView(
                source: dmcnSource("dmcn mail, from an address \(domain) no longer vouches for."),
                checks: [
                    .init(word: .sender, ok: false, tip: "\(domain) no longer vouches for \(address)."),
                    .init(
                        word: .domain, ok: false,
                        tip: "\(domain)’s approval of \(address) was withdrawn or does not check out."),
                    origin, encrypted,
                ],
                notice: .init(
                    tone: .danger,
                    text:
                        "\(domain) no longer vouches for \(address). Do not click links or reply until you have checked with them another way."
                ))
        case .directoryMissing, nil:
            return MessageChecksView(
                source: dmcnSource("dmcn mail."),
                checks: [
                    .init(word: .sender, ok: false, tip: "Could not look up the key for \(address) just now."),
                    .init(word: .domain, ok: false, tip: "Could not reach \(domain) to check this key."),
                    origin, encrypted,
                ],
                notice: .init(
                    tone: .warning,
                    text: "Could not look up \(address) just now, so who signed this cannot be confirmed yet."))
        }
    }

    /// `a || b`, for strings.
    private static func orElse(_ a: String, _ b: String) -> String { a.isEmpty ? b : a }

    private static func nonEmpty(_ text: String?) -> String? { text.flatMap { $0.isEmpty ? nil : $0 } }
}
