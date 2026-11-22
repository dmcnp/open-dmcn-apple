import DMCNKit
import SwiftUI
import UniformTypeIdentifiers

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

                    // Press and hold a folder or label to drag it into a new order.
                    if !session.folders.isEmpty {
                        GroupLabel(text: "Folders")
                        ReorderableRows(ids: session.folders.map(\.id), onReorder: session.reorderFolders) { id in
                            if let folder = session.folders.first(where: { $0.id == id }) {
                                folderRow(.folder, .folder(folder.id), folder.name)
                            }
                        }
                    }
                    if !session.labels.isEmpty {
                        GroupLabel(text: "Labels")
                        ReorderableRows(ids: session.labels.map(\.id), onReorder: session.reorderLabels) { id in
                            if let label = session.labels.first(where: { $0.id == id }) {
                                NavRow(
                                    swatch: LabelColor.color(label.color), label: label.name,
                                    active: session.section == .mail && session.folder == .label(label.id)
                                ) { choose(.label(label.id)) }
                            }
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

/// Rows the owner can put in a new order: press and hold one, drag it up or down, and the others
/// make way as it passes. The new order is handed over once the row is let go, wherever that is.
struct ReorderableRows<Row: View>: View {
    let ids: [String]
    let onReorder: ([String]) -> Void
    @ViewBuilder let row: (String) -> Row

    /// The order while a drag is under way, nil otherwise.
    @State private var draft: [String]?
    @State private var dragging: String?

    var body: some View {
        ForEach(draft ?? ids, id: \.self) { id in
            row(id)
                .contentShape(Rectangle())
                .opacity(dragging == id ? 0.35 : 1)
                .onDrag {
                    draft = ids
                    dragging = id
                    return DragToken(id) { finish() }
                } preview: {
                    row(id).frame(width: 240).background(.surfaceCard, in: .dsCard)
                }
                .onDrop(
                    of: [.text],
                    delegate: RowDrop(target: id, draft: $draft, dragging: dragging, finish: finish))
        }
    }

    /// Ends the drag once: a drop on a row ends it at once, a drop anywhere else when the system
    /// lets go of the dragged item.
    private func finish() {
        guard dragging != nil else { return }
        let order = draft
        dragging = nil
        if let order, order != ids { onReorder(order) }
        draft = nil
    }
}

/// What a drag carries: the row's id, and a call back for when the drag is over. The system lets
/// go of it then, whether the row was dropped on a row or not.
private final class DragToken: NSItemProvider, @unchecked Sendable {
    private let onEnd: @MainActor () -> Void

    init(_ id: String, onEnd: @escaping @MainActor () -> Void) {
        self.onEnd = onEnd
        super.init()
        registerObject(id as NSString, visibility: .ownProcess)
    }

    deinit {
        let onEnd = onEnd
        Task { @MainActor in onEnd() }
    }
}

/// A row the dragged row passes over: the dragged row takes its place, and the rest shift.
private struct RowDrop: DropDelegate {
    let target: String
    @Binding var draft: [String]?
    let dragging: String?
    let finish: () -> Void

    func dropEntered(info: DropInfo) {
        guard let dragging, dragging != target, var order = draft,
            let from = order.firstIndex(of: dragging), let to = order.firstIndex(of: target)
        else { return }
        order.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
        withAnimation(Motion.normal) { draft = order }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        finish()
        return true
    }
}
