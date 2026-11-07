import Crypto
import Foundation

// Reply, Reply all and Forward, as pure functions from a message to what the composer opens with.
// Reply and Reply all are the browser's buildReply (components/MessageReader.tsx) and the prefill at
// the top of components/ComposeDialog.tsx.
//
// Forward is not: the browser has no Forward. It is built here from the same rules, with its subject
// shaped like replySubject and its header block like the common mail-client convention. What it
// produces is an ordinary new message, so nothing on the wire depends on the choices made.

/// What a reply is built from: a verified header and, once it has opened, the body text.
public struct ReplyOriginal: Sendable, Equatable {
    public var senderAddress: String
    public var to: [String]
    public var cc: [String]
    public var subject: String
    /// Hex.
    public var messageID: String
    /// Hex.
    public var threadID: String
    /// Unix seconds.
    public var sentAt: Int64
    /// Nil until the body has loaded, so an early Reply just opens with an empty body.
    public var bodyText: String?

    public init(
        senderAddress: String, to: [String], cc: [String], subject: String, messageID: String, threadID: String,
        sentAt: Int64, bodyText: String? = nil
    ) {
        self.senderAddress = senderAddress
        self.to = to
        self.cc = cc
        self.subject = subject
        self.messageID = messageID
        self.threadID = threadID
        self.sentAt = sentAt
        self.bodyText = bodyText
    }

    public init(header: Dmcn_Message_MessageHeader, bodyText: String? = nil) {
        self.init(
            senderAddress: header.senderAddress, to: header.to, cc: header.cc, subject: header.subject,
            messageID: header.messageID.hex, threadID: header.threadID.hex, sentAt: header.sentAt, bodyText: bodyText)
    }
}

public enum ComposeReplies {
    /// The attachment types a bridge carries for its own purposes. Neither is a person's attachment.
    private static let classificationType = "application/x-dmcn-bridge-classification"
    private static let receiptType = "application/x-dmcn-bridge-delivery-receipt"

    /// What a Reply or Reply all starts from. `me` is the signed-in address and `senderName` the
    /// name of the sender's contact, if any. The date in the quote follows `locale` and `timeZone`.
    public static func reply(
        to original: ReplyOriginal, all: Bool, me: String, senderName: String? = nil, locale: Locale = .current,
        timeZone: TimeZone = .current
    ) -> ComposeReplyTo {
        let mine = me.lowercased()
        let notMe: (String) -> Bool = { $0.lowercased() != mine }
        let sentByMe = original.senderAddress.lowercased() == mine

        // To the sender; on my own message, to the original recipients instead.
        let primary = dedupe(
            sentByMe ? (original.to + original.cc).filter(notMe) : [original.senderAddress].filter(notMe))
        let to = primary.isEmpty ? [original.senderAddress] : primary
        // Reply all adds every other original recipient as Cc, minus me and the To set. Bcc is
        // ignored: it is only ever on my own Sent copy.
        let inTo = Set(to.map { Data($0.lowercased().utf8) })
        let cc =
            all
            ? dedupe(original.to + original.cc).filter(notMe).filter { !inTo.contains(Data($0.lowercased().utf8)) } : []

        let quote = original.bodyText.map {
            "On \(when(original.sentAt, locale: locale, timeZone: timeZone)), "
                + "\(who(original, senderName)) wrote:\n" + quoted($0)
        }
        // Which of our addresses it goes out as is the composer's call, since it knows the aliases.
        // So it gets what the original was addressed to, or sent from when the original is ours.
        return ComposeReplyTo(
            to: to, cc: cc, subject: original.subject,
            sentTo: sentByMe ? [original.senderAddress] : original.to + original.cc, quote: quote,
            replyToId: original.messageID, threadId: original.threadID)
    }

    /// Reply all is offered only when it would reach someone a plain Reply wouldn't.
    public static func offersReplyAll(_ original: ReplyOriginal, me: String) -> Bool {
        !(reply(to: original, all: true, me: me).cc ?? []).isEmpty
    }

