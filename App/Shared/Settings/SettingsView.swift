import DMCNKit
import SwiftUI

/// Settings, in the web's five tabs. Mail state that should follow the account is written to the
/// personal store; theme and density belong to this device.
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    let session: MailSession
    @State private var tab = Tab.profile

    enum Tab: String, CaseIterable, Identifiable {
        case profile = "Profile"
        case privacy = "Privacy & security"
        case appearance = "Appearance"
        case organise = "Labels & folders"
        case account = "Account"

        var id: Self { self }
        var icon: Icon {
            switch self {
            case .profile: .user
            case .privacy: .shield
            case .appearance: .sun
            case .organise: .tag
            case .account: .atSign
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "Settings", onBack: { session.section = .mail })
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(Tab.allCases) { item in
                        Button {
                            tab = item
                        } label: {
                            HStack(spacing: 6) {
                                item.icon.image(16)
                                Text(item.rawValue).dsFont(.md, .medium)
                            }
                            .foregroundStyle(tab == item ? Color.brandText : .textMuted)
                            .padding(.horizontal, Space.s3)
                            .frame(height: 44)
                            .overlay(alignment: .bottom) {
                                Rectangle().fill(tab == item ? Color.brand : .clear).frame(height: 2)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, Space.s2)
            }
            .background(.surfaceCard)
            .overlay(alignment: .bottom) { Rectangle().fill(.borderDefault).frame(height: 1) }

            ScrollView {
                VStack(alignment: .leading, spacing: Space.s4) {
                    switch tab {
                    case .profile: ProfileTab(session: session)
                    case .privacy: PrivacyTab(session: session)
                    case .appearance: AppearanceTab()
                    case .organise: OrganiseTab(session: session)
                    case .account: AccountTab(session: session)
                    }
                    Text("DMCN Mail \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")")
                        .dsFont(.xs)
                        .foregroundStyle(.textSubtle)
                        .padding(.top, Space.s2)
                }
                .padding(Space.s4)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(.surfacePage)
        }
    }
}

private struct ProfileTab: View {
    let session: MailSession
    @State private var signature = ""
    @State private var saved: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s3) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Signature").dsFont(.md, .semibold).foregroundStyle(.textStrong)
                Text("Appended to new messages you compose. Synced across your devices.")
                    .dsFont(.sm)
                    .foregroundStyle(.textMuted)
            }
            TextEditor(text: $signature)
                .font(.system(size: 16))
                .foregroundStyle(.textStrong)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 96)
                .padding(Space.s2)
                .background(.surfaceCard, in: .dsCard)
                .dsBorder(.borderDefault)
                .accessibilityLabel("Signature")
            HStack(spacing: Space.s3) {
                DSButton("Save profile") {
                    Task {
                        saved = await session.saveSignature(signature) ? "Saved." : "Couldn't save."
                    }
                }
                if let saved { Text(saved).dsFont(.sm).foregroundStyle(.textMuted) }
            }
        }
        .onAppear { signature = session.settings.signature ?? "" }
    }
}

private struct PrivacyTab: View {
    @Environment(AppModel.self) private var model
    let session: MailSession
    @State private var exportPassphrase = ""
    @State private var exporting = false
    @State private var backup: FileDocumentData?
    @State private var note: String?

