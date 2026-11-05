import DMCNKit
import SwiftUI

/// The rail. Everything in the scrolling part grows as the mailbox is used; what's pinned at the
/// bottom is a small fixed set that should never scroll out of reach.
struct NavRail: View {
    @Environment(AppModel.self) private var model
    let session: MailSession
    let onChoose: () -> Void
    let onSwitchAccount: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            DSButton("Compose", icon: .pencil, size: .lg, fullWidth: true) {
                session.compose()
                onChoose()
            }
            .padding(Space.s4)

            ScrollView {
                VStack(spacing: 0) {
                    if session.hasSearch { folderRow(.search, .search, "Search") }
                    folderRow(.inbox, .inbox, "Inbox", count: session.unreadCount)
                    folderRow(.star, .starred, "Starred")
                    folderRow(.send, .sent, "Sent")
                    if !session.drafts.isEmpty { folderRow(.filePen, .drafts, "Drafts", count: session.drafts.count) }
                    folderRow(.archive, .archive, "Archive")
                    if session.hasDeleted { folderRow(.trash, .deleted, "Deleted") }

                    if !session.folders.isEmpty {
                        GroupLabel(text: "Folders")
                        ForEach(session.folders, id: \.id) { folder in
                            folderRow(.folder, .folder(folder.id), folder.name)
                        }
                    }
                    if !session.labels.isEmpty {
                        GroupLabel(text: "Labels")
                        ForEach(session.labels, id: \.id) { label in
                            NavRow(
                                swatch: LabelColor.color(label.color), label: label.name,
                                active: session.section == .mail && session.folder == .label(label.id)
                            ) { choose(.label(label.id)) }
                        }
                    }
                }
            }

            VStack(spacing: 0) {
                Rectangle().fill(.borderSubtle).frame(height: 1)
                NavRow(icon: .user, label: "Switch account", action: onSwitchAccount)
                NavRow(icon: .users, label: "Contacts", active: session.section == .contacts) { go(.contacts) }
                NavRow(icon: .settings, label: "Settings", active: session.section == .settings) { go(.settings) }
                Rectangle().fill(.borderSubtle).frame(height: 1)
                NavRow(icon: .logOut, label: "Sign out") { Task { await model.signOut() } }
                Rectangle().fill(.borderSubtle).frame(height: 1)
                // "By your device", not "on" or "from": this states who does the sealing, the one
                // claim with no exception, without promising how far the encryption reaches.
                HStack(spacing: Space.s2) {
                    Icon.lock.image(16)
                    Text("Encrypted by your device").dsFont(.xs)
                    Spacer(minLength: 0)
                }
                .foregroundStyle(.textMuted)
                .padding(.vertical, Space.s3)
                .padding(.horizontal, Space.s4)
            }
        }
    }

    private func folderRow(_ icon: Icon, _ folder: MailFolder, _ label: String, count: Int? = nil) -> some View {
        NavRow(
            icon: icon, label: label, active: session.section == .mail && session.folder == folder, count: count
        ) { choose(folder) }
    }

    private func choose(_ folder: MailFolder) {
        session.select(folder)
        onChoose()
    }

    private func go(_ section: MailSession.Section) {
        session.section = section
        onChoose()
    }
}

private struct GroupLabel: View {
    let text: String

    var body: some View {
        Text(text.uppercased())
            .dsFont(.xxs, .semibold)
            .tracking(0.66)
            .foregroundStyle(.textSubtle)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(EdgeInsets(top: Space.s4, leading: Space.s4, bottom: Space.s2, trailing: Space.s4))
    }
}

/// One row in the rail. Active rows are teal on a tint, with a 2-point rule on the leading edge.
struct NavRow: View {
    var icon: Icon?
    var swatch: Color?
    let label: String
    var active = false
    var count: Int?
    let action: () -> Void

    init(
        icon: Icon? = nil, swatch: Color? = nil, label: String, active: Bool = false, count: Int? = nil,
        action: @escaping () -> Void
    ) {
        self.icon = icon
        self.swatch = swatch
        self.label = label
        self.active = active
        self.count = count
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: Space.s3) {
                if let swatch {
                    Circle().fill(swatch).frame(width: 12, height: 12)
                } else if let icon {
                    icon.image(17).foregroundStyle(active ? Color.brand : .textMuted)
                }
                Text(label)
                    .dsFont(.md, active ? .semibold : .medium)
                    .foregroundStyle(active ? Color.brandText : .textBody)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if let count, count > 0 {
                    Text(String(count)).dsFont(.xs, .semibold).foregroundStyle(active ? Color.brandText : .textMuted)
                }
            }
            .padding(.horizontal, Space.s3)
            .frame(minHeight: 36)
            .background(active ? Color.brandSubtle : .clear)
            .overlay(alignment: .leading) {
                Rectangle().fill(active ? Color.brand : .clear).frame(width: 2)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(active ? .isSelected : [])
    }
}