    /// The moment as a quote gives it: "Thu, Sep 3, 2026 at 10:21 AM" in en-US.
    static func when(_ seconds: Int64, locale: Locale, timeZone: TimeZone) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(seconds))
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.setLocalizedDateFormatFromTemplate("EEEyMMMd")
        let day = formatter.string(from: date)
        formatter.setLocalizedDateFormatFromTemplate("jmm")
        // Recent locale data puts a narrow no-break space before AM. Browsers don't show one, and
        // it would turn up as a stray character in a plain-text reader.
        let time = formatter.string(from: date).replacingOccurrences(of: "\u{202F}", with: " ")
        return "\(day) at \(time)"
    }

    private static func who(_ original: ReplyOriginal, _ senderName: String?) -> String {
        if let senderName, !senderName.isEmpty { return "\(senderName) <\(original.senderAddress)>" }
        return original.senderAddress
    }

    /// Each line behind "> ", and an empty one as ">". Split on the scalar: "\r\n" is one Character
    /// in Swift, and mail that came in over a bridge has them.
    private static func quoted(_ body: String) -> String {
        lines(of: body).map { $0.isEmpty ? ">" : "> " + $0 }.joined(separator: "\n")
    }

    private static func lines(of text: String) -> [String] {
        text.unicodeScalars.split(separator: "\n", omittingEmptySubsequences: false).map { String($0) }
    }

    /// First spelling wins, compared without case, and an empty address goes. Compared as bytes
    /// because Swift's `==` treats two spellings of an accent as one, and JavaScript's doesn't.
    private static func dedupe(_ addresses: [String]) -> [String] {
        var seen = Set<Data>()
        return addresses.filter { !$0.isEmpty && seen.insert(Data($0.lowercased().utf8)).inserted }
    }

    /// What the composer opens with for a reply. `from` is the signed-in address and `ours` the
    /// account's other addresses: the reply goes out as whichever of them the other side wrote to,
    /// and none of them stays a recipient, which the reader couldn't have known to strip.
    public static func opening(
        _ reply: ComposeReplyTo, from: String, ours: [String] = [], signature: String? = nil
    ) -> DraftContent {
        let mine = Set(ours.map { Data($0.lowercased().utf8) })
        let isOurs: (String) -> Bool = { mine.contains(Data($0.lowercased().utf8)) }
        let reached = (reply.sentTo ?? []).map { $0.lowercased() }.first(where: isOurs)
        let to = reached == nil ? reply.to : reply.to.filter { !isOurs($0) }
        let cc = reached == nil ? reply.cc ?? [] : (reply.cc ?? []).filter { !isOurs($0) }
        // The quote is already in the body; what a draft keeps is what threading and From need.
        var kept = reply
        kept.quote = nil
        kept.quoteHtml = nil
        return DraftContent(
            from: reached ?? from, to: to, cc: cc, showCcBcc: !(reply.cc ?? []).isEmpty,
            subject: DraftStore.replySubject(reply.subject),
            text: startingText(signature: signature, isReply: true, quote: reply.quote), replyTo: kept)
    }

    /// What a body starts as, before anyone types. The signature goes above any quote, and the
    /// leading blank lines are where the person writes.
    public static func startingText(signature: String?, isReply: Bool = false, quote: String? = nil) -> String {
        let signature = signature ?? ""
        if !isReply, signature.isEmpty { return "" }
        let quote = quote ?? ""
        return "\n\n" + (signature.isEmpty ? quote : signature + (quote.isEmpty ? "" : "\n\n" + quote))
    }

    /// A saved draft as a plain-text composer carries it on: the text rendering, with the HTML let
    /// go. A draft left marked rich reopens in the browser from its HTML, which would lose whatever
    /// was typed here. Switching a message to plain text does the same in the browser.
    public static func resuming(_ draft: LoadedDraft) -> DraftContent {
        var content = draft.content
        content.rich = false
        content.html = ""
        return content
    }

    /// The subject a forward starts with, by the rule of `DraftStore.replySubject`.
    public static func forwardSubject(_ subject: String) -> String {
        guard !subject.isEmpty else { return "" }
        var rest = Substring(subject)
        if rest.prefix(4).lowercased() == "fwd:" {
            rest = rest.dropFirst(4)
            let spaces = rest.unicodeScalars.prefix(while: JSText.isWhitespace).count
            rest = Substring(rest.unicodeScalars.dropFirst(spaces))
        }
        return "Fwd: " + rest
    }

    /// What the composer opens with for a forward: no recipients, a thread of its own, and the
    /// original below the signature, unquoted. `attachments` are the original's, and those a person
    /// attached come along. Inline images don't: they belong to markup a plain forward doesn't carry.
    public static func forward(
        _ original: ReplyOriginal, attachments: [Dmcn_Message_AttachmentRecord] = [], from: String,
        senderName: String? = nil, signature: String? = nil, internalTypes: [String] = [],
        locale: Locale = .current, timeZone: TimeZone = .current
    ) -> DraftContent {
        var block = [
            "---------- Forwarded message ---------",
            "From: \(who(original, senderName))",
            "Date: \(when(original.sentAt, locale: locale, timeZone: timeZone))",
            "Subject: \(original.subject)",
            "To: \(original.to.joined(separator: ", "))",
        ]
        if !original.cc.isEmpty { block.append("Cc: \(original.cc.joined(separator: ", "))") }
        let quote = block.joined(separator: "\n") + "\n\n" + (original.bodyText ?? "")
        return DraftContent(
            from: from, subject: forwardSubject(original.subject),
            text: startingText(signature: signature, isReply: true, quote: quote),
            attachments: userAttachments(attachments, internalTypes: internalTypes)
                .filter { $0.disposition != "inline" }
                .map { record in
                    DraftAttachment(
                        attachmentID: ComposeAttachments.newUUID(), filename: record.filename,
                        contentType: record.contentType, sizeBytes: record.content.count,
                        contentHash: Data(SHA256.hash(data: record.content)), content: record.content)
                })
    }

    /// The attachments a person sent, as opposed to the ones the protocol carries alongside them.
    /// The bridge's raw copy of a legacy email is found by its slot, never by type alone: an email
    /// forwarded as an attachment is message/rfc822 too, and is the reader's to see. `internalTypes`
    /// are what this build carries for its own purposes. Parity with lib/userAttachments.ts.
    public static func userAttachments(
        _ all: [Dmcn_Message_AttachmentRecord], internalTypes: [String] = []
    ) -> [Dmcn_Message_AttachmentRecord] {
        let internalSet = Set(internalTypes + [classificationType, receiptType])
        let original =
            all.count >= 2 && all[0].contentType == classificationType && all[1].contentType == "message/rfc822"
                && all[1].filename == "original.eml"
            ? 1 : -1
        return all.enumerated().filter { $0.offset != original && !internalSet.contains($0.element.contentType) }
            .map(\.element)
    }
}
