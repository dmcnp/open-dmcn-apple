import Foundation
import Testing
@testable import DMCNKit

private let device = fill(16, 0xd1)
private let fixedNow: StoreClock = { 1_760_000_000_000 }

@Suite struct Flags {
    let hash = String(repeating: "a1", count: 32)

    @Test func writesTheBrowsersRecordUnderTheMessageHash() async throws {
        let storage = InMemoryPersonalStorage()
        let flags = FlagStore(storage: storage, deviceID: device, now: fixedNow)
        try await flags.markRead(hash)
        let record = try #require(try await storedObject(storage, "flags/" + hash))
        #expect(
            record == [
                "v": .int(1), "read": .bool(true), "updatedAt": .int(1_760_000_000_000),
                "deviceId": .string(device.hex),
            ])
    }

    @Test func aDeltaKeepsWhatItDoesNotNameAndClearsWhatItSaysTo() async throws {
        let flags = FlagStore(storage: InMemoryPersonalStorage(), deviceID: device, now: fixedNow)
        let current = FlagRecord(
            read: false, archived: true, folderId: "f", labelIds: ["l"], trashedAt: 5, updatedAt: 1)
        let next = try await flags.apply(
            hash, current: current, delta: FlagDelta(starred: .set(true), folderId: .clear, trashedAt: .clear))
        #expect(next.read == false)
        #expect(next.archived == true)
        #expect(next.starred == true)
        #expect(next.labelIds == ["l"])
        #expect(next.folderId == nil)
        #expect(next.trashedAt == nil)
        #expect(next.updatedAt == 1_760_000_000_000)
        #expect(next.deviceId == device.hex)
    }

    @Test func restoringRemovesTheKeyRatherThanWritingNull() async throws {
        let storage = InMemoryPersonalStorage()
        let flags = FlagStore(storage: storage, deviceID: device, now: fixedNow)
        try await flags.trash(hash)
        #expect(try await storedObject(storage, "flags/" + hash)?["trashedAt"] == .int(1_760_000_000_000))
        try await flags.restore(hash)
        #expect(try await storedObject(storage, "flags/" + hash)?["trashedAt"] == nil)
    }

    @Test func aMessageAlreadyReadIsNotWrittenAgain() async throws {
        let storage = RacingStorage(races: 0)
        let flags = FlagStore(storage: storage, deviceID: device)
        try await flags.markRead(hash)
        try await flags.markRead(hash)
        #expect(await storage.puts.count == 1)
        #expect(await storage.puts[0].expectedVersion == 0)
    }

    @Test func labelsAndFoldersGoThroughTheLastKnownRecord() async throws {
        let flags = FlagStore(storage: InMemoryPersonalStorage(), deviceID: device)
        try await flags.addLabel(hash, "a")
        try await flags.addLabel(hash, "b")
        try await flags.addLabel(hash, "a")
        try await flags.removeLabel(hash, "a")
        try await flags.removeLabel(hash, "missing")
        try await flags.setFolder(hash, "f")
        #expect(await flags.flags[hash]?.labelIds == ["b"])
        #expect(await flags.flags[hash]?.folderId == "f")
        try await flags.setFolder(hash, nil)
        #expect(await flags.flags[hash]?.folderId == nil)
    }

    @Test func aListingIsKeyedByHashAndBecomesTheCurrentRecord() async throws {
        let storage = InMemoryPersonalStorage()
        let one = FlagStore(storage: storage, deviceID: device)
        try await one.set(hash, FlagDelta(starred: .set(true)))
        let two = FlagStore(storage: storage, deviceID: device)
        #expect(try await two.list()[hash]?.starred == true)
        try await two.set(hash, FlagDelta(archived: .set(true)))
        #expect(try await one.list()[hash]?.starred == true)
        #expect(await one.flags[hash]?.archived == true)
    }

    @Test func removingIsBestEffortAndOnlyForAKnownRecord() async throws {
        let storage = InMemoryPersonalStorage()
        let flags = FlagStore(storage: storage, deviceID: device)
        await flags.remove(hash)
        try await flags.markRead(hash)
        await flags.remove(hash)
        #expect(try await storage.get("flags/" + hash, as: JSONValue.self) == nil)
        #expect(await flags.flags[hash] == nil)
    }

    @Test func aRecordMissingItsBookkeepingStillReads() throws {
        let record = try StoreJSON.decode(FlagRecord.self, from: Data(#"{"v":1,"read":true}"#.utf8))
        #expect(record.read == true)
        #expect(record.updatedAt == 0)
    }

    /// Pinned because it surprises: the relay's key charset has no colon, so a Sent row, whose hash
    /// is `sent:<id>`, can't hold flags on a real relay. The browser has the same limit.
    @Test func aSentRowCannotHoldFlagsOnARelay() async throws {
        let flags = FlagStore(storage: InMemoryPersonalStorage(), deviceID: device)
        await #expect(throws: APIError.self) { try await flags.trash("sent:" + String(repeating: "5", count: 32)) }
    }
}

@Suite struct Labels {
    @Test func anEmptyAccountHasAnEmptyDocumentAtVersionZero() async throws {
        let (doc, version) = try await LabelStore(storage: InMemoryPersonalStorage()).get()
        #expect(version == 0)
        #expect(doc.fields == ["v": .int(1), "labels": .array([]), "folders": .array([])])
    }

    @Test func editsDefinitionsTheWayTheBrowserDoes() async throws {
        let storage = InMemoryPersonalStorage()
        let labels = LabelStore(storage: storage)
        let id = try await labels.createLabel(name: "  Work\n", color: "#ef4444")
        let folder = try await labels.createFolder(name: " Receipts ")
        #expect(id.count == 16)
        try await labels.renameLabel(id: id, name: " Job ")
        try await labels.renameFolder(id: folder, name: "Bills")
        let (doc, version) = try await labels.get()
        #expect(version == 4)
        #expect(doc.labels.map(\.name) == ["Job"])
        #expect(doc.labels.map(\.color) == ["#ef4444"])
        #expect(doc.folders.map(\.name) == ["Bills"])
        #expect(await labels.doc == doc)

        try await labels.renameLabel(id: id, name: "Job", color: "#3b82f6")
        #expect(try await labels.get().doc.labels.first?.color == "#3b82f6")
        try await labels.deleteLabel(id: id)
        try await labels.deleteFolder(id: folder)
        #expect(
            try await storedObject(storage, LabelStore.key) == [
                "v": .int(1), "labels": .array([]), "folders": .array([]),
            ])
    }

    @Test func aConcurrentEditIsRereadNotClobbered() async throws {
        // Another device adds a label between this one's read and its write.
        let storage = RacingStorage(races: 1) { inner, key in
            var doc = LabelsDoc()
            doc.labels = [LabelDef(id: "theirs", name: "Theirs", color: "#000")]
            try await inner.put(key, doc)
        }
        try await storage.inner.put(LabelStore.key, LabelsDoc())
        let labels = LabelStore(storage: storage)
        try await labels.createLabel(name: "Mine", color: "#fff")
        let names = try await labels.get().doc.labels.map(\.name)
        #expect(names == ["Theirs", "Mine"])
    }

    @Test func givesUpAfterFiveConflicts() async throws {
        let storage = RacingStorage(races: 5)
        try await storage.inner.put(LabelStore.key, LabelsDoc())
        let labels = LabelStore(storage: storage)
        await #expect(throws: TooManyConflictsError()) { try await labels.createLabel(name: "x", color: "#fff") }
        #expect(await storage.puts.count == 5)
    }

    @Test func fieldsThisKitDoesNotKnowSurviveAnEdit() async throws {
        let storage = InMemoryPersonalStorage()
        let written = #"""
            {"v":1,"sortOrder":["b"],"labels":[{"id":"a","name":"A","color":"#fff","shade":3}],
             "folders":[{"id":"f","name":"F","pinned":true}]}
            """#
        try await storage.put(LabelStore.key, try StoreJSON.decode(JSONValue.self, from: Data(written.utf8)))
        let labels = LabelStore(storage: storage)
        try await labels.renameLabel(id: "a", name: "Renamed")
        try await labels.renameFolder(id: "f", name: "Renamed")

        let doc = try #require(try await storedObject(storage, LabelStore.key))
        #expect(doc["sortOrder"] == .array([.string("b")]))
        let saved = try await labels.get().doc
        #expect(saved.labels[0].fields["shade"] == .int(3))
        #expect(saved.labels[0].name == "Renamed")
        #expect(saved.folders[0].fields["pinned"] == .bool(true))
    }

    @Test func aFailedRefreshKeepsTheLastGoodDocument() async throws {
        let storage = InMemoryPersonalStorage()
        let labels = LabelStore(storage: storage)
        #expect(await labels.ready == false)
        try await labels.createFolder(name: "Kept")

        try await storage.put(LabelStore.key, "not a document")
        await labels.refresh()
        #expect(await labels.ready == true)
        #expect(await labels.doc.folders.map(\.name) == ["Kept"])
    }
}

@Suite struct Settings {
    @Test func anEmptyAccountReadsAsDefaults() async throws {
        let (settings, version) = try await SettingsStore(storage: InMemoryPersonalStorage()).get()
        #expect(version == 0)
        #expect(settings == AppSettings())
        #expect(settings.fields == ["v": .int(1)])
        #expect(settings.retentionDays == 7)
    }

    @Test func everyFieldRoundTripsUnderItsOwnKey() async throws {
        let storage = InMemoryPersonalStorage()
        let store = SettingsStore(storage: storage)
        try await store.update {
            $0.displayName = "Old"
            $0.signature = "Ada"
            $0.composePlainText = true
            $0.remoteImagesForTrusted = false
            $0.gettingStartedHidden = true
            $0.trashDays = 3
        }
        #expect(
            try await storedObject(storage, SettingsStore.key) == [
                "v": .int(1), "displayName": .string("Old"), "signature": .string("Ada"),
                "composePlainText": .bool(true), "remoteImagesForTrusted": .bool(false),
                "gettingStartedHidden": .bool(true), "trashDays": .int(3),
            ])
        let read = try await store.get().settings
        #expect(read.signature == "Ada")
        #expect(read.composePlainText == true)
        #expect(read.remoteImagesForTrusted == false)
        #expect(read.gettingStartedHidden == true)
        #expect(read.retentionDays == 3)
    }

    @Test func nilRemovesAKey() async throws {
        let storage = InMemoryPersonalStorage()
        let store = SettingsStore(storage: storage)
        try await store.update { $0.signature = "Ada" }
        try await store.update { $0.signature = nil }
        #expect(try await storedObject(storage, SettingsStore.key) == ["v": .int(1)])
    }

    @Test func aFieldFromANewerClientSurvivesAnUpdate() async throws {
        let storage = InMemoryPersonalStorage()
        let written = #"{"v":1,"signature":"a","newer":{"list":[1,2.5,null,1730000000123]},"trashDays":"odd"}"#
        try await storage.put(SettingsStore.key, try StoreJSON.decode(JSONValue.self, from: Data(written.utf8)))
        try await SettingsStore(storage: storage).update { $0.signature = "b" }
        let saved = try #require(try await storedObject(storage, SettingsStore.key))
        #expect(saved["newer"] == .object(["list": .array([.int(1), .double(2.5), .null, .int(1_730_000_000_123)])]))
        #expect(saved["signature"] == .string("b"))
        // A known key holding something unexpected is left alone rather than failing the read.
        #expect(saved["trashDays"] == .string("odd"))
    }

    @Test func retentionStaysInTheRangeOffered() throws {
        var settings = AppSettings()
        settings.trashDays = 0
        #expect(settings.retentionDays == 1)
        settings.trashDays = 99
        #expect(settings.retentionDays == 7)
        settings.fields["trashDays"] = .double(2.6)
        #expect(settings.retentionDays == 3)
    }

    @Test func aConcurrentEditIsRereadNotClobbered() async throws {
        let storage = RacingStorage(races: 1) { inner, key in
            var theirs = AppSettings()
            theirs.signature = "theirs"
            try await inner.put(key, theirs)
        }
        try await storage.inner.put(SettingsStore.key, AppSettings())
        let store = SettingsStore(storage: storage)
        try await store.update { $0.trashDays = 2 }
        let saved = try await store.get().settings
        #expect(saved.signature == "theirs")
        #expect(saved.trashDays == 2)
        #expect(await store.settings == saved)
    }

    @Test func givesUpAfterFiveConflicts() async throws {
        let storage = RacingStorage(races: 5)
        try await storage.inner.put(SettingsStore.key, AppSettings())
        await #expect(throws: TooManyConflictsError()) {
            try await SettingsStore(storage: storage).update { $0.trashDays = 2 }
        }
    }

    @Test func loadedOnlyAfterTheAccountsOwnDocumentWasRead() async throws {
        let store = SettingsStore(storage: InMemoryPersonalStorage())
        #expect(await store.loaded == false)
        await store.refresh()
        #expect(await store.loaded == true)
    }
}

@Suite struct Contacts {
    let owner = "me@parity.example"
    let ada = "ada@parity.example"
    let keyA = fill(32, 0x31).base64EncodedString()
    let keyB = fill(32, 0x32).base64EncodedString()
    let keyC = fill(32, 0x33).base64EncodedString()

    func store(_ storage: any PersonalStorage, pins: any DeviceStorage = InMemoryPersonalStorage()) -> ContactStore {
        ContactStore(storage: storage, pins: pins, owner: owner, deviceID: device, now: fixedNow)
    }

    func facts(_ key: String, custody: Bool = false) -> PinnedFacts {
        PinnedFacts(ed25519Pub: key, x25519Pub: keyB, adminKeyCustody: custody)
    }

    /// The synced row, as another device left it.
    func writeSynced(_ storage: InMemoryPersonalStorage, ed25519Pub: String?, pinSeq: Int64? = nil) async throws {
        var record = ContactRecord(address: ada, name: "Ada", fingerprint: "fp", ed25519Pub: ed25519Pub, pinSeq: pinSeq)
        if ed25519Pub != nil { record.x25519Pub = keyB }
        try await storage.put(ContactStore.key(for: ada), record)
    }

    @Test func anIDIsBase64urlOfTheNormalisedAddress() {
        #expect(ContactStore.id(for: " Ada@Parity.Example\n") == "YWRhQHBhcml0eS5leGFtcGxl")
        #expect(ContactStore.key(for: "ada@parity.example") == "contacts/YWRhQHBhcml0eS5leGFtcGxl")
        // Its UTF-8 is "76+/" in plain base64: the two characters base64url replaces.
        #expect(ContactStore.id(for: "\u{FBFF}") == "76-_")
    }

    @Test func aPutIsVersionThreeWithItsBookkeeping() async throws {
        let storage = InMemoryPersonalStorage()
        try await store(storage).put(ContactRecord(address: ada, name: "Ada", fingerprint: "fp"))
        #expect(
            try await storedObject(storage, ContactStore.key(for: ada)) == [
                "v": .int(3), "address": .string(ada), "name": .string("Ada"), "fingerprint": .string("fp"),
                "updatedAt": .int(1_760_000_000_000), "deviceId": .string(device.hex),
            ])
    }

    @Test func aRenameKeepsTrustFieldsAndAnythingElseOnTheRecord() async throws {
        let storage = InMemoryPersonalStorage()
        var record = ContactRecord(
            address: ada, name: "Ada", fingerprint: "fp", notes: "keep", provenance: .inPerson, ed25519Pub: keyA,
            x25519Pub: keyB, pinnedAt: 7, adminKeyCustody: true, pinSeq: 2)
        record.fields["fromTheFuture"] = .string("kept")
        try await storage.put(ContactStore.key(for: ada), record)

        let saved = try await store(storage).update(ada, name: "Ada L")
        #expect(saved.name == "Ada L")
        #expect(saved.notes == "keep")
        #expect(saved.provenance == .inPerson)
        #expect(saved.ed25519Pub == keyA)
        #expect(saved.pinSeq == 2)
        #expect(saved.v == 3)
        #expect(try await storedObject(storage, ContactStore.key(for: ada))?["fromTheFuture"] == .string("kept"))
    }

    @Test func anEditRetriesOnceThenGivesUp() async throws {
        let once = RacingStorage(races: 1)
        try await once.inner.put(ContactStore.key(for: ada), ContactRecord(address: ada, name: "A", fingerprint: ""))
        try await store(once).update(ada, name: "B")
        #expect(await once.puts.count == 2)

        let twice = RacingStorage(races: 2)
        try await twice.inner.put(ContactStore.key(for: ada), ContactRecord(address: ada, name: "A", fingerprint: ""))
        await #expect(throws: StorageConflictError()) { try await store(twice).update(ada, name: "B") }
    }

    @Test func editingAContactThatIsGoneSaysSo() async {
        await #expect(throws: ContactNotFoundError()) {
            try await store(InMemoryPersonalStorage()).update(ada, name: "B")
        }
    }

    @Test func aFirstSightingOfASyncedPinIsAdoptedAndKept() async throws {
        let storage = InMemoryPersonalStorage()
        let pins = InMemoryPersonalStorage()
        try await writeSynced(storage, ed25519Pub: keyA)
        let contacts = store(storage, pins: pins)
        await contacts.refresh()
        #expect(await contacts.pinAlerts.isEmpty)
        #expect(await contacts.records.first?.pinSeq == 1)
        let held = try await pins.list(prefix: "pins/", as: LocalPin.self)
        #expect(held.map(\.value.ed25519Pub) == [keyA])
        #expect(held.map(\.value.address) == [ada])
    }

    @Test func aPinTheRelayRolledBackIsKeptAndPushedBack() async throws {
        let storage = InMemoryPersonalStorage()
        try await writeSynced(storage, ed25519Pub: keyA)
        let contacts = store(storage)
        await contacts.refresh()

        // The relay serves an older row, from before the pin.
        try await writeSynced(storage, ed25519Pub: nil)
        await contacts.refresh()
        #expect(await contacts.pinAlerts == [PinAlert(address: ada, anomaly: .syncedCopyMissing)])
        #expect(await contacts.records.first?.ed25519Pub == keyA)
        let row = try #require(try await storage.get(ContactStore.key(for: ada), as: ContactRecord.self))
        #expect(row.value.ed25519Pub == keyA)
    }

    @Test func aDifferentSyncedPinWithoutAHigherSequenceLosesAndIsLeftAlone() async throws {
        let storage = InMemoryPersonalStorage()
        try await writeSynced(storage, ed25519Pub: keyA)
        let contacts = store(storage)
        await contacts.refresh()

        try await writeSynced(storage, ed25519Pub: keyC, pinSeq: 1)
        await contacts.refresh()
        #expect(await contacts.pinAlerts == [PinAlert(address: ada, anomaly: .syncedCopyConflict)])
        #expect(await contacts.records.first?.ed25519Pub == keyA)
        // Not healed: two of the owner's devices would otherwise overwrite each other forever.
        let row = try #require(try await storage.get(ContactStore.key(for: ada), as: ContactRecord.self))
        #expect(row.value.ed25519Pub == keyC)
    }

    @Test func aHigherSequenceIsTheOneThingThatMovesAHeldPin() async throws {
        let storage = InMemoryPersonalStorage()
        try await writeSynced(storage, ed25519Pub: keyA)
        let contacts = store(storage)
        await contacts.refresh()

        try await writeSynced(storage, ed25519Pub: keyC, pinSeq: 2)
        await contacts.refresh()
        #expect(await contacts.pinAlerts.isEmpty)
        #expect(await contacts.records.first?.ed25519Pub == keyC)
        #expect(await contacts.records.first?.pinSeq == 2)
    }

    @Test func allowlistingAdvancesTheSequenceAndClearsTheAlert() async throws {
        let storage = InMemoryPersonalStorage()
        try await writeSynced(storage, ed25519Pub: keyA)
        let contacts = store(storage)
        await contacts.refresh()
        try await writeSynced(storage, ed25519Pub: keyC, pinSeq: 1)
        await contacts.refresh()
        #expect(await contacts.pinAlerts.count == 1)

        try await contacts.allowlist(
            ContactRecord(
                address: ada, name: "Ada", fingerprint: "fp", provenance: .fingerprint, ed25519Pub: keyC,
                x25519Pub: keyB))
        #expect(await contacts.pinAlerts.isEmpty)
        let row = try #require(try await storage.get(ContactStore.key(for: ada), as: ContactRecord.self))
        #expect(row.value.pinSeq == 2)
        #expect(row.value.provenance == .fingerprint)
        await contacts.refresh()
        #expect(await contacts.pinAlerts.isEmpty)
    }

    @Test func aLazyPinNeverOverwritesOneThisDeviceHolds() async throws {
        let storage = InMemoryPersonalStorage()
        let contacts = store(storage)
        try await contacts.put(ContactRecord(address: ada, name: "Ada", fingerprint: "fp"))
        await contacts.pinKey(ada, facts: facts(keyA))
        var row = try #require(try await storage.get(ContactStore.key(for: ada), as: ContactRecord.self))
        #expect(row.value.ed25519Pub == keyA)
        #expect(row.value.pinSeq == 1)
        #expect(row.value.pinnedAt == 1_760_000_000_000)
        #expect(await contacts.contact(for: ada)?.ed25519Pub == keyA)

        // Even with the synced copy stripped of its pin, which is the attack this closes.
        try await writeSynced(storage, ed25519Pub: nil)
        await contacts.pinKey(ada, facts: facts(keyC))
        row = try #require(try await storage.get(ContactStore.key(for: ada), as: ContactRecord.self))
        #expect(row.value.ed25519Pub == nil)
    }

    @Test func aDeliberateRepinReplacesThePinOnBothCopies() async throws {
        let storage = InMemoryPersonalStorage()
        let contacts = store(storage)
        try await contacts.put(ContactRecord(address: ada, name: "Ada", fingerprint: "fp"))
        await contacts.pinKey(ada, facts: facts(keyA))
        try await contacts.repinKey(ada, facts: facts(keyC, custody: true), seq: 2)
        await contacts.refresh()
        #expect(await contacts.pinAlerts.isEmpty)
        #expect(await contacts.contact(for: ada)?.ed25519Pub == keyC)
        #expect(await contacts.contact(for: ada)?.adminKeyCustody == true)
    }

    @Test func removingAContactDropsItsPinToo() async throws {
        let storage = InMemoryPersonalStorage()
        let pins = InMemoryPersonalStorage()
        let contacts = store(storage, pins: pins)
        try await contacts.allowlist(
            ContactRecord(
                address: ada, name: "Ada", fingerprint: "fp", provenance: .userApproved, ed25519Pub: keyA,
                x25519Pub: keyB))
        try await contacts.remove(ada)
        #expect(try await pins.list(prefix: "", as: LocalPin.self).isEmpty)
        #expect(await contacts.contact(for: ada) == nil)

        // Removing and re-adding is the documented way to accept a rotation.
        try await contacts.allowlist(
            ContactRecord(
                address: ada, name: "Ada", fingerprint: "fp", provenance: .userApproved, ed25519Pub: keyC,
                x25519Pub: keyB))
        await contacts.refresh()
        #expect(await contacts.pinAlerts.isEmpty)
        #expect(await contacts.contact(for: ada)?.ed25519Pub == keyC)
    }

    @Test func pinsAreKeptPerOwner() async throws {
        let pins = InMemoryPersonalStorage()
        let mine = InMemoryPersonalStorage()
        let theirs = InMemoryPersonalStorage()
        let me = store(mine, pins: pins)
        try await me.allowlist(
            ContactRecord(
                address: ada, name: "Ada", fingerprint: "fp", provenance: .userApproved, ed25519Pub: keyA,
                x25519Pub: keyB))
        try await writeSynced(theirs, ed25519Pub: keyC)
        let them = ContactStore(storage: theirs, pins: pins, owner: "them@parity.example", deviceID: device)
        await them.refresh()
        #expect(await them.pinAlerts.isEmpty)
        #expect(await them.contact(for: ada)?.ed25519Pub == keyC)
    }

    @Test func aNameThatIsJustTheAddressIsNoName() async throws {
        let contacts = store(InMemoryPersonalStorage())
        try await contacts.put(ContactRecord(address: ada, name: " ADA@parity.example ", fingerprint: ""))
        #expect(await contacts.name(for: ada) == ada)
        try await contacts.put(ContactRecord(address: ada, name: " Ada ", fingerprint: ""))
        #expect(await contacts.name(for: "Ada@Parity.Example") == "Ada")
        #expect(await contacts.name(for: "x@parity.example") == "x@parity.example")
    }

    @Test func aRecordWithAProvenanceThisKitDoesNotKnowKeepsIt() async throws {
        let storage = InMemoryPersonalStorage()
        let written = #"{"v":3,"address":"ada@parity.example","name":"Ada","fingerprint":"","provenance":"newer_kind"}"#
        try await storage.put(
            ContactStore.key(for: ada), try StoreJSON.decode(JSONValue.self, from: Data(written.utf8)))
        let saved = try await store(storage).update(ada, name: "A")
        #expect(saved.provenance == nil)
        #expect(saved.fields["provenance"] == .string("newer_kind"))
    }
}

@Suite struct MailFilters {
    let key = String(repeating: "AB", count: 32)

    @Test func noListIsNotAnEmptyList() async throws {
        let client = DeviceMailFilter(storage: InMemoryPersonalStorage())
        #expect(try await client.get() == nil)
        try await client.save(FilterList())
        #expect(try await client.get() == FilterList())
        try await client.clear()
        #expect(try await client.get() == nil)
    }

    @Test func writesGoFieldNames() async throws {
        let storage = InMemoryPersonalStorage()
        try await DeviceMailFilter(storage: storage).save(FilterList(senderKeys: ["ab"]))
        #expect(
            try await storedObject(storage, "filter/list") == [
                "mode": .string("deny"), "domains": .array([]), "senders": .array([]),
                "allow_verified": .bool(false), "sender_keys": .array([.string("ab")]),
            ])
    }

    @Test func absentOptionalsStayAbsent() throws {
        let list = try StoreJSON.decode(
            FilterList.self, from: Data(#"{"mode":"allow","domains":[],"senders":[]}"#.utf8))
        #expect(list.allowVerified == nil)
        let written = try StoreJSON.decode([String: JSONValue].self, from: StoreJSON.encode(list))
        #expect(Set(written.keys) == ["mode", "domains", "senders"])
    }

    @Test func aBlockInDenyModeListsTheKeyAndTheAddress() async throws {
        let client = DeviceMailFilter(storage: InMemoryPersonalStorage())
        let store = MailFilterStore(client: client)
        try await store.blockSender(" Spam@Parity.Example ", senderKeyHex: key)
        try await store.blockSender("spam@parity.example", senderKeyHex: key.lowercased())
        let list = try #require(try await client.get())
        #expect(list.senderKeys == [key.lowercased()])
        #expect(list.senders == ["spam@parity.example"])
        #expect(await store.filter == list)
    }

    @Test func aBlockInAllowModeNeverAddsToTheAllowList() async throws {
        let client = DeviceMailFilter(storage: InMemoryPersonalStorage())
        try await client.save(
            FilterList(mode: .allow, senders: ["friend@parity.example"], allowVerified: nil, senderKeys: nil))
        try await MailFilterStore(client: client).blockSender("spam@parity.example", senderKeyHex: key)
        let list = try #require(try await client.get())
        #expect(list.senders == ["friend@parity.example"])
        #expect(list.senderKeys == [key.lowercased()])
        #expect(list.allowVerified == nil)
    }

    @Test func aBlockStartsFromWhatIsStoredNotAStaleCopy() async throws {
        let client = DeviceMailFilter(storage: InMemoryPersonalStorage())
        let store = MailFilterStore(client: client)
        await store.refresh()
        try await client.save(FilterList(domains: ["bad.example"]))
        try await store.blockSender("spam@parity.example")
        #expect(try await client.get()?.domains == ["bad.example"])
    }

    @Test func whatBlocks() {
        let deny = FilterList(domains: ["Bad.Example"], senders: [" Spam@Parity.Example"], senderKeys: [key])
        #expect(deny.blocks(senderAddress: "ok@parity.example", senderKeyHex: key.lowercased()))
        #expect(deny.blocks(senderAddress: "spam@parity.example", senderKeyHex: ""))
        #expect(deny.blocks(senderAddress: "anyone@bad.example", senderKeyHex: ""))
        #expect(!deny.blocks(senderAddress: "ok@parity.example", senderKeyHex: "cd"))

        let allow = FilterList(
            mode: .allow, domains: ["bad.example"], senders: ["spam@parity.example"], senderKeys: [key])
        #expect(allow.blocks(senderAddress: "x@parity.example", senderKeyHex: key))
        #expect(!allow.blocks(senderAddress: "spam@parity.example", senderKeyHex: ""))
    }

    @Test func aListThatGoesAwayIsForgotten() async throws {
        let client = DeviceMailFilter(storage: InMemoryPersonalStorage())
        let store = MailFilterStore(client: client)
        try await client.save(FilterList())
        await store.refresh()
        #expect(await store.filter != nil)
        try await client.clear()
        await store.refresh()
        #expect(await store.filter == nil)
        #expect(await store.ready)
    }
}
