import Foundation

// The account's block/allow list: its shape, and what a client must be able to do with it. Parity
// with the browser's lib/api/filterList.ts, hooks/useMailFilter.ts and the reference build's
// app/lib/api/filterRest.ts.
//
// Where the list lives is a deployment decision. In this reference form it never leaves the device:
// not sealed, no relay op, nothing in personal storage. So it is advisory: blocked mail still
// arrives and just isn't shown, and a block made here doesn't reach the owner's other devices. A
// build whose relays enforce the list plugs in its own `MailFilter` from outside the kit.

/// The JSON of Go's mailfilter.List.
public struct FilterList: Codable, Sendable, Equatable {
    public enum Mode: String, Codable, Sendable {
        case deny, allow
    }

    public var mode: Mode
    public var domains: [String]
    public var senders: [String]
    public var allowVerified: Bool?
    /// Hex ed25519 keys of blocked identities. Unlike `senders` and `domains` a match here always
    /// applies, whatever the mode, so a blocked sender can't get round it by changing address.
    public var senderKeys: [String]?

    enum CodingKeys: String, CodingKey {
        case mode, domains, senders
        case allowVerified = "allow_verified"
        case senderKeys = "sender_keys"
    }

    public init(
        mode: Mode = .deny, domains: [String] = [], senders: [String] = [], allowVerified: Bool? = false,
        senderKeys: [String]? = []
    ) {
        self.mode = mode
        self.domains = domains
        self.senders = senders
        self.allowVerified = allowVerified
        self.senderKeys = senderKeys
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mode = try c.decodeIfPresent(Mode.self, forKey: .mode) ?? .deny
        domains = try c.decodeIfPresent([String].self, forKey: .domains) ?? []
        senders = try c.decodeIfPresent([String].self, forKey: .senders) ?? []
        allowVerified = try c.decodeIfPresent(Bool.self, forKey: .allowVerified)
        senderKeys = try c.decodeIfPresent([String].self, forKey: .senderKeys)
    }

    /// Whether this list blocks a sender. A key match always does; an address or domain match does
    /// only in deny mode, since an allow-mode list is an admission policy, not a per-sender block.
    public func blocks(senderAddress: String, senderKeyHex: String) -> Bool {
        let key = senderKeyHex.lowercased()
        if !key.isEmpty, (senderKeys ?? []).contains(where: { $0.lowercased() == key }) { return true }
        guard mode == .deny else { return false }
        let address = JSText.normalizedAddress(senderAddress)
        if senders.contains(where: { JSText.normalizedAddress($0) == address }) { return true }
        let domain = address.lastIndex(of: "@").map { String(address[address.index(after: $0)...]) } ?? address
        return domains.contains { JSText.normalizedAddress($0) == domain }
    }
}

/// Where a filter list lives. `get` returns nil when the account has none yet, which is not the
/// same as an empty one.
public protocol MailFilter: Sendable {
    func get() async throws -> FilterList?
    func save(_ list: FilterList) async throws
    func clear() async throws
}

/// The reference form: the list kept on this device, like the reference web build's.
public struct DeviceMailFilter: MailFilter {
    private static let key = "filter/list"
    private let storage: any DeviceStorage

    /// `storage` is this account's own: nothing here tells two accounts apart.
    public init(storage: any DeviceStorage) {
        self.storage = storage
    }

    public func get() async throws -> FilterList? {
        try await storage.get(Self.key, as: FilterList.self)?.value
    }

    public func save(_ list: FilterList) async throws {
        try await storage.put(Self.key, list)
    }

    public func clear() async throws {
        try await storage.delete(Self.key)
    }
}

/// The account's list and the block action, whichever `MailFilter` holds it.
public actor MailFilterStore {
    private let client: any MailFilter
    public private(set) var filter: FilterList?
    /// False until the first load settles, so a list not yet read isn't taken for no list.
    public private(set) var ready = false

    public init(client: any MailFilter) {
        self.client = client
    }

    /// Reads the list. A failure keeps the last good one and still counts as settled.
    public func refresh() async {
        defer { ready = true }
        do {
            filter = try await client.get()
        } catch {
            // Transient: keep the last good list.
        }
    }

    /// Blocks a sender. The key goes on the unconditional list, so the block survives an address
    /// change. In deny mode the address is listed too, as the readable entry; in allow mode it
    /// isn't, because adding to `senders` there would admit them. Starts from a fresh read so a
    /// stale copy can't undo an edit made elsewhere.
    public func blockSender(_ senderAddress: String, senderKeyHex: String? = nil) async throws {
        var next = try await client.get() ?? FilterList()
        var keys = next.senderKeys ?? []
        if let senderKeyHex, !senderKeyHex.isEmpty {
            let key = senderKeyHex.lowercased()
            if !keys.contains(where: { $0.lowercased() == key }) { keys.append(key) }
        }
        next.senderKeys = keys
        if next.mode == .deny {
            let address = JSText.normalizedAddress(senderAddress)
            if !next.senders.contains(where: { JSText.normalizedAddress($0) == address }) {
                next.senders.append(address)
            }
        }
        try await client.save(next)
        filter = next
    }

    /// Takes an address off the list, from a fresh read for the same reason. A key blocked with it
    /// stays on the key list, as on the web: nothing ties the two entries together.
    public func removeSender(_ sender: String) async throws {
        var next = try await client.get() ?? FilterList()
        next.senders.removeAll { $0 == sender }
        try await client.save(next)
        filter = next
    }
}
