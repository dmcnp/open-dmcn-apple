import DMCNKit
import Foundation

/// A mailbox that lives in memory, for previews, debug builds and tests. For a whole account around
/// it, with folders, contacts and Sent mail, see `SampleAccount`.
///
/// It has no shortcuts: every message is really sealed, and the app opens and checks it with the
/// same code it uses for real mail. There is one message for each way a sender can turn out, so
/// you can see every state of the inbox without an account or a server.
public actor SampleMailbox: MailboxService {
    /// The account reading this mailbox.
    public nonisolated let keys: SoftwareAccountKeys

    private var messages: [(hash: String, entry: Dmcn_Relay_MailboxEntry, body: Dmcn_Relay_MailboxBody)] = []
    private var directory: [String: IdentityLookup] = [:]

    /// One message for each way a sender can turn out.
    public init() throws {
        try self.init(cast: SampleCast(), moreMail: false)
    }

    /// `moreMail` adds a message for each state a list can show. `SampleAccount` is what files them.
    init(cast: SampleCast, moreMail: Bool) throws {
        let reader = cast.reader
        let ada = cast.ada
        let former = cast.former
        let elsewhere = cast.elsewhere
        let otherReader = cast.otherReader
        // Claims Ada's address but holds a key of its own.
        let forger = SoftwareAccountKeys(address: ada.address)

        keys = reader
        for listed in [reader, ada, otherReader, cast.newcomer, cast.grace] {
            directory[listed.address] = IdentityLookup(
                address: listed.address, ed25519Public: listed.ed25519Public, x25519Public: listed.x25519Public)
        }
        directory[former.address] = IdentityLookup(
            address: former.address, ed25519Public: former.ed25519Public, x25519Public: former.x25519Public,
            identityUnverifiable: true)

        func letter(
            from sender: SoftwareAccountKeys, to recipient: String? = nil, subject: String, body: String,
            html: String? = nil, attachments: [DraftAttachment] = [], minutesAgo: Int64
        ) throws -> Dmcn_Message_EncryptedEnvelope {
            let addressee = recipient ?? reader.address
            let draft = SplitMessage.Draft(
                messageID: Self.randomID(), threadID: Self.randomID(), recipientAddress: addressee, to: [addressee],
                subject: subject, bodyText: body, bodyHTML: html, attachments: attachments,
                sentAt: sampleEpoch - minutesAgo * 60)
            return try SplitMessage.seal(draft, from: sender, to: [.init(x25519Public: reader.x25519Public)])
        }

        var unreadable = try letter(from: ada, subject: "Unreadable", body: "Never seen.", minutesAgo: 50)
        unreadable.encryptedHeader[unreadable.encryptedHeader.startIndex] ^= 0xff

        var envelopes = [
            try letter(
                from: ada, subject: "A verified sender",
                body:
                    "The directory lists the key that signed this message for ada@sample.example, so the app shows that address with a check mark.",
                minutesAgo: 10),
            try letter(
                from: elsewhere, subject: "An unverified sender",
                body:
                    "This address isn't in the directory, as with an outage or ordinary email. The message still opens, but the address isn't confirmed.",
                minutesAgo: 20),
            try letter(
                from: forger, subject: "A forged sender",
                body:
                    "You should never see this text: the key that signed it isn't the one listed for the address it names.",
                minutesAgo: 30),
            try letter(
                from: former, subject: "A sender the domain no longer vouches for",
                body:
                    "The key matches, but the domain no longer vouches for this address, so this waits behind a warning and the address isn't shown as who it's from.",
                minutesAgo: 40),
            unreadable,
            try letter(
                from: ada, to: otherReader.address, subject: "A message written to someone else",
                body:
                    "Ada wrote this to another reader, and someone sealed the same message again for you. It opens, with a warning.",
                minutesAgo: 60),
        ]
        if moreMail {
            let plan = ComposeAttachments.File(
                name: "garden-plan.pdf", contentType: "application/pdf", content: Data("A plan, in spirit.".utf8))
            envelopes += [
                try letter(
                    from: ada, subject: SampleAccount.Subject.read, body: "Already opened, so the row isn't bold.",
                    minutesAgo: 70),
                try letter(
                    from: ada, subject: SampleAccount.Subject.starred, body: "It shows in Starred as well as here.",
                    minutesAgo: 80),
                try letter(
                    from: ada, subject: SampleAccount.Subject.archived, body: "Out of the Inbox, and still searchable.",
                    minutesAgo: 90),
                try letter(
                    from: ada, subject: SampleAccount.Subject.filed, body: "This one lives in the Projects folder.",
                    minutesAgo: 100),
                try letter(
                    from: ada, subject: SampleAccount.Subject.labelled, body: "Labels sit on top of where mail lives.",
                    minutesAgo: 110),
                try letter(
                    from: ada, subject: SampleAccount.Subject.deleted,
                    body: "Restore this and it goes back to the Inbox.",
                    minutesAgo: 120),
                try letter(
                    from: cast.newcomer, subject: SampleAccount.Subject.newSender,
                    body: "A real identity, just not one of your contacts, so this line waits until you've looked.",
                    minutesAgo: 130),
                try letter(
                    from: cast.grace, subject: SampleAccount.Subject.changedKey,
                    body: "Grace's key isn't the one you pinned, so she reads as new until you check with her.",
                    minutesAgo: 140),
                try letter(
                    from: cast.penFriend, subject: SampleAccount.Subject.legacyContact,
                    body: "A contact on ordinary email: trusted by you, with no key to check.", minutesAgo: 150),
                try letter(
                    from: cast.blocked, subject: SampleAccount.Subject.blocked,
                    body: "Hidden from every list: its domain is on your block list.", minutesAgo: 160),
                try letter(
                    from: reader, subject: SampleAccount.Subject.toYourself, body: "Mail to yourself is received mail.",
                    minutesAgo: 170),
                try letter(
                    from: reader, to: cast.oldFriend.address, subject: SampleAccount.Subject.olderSent,
                    body: "A copy of something you sent, from before Sent had a store of its own.", minutesAgo: 180),
                try letter(from: ada, subject: "", body: "Nobody wrote a subject for this one.", minutesAgo: 190),
                try letter(
                    from: ada, subject: SampleAccount.Subject.newsletter,
                    body: "[image: Logo][1] [This week][2] What's new in the garden, with links tidied away.",
                    html: SampleAccount.newsletterHTML, minutesAgo: 200),
                try letter(
                    from: ada, subject: SampleAccount.Subject.attachment,
                    body: String(repeating: "Search needs the index to find what's said further down. ", count: 4)
                        + SampleAccount.bodyOnlyWord,
                    attachments: try ComposeAttachments.adding([plan], to: []), minutesAgo: 210),
            ]
        }
        messages = envelopes.enumerated().map { index, envelope in
            ("sample-\(index)", Dmcn_Relay_MailboxEntry(filing: envelope), Dmcn_Relay_MailboxBody(filing: envelope))
        }
    }

    public func list(_ keys: some AccountKeys, limit: Int, cursor: String?) async throws -> MailboxPage {
        MailboxPage(items: messages.map { .init(hash: $0.hash, entry: $0.entry) }, nextCursor: nil)
    }

    public func body(hash: String, keys: some AccountKeys) async throws -> Dmcn_Relay_MailboxBody {
        guard let message = messages.first(where: { $0.hash == hash }) else {
            throw APIError(status: 404, message: "not found")
        }
        return message.body
    }

    public func lookup(_ address: String) async throws -> IdentityLookup {
        guard let answer = directory[address.lowercased()] else {
            throw APIError(status: 404, message: "not found")
        }
        return answer
    }

    public func signOut() async {}

    fileprivate static func randomID() -> Data {
        Data((0..<16).map { _ in UInt8.random(in: .min ... .max) })
    }
}

