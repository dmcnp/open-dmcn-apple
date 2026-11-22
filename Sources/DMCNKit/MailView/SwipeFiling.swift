import Foundation

// Filing: a right swipe on a row (or the folder button on an open message) picks a folder, and
// filing can become a rule that files a sender's future mail. This build's own feature, with no
// browser counterpart. It
// lives in one synced settings field, "swipeFiling", which the browser keeps as it is: its settings
// writes re-read the document and change only the fields they set (useSettings.ts).

/// A sender's standing rule: their new mail goes straight to a folder.
public struct FilingRule: JSONDocument {
    public var fields: [String: JSONValue]
    public init(fields: [String: JSONValue]) { self.fields = fields }

    public init(sender: String, folderID: String, since: Int64) {
        fields = [:]
        self.sender = sender
        self.folderID = folderID
        self.since = since
    }

    /// Normalized: trimmed and lowercased.
    public var sender: String {
        get { fields.string("sender") ?? "" }
        set { fields.set("sender", newValue) }
    }
    public var folderID: String {
        get { fields.string("folderId") ?? "" }
        set { fields.set("folderId", newValue) }
    }
    /// Unix seconds. Mail sent before the rule was made is moved when the rule is made, not by it.
    public var since: Int64 {
        get { fields.int("since") ?? 0 }
        set { fields.set("since", newValue) }
    }
}

/// Filing's settings: whether filing asks about the sender's other mail, what a full left swipe
/// does, and the rules.
public struct SwipeFiling: JSONDocument {
    public var fields: [String: JSONValue]
    public init(fields: [String: JSONValue]) { self.fields = fields }
    public init() { self.init(fields: [:]) }

    /// Whether filing a message asks if the sender's other mail, and their new mail, should follow.
    /// On unless the owner turned it off: off, filing moves that one message and makes no rule.
    public var asksAboutSender: Bool {
        get { fields.bool("asksAboutSender") ?? true }
        set { fields.set("asksAboutSender", newValue) }
    }

    /// Whether a full swipe to the left archives instead of deleting. Off unless the owner chose it.
    public var fullSwipeArchives: Bool {
        get { fields.bool("fullSwipeArchives") ?? false }
        set { fields.set("fullSwipeArchives", newValue) }
    }

    public var rules: [FilingRule] {
        get { fields.documents("rules") }
        set { fields.set("rules", newValue) }
    }

    /// The rules sorted under their folders, in the folder list's order, senders by address. Rules
    /// whose folder was deleted come last, under nil: they file nothing until removed.
    public func rulesByFolder(_ folders: [FolderDef]) -> [(folder: FolderDef?, rules: [FilingRule])] {
        let known = Set(folders.map(\.id))
        let sorted = rules.sorted { $0.sender < $1.sender }
        var groups: [(folder: FolderDef?, rules: [FilingRule])] = folders.compactMap { folder in
            let mine = sorted.filter { $0.folderID == folder.id }
            return mine.isEmpty ? nil : (folder, mine)
        }
        let orphans = sorted.filter { !known.contains($0.folderID) }
        if !orphans.isEmpty { groups.append((nil, orphans)) }
        return groups
    }

    public func rule(for sender: String) -> FilingRule? {
        let sender = JSText.normalizedAddress(sender)
        return rules.last { $0.sender == sender }
    }

    /// One rule per sender: a new choice replaces the old one.
    public mutating func setRule(sender: String, folderID: String, now: Date) {
        let sender = JSText.normalizedAddress(sender)
        var next = rules.filter { $0.sender != sender }
        next.append(FilingRule(sender: sender, folderID: folderID, since: Int64(now.timeIntervalSince1970)))
        rules = next
    }

    public mutating func removeRule(sender: String) {
        let sender = JSText.normalizedAddress(sender)
        rules = rules.filter { $0.sender != sender }
    }
}