    var body: some View {
        card {
            HStack(spacing: Space.s2) {
                Icon.key.image(16).foregroundStyle(.brand)
                Text("Your encryption key").dsFont(.md, .semibold).foregroundStyle(.textStrong)
                DSBadge(text: "Active", tone: .success)
            }
            // Five groups a line, so a group never splits while it's being read to someone.
            Text(fingerprintLines)
                .dsMono(.sm)
                .tracking(0.5)
                .foregroundStyle(.textBody)
                .textSelection(.enabled)
                .padding(Space.s3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.surfaceSunken)
            Text(
                "Private keys are kept on this device and never leave it. The server holds no copy of your keys, not even encrypted. All encryption and signing happens here."
            )
            .dsFont(.sm)
            .foregroundStyle(.textMuted)
        }

        card {
            HStack(spacing: Space.s2) {
                Icon.shieldCheck.image(16).foregroundStyle(.brand)
                Text("Backup & recovery").dsFont(.md, .semibold).foregroundStyle(.textStrong)
            }
            Text(
                "Because the server keeps no copy of your keys, losing every device without a backup means losing this identity. Download an encrypted backup file and keep it somewhere safe."
            )
            .dsFont(.sm)
            .foregroundStyle(.textMuted)
            if let note { Callout(tone: .neutral, text: note) }
            if exporting {
                DSTextField(
                    "Backup passphrase", text: $exportPassphrase, secure: true,
                    hint: "Encrypts the backup file. You'll need it to restore.", contentType: .newPassword)
                HStack(spacing: Space.s2) {
                    DSButton("Download backup", size: .sm) {
                        Task {
                            do {
                                let file = try await model.backup(passphrase: exportPassphrase)
                                backup = FileDocumentData(data: file.data, filename: file.filename)
                                exporting = false
                                exportPassphrase = ""
                            } catch {
                                note = error.localizedDescription
                            }
                        }
                    }
                    .disabled(exportPassphrase.isEmpty)
                    DSButton("Cancel", variant: .secondary, size: .sm) { exporting = false }
                }
            } else {
                DSButton("Export encrypted backup…", variant: .secondary, size: .sm) { exporting = true }
            }
        }
        .fileExporter(
            isPresented: Binding(get: { backup != nil }, set: { if !$0 { backup = nil } }), document: backup,
            contentType: .json, defaultFilename: backup?.filename
        ) { result in
            if case .success = result { note = "Backup saved. Keep it somewhere safe." }
        }

        card {
            HStack(alignment: .top, spacing: Space.s4) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Lock when I leave").dsFont(.md, .semibold).foregroundStyle(.textStrong)
                    Text(
                        "On (recommended): accounts lock when you close this app, and a couple of minutes after you leave it for something else."
                    )
                    .dsFont(.sm)
                    .foregroundStyle(.textMuted)
                }
                Spacer(minLength: 0)
                DSToggle(
                    title: "Lock when I leave",
                    isOn: Binding(get: { model.lockOnLeave }, set: { model.lockOnLeave = $0 }))
            }
        }

        card {
            HStack(alignment: .top, spacing: Space.s4) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Load remote images from senders you trust").dsFont(.md, .semibold).foregroundStyle(
                        .textStrong)
                    Text(
                        "Off (recommended): images hosted on a sender's server are never fetched, so opening a message tells them nothing. On: they load for senders on your allowlist only. A remote image is how ordinary mail measures whether, when and where you opened it."
                    )
                    .dsFont(.sm)
                    .foregroundStyle(.textMuted)
                }
                Spacer(minLength: 0)
                DSToggle(
                    title: "Load remote images",
                    isOn: Binding(
                        get: { session.settings.remoteImagesForTrusted ?? false },
                        set: { value in Task { await session.setRemoteImages(value) } }))
            }
        }

        card {
            Text("Blocked senders").dsFont(.md, .semibold).foregroundStyle(.textStrong)
            if session.blockedSenders.isEmpty {
                Text("No one is blocked.").dsFont(.sm).foregroundStyle(.textMuted)
            }
            ForEach(session.blockedSenders, id: \.self) { sender in
                HStack(spacing: Space.s2) {
                    Text(sender).dsFont(.sm).foregroundStyle(.textBody).lineLimit(1)
                    Spacer(minLength: 0)
                    DSButton("Unblock", variant: .secondary, size: .sm) {
                        Task { await session.unblock(sender) }
                    }
                }
            }
        }
    }

    private var fingerprintLines: String {
        let groups = session.fingerprintGrouped.components(separatedBy: "·")
        return groups.prefix(5).joined(separator: "·") + "\n" + groups.dropFirst(5).joined(separator: "·")
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Space.s3) { content() }
            .padding(Space.s4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.surfaceCard)
            .dsBorder(.borderDefault)
    }
}

private struct AppearanceTab: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        SettingsCard {
            SettingsRow(title: "Theme", detail: "Light, dark, or follow your system setting.", stacked: true) {
                Segmented(
                    options: [("Light", ThemePreference.light), ("Dark", .dark), ("System", .system)],
                    selected: Binding(get: { model.theme }, set: { model.theme = $0 }))
            }
        }
    }
}

