import Foundation

/// The rules a mail list follows, one place each, so the views, the rail and search can't disagree.
/// Parity with the browser's lib/mailView.ts, lib/unread.ts and lib/firstRun.ts.
public enum MailView {}

extension JSText {
    /// `text.includes(needle)`. `String.contains` compares whole characters, so it wouldn't find a
    /// person in a family emoji. Over UTF-8 a match can only start on a scalar boundary.
    static func includes(_ text: String, _ needle: String) -> Bool {
        let haystack = Array(text.utf8)
        let wanted = Array(needle.utf8)
        guard !wanted.isEmpty else { return true }
        guard haystack.count >= wanted.count else { return false }
        for start in 0...(haystack.count - wanted.count) where haystack[start] == wanted[0] {
            if haystack[start..<(start + wanted.count)].elementsEqual(wanted) { return true }
        }
        return false
    }

    /// `text.startsWith(prefix)`, for the same reason.
    static func startsWith(_ text: String, _ prefix: String) -> Bool {
        text.utf8.starts(with: prefix.utf8)
    }
}

extension Array {
    /// JavaScript's `sort` is stable and the lists depend on it for messages sent in the same
    /// second; Swift doesn't promise it.
    func stablySorted<Key: Comparable>(descendingBy key: (Element) -> Key) -> [Element] {
        enumerated()
            .sorted { a, b in
                let (ka, kb) = (key(a.element), key(b.element))
                return ka == kb ? a.offset < b.offset : ka > kb
            }
            .map(\.element)
    }
}

/// Where a message is listed.
public enum MailPlace: Hashable, Sendable {
    case inbox, archive, sent, deleted
    case folder(String)
}

/// What `placeOf` reads besides the message.
public struct PlaceContext: Sendable {
    public var address: String?
    public var flags: [String: FlagRecord]
    public var filter: FilterList?
    public var control: Set<String>
    /// Folders that still exist: a message filed in a deleted folder is back in the Inbox.
    public var knownFolderIDs: Set<String>

    public init(
        address: String?, flags: [String: FlagRecord], filter: FilterList?, control: Set<String> = [],
        knownFolderIDs: Set<String>
    ) {
        self.address = address
        self.flags = flags
        self.filter = filter
        self.control = control
        self.knownFolderIDs = knownFolderIDs
    }
}

/// What `isFirstRun` weighs.
public struct FirstRunInput: Sendable {
    /// Both listings have landed. Before then an empty list says nothing about the mailbox.
    public var mailLoaded: Bool
    public var sentLoaded: Bool
    /// Received mail, control messages excluded, and the Sent store.
    public var mailCount: Int
    public var sentCount: Int
    /// Something else already explains the empty list: reading locked, or a listing error.
    public var explained: Bool

    public init(mailLoaded: Bool, sentLoaded: Bool, mailCount: Int, sentCount: Int, explained: Bool) {
        self.mailLoaded = mailLoaded
        self.sentLoaded = sentLoaded
        self.mailCount = mailCount
        self.sentCount = sentCount
        self.explained = explained
    }
}

extension MailView {
    static func newestFirst(_ previews: [MailPreview]) -> [MailPreview] {
        previews.stablySorted(descendingBy: \.sentAt)
    }

    /// Whether the header's address is the owner's. A withheld message's address isn't anyone's.
    static func isFromOwner(_ m: MailPreview, address: String?) -> Bool {
        guard let address else { return false }
        return JSText.same(m.attributedAddress.lowercased(), address.lowercased())
    }

    /// Whether a mailbox message belongs in the received views for the owner at `address`. A copy
    /// here was normally sent by someone else; the exception is mailing yourself, which is genuine
    /// received mail and also appears in Sent, from the separate Sent store.
    public static func isReceivedForMe(_ m: MailPreview, address: String?) -> Bool {
        guard let address, !address.isEmpty else { return false }
        if !isFromOwner(m, address: address) { return true }
        let me = address.lowercased()
        func isMe(_ a: String) -> Bool { JSText.same(a.lowercased(), me) }
        return isMe(m.recipientAddress) || m.to.contains(where: isMe) || m.cc.contains(where: isMe)
    }

    /// Where a message lives, for search, which lists every view at once and keeps each row's
    /// actions true to its place. Nil for what search leaves out: control messages and blocked
    /// senders. Deleted wins over everything; a message filed and archived appears in both, and its
    /// place is the folder, the more specific.
    public static func placeOf(_ m: MailPreview, _ ctx: PlaceContext) -> MailPlace? {
        let flag = ctx.flags[m.hash]
        if flag?.trashedAt != nil {
            return shownInDeleted(m, address: ctx.address, flags: ctx.flags, filter: ctx.filter, control: ctx.control)
                ? .deleted : nil
        }
        if ctx.control.contains(m.subject) { return nil }
        if SentStore.isSentHash(m.hash) || !isReceivedForMe(m, address: ctx.address) { return .sent }
        if !isFromOwner(m, address: ctx.address), blocks(ctx.filter, m) { return nil }
        if let folder = flag?.folderId, !folder.isEmpty, ctx.knownFolderIDs.contains(folder) { return .folder(folder) }
        if flag?.archived == true { return .archive }
        return .inbox
    }

    static func blocks(_ filter: FilterList?, _ m: MailPreview) -> Bool {
        filter?.blocks(senderAddress: m.senderAddress, senderKeyHex: m.senderPublicKey) ?? false
    }

