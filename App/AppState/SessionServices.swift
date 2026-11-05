import DMCNKit
import Foundation

#if DEBUG
    import DMCNKitSamples
#endif

/// Everything a session talks to. A real account and the sample account differ only in how this
/// is built, so every screen runs the same code for both.
struct SessionServices: Sendable {
    let host: String
    let keys: any AccountKeys
    let deviceID: Data
    let inbox: Inbox
    let flags: FlagStore
    let labels: LabelStore
    let contacts: ContactStore
    let filter: MailFilterStore
    let sent: SentStore
    let drafts: DraftStore
    let settings: SettingsStore
    let storage: any PersonalStorage
    let bridge: any BridgeVerifier
    let directory: @Sendable (String) async throws -> DirectoryAnswer
    let identityRecord: @Sendable (String) async throws -> IdentityRecordAnswer
    let deleteMessage: @Sendable (String) async throws -> Void
    /// Nil where nothing can be sent: the sample account.
    let composer: Composer?
    let isLocalOnly: @Sendable () async -> Bool
    let search: MailSearchSession?

    static func live(
        host: String, client: WebHostClient, payload: KeyPayload, address: String, directory folder: URL
    ) async throws -> SessionServices {
        let keys = payload.accountKeys(address: address)
        let deviceID = payload.deviceId
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let storage = PersonalStore(client: client, keys: keys, localDirectory: folder.appending(path: "local"))
        let device = LocalPersonalStorage(directory: folder.appending(path: "device"))
        let inbox = Inbox(service: client, keys: keys)
        let contacts = ContactStore(storage: storage, pins: device, owner: address, deviceID: deviceID)
        let sent = SentStore(storage: storage, keys: keys)
        // The root key only says whether a bridge can be believed: without it, bridged mail reads
        // as unverified, which is the safe way to be wrong.
        let rootKey = try? await client.domainRootKey()
        // Caches, on purpose: the index can be rebuilt from the mail and is fine to lose.
        let index = try? SearchIndex.open(
            keys: keys,
            storage: FileSearchIndexStorage(baseDirectory: folder.appending(path: "search"), address: address))
        return SessionServices(
            host: host, keys: keys, deviceID: deviceID, inbox: inbox,
            flags: FlagStore(storage: storage, deviceID: deviceID), labels: LabelStore(storage: storage),
            contacts: contacts, filter: MailFilterStore(client: DeviceMailFilter(storage: device)), sent: sent,
            drafts: DraftStore(storage: storage, address: address), settings: SettingsStore(storage: storage),
            storage: storage, bridge: RootKeyBridgeVerifier(domainRootKey: rootKey),
            directory: { try await client.directoryAnswer(for: $0, keys: keys) },
            identityRecord: { try await client.identityRecord(for: $0, keys: keys) },
            deleteMessage: { try await client.delete(hash: $0, keys: keys) },
            composer: Composer(host: client, account: keys, deviceID: deviceID, contacts: contacts, sent: sent),
            isLocalOnly: { await storage.isLocalOnly },
            search: index.map { index in
                MailSearchSession(index: index, inbox: inbox, sent: sent, runnable: { true })
            })
    }

    #if DEBUG
        static func sample(_ account: SampleAccount) -> SessionServices {
            let mailbox = account.mailbox
            return SessionServices(
                host: "Sample mail", keys: account.keys, deviceID: account.deviceID, inbox: account.inbox,
                flags: account.flags, labels: account.labels, contacts: account.contacts, filter: account.filter,
                sent: account.sent, drafts: account.drafts, settings: account.settings, storage: account.storage,
                bridge: RootKeyBridgeVerifier(domainRootKey: nil),
                directory: { DirectoryAnswer(try await mailbox.lookup($0)) },
                identityRecord: { _ in IdentityRecordAnswer(record: "") },
                deleteMessage: { _ in }, composer: nil, isLocalOnly: { false }, search: nil)
        }
    #endif
}
