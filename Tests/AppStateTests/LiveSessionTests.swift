import DMCNKit
import Foundation
import Testing

@testable import AppState

/// What the screens drive, against a real `dmcnd`. Skipped unless a host is named, as in
/// `LiveHostTests`, which says how to start one.
private let liveHost = ProcessInfo.processInfo.environment["DMCN_LIVE_HOST"].flatMap(URL.init(string:))

@MainActor
private func account(_ name: String, host: URL) async throws -> (session: MailSession, model: AppModel) {
    let address = "\(name)-\(UInt32.random(in: 0...UInt32.max))@localhost"
    let keys = KeyPayload.generate()
    let client = WebHostClient(baseURL: host)
    _ = try await client.register(keys, address: address)
    try await client.signIn(keys.accountKeys(address: address))
    let folder = FileManager.default.temporaryDirectory.appending(path: "dmcn-live-session-\(UUID().uuidString)")
    let services = try await SessionServices.live(
        host: "localhost", client: client, payload: keys, address: address, directory: folder)
    let model = AppModel(defaults: UserDefaults(suiteName: UUID().uuidString)!)
    await model.start(services)
    guard case .signedIn(let session) = model.phase else { throw APIError(status: 0, message: "no session") }
    return (session, model)
}

@MainActor
private func settle(_ until: () -> Bool) async {
    for _ in 0..<3000 where !until() {
        try? await Task.sleep(for: .milliseconds(1))
    }
}

@MainActor
@Suite(.enabled(if: liveHost != nil), .serialized) struct LiveSession {
    @Test func aFullRoundTripThroughTheScreensState() async throws {
        let host = try #require(liveHost)
        let (ada, _) = try await account("ada", host: host)
        let (bob, _) = try await account("bob", host: host)
        #expect(!ada.loadFailed)
        #expect(!ada.isSorting)
        #expect(ada.rows.isEmpty)
        #expect(!ada.storageIsLocalOnly)

        // Ada writes through the composer.
        ada.compose()
        let compose = try #require(ada.composing)
        compose.to.pick(bob.address)
        compose.subject = "Through the app"
        compose.body = "Sent by the same code the screen calls."
        await compose.send()
        #expect(compose.error == nil)
        #expect(compose.sentReport != nil)
        ada.select(.sent)
        #expect(ada.rows.contains { $0.subject == "Through the app" })

        // Bob finds it, verified, and opens it.
        await bob.refresh()
        let row = try #require(bob.rows.first { $0.subject == "Through the app" })
        #expect(row.isUnread)
        #expect(bob.unreadCount == 1)
        bob.open(row)
        let reader = try #require(bob.openMessage)
        await reader.load()
        await settle { bob.flag(row.id)?.read == true }
        #expect(bob.unreadCount == 0)
        guard case .text(let text) = reader.body else {
            Issue.record("expected the body, got \(reader.body)")
            return
        }
        #expect(text == "Sent by the same code the screen calls.")
        #expect(reader.decision.trustReady)
        #expect(reader.decision.checks != nil)
        #expect(!reader.decision.withheld)
        // Not a contact yet: held behind the gate until Bob decides.
        #expect(reader.decision.gated)

        // Trusting opens it, and the sender becomes a contact.
        await reader.trustSender()
        #expect(!reader.decision.gated)
        #expect(bob.contact(for: ada.address) != nil)

        // Organising it survives a fresh read.
        reader.toggleStar()
        await settle { bob.flag(row.id)?.starred == true }
        let label = await bob.createLabel(name: "Keep", color: "#3b82f6")
        reader.addLabel(try #require(label))
        await settle { bob.flag(row.id)?.labelIds?.isEmpty == false }
        await bob.refresh()
        #expect(bob.flag(row.id)?.starred == true)
        bob.select(.label(try #require(label)))
        #expect(bob.rows.contains { $0.id == row.id })

        // Delete, restore, delete for good.
        bob.select(.inbox)
        bob.trash(row)
        await settle { bob.flag(row.id)?.trashedAt != nil }
        #expect(bob.hasDeleted)
        bob.restore(row)
        await settle { bob.flag(row.id)?.trashedAt == nil }
        await bob.deleteForever(row.id)
        await bob.refresh()
        #expect(!bob.messages.contains { $0.hash == row.id })
    }

    @Test func aDraftSurvivesClosingTheComposer() async throws {
        let host = try #require(liveHost)
        let (ada, _) = try await account("ada", host: host)
        ada.compose()
        let compose = try #require(ada.composing)
        compose.subject = "Half written"
        compose.body = "To be continued"
        await compose.putAway()
        await ada.refresh()
        let draft = try #require(ada.drafts.first { $0.subject == "Half written" })
        ada.openDraft(draft)
        await settle { ada.composing != nil }
        #expect(ada.composing?.body == "To be continued")
    }

    @Test func settingsAndSearchWork() async throws {
        let host = try #require(liveHost)
        let (ada, _) = try await account("ada", host: host)
        #expect(await ada.saveSignature("Ada"))
        await ada.refresh()
        #expect(ada.settings.signature == "Ada")
        await ada.setTrashDays(3)
        #expect(ada.trashDays == 3)
        #expect(ada.fingerprintGrouped.count == 49)
        ada.compose()
        #expect(ada.composing?.body.contains("Ada") == true)
        ada.composing = nil
    }
}
