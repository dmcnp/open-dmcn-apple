import Foundation

// The address book: one sealed record per contact at "contacts/<id>", last write wins per record.
// Parity with the browser's lib/api/contactStore.ts, the non-UI half of hooks/useContacts.ts, and
// lib/trust/pinStore.ts.
//
// The pinned facts on a record are the sync copy only. A relay can't read or forge a sealed record,
// but it serves them, so it can withhold one or hand back an older one the owner really wrote, and
// either makes a pinned contact look unpinned. An unpinned contact is pinned afresh on next sight,
// to whatever key the directory serves that day. So the pin that decides lives on this device, and
// `refresh` reconciles the two before anything reads a pin off a record.

/// How the owner confirmed a contact's identity, strongest first. A record with one is an
/// allowlist entry; one without is a plain address-book row.
public enum TrustProvenance: String, Codable, Sendable {
    case inPerson = "in_person"
    case fingerprint
    case networkVouched = "network_vouched"
    case orgVerified = "org_verified"
    case userApproved = "user_approved"
}

public struct ContactRecord: JSONDocument {
    public var fields: [String: JSONValue]
    public init(fields: [String: JSONValue]) { self.fields = fields }

    /// The fields a caller supplies; `v`, `updatedAt` and `deviceId` are the store's to write.
    public init(
        address: String, name: String, fingerprint: String, notes: String? = nil, provenance: TrustProvenance? = nil,
        ed25519Pub: String? = nil, x25519Pub: String? = nil, pinnedAt: Int64? = nil, adminKeyCustody: Bool? = nil,
        noIdentity: Bool? = nil, pinSeq: Int64? = nil
    ) {
        fields = [:]
        self.address = address
        self.name = name
        self.fingerprint = fingerprint
        self.notes = notes
        self.provenance = provenance
        self.ed25519Pub = ed25519Pub
        self.x25519Pub = x25519Pub
        self.pinnedAt = pinnedAt
        self.adminKeyCustody = adminKeyCustody
        self.noIdentity = noIdentity
        self.pinSeq = pinSeq
    }

    public var v: Int64 {
        get { fields.int("v") ?? 1 }
        set { fields.set("v", newValue) }
    }
    public var address: String {
        get { fields.string("address") ?? "" }
        set { fields.set("address", newValue) }
    }
    public var name: String {
        get { fields.string("name") ?? "" }
        set { fields.set("name", newValue) }
    }
    public var fingerprint: String {
        get { fields.string("fingerprint") ?? "" }
        set { fields.set("fingerprint", newValue) }
    }
    public var notes: String? {
        get { fields.string("notes") }
        set { fields.set("notes", newValue) }
    }
    public var updatedAt: Int64 {
        get { fields.int("updatedAt") ?? 0 }
        set { fields.set("updatedAt", newValue) }
    }
    /// Hex.
    public var deviceId: String {
        get { fields.string("deviceId") ?? "" }
        set { fields.set("deviceId", newValue) }
    }
    /// Present means this contact is allowlisted.
    public var provenance: TrustProvenance? {
        get { fields.string("provenance").flatMap(TrustProvenance.init(rawValue:)) }
        set { fields.set("provenance", newValue?.rawValue) }
    }
    /// Standard base64, as the directory serves it. Absent on old records until lazily pinned.
    public var ed25519Pub: String? {
        get { fields.string("ed25519Pub") }
        set { fields.set("ed25519Pub", newValue) }
    }
    /// Standard base64.
    public var x25519Pub: String? {
        get { fields.string("x25519Pub") }
        set { fields.set("x25519Pub", newValue) }
    }
    /// Unix ms, when the keys were pinned.
    public var pinnedAt: Int64? {
        get { fields.int("pinnedAt") }
        set { fields.set("pinnedAt", newValue) }
    }
    /// Domain policy an operator controls alone, so a silent flip is what a key comparison can't see.
    public var adminKeyCustody: Bool? {
        get { fields.bool("adminKeyCustody") }
        set { fields.set("adminKeyCustody", newValue) }
    }
    /// The owner confirmed this contact has no identity after once verifying one. Recorded rather
    /// than clearing the pin, so a key that appears afterwards reads as a change.
    public var noIdentity: Bool? {
        get { fields.bool("noIdentity") }
        set { fields.set("noIdentity", newValue) }
    }
    /// Counts deliberate re-pins. The only thing that lets a synced pin replace one a device holds,
    /// so it must only ever rise. Absent on old records, treated as 1.
    public var pinSeq: Int64? {
        get { fields.int("pinSeq") }
        set { fields.set("pinSeq", newValue) }
    }

