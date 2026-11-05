import SwiftUI

@main
struct OpenDMCNApp: App {
    @State private var model = AppModel(
        vault: KeychainVault(),
        dataDirectory: URL.applicationSupportDirectory.appending(path: "accounts", directoryHint: .isDirectory))

    var body: some Scene {
        WindowGroup {
            RootView().environment(model)
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            switch model.phase {
            case .signedOut:
                SignedOutFlow()
            case .signedIn(let session):
                AppShell(session: session).id(ObjectIdentifier(session))
            }
        }
        .preferredColorScheme(model.theme.colorScheme)
        .tint(.brand)
        .task {
            await model.loadAccounts()
            #if DEBUG
                // For testers: straight to the in-memory sample account, whatever's on this device.
                if ProcessInfo.processInfo.arguments.contains("-sampleMail") { await model.exploreSampleMail() }
            #endif
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background: model.didLeave()
            case .active: Task { await model.didReturn() }
            default: break
            }
        }
    }
}