/// When the sample mail was sent, unix seconds. Fixed, so a screenshot doesn't drift.
private let sampleEpoch: Int64 = 1_780_000_000

/// Everyone in the samples.
struct SampleCast: Sendable {
    let reader = SoftwareAccountKeys(address: "you@sample.example")
    let ada = SoftwareAccountKeys(address: "ada@sample.example")
    let former = SoftwareAccountKeys(address: "former@sample.example")
    let elsewhere = SoftwareAccountKeys(address: "someone@elsewhere.example")
    let otherReader = SoftwareAccountKeys(address: "other.reader@sample.example")
    let newcomer = SoftwareAccountKeys(address: "newcomer@sample.example")
    let grace = SoftwareAccountKeys(address: "grace@sample.example")
    let penFriend = SoftwareAccountKeys(address: "pen.friend@mail.example")
    let blocked = SoftwareAccountKeys(address: "offers@blocked.example")
    let oldFriend = SoftwareAccountKeys(address: "old.friend@mail.example")
}

/// A complete account with no server: the sample mailbox, and everything a real account keeps in
/// personal storage, written through the real stores. Mail is sealed for real, so the app opens and
/// checks it with the code it uses for real mail. There's one of each state a screen can show, which
/// is how to see every screen, and how a test reaches it.
public struct SampleAccount: Sendable {
    /// The subjects to find each state by.
    public enum Subject {
        public static let read = "A message you've read"
        public static let starred = "A starred message"
        public static let archived = "An archived message"
        public static let filed = "A message filed in a folder"
        public static let labelled = "A message with labels"
        public static let deleted = "A message you deleted"
        public static let newSender = "A sender who isn't a contact yet"
        public static let changedKey = "A contact whose key changed"
        public static let legacyContact = "A contact on ordinary email"
        public static let blocked = "A blocked sender"
        public static let toYourself = "A note to yourself"
        public static let olderSent = "An older copy of something you sent"
        public static let newsletter = "A newsletter"
        public static let attachment = "A message with an attachment"
        public static let sentToContact = "Sent to a contact"
        public static let sentToSeveral = "Sent to several people"
        public static let draft = "A draft you haven't sent"
    }

