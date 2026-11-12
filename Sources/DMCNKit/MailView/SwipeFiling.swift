import Foundation

// Swipe to file: a right swipe on a row offers folders to file it in, and filing can become a rule
// that files a sender's future mail. This build's own feature, with no browser counterpart. It
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

/// The swipe's settings: how many folder buttons, which folder each slot holds, and the rules.
public struct SwipeFiling: JSONDocument {
    /// What Settings offers. Zero turns the swipe off.
    public static let choices = [0, 2, 3, 4]
    public static let defaultCount = 4

    public var fields: [String: JSONValue]
    public init(fields: [String: JSONValue]) { self.fields = fields }
    public init() { self.init(fields: [:]) }

    /// How many folder buttons the swipe shows. Anything not on offer reads as the default.
    public var count: Int {
        get {
            let n = fields.int("count").map(Int.init) ?? Self.defaultCount
            return Self.choices.contains(n) ? n : Self.defaultCount
        }
        set { fields.set("count", Int64(newValue)) }
    }

    /// The folder the owner pinned to each slot, by position. An empty string is an automatic slot.
    public var pins: [String] {
        get {
            guard case .array(let items)? = fields["pins"] else { return [] }
            return items.map { if case .string(let id) = $0 { id } else { "" } }
        }
        set { fields["pins"] = .array(newValue.map(JSONValue.string)) }
    }

    public var rules: [FilingRule] {
        get { fields.documents("rules") }
        set { fields.set("rules", newValue) }
    }

    /// The folders the swipe offers, in slot order. A pinned slot keeps its folder while it exists.
    /// Every other slot takes the next folder in the list that isn't already offered, so a new
    /// folder fills an empty slot by itself, and deleting a pinned folder hands its slot back.
    public func slots(_ folders: [FolderDef]) -> [FolderDef] {
        assignments(folders).compactMap { $0 }
    }

    /// Each slot's folder, by position: nil where an automatic slot has no folder left to take.
    public func assignments(_ folders: [FolderDef]) -> [FolderDef?] {
        guard count > 0 else { return [] }
        let byID = Dictionary(folders.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var pinned: [FolderDef?] = []
        var taken = Set<String>()
        for i in 0..<count {
            let id = i < pins.count ? pins[i] : ""
            if !id.isEmpty, let folder = byID[id], !taken.contains(id) {
                pinned.append(folder)
                taken.insert(id)
            } else {
                pinned.append(nil)
            }
        }
        var unpinned = folders.filter { !taken.contains($0.id) }.makeIterator()
        return pinned.map { $0 ?? unpinned.next() }
    }

    /// Whether the owner pinned a folder that still exists to this slot.
    public func isPinned(_ slot: Int, among folders: [FolderDef]) -> Bool {
        slot < pins.count && !pins[slot].isEmpty && folders.contains { $0.id == pins[slot] }
    }

    /// Pins `folderID` to `slot`, or makes the slot automatic again with nil.
    public mutating func pin(_ folderID: String?, at slot: Int) {
        guard slot >= 0, slot < Self.choices.max()! else { return }
        var next = pins
        while next.count <= slot { next.append("") }
        next[slot] = folderID ?? ""
        pins = next
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