    /// The facts pinned on this record, or nil when it carries no pin.
    public var pinnedFacts: PinnedFacts? {
        if noIdentity == true { return .absentIdentity }
        guard let ed25519Pub, !ed25519Pub.isEmpty else { return nil }
        return PinnedFacts(
            ed25519Pub: ed25519Pub, x25519Pub: x25519Pub ?? "", adminKeyCustody: adminKeyCustody == true)
    }

    fileprivate mutating func apply(_ facts: PinnedFacts) {
        ed25519Pub = facts.ed25519Pub
        x25519Pub = facts.x25519Pub
        adminKeyCustody = facts.adminKeyCustody
        if let noIdentity = facts.noIdentity { self.noIdentity = noIdentity }
    }
}

/// What a pin covers: each field is here because a silent change to it is something the others
/// wouldn't catch.
public struct PinnedFacts: Codable, Sendable, Equatable {
    public var ed25519Pub: String
    public var x25519Pub: String
    public var adminKeyCustody: Bool
    /// The confirmed absence of an identity, a pinned state in its own right.
    public var noIdentity: Bool?

    public init(ed25519Pub: String, x25519Pub: String, adminKeyCustody: Bool, noIdentity: Bool? = nil) {
        self.ed25519Pub = ed25519Pub
        self.x25519Pub = x25519Pub
        self.adminKeyCustody = adminKeyCustody
        self.noIdentity = noIdentity
    }

    /// What the directory offering no identity for an address looks like as facts.
    public static let absentIdentity = PinnedFacts(
        ed25519Pub: "", x25519Pub: "", adminKeyCustody: false, noIdentity: true)

    func samePin(as other: PinnedFacts) -> Bool {
        ed25519Pub == other.ed25519Pub && x25519Pub == other.x25519Pub && adminKeyCustody == other.adminKeyCustody
    }
}

/// This device's pin on a counterparty: the copy that decides.
public struct LocalPin: Codable, Sendable, Equatable {
    public var v = 1
    /// The owning account, normalised.
    public var owner: String
    /// The counterparty, normalised.
    public var address: String
    public var ed25519Pub: String
    public var x25519Pub: String
    public var adminKeyCustody: Bool
    public var noIdentity: Bool?
    /// Counts deliberate pins, and is the rollback floor: a synced pin replaces this one only with
    /// a strictly higher value. A first pin is 1.
    public var seq: Int64
    /// Unix ms, when this device recorded it.
    public var pinnedAt: Int64

    init(owner: String, address: String, facts: PinnedFacts, seq: Int64, pinnedAt: Int64) {
        self.owner = JSText.normalizedAddress(owner)
        self.address = JSText.normalizedAddress(address)
        ed25519Pub = facts.ed25519Pub
        x25519Pub = facts.x25519Pub
        adminKeyCustody = facts.adminKeyCustody
        noIdentity = facts.noIdentity
        self.seq = max(1, seq)
        self.pinnedAt = pinnedAt
    }

    var facts: PinnedFacts {
        PinnedFacts(ed25519Pub: ed25519Pub, x25519Pub: x25519Pub, adminKeyCustody: adminKeyCustody)
    }
}

/// A disagreement between this device's pin and the synced copy. Neither proves an attack, a device
/// that pinned while offline produces `syncedCopyMissing` too, but both are what a rollback looks
/// like, and nobody sees them unless something says so.
public enum PinAnomaly: String, Sendable {
    /// This device holds a pin the synced copy no longer carries.
    case syncedCopyMissing = "kv_missing"
    /// The synced copy carries a different pin without a higher sequence.
    case syncedCopyConflict = "kv_conflict"
}