    /// A snippet ready for a one-line row. It's a signed prefix of the body, so this changes only
    /// how it reads: bridged newsletters arrive as "[image: Logo][1] [Sale][2]", and a row has no
    /// use for reference markers. The body isn't here, so nothing tries to find a better line.
    ///
    /// Written out rather than as a regex: JavaScript's `\d` and `\s` differ from Swift's, and
    /// Swift's matching steps over whole characters where the browser steps over code units.
    public static func previewText(_ snippet: String) -> String {
        var s = Array(snippet.unicodeScalars)
        s = dropImagePlaceholders(s)
        s = unwrapReferences(s)
        s = dropBareReferences(s)
        // The snippet is a truncated prefix, so it routinely ends inside a construct: a half-written
        // image placeholder goes, and any other unclosed bracket keeps its text.
        if let cut = s.indices.first(where: { isImageOpener(s, $0) && closing(s, from: $0 + imageOpener.count) == nil })
        {
            s.removeSubrange(cut...)
        }
        if let cut = s.indices.first(where: { s[$0] == "[" && closing(s, from: $0 + 1) == nil }) {
            s.remove(at: cut)
        }
        var out = String.UnicodeScalarView()
        out.append(contentsOf: s)
        return JSText.foldedWhitespace(String(out))
    }

    private static let imageOpener = Array("[image:".unicodeScalars)

    private static func isImageOpener(_ s: [Unicode.Scalar], _ i: Int) -> Bool {
        s[i...].starts(with: imageOpener)
    }

    private static func closing(_ s: [Unicode.Scalar], from i: Int) -> Int? {
        i <= s.count ? s[i...].firstIndex(of: "]") : nil
    }

    /// The index past a "[n]" starting at `i`, if one does.
    private static func referenceEnd(_ s: [Unicode.Scalar], at i: Int) -> Int? {
        guard i < s.count, s[i] == "[" else { return nil }
        var j = i + 1
        while j < s.count, ("0"..."9").contains(s[j]) { j += 1 }
        guard j > i + 1, j < s.count, s[j] == "]" else { return nil }
        return j + 1
    }

    /// `/\[image:[^\]]*\]\s*(\[\d+\])?/g`, removed. It runs before the unwrapping so an image that
    /// was also a link leaves nothing behind.
    private static func dropImagePlaceholders(_ s: [Unicode.Scalar]) -> [Unicode.Scalar] {
        var out: [Unicode.Scalar] = []
        var i = 0
        while i < s.count {
            if isImageOpener(s, i), let close = closing(s, from: i + imageOpener.count) {
                i = close + 1
                while i < s.count, JSText.isWhitespace(s[i]) { i += 1 }
                if let end = referenceEnd(s, at: i) { i = end }
                continue
            }
            out.append(s[i])
            i += 1
        }
        return out
    }

    /// `/\[([^\]]*)\]\[\d+\]/g` to its label. The number means nothing without the link table at
    /// the end of the body.
    private static func unwrapReferences(_ s: [Unicode.Scalar]) -> [Unicode.Scalar] {
        var out: [Unicode.Scalar] = []
        var i = 0
        while i < s.count {
            if s[i] == "[", let close = closing(s, from: i + 1), let end = referenceEnd(s, at: close + 1) {
                out.append(contentsOf: s[(i + 1)..<close])
                i = end
                continue
            }
            out.append(s[i])
            i += 1
        }
        return out
    }

    /// `/\[\d+\]/g`, removed: a link whose text was empty.
    private static func dropBareReferences(_ s: [Unicode.Scalar]) -> [Unicode.Scalar] {
        var out: [Unicode.Scalar] = []
        var i = 0
        while i < s.count {
            if let end = referenceEnd(s, at: i) {
                i = end
            } else {
                out.append(s[i])
                i += 1
            }
        }
        return out
    }

    /// Everyone a message went to (To + Cc), falling back to the single recipient for copies from
    /// before the lists. A Sent row is about the first of them.
    public static func recipientsOf(_ m: MailPreview) -> [String] {
        m.to.isEmpty && m.cc.isEmpty ? [m.recipientAddress] : m.to + m.cc
    }

    /// Received, non-control, unarchived, unread mail not in Deleted, excluding blocked senders.
    /// Trust is decided when a message is read, so an unknown sender counts. The inbox badge and the
    /// account switcher must both use this: two counts for one mailbox is worse than none.
    public static func countUnread(
        _ previews: [MailPreview], address: String?, flags: [String: FlagRecord], filter: FilterList?,
        control: Set<String> = []
    ) -> Int {
        previews.reduce(0) { count, m in
            guard isReceivedForMe(m, address: address), !control.contains(m.subject) else { return count }
            let flag = flags[m.hash]
            if flag?.archived == true || flag?.read == true || flag?.trashedAt != nil { return count }
            if !isFromOwner(m, address: address), blocks(filter, m) { return count }
            return count + 1
        }
    }

    /// Whether a mailbox has never had mail in either direction: the one moment the Inbox has
    /// nothing better to show than how to start.
    public static func isFirstRun(_ s: FirstRunInput) -> Bool {
        s.mailLoaded && s.sentLoaded && !s.explained && s.mailCount == 0 && s.sentCount == 0
    }

    /// Two letters for an account's monogram.
    public static func initialsOf(_ address: String) -> String {
        let local = address.split(separator: "@", omittingEmptySubsequences: false).first.map(String.init) ?? ""
        let source = local.isEmpty ? address : local
        // Two UTF-16 units, as the browser takes them. Half of an emoji can't be held here, so it goes.
        var units = Array(source.utf16.prefix(2))
        if let last = units.last, UTF16.isLeadSurrogate(last) { units.removeLast() }
        return String(decoding: units, as: UTF16.self).uppercased()
    }
}