extension AppSettings {
    public var swipeFiling: SwipeFiling {
        get {
            if case .object(let fields)? = self.fields["swipeFiling"] { return SwipeFiling(fields: fields) }
            return SwipeFiling()
        }
        set { fields["swipeFiling"] = .object(newValue.fields) }
    }
}

/// One message a rule files.
public struct AutoFiling: Equatable, Sendable {
    public let hash: String
    public let folderID: String
}

extension MailView {
    /// What filing writes: the folder, or none for the Inbox. Back to the Inbox also clears the
    /// archived mark, or a message that was filed and archived would land in Archive instead: a
    /// folder outranks Archive, so the mark was hidden until the folder went.
    public static func filingDelta(to folderID: String?) -> FlagDelta {
        guard let folderID else { return FlagDelta(archived: .clear, folderId: .clear) }
        return FlagDelta(folderId: .set(folderID))
    }

    /// The address filing may follow: a verified DMCN sender, or ordinary email whose address simply
    /// didn't resolve, filed by that address alone. Never a header the checks caught: one claiming
    /// an address whose published key is someone else's, or an address its domain disowned.
    ///
    /// DEV NOTE: filing ordinary email by address alone is the owner's choice for now (it's mostly
    /// newsletters and receipts). Whether such a message passed SPF/DKIM/DMARC is in the bridge's
    /// attestation, inside the encrypted body, so the list can't see it. A row filed this way gets a
    /// caution mark (`MailRowView`). The better fix: open new mail from rule senders in the
    /// background, read `BridgeAttestation`, and file only what passed. A directory outage also reads
    /// as unverified, so a forged copy of a DMCN sender could be filed during one: same fix covers it.
    public static func filingSender(_ m: MailPreview) -> String? {
        switch m.sender {
        case .verified(let address), .unverified(let address): JSText.normalizedAddress(address)
        case .mismatch, .disowned, .unreadable: nil
        }
    }

    /// The sender's other mail that filing `m` takes along, to a folder or back to the Inbox (nil):
    /// what sits where `m` was, plus the Inbox when `m` came from a folder, less wherever it's going.
    /// Never Archive, Deleted, Sent or another folder. Empty when the sender can't be filed by, or
    /// `m` isn't in the Inbox or a folder.
    public static func sameSenderMail(
        as m: MailPreview, into folderID: String?, among messages: [MailPreview], _ ctx: PlaceContext
    ) -> [String] {
        guard let sender = filingSender(m), let from = placeOf(m, ctx) else { return [] }
        var places: Set<MailPlace> = [.inbox]
        switch from {
        case .inbox: break
        case .folder(let id): places.insert(.folder(id))
        default: return []
        }
        places.remove(folderID.map(MailPlace.folder) ?? .inbox)
        return messages.filter { other in
            guard other.hash != m.hash, filingSender(other) == sender, let place = placeOf(other, ctx) else {
                return false
            }
            return places.contains(place)
        }.map(\.hash)
    }

    /// New mail the rules file. Only a message in the Inbox that nobody has touched yet (no flag
    /// record: not read, moved or brought back), sent once its sender's rule existed, from a sender
    /// filing may follow, to a folder that still exists. Filing writes a flag, so each message is
    /// filed once and a message the owner moves back stays where they put it.
    public static func autoFiling(_ messages: [MailPreview], rules: [FilingRule], _ ctx: PlaceContext)
        -> [AutoFiling]
    {
        let bySender = Dictionary(rules.map { ($0.sender, $0) }, uniquingKeysWith: { _, last in last })
        guard !bySender.isEmpty else { return [] }
        return messages.compactMap { m in
            guard ctx.flags[m.hash] == nil, let sender = filingSender(m), let rule = bySender[sender],
                ctx.knownFolderIDs.contains(rule.folderID), m.sentAt >= rule.since, placeOf(m, ctx) == .inbox
            else { return nil }
            return AutoFiling(hash: m.hash, folderID: rule.folderID)
        }
    }
}