public struct PinAlert: Sendable, Equatable {
    public let address: String
    public let anomaly: PinAnomaly
}

/// What to make of one contact's two pins.
struct PinDecision: Equatable {
    var facts: PinnedFacts?
    var seq: Int64
    var anomaly: PinAnomaly?
    /// A pin to record here: the synced copy taught this device something.
    var adopt: LocalPin?
    /// Push the local pin back into the synced copy. Never set for a conflict: see below.
    var heal = false
}

enum PinReconciler {
    /// Merges this device's pin with the synced copy. The synced copy may add a pin this device has
    /// never held, and may replace one only with a higher sequence. It can never clear or downgrade
    /// one this device holds.
    static func reconcile(
        owner: String, address: String, local: LocalPin?, synced: PinnedFacts?, syncedSeq: Int64, now: Int64
    ) -> PinDecision {
        let seq = max(0, syncedSeq) != 0 ? max(0, syncedSeq) : (synced != nil ? 1 : 0)
        let syncedHasKey = !(synced?.ed25519Pub ?? "").isEmpty

        guard let local else {
            // A device that has never seen this counterparty has no basis but the synced copy. This
            // is the one moment it extends trust to a value a relay served, so it's kept at once.
            guard syncedHasKey, let synced else { return PinDecision(seq: 0) }
            let adopt = LocalPin(owner: owner, address: address, facts: synced, seq: seq, pinnedAt: now)
            return PinDecision(facts: synced, seq: seq, adopt: adopt)
        }
        guard syncedHasKey, let synced else {
            return PinDecision(facts: local.facts, seq: local.seq, anomaly: .syncedCopyMissing, heal: true)
        }
        if local.facts.samePin(as: synced) {
            return PinDecision(facts: local.facts, seq: max(local.seq, seq))
        }
        if seq > local.seq {
            // Another of the owner's devices deliberately re-pinned.
            let adopt = LocalPin(owner: owner, address: address, facts: synced, seq: seq, pinnedAt: now)
            return PinDecision(facts: synced, seq: seq, adopt: adopt)
        }
        // A different pin with no higher sequence: a rollback, a substituted record, or two devices
        // that first saw either side of a real rotation. Local wins and the disagreement is
        // reported, but it isn't healed: if the other side is another of the owner's devices, both
        // would overwrite each other on every refresh. Allowlisting again settles it.
        return PinDecision(facts: local.facts, seq: local.seq, anomaly: .syncedCopyConflict)
    }
}

public struct ContactNotFoundError: Error, Equatable, Sendable {
    public init() {}
}

extension ContactNotFoundError: LocalizedError {
    public var errorDescription: String? { "This contact no longer exists." }
}