/// A row of joined options: `SegOption` on the web.
struct Segmented<Value: Hashable>: View {
    let options: [(String, Value)]
    @Binding var selected: Value

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.1) { title, value in
                Button {
                    selected = value
                } label: {
                    Text(title)
                        .dsFont(.sm, .medium)
                        .foregroundStyle(selected == value ? Color.brandText : .textBody)
                        .padding(.horizontal, Space.s3)
                        .frame(height: 30)
                        .background(selected == value ? Color.brandSubtle : .surfaceCard)
                        .dsBorder(selected == value ? .brand : .borderDefault)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

private struct OrganiseTab: View {
    let session: MailSession
    @State private var newLabel = ""
    @State private var color = LabelColor.choices[0]
    @State private var newFolder = ""

    var body: some View {
        SectionHeading(title: "Labels")
        Text("Press and hold a label or folder to drag it into a new order. The order is saved with your account.")
            .dsFont(.sm)
            .foregroundStyle(.textMuted)
        SettingsCard {
            ReorderableRows(ids: session.labels.map(\.id), onReorder: session.reorderLabels) { id in
                if let label = session.labels.first(where: { $0.id == id }) {
                    HStack(spacing: Space.s3) {
                        Circle().fill(LabelColor.color(label.color)).frame(width: 12, height: 12)
                        Text(label.name).dsFont(.md).foregroundStyle(.textBody)
                        Spacer(minLength: 0)
                        ConfirmTrashButton(label: "Delete label \(label.name)", size: .sm) {
                            Task { await session.deleteLabel(label.id) }
                        }
                    }
                    .padding(.vertical, Space.s2)
                    .padding(.horizontal, Space.s4)
                }
            }
            VStack(alignment: .leading, spacing: Space.s2) {
                DSTextField(placeholder: "New label name", text: $newLabel)
                ColorSwatches(selected: $color)
                DSButton("Add label", icon: .plus, variant: .secondary, size: .sm) {
                    let name = newLabel.trimmingCharacters(in: .whitespaces)
                    newLabel = ""
                    Task { await session.createLabel(name: name, color: color) }
                }
                .disabled(newLabel.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(Space.s4)
        }
        SectionHeading(title: "Folders")
        SettingsCard {
            ReorderableRows(ids: session.folders.map(\.id), onReorder: session.reorderFolders) { id in
                if let folder = session.folders.first(where: { $0.id == id }) {
                    HStack(spacing: Space.s3) {
                        Icon.folder.image(16).foregroundStyle(.textMuted)
                        Text(folder.name).dsFont(.md).foregroundStyle(.textBody)
                        Spacer(minLength: 0)
                        ConfirmTrashButton(label: "Delete folder \(folder.name)", size: .sm) {
                            Task { await session.deleteFolder(folder.id) }
                        }
                    }
                    .padding(.vertical, Space.s2)
                    .padding(.horizontal, Space.s4)
                }
            }
            VStack(alignment: .leading, spacing: Space.s2) {
                DSTextField(placeholder: "New folder name", text: $newFolder)
                DSButton("Add folder", icon: .plus, variant: .secondary, size: .sm) {
                    let name = newFolder.trimmingCharacters(in: .whitespaces)
                    newFolder = ""
                    Task { await session.createFolder(name: name) }
                }
                .disabled(newFolder.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(Space.s4)
        }
        FilingSection(session: session)
    }
}

/// How filing and swiping behave, and the senders whose new mail is filed for you. Synced across
/// your devices.
private struct FilingSection: View {
    let session: MailSession
    @State private var showingRules = false

    var body: some View {
        let filing = session.swipeFiling
        SectionHeading(title: "Filing and swiping")
        SettingsCard {
            SettingsRow(
                title: "Ask about the sender's other mail",
                detail:
                    "After you move a message to a folder, ask whether the sender's other mail and new mail should go there too."
            ) {
                DSToggle(
                    title: "Ask about the sender's other mail",
                    isOn: Binding(
                        get: { filing.asksAboutSender },
                        set: { on in Task { await session.setAsksAboutSender(on) } }))
            }
            SettingsRow(
                title: "Full swipe left archives",
                detail: "Swiping a message all the way left archives it instead of deleting it."
            ) {
                DSToggle(
                    title: "Full swipe left archives",
                    isOn: Binding(
                        get: { filing.fullSwipeArchives },
                        set: { on in Task { await session.setFullSwipeArchives(on) } }))
            }
            SettingsRow(title: "Sender rules", detail: rulesDetail(filing.rules.count), stacked: true) {
                DSButton("Manage sender rules", variant: .secondary, size: .sm) { showingRules = true }
            }
        }
        .sheet(isPresented: $showingRules) {
            NavigationStack { SenderRulesView(session: session) }
        }
    }

    private func rulesDetail(_ count: Int) -> String {
        switch count {
        case 0: "None yet. When you move a message and choose to always move that sender's mail, it shows here."
        case 1: "1 sender's new mail goes straight to a folder."
        default: "\(count) senders' new mail goes straight to a folder."
        }
    }
}

/// The rules under their folders: tap a folder to see its senders, each with a way to stop.
private struct SenderRulesView: View {
    let session: MailSession
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let groups = session.swipeFiling.rulesByFolder(session.folders)
        List {
            if groups.isEmpty {
                Text("No sender rules yet.").dsFont(.sm).foregroundStyle(.textMuted)
            }
            ForEach(groups, id: \.folder?.id) { group in
                NavigationLink {
                    FolderRulesView(session: session, folderID: group.folder?.id)
                } label: {
                    HStack(spacing: Space.s3) {
                        Icon.folder.image(16).foregroundStyle(.textMuted)
                        Text(group.folder?.name ?? "Deleted folders").dsFont(.md).foregroundStyle(.textBody)
                        Spacer(minLength: 0)
                        Text("\(group.rules.count)").dsFont(.sm).foregroundStyle(.textMuted)
                    }
                }
            }
        }
        .navigationTitle("Sender rules")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
        }
    }
}

/// One folder's senders. Removing one stops filing their new mail; nothing already filed moves.
private struct FolderRulesView: View {
    let session: MailSession
    /// Nil is the rules whose folder was deleted.
    let folderID: String?

    var body: some View {
        let group = session.swipeFiling.rulesByFolder(session.folders).first { $0.folder?.id == folderID }
        List {
            Section {
                ForEach(group?.rules ?? [], id: \.sender) { rule in
                    HStack(spacing: Space.s3) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(session.name(for: rule.sender)).dsFont(.md).foregroundStyle(.textBody).lineLimit(1)
                            if session.name(for: rule.sender) != rule.sender {
                                Text(rule.sender).dsFont(.sm).foregroundStyle(.textMuted).lineLimit(1)
                            }
                        }
                        Spacer(minLength: 0)
                        ConfirmTrashButton(label: "Stop filing mail from \(rule.sender)", size: .sm) {
                            Task { await session.removeFilingRule(rule.sender) }
                        }
                    }
                }
            } footer: {
                Text(
                    folderID == nil
                        ? "These folders were deleted, so nothing is filed for these senders. Removing them tidies up."
                        : "Removing a sender stops filing their new mail here. Mail already here stays."
                )
            }
        }
        .navigationTitle(group?.folder?.name ?? "Deleted folders")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct AccountTab: View {
    @Environment(AppModel.self) private var model
    let session: MailSession
    @State private var showingAcknowledgements = false

    var body: some View {
        Text("Manage your identity and session on this device.").dsFont(.md).foregroundStyle(.textMuted)
        if let usage = session.storageUsage {
            SectionHeading(title: "Storage")
            SettingsCard {
                SettingsRow(
                    title: "\(MailView.formatBytes(usage.usedBytes)) used",
                    detail: usage.quotaBytes > 0
                        ? "Of \(MailView.formatBytes(usage.quotaBytes))." : "No limit on this server."
                ) { EmptyView() }
            }
        }
        SectionHeading(title: "Mailbox")
        SettingsCard {
            SettingsRow(title: "Signed in as", detail: "This identity signs and decrypts your mail.", stacked: true) {
                HStack(spacing: Space.s2) {
                    Text(session.address).dsMono(.sm).foregroundStyle(.textBody).lineLimit(1).textSelection(.enabled)
                    DSIconButton(.copy, label: "Copy your address", size: .sm) {
                        UIPasteboard.general.string = session.address
                    }
                }
            }
            SettingsRow(
                title: "Keep deleted mail",
                detail:
                    "Deleted messages wait in Deleted for this long, where you can restore them, and are then deleted for good. Synced across your devices.",
                stacked: true
            ) {
                Picker(
                    "Keep deleted mail for",
                    selection: Binding(
                        get: { session.trashDays },
                        set: { days in Task { await session.setTrashDays(days) } })
                ) {
                    ForEach(1...7, id: \.self) { days in
                        Text(days == 1 ? "1 day" : "\(days) days").tag(days)
                    }
                }
                .tint(.textBody)
            }
            SettingsRow(
                title: "Sign out",
                detail: "Locks this account on this device and ends the session. It stays available to unlock again.",
                stacked: true
            ) {
                DSButton("Sign out", icon: .logOut, variant: .danger, size: .sm) {
                    Task { await model.signOut() }
                }
            }
            SettingsRow(title: "Acknowledgements", detail: "Open-source software in this app.", stacked: true) {
                DSButton("View", variant: .secondary, size: .sm) { showingAcknowledgements = true }
            }
        }
        .sheet(isPresented: $showingAcknowledgements) {
            NavigationStack { AcknowledgementsView() }
        }
    }
}