    /// HTML with something for each layer of the reader to stop: the remote image must stay blocked,
    /// and the script must never run, so "Scripts are off." on screen is the sandbox holding. The
    /// table is as wide as a desktop newsletter, so seeing its right edge is the view fitting it.
    public static let newsletterHTML = """
        <h2 style="color:#0b7a6b;margin-top:0">This week in the garden</h2>
        <p>What's new in the garden, with links tidied away.</p>
        <p><img src="https://images.sample.example/logo.png" alt="Logo" width="120" height="40"></p>
        <p><a href="https://sample.example/garden">Read the full story</a></p>
        <table width="640" style="width:640px;background:#eef6f3"><tr>
        <td width="320" style="padding:12px">The left edge of a wide table</td>
        <td width="320" align="right" style="padding:12px">The right edge of it</td>
        </tr></table>
        <p id="proof">Scripts are off.</p>
        <script>document.getElementById("proof").textContent = "A script ran.";</script>
        """

    /// A word only the body of `Subject.attachment` holds, so finding it proves the index answered.
    public static let bodyOnlyWord = "periwinkle"
    public static let folderName = "Projects"
    public static let emptyFolderName = "Receipts 2026"
    public static let labelName = "Work"
    public static let otherLabelName = "Receipts"

    public let keys: SoftwareAccountKeys
    public let mailbox: SampleMailbox
    public let inbox: Inbox
    /// What follows the account between devices.
    public let storage: InMemoryPersonalStorage
    /// What stays on this device: key pins and the block list.
    public let deviceStorage: InMemoryPersonalStorage
    public let deviceID: Data
    public let flags: FlagStore
    public let labels: LabelStore
    public let contacts: ContactStore
    public let filter: MailFilterStore
    public let sent: SentStore
    public let drafts: DraftStore
    public let settings: SettingsStore