/// The account's address book, with pins reconciled against this device's.
public actor ContactStore {
    private let storage: any PersonalStorage
    private let pins: any DeviceStorage
    private let owner: String
    private let deviceHex: String
    private let now: StoreClock

    /// Every contact as of the last `refresh`, pins already reconciled.
    public private(set) var records: [ContactRecord] = []
    /// Contacts whose local pin disagrees with the synced copy. Empty in normal operation.
    public private(set) var pinAlerts: [PinAlert] = []
    /// False until the first load settles, so nothing acts on an empty list before contacts are
    /// known.
    public private(set) var ready = false

    /// `pins` must stay on this device: a pin a relay can roll back protects nothing. `deviceID`
    /// names this install in the records it writes.
    public init(
        storage: any PersonalStorage, pins: any DeviceStorage, owner: String, deviceID: Data,
        now: @escaping StoreClock = systemClock
    ) {
        self.storage = storage
        self.pins = pins
        self.owner = owner
        deviceHex = deviceID.hex
        self.now = now
    }

    /// A stable id from the normalised address, so adding one address twice updates one record.
    /// Base64url, because the relay refuses the `@` a raw address would put in a key.
    public static func id(for address: String) -> String {
        Data(JSText.normalizedAddress(address).utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public static func key(for address: String) -> String { "contacts/" + id(for: address) }

    /// Reads the address book and reconciles every record against this device's pins, on each
    /// refresh, so a synced copy that loses or changes a pin is caught then. A failure keeps the
    /// last good list and still counts as settled.
    @discardableResult
    public func refresh() async -> [ContactRecord] {
        defer { ready = true }
        guard let entries = try? await storage.list(prefix: "contacts/", as: ContactRecord.self) else {
            return records
        }
        let localPins = await loadPins()
        var merged: [ContactRecord] = []
        var alerts: [PinAlert] = []
        for entry in entries {
            var record = entry.value
            let decision = PinReconciler.reconcile(
                owner: owner, address: record.address, local: localPins[JSText.normalizedAddress(record.address)],
                synced: record.pinnedFacts, syncedSeq: record.pinSeq ?? 0, now: now())
            if let adopt = decision.adopt { await save(adopt) }
            if let anomaly = decision.anomaly { alerts.append(PinAlert(address: record.address, anomaly: anomaly)) }
            if decision.heal, let facts = decision.facts {
                // Repairs the synced copy from ours. Never the reverse, and never a new decision.
                try? await writePin(record.address, facts: facts, seq: decision.seq, force: true)
            }
            if let facts = decision.facts {
                record.apply(facts)
                record.pinSeq = decision.seq
            }
            merged.append(record)
        }
        records = merged
        pinAlerts = alerts
        return merged
    }

    public func contact(for address: String) -> ContactRecord? {
        let wanted = JSText.normalizedAddress(address)
        return records.first { JSText.normalizedAddress($0.address) == wanted }
    }

    /// The name to show: the one the owner chose, else the address. A name that is just the address
    /// again says nothing, so it counts as none.
    public func name(for address: String) -> String {
        let name = contact(for: address).map { JSText.trim($0.name) } ?? ""
        if name.isEmpty || JSText.normalizedAddress(name) == JSText.normalizedAddress(address) { return address }
        return name
    }

    /// Creates or replaces a contact, keyed by address. This replaces the whole record: to edit one
    /// use `update`, which keeps its trust fields.
    @discardableResult
    public func put(_ contact: ContactRecord) async throws -> Int {
        var record = contact
        record.v = 3
        record.updatedAt = now()
        record.deviceId = deviceHex
        let version = try await storage.put(Self.key(for: record.address), record)
        replaceInMemory(record)
        return version
    }

    /// Edits the owner's chosen name or notes on an existing contact, leaving everything else
    /// alone. Compare-and-swap, with one retry if another device wrote in between.
    @discardableResult
    public func update(_ address: String, name: String? = nil, notes: String? = nil) async throws -> ContactRecord {
        for attempt in 0..<2 {
            guard let entry = try await storage.get(Self.key(for: address), as: ContactRecord.self) else {
                throw ContactNotFoundError()
            }
            var record = entry.value
            if let name { record.name = name }
            if let notes { record.notes = notes }
            record.v = 3
            record.updatedAt = now()
            record.deviceId = deviceHex
            do {
                try await storage.put(Self.key(for: address), record, expectedVersion: entry.version)
                replaceInMemory(record)
                return record
            } catch is StorageConflictError where attempt == 0 {
                continue
            }
        }
        throw StorageConflictError()
    }

    /// Adds or updates a contact with a trust decision and the keys it was made about. This is the
    /// only action allowed to replace a pin this device holds, the owner deliberately deciding to
    /// trust these keys. Advancing the sequence is what carries that to their other devices.
    public func allowlist(_ contact: ContactRecord) async throws {
        var record = contact
        if !(contact.ed25519Pub ?? "").isEmpty || contact.noIdentity == true {
            let facts =
                contact.noIdentity == true
                ? PinnedFacts.absentIdentity
                : PinnedFacts(
                    ed25519Pub: contact.ed25519Pub ?? "", x25519Pub: contact.x25519Pub ?? "",
                    adminKeyCustody: contact.adminKeyCustody == true)
            let seq = (await loadPin(contact.address)?.seq ?? 0) + 1
            await save(LocalPin(owner: owner, address: contact.address, facts: facts, seq: seq, pinnedAt: now()))
            record.pinSeq = seq
        }
        try await put(record)
        let wanted = JSText.normalizedAddress(contact.address)
        pinAlerts.removeAll { JSText.normalizedAddress($0.address) == wanted }
    }

    /// Records a contact's keys the first time they can be confirmed, so a later change is
    /// detectable. Does nothing if this device already holds a pin: that is what makes it a pin, and
    /// checking the local copy rather than the record is the point, since a synced copy stripped of
    /// its pin would otherwise make this contact look pinnable again.
    public func pinKey(_ address: String, facts: PinnedFacts) async {
        guard !facts.ed25519Pub.isEmpty, await loadPin(address) == nil else { return }
        await save(LocalPin(owner: owner, address: address, facts: facts, seq: 1, pinnedAt: now()))
        // The synced copy is sync only: a failure here costs other devices the pin, not this one.
        try? await writePin(address, facts: facts, seq: 1, force: false)
        guard let index = index(of: address), (records[index].ed25519Pub ?? "").isEmpty else { return }
        records[index].apply(facts)
        records[index].pinSeq = 1
        records[index].pinnedAt = now()
    }

    /// The deliberate re-pin: the owner re-verified a counterparty after a rotation. The higher
    /// sequence is what lets the new pin travel to their other devices at all.
    public func repinKey(_ address: String, facts: PinnedFacts, seq: Int64) async throws {
        await save(LocalPin(owner: owner, address: address, facts: facts, seq: seq, pinnedAt: now()))
        try await writePin(address, facts: facts, seq: seq, force: true)
    }

    /// Removes a contact and this device's pin with it: removing and re-adding is the documented way
    /// to accept a real rotation, and a pin left behind would keep rejecting the new key.
    public func remove(_ address: String) async throws {
        try await storage.delete(Self.key(for: address))
        try? await pins.delete(pinKey(for: address))
        let wanted = JSText.normalizedAddress(address)
        records.removeAll { JSText.normalizedAddress($0.address) == wanted }
        pinAlerts.removeAll { JSText.normalizedAddress($0.address) == wanted }
    }

    /// Writes a pin onto the synced record. A contact that doesn't exist is left alone, and a
    /// concurrent write that wins is left to win: the next sighting pins again if it needs to.
    private func writePin(_ address: String, facts: PinnedFacts, seq: Int64, force: Bool) async throws {
        guard let entry = try await storage.get(Self.key(for: address), as: ContactRecord.self) else { return }
        if !force, !(entry.value.ed25519Pub ?? "").isEmpty { return }
        var record = entry.value
        record.v = 3
        record.ed25519Pub = facts.ed25519Pub
        record.x25519Pub = facts.x25519Pub
        record.adminKeyCustody = facts.adminKeyCustody
        record.pinSeq = max(1, seq)
        record.pinnedAt = now()
        record.updatedAt = now()
        record.deviceId = deviceHex
        _ = try? await storage.put(Self.key(for: address), record, expectedVersion: entry.version)
    }

    private func index(of address: String) -> Int? {
        let wanted = JSText.normalizedAddress(address)
        return records.firstIndex { JSText.normalizedAddress($0.address) == wanted }
    }

    private func replaceInMemory(_ record: ContactRecord) {
        if let index = index(of: record.address) {
            records[index] = record
        } else {
            records.append(record)
        }
    }

    // MARK: This device's pins

    // Failures degrade to "no local pin", which is how the synced copy was used before the local
    // one existed: worse, never worse than that, and never open in the other direction.

    private var pinPrefix: String { "pins/" + Self.id(for: owner) + "/" }
    private func pinKey(for address: String) -> String { pinPrefix + Self.id(for: address) }

    private func loadPin(_ address: String) async -> LocalPin? {
        (try? await pins.get(pinKey(for: address), as: LocalPin.self))?.value
    }

    private func loadPins() async -> [String: LocalPin] {
        let entries = (try? await pins.list(prefix: pinPrefix, as: LocalPin.self)) ?? []
        return Dictionary(entries.map { ($0.value.address, $0.value) }, uniquingKeysWith: { first, _ in first })
    }

    private func save(_ pin: LocalPin) async {
        _ = try? await pins.put(pinKey(for: pin.address), pin)
    }
}