    /// `now` is when the deleted mail was deleted from: a day before it, so it isn't due for removal.
    public init(now: Date = Date()) async throws {
        let cast = SampleCast()
        let reader = cast.reader
        keys = reader
        mailbox = try SampleMailbox(cast: cast, moreMail: true)
        inbox = Inbox(service: mailbox, keys: reader)
        storage = InMemoryPersonalStorage()
        deviceStorage = InMemoryPersonalStorage()
        deviceID = Data(repeating: 0x5A, count: 16)
        flags = FlagStore(storage: storage, deviceID: deviceID)
        labels = LabelStore(storage: storage)
        contacts = ContactStore(storage: storage, pins: deviceStorage, owner: reader.address, deviceID: deviceID)
        filter = MailFilterStore(client: DeviceMailFilter(storage: deviceStorage))
        sent = SentStore(storage: storage, keys: reader)
        drafts = DraftStore(storage: storage, address: reader.address)
        settings = SettingsStore(storage: storage)

        let work = try await labels.createLabel(name: Self.labelName, color: LabelStore.colors[3])
        let receipts = try await labels.createLabel(name: Self.otherLabelName, color: LabelStore.colors[2])
        let projects = try await labels.createFolder(name: Self.folderName)
        _ = try await labels.createFolder(name: Self.emptyFolderName)

        try await contacts.allowlist(Self.contact(cast.ada, name: "Ada Lovelace"))
        // Pinned to a key Grace no longer signs with.
        try await contacts.allowlist(
            Self.contact(SoftwareAccountKeys(address: cast.grace.address), name: "Grace Hopper"))
        try await contacts.put(ContactRecord(address: cast.penFriend.address, name: "Pen Friend", fingerprint: ""))

        try await filter.blockSender(cast.blocked.address)
        var list = await filter.filter ?? FilterList()
        list.domains = ["blocked.example"]
        try await DeviceMailFilter(storage: deviceStorage).save(list)

        try await settings.update { $0.signature = "Sent from the sample account" }

        var bySubject: [String: String] = [:]
        for message in try await inbox.previews(limit: .max).previews { bySubject[message.subject] = message.hash }
        func hash(_ subject: String) -> String { bySubject[subject] ?? subject }

        try await flags.markRead(hash(Subject.read))
        try await flags.set(hash(Subject.starred), FlagDelta(starred: .set(true)))
        try await flags.set(hash(Subject.archived), FlagDelta(read: .set(true), archived: .set(true)))
        try await flags.setFolder(hash(Subject.filed), projects)
        try await flags.set(hash(Subject.labelled), FlagDelta(labelIds: .set([work, receipts])))
        let yesterday = Int64(now.timeIntervalSince1970 * 1000) - 86_400_000
        try await flags.set(hash(Subject.deleted), FlagDelta(trashedAt: .set(yesterday)))

        func keep(_ subject: String, to: [String], cc: [String] = [], bcc: [String] = [], minutesAgo: Int64)
            async throws
        {
            let draft = SplitMessage.Draft(
                messageID: SampleMailbox.randomID(), threadID: SampleMailbox.randomID(),
                recipientAddress: reader.address, to: to, cc: cc, bcc: bcc, subject: subject,
                bodyText: "What you wrote for \"\(subject)\".", sentAt: sampleEpoch - minutesAgo * 60)
            try await sent.keepCopy(of: draft, from: reader, deviceID: deviceID)
        }
        try await keep(Subject.sentToContact, to: [cast.ada.address], minutesAgo: 15)
        try await keep(
            Subject.sentToSeveral, to: [cast.ada.address, cast.elsewhere.address], cc: [cast.grace.address],
            bcc: [cast.newcomer.address], minutesAgo: 25)

        let draftText = "Half a thought, saved so closing the composer doesn't lose it."
        try await drafts.save(
            DraftStore.newID(),
            content: DraftContent(
                from: reader.address, to: [cast.ada.address], subject: Subject.draft, text: draftText),
            base: .new, updatedAt: sampleEpoch * 1000)
    }

    private static func contact(_ person: SoftwareAccountKeys, name: String) -> ContactRecord {
        ContactRecord(
            address: person.address, name: name, fingerprint: person.ed25519Public.base64EncodedString(),
            provenance: .userApproved, ed25519Pub: person.ed25519Public.base64EncodedString(),
            x25519Pub: person.x25519Public.base64EncodedString())
    }
}
