import DMCNKit
import SwiftUI
import UIKit

/// The main column in the mail section: the list for the chosen view, or the open message.
struct MailColumn: View {
    let session: MailSession

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            if let open = session.openMessage {
                MessageReader(session: session, reader: open)
                    .id(open.id)
                    .transition(.move(edge: .trailing))
            } else if session.folder == .drafts {
                DraftList(session: session)
            } else {
                MailList(session: session)
            }
            if session.openMessage == nil {
                Button {
                    session.compose()
                } label: {
                    Icon.pencil.image(22)
                        .foregroundStyle(.textOnBrand)
                        .frame(width: 56, height: 56)
                        .background(.brand, in: .dsCard)
                        .dsShadow()
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Compose")
                .padding(Space.s5)
            }
        }
        .animation(Motion.normal, value: session.openMessage?.id)
    }
}

struct MailList: View {
    let session: MailSession
    /// The row whose ⋮ swipe button opened the full folder list.
    @State private var pickingFolderFor: MailRow?
    /// What was picked there (nil folder: the Inbox), filed once the sheet is gone so the follow-up
    /// question can show.
    @State private var picked: (row: MailRow, folderID: String?)?
    /// The row with a swipe tray open, if any.
    @State private var openSwipe: OpenSwipe?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Space.s3) {
                PageTitle(title: session.folderTitle, count: session.isLocked ? nil : session.rowCountText)
                Spacer(minLength: 0)
                DSIconButton(.refresh, label: "Refresh", size: .sm) { Task { await session.refresh() } }
            }
            .padding(.horizontal, Space.s4)
            .padding(.vertical, Space.s3)
            .background(.surfaceCard)
            .overlay(alignment: .bottom) { Rectangle().fill(.borderDefault).frame(height: 1) }

            if session.folder == .deleted {
                listNote(session.deletedNote)
            }
            if let progress = session.searchProgressNote {
                listNote(progress)
            }

            List {
                if let error = session.listError {
                    Text(error)
                        .dsFont(.sm)
                        .foregroundStyle(.danger)
                        .padding(Space.s3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.dangerSubtle, in: .dsCard)
                        .padding(Space.s4)
                        .plainRow()
                }
                if session.isSorting {
                    EmptyView()
                } else if session.rows.isEmpty {
                    if !session.isLocked {
                        EmptyState(icon: session.emptyIcon.designIcon, text: session.emptyText).plainRow()
                    }
                } else {
                    ForEach(session.rows) { row in
                        swipeRow(row) {
                            MailRowView(row: row, caution: session.filedByAddressOnly(row))
                                .contentShape(Rectangle())
                                .onTapGesture { session.open(row) }
                        }
                        .plainRow()
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(.surfacePage)
            .refreshable { await session.refresh() }
            .modifier(ClosesSwipeOnScroll(open: $openSwipe))
        }
        .sheet(
            item: $pickingFolderFor,
            onDismiss: {
                if let choice = picked {
                    picked = nil
                    session.file(choice.row, in: choice.folderID)
                }
            }
        ) { row in
            FolderPicker(
                includeInbox: session.folder != .inbox,
                folders: session.folders.filter { MailFolder.folder($0.id) != session.folder }
            ) { id in
                picked = (row, id)
                pickingFolderFor = nil
            }
            .presentationDetents([.medium, .large])
        }
        // Hung on an empty view of its own so its plain text colour doesn't reach the list.
        .background { filingQuestion.tint(.textStrong) }
    }

    /// An alert, not a confirmation dialog: on a phone that shows as a popover, which hides Cancel.
    private var filingQuestion: some View {
        Color.clear.alert(
            session.filingOffer?.title ?? "",
            isPresented: Binding(
                get: { session.filingOffer != nil },
                set: { if !$0 { session.dismissFilingOffer() } }),
            presenting: session.filingOffer
        ) { offer in
            Button(offer.answer) {
                Task { await session.acceptFilingOffer(offer) }
            }
            Button("Just this one") { session.fileOnlyThis(offer) }
            Button("Cancel", role: .cancel) {}
        } message: { offer in
            Text(offer.summary)
        }
    }

    /// Both swipes: right files the row, left archives or deletes it. Drawn by hand on iOS 18, so
    /// four folders and ⋮ fit and both sides look alike. iOS 17 gets the system's swipes, whose
    /// buttons are wide, so only two folders fit beside ⋮ there.
    @ViewBuilder private func swipeRow(_ row: MailRow, @ViewBuilder content: () -> some View) -> some View {
        if #available(iOS 18, *) {
            SwipeRow(id: row.id, open: $openSwipe, leading: fileActions(row), trailing: tidyActions(row)) {
                content()
            }
        } else {
            content()
                .swipeActions(edge: .leading, allowsFullSwipe: false) {
                    systemButtons(fileActions(row, folderLimit: 2))
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    // The system puts its first button at the edge; the tray lists them left to right.
                    systemButtons(tidyActions(row).reversed())
                }
        }
    }

    /// One button per folder slot, then ⋮ for every other folder and the Inbox. The folder already
    /// being shown is left out, since filing there would do nothing.
    private func fileActions(_ row: MailRow, folderLimit: Int = .max) -> [SwipeAction] {
        guard session.canSwipeToFile, !row.isSent, !row.inDeleted else { return [] }
        let folders = session.swipeFolders.filter { MailFolder.folder($0.id) != session.folder }
        let buttons = folders.prefix(folderLimit).enumerated().map { index, folder in
            SwipeAction(
                id: folder.id, label: folder.name, spoken: "Move to \(folder.name)", icon: .folder,
                color: SwipeAction.folderColor(index)
            ) { session.file(row, in: folder.id) }
        }
        let more = SwipeAction(
            id: "more", label: "More", spoken: "More folders", icon: .moreVertical, color: .textMuted, narrow: true
        ) { pickingFolderFor = row }
        return buttons + [more]
    }

    /// Left to right. Deleted mail offers Restore and a permanent delete; everything else, Archive
    /// (not for sent mail) and Delete.
    private func tidyActions(_ row: MailRow) -> [SwipeAction] {
        if row.inDeleted {
            return [
                SwipeAction(id: "restore", label: "Restore", icon: .undo, color: .textMuted) { session.restore(row) },
                SwipeAction(id: "forever", label: "Delete forever", icon: .trash, color: .danger, destructive: true) {
                    session.deleteForever(row)
                },
            ]
        }
        let delete = SwipeAction(id: "delete", label: "Delete", icon: .trash, color: .danger, destructive: true) {
            session.trash(row)
        }
        guard !row.isSent else { return [delete] }
        let archive = SwipeAction(
            id: "archive", label: row.inArchive ? "Unarchive" : "Archive", icon: .archive, color: .textMuted
        ) { session.toggleArchive(row) }
        return [archive, delete]
    }

    /// The same actions as the system's own swipe buttons, for iOS 17.
    private func systemButtons(_ actions: [SwipeAction]) -> some View {
        ForEach(actions) { action in
            Button(role: action.destructive ? .destructive : nil, action: action.run) {
                Label {
                    Text(action.label)
                } icon: {
                    action.icon.image(20)
                }
            }
            .tint(action.color)
        }
    }

    private func listNote(_ text: String) -> some View {
        Text(text)
            .dsFont(.sm)
            .foregroundStyle(.textMuted)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Space.s4)
            .padding(.vertical, Space.s2)
            .background(.surfaceCard)
            .overlay(alignment: .bottom) { Rectangle().fill(.borderSubtle).frame(height: 1) }
    }
}

/// One button in a swipe tray.
struct SwipeAction: Identifiable {
    let id: String
    let label: String
    /// What VoiceOver says, when the label alone is too short.
    var spoken: String?
    let icon: Icon
    let color: Color
    /// Keeps a small fixed width (⋮); the other buttons share whatever is left.
    var narrow = false
    var destructive = false
    let run: () -> Void

    static func folderColor(_ index: Int) -> Color {
        LabelColor.color(LabelColor.choices[(index + 3) % LabelColor.choices.count])
    }
}

/// The row with a tray open, and which side. Shared by the list, so opening one closes the rest.
struct OpenSwipe: Equatable {
    let id: String
    let leading: Bool
}

/// A row with a tray on each side: swipe right for the leading buttons, left for the trailing ones.
/// Built by hand because the system's swipe buttons are a fixed width, so five don't fit a phone,
/// and drawn like the system's (a coloured pill, its name below) so it still feels at home.
///
/// The leading (filing) tray takes the whole row but a peek of the message, so it's clear what is
/// being filed: ⋮ keeps its small width at the far end and the folders share the rest. The trailing
/// tray is as wide as its buttons.
@available(iOS 18, *)
private struct SwipeRow<Content: View>: View {
    let id: String
    @Binding var open: OpenSwipe?
    let leading: [SwipeAction]
    let trailing: [SwipeAction]
    @ViewBuilder var content: Content

    @State private var drag: CGFloat = 0
    @State private var width: CGFloat = 0

    private var openLeading: Bool { open == OpenSwipe(id: id, leading: true) }
    private var openTrailing: Bool { open == OpenSwipe(id: id, leading: false) }

    private var leadingReveal: CGFloat {
        guard !leading.isEmpty else { return 0 }
        return max(width - SwipeMetrics.peek, SwipeMetrics.buttonWidth * CGFloat(leading.count))
    }
    private var trailingReveal: CGFloat { SwipeMetrics.buttonWidth * CGFloat(trailing.count) }
    /// Where the row rests: right for the leading tray, left for the trailing one.
    private var rest: CGFloat { openLeading ? leadingReveal : openTrailing ? -trailingReveal : 0 }

    /// Positive shows the leading tray. Past the end the row resists, the way the system's swipe does.
    private var offset: CGFloat {
        let raw = rest + drag
        if raw >= 0 {
            guard !leading.isEmpty else { return 0 }
            return raw > leadingReveal ? leadingReveal + (raw - leadingReveal) * 0.25 : raw
        }
        guard !trailing.isEmpty else { return 0 }
        return raw < -trailingReveal ? -trailingReveal + (raw + trailingReveal) * 0.25 : raw
    }

    var body: some View {
        ZStack {
            if offset > 0 {
                tray(leading, shown: offset, laidOutFor: leadingReveal)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if offset < 0 {
                tray(trailing, shown: -offset, laidOutFor: trailingReveal)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            content
                .overlay {
                    // While open, a tap on the row closes the tray instead of opening the message.
                    // Laid on before the offset so it slides with the row and leaves the buttons
                    // uncovered.
                    if open?.id == id {
                        Color.clear
                            .contentShape(Rectangle())
                            .onTapGesture { close() }
                    }
                }
                .offset(x: offset)
        }
        .clipped()
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.width
        } action: { newWidth in
            width = newWidth
        }
        .gesture(
            SwipePan(
                takesRight: open?.id == id || !leading.isEmpty,
                takesLeft: open?.id == id || !trailing.isEmpty,
                moved: dragged, released: released)
        )
        .sensoryFeedback(.selection, trigger: openLeading || openTrailing)
        .accessibilityActions {
            ForEach(leading + trailing) { action in
                Button(action.spoken ?? action.label, action: action.run)
            }
        }
    }

    /// A tray `shown` wide. The buttons are laid out for the open tray and stretch or squeeze with
    /// the drag, as the system's do.
    private func tray(_ actions: [SwipeAction], shown: CGFloat, laidOutFor reveal: CGFloat) -> some View {
        let scale = reveal > 0 ? shown / reveal : 0
        let narrow = actions.filter(\.narrow).count
        let shared = actions.count - narrow
        let each = shared > 0 ? max(0, reveal - CGFloat(narrow) * SwipeMetrics.narrowWidth) / CGFloat(shared) : 0
        return HStack(spacing: 0) {
            ForEach(actions) { action in
                SwipeButton(action: action) {
                    close()
                    action.run()
                }
                .frame(width: (action.narrow ? SwipeMetrics.narrowWidth : each) * scale)
            }
        }
        .frame(width: shown)
        .frame(maxHeight: .infinity)
        .background(.surfaceSunken)
    }

    private func dragged(_ dx: CGFloat) {
        // Starting on this row puts away a tray open on another.
        if let open, open.id != id { withAnimation(.snappy) { self.open = nil } }
        drag = dx
    }

    /// `dx` is where the drag would coast to, so a quick flick opens or shuts a tray too.
    private func released(_ dx: CGFloat) {
        let landing = rest + dx
        let far = SwipeMetrics.threshold
        // An open tray stays open unless pushed back far enough; a shut one opens once pulled far enough.
        var next: OpenSwipe?
        if landing > 0, !leading.isEmpty, openLeading ? dx > -far : landing > far {
            next = OpenSwipe(id: id, leading: true)
        } else if landing < 0, !trailing.isEmpty, openTrailing ? dx < far : landing < -far {
            next = OpenSwipe(id: id, leading: false)
        }
        withAnimation(.snappy) {
            if next != nil || open?.id == id { open = next }
            drag = 0
        }
    }

    private func close() {
        withAnimation(.snappy) {
            if open?.id == id { open = nil }
            drag = 0
        }
    }
}

/// Sizes for the swipe trays (a generic view can't hold its own constants).
private enum SwipeMetrics {
    /// How much of the message stays in view beside the open filing tray.
    static let peek: CGFloat = 64
    static let buttonWidth: CGFloat = 74
    /// The ⋮ button's width.
    static let narrowWidth: CGFloat = 56
    /// How far a drag must go, or a flick coast, before a tray opens or shuts.
    static let threshold: CGFloat = 60
}

/// Drawn like the system's swipe buttons: a coloured pill holding the icon, the name underneath.
private struct SwipeButton: View {
    let action: SwipeAction
    let tap: () -> Void

    var body: some View {
        Button(action: tap) {
            VStack(spacing: Space.s1) {
                Capsule()
                    .fill(action.color)
                    .frame(maxWidth: .infinity)
                    .frame(height: 40)
                    .overlay { action.icon.image(18).foregroundStyle(.white) }
                Text(action.label)
                    .dsFont(.xxs, .medium)
                    .foregroundStyle(.textMuted)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(action.spoken ?? action.label)
    }
}

/// The swipe's drag. A UIKit one, because UIKit asks before a drag starts whether it's wanted: only
/// a clearly sideways drag toward a tray (or toward shutting the open one) is taken, and the rest go
/// on to the list, so scrolling keeps working.
@available(iOS 18, *)
private struct SwipePan: UIGestureRecognizerRepresentable {
    let takesRight: Bool
    let takesLeft: Bool
    let moved: (CGFloat) -> Void
    let released: (CGFloat) -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator {
        Coordinator()
    }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let pan = UIPanGestureRecognizer()
        pan.delegate = context.coordinator
        return pan
    }

    func updateUIGestureRecognizer(_ recognizer: UIPanGestureRecognizer, context: Context) {
        context.coordinator.takesRight = takesRight
        context.coordinator.takesLeft = takesLeft
    }

    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
        let dx = recognizer.translation(in: recognizer.view).x
        switch recognizer.state {
        case .began, .changed:
            moved(dx)
        case .ended:
            // A short coast in the direction of travel, like SwiftUI's predicted end.
            released(dx + recognizer.velocity(in: recognizer.view).x * 0.2)
        case .cancelled, .failed:
            released(dx)
        default:
            break
        }
    }

    @MainActor final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var takesRight = false
        var takesLeft = false

        /// Asked once, as the touch starts to move: is this drag ours?
        func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
            guard let pan = recognizer as? UIPanGestureRecognizer else { return false }
            // The distance moved still reads zero here, so go by the direction the finger is heading.
            let heading = pan.velocity(in: pan.view)
            guard abs(heading.x) > abs(heading.y) * 1.5 else { return false }
            return heading.x > 0 ? takesRight : takesLeft
        }
    }
}

/// Scrolling the list puts away an open tray. The scroll phase arrived in iOS 18, the same as the
/// hand-built trays; iOS 17 uses the system's swipes, which put themselves away.
private struct ClosesSwipeOnScroll: ViewModifier {
    @Binding var open: OpenSwipe?

    func body(content: Content) -> some View {
        if #available(iOS 18, *) {
            content.onScrollPhaseChange { _, phase in
                if phase != .idle, open != nil { withAnimation(.snappy) { open = nil } }
            }
        } else {
            content
        }
    }
}

/// Every folder, for the swipe's ⋮ button, so a folder that isn't in a slot can still be reached,
/// and the Inbox, to put something back. `pick` gets nil for the Inbox.
private struct FolderPicker: View {
    let includeInbox: Bool
    let folders: [FolderDef]
    let pick: (String?) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if includeInbox {
                    choice(icon: .inbox, name: "Inbox") { pick(nil) }
                }
                ForEach(folders, id: \.id) { folder in
                    choice(icon: .folder, name: folder.name) { pick(folder.id) }
                }
            }
            .navigationTitle("Move to folder")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private func choice(icon: Icon, name: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: Space.s3) {
                icon.image(18).foregroundStyle(.textMuted)
                Text(name).dsFont(.md).foregroundStyle(.textBody)
            }
        }
    }
}

extension View {
    /// A list row with no system chrome: the row draws its own surface and rule.
    fileprivate func plainRow() -> some View {
        listRowInsets(EdgeInsets()).listRowSeparator(.hidden).listRowBackground(Color.clear)
    }
}

/// One message in a list. Two lines and a snippet, as the web's phone layout.
struct MailRowView: View {
    let row: MailRow
    /// Filed by an address nothing checked: see `MailSession.filedByAddressOnly`.
    var caution = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: Space.s2) {
                if row.isUnread {
                    Circle().fill(.brand).frame(width: 8, height: 8).accessibilityLabel("Unread")
                }
                KindIcon(kind: row.kind, trusted: row.trustedSender).padding(.trailing, 2)
                Text(row.who)
                    .dsFont(.md, row.isUnread ? .bold : .medium)
                    .foregroundStyle(.textStrong)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let deliveredTo = row.deliveredTo {
                    Text("to \(deliveredTo)")
                        .dsMono(.xs)
                        .foregroundStyle(.textMuted)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                if caution {
                    Text("UNCHECKED")
                        .dsFont(.xxs, .semibold)
                        .foregroundStyle(.danger)
                        .lineLimit(1)
                        .padding(.horizontal, 5)
                        .background(.dangerSubtle, in: .dsCard)
                        .accessibilityLabel("Filed by address only. This sender wasn't checked.")
                } else if row.isNewSender {
                    SmallTag(text: "NEW", weight: .semibold)
                }
                if row.isStarred {
                    Icon.starFill.image(14).foregroundStyle(.warning).accessibilityLabel("Starred")
                }
                Text(row.when).dsFont(.xs).foregroundStyle(.textMuted)
            }
            HStack(spacing: Space.s2) {
                if let place = row.place { SmallTag(text: place, weight: .medium) }
                Text(row.subject)
                    .dsFont(.md)
                    .foregroundStyle(.textStrong)
                    .lineLimit(1)
            }
            if let snippet = row.snippet {
                Text(snippet).dsFont(.sm).foregroundStyle(.textMuted).lineLimit(1)
            }
        }
        .padding(.horizontal, Space.s4)
        .padding(.vertical, Space.s3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.surfaceCard)
        .overlay(alignment: .bottom) { Rectangle().fill(.borderSubtle).frame(height: 1) }
    }
}

private struct SmallTag: View {
    let text: String
    let weight: Font.Weight

    var body: some View {
        Text(text)
            .dsFont(.xxs, weight)
            .foregroundStyle(.textMuted)
            .lineLimit(1)
            .padding(.horizontal, 5)
            .background(.surfaceSunken, in: .dsCard)
            .dsBorder()
    }
}

/// Which network a person is on, in one glyph. A teal shield is a DMCN identity, a blue one a
/// contact whose key still holds, and a muted envelope legacy email, which has no encryption to
/// claim however trusted the sender. An unknown kind holds the space, so rows don't shift.
struct KindIcon: View {
    let kind: SenderKind
    var trusted = false
    var size: CGFloat = 14

    var body: some View {
        switch kind {
        case .dmcn:
            Icon.shieldCheck.image(size)
                .foregroundStyle(trusted ? Color.trustContact : .trustDMCN)
                .accessibilityHidden(false)
                .accessibilityLabel(trusted ? "Trusted contact" : "DMCN identity")
        case .legacy:
            Icon.mail.image(size)
                .foregroundStyle(.textMuted)
                .accessibilityHidden(false)
                .accessibilityLabel("Legacy email")
        case .unknown:
            Color.clear.frame(width: size, height: size)
        }
    }
}

/// The saved drafts. Drafts aren't mail, so their folder is a list of its own.
struct DraftList: View {
    let session: MailSession

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Space.s3) {
                PageTitle(
                    title: "Drafts",
                    count: session.drafts.count == 1 ? "1 draft" : "\(session.drafts.count) drafts")
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Space.s4)
            .padding(.vertical, Space.s3)
            .background(.surfaceCard)
            .overlay(alignment: .bottom) { Rectangle().fill(.borderDefault).frame(height: 1) }
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(session.drafts, id: \.id) { draft in
                        HStack(alignment: .top, spacing: Space.s3) {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(alignment: .firstTextBaseline, spacing: Space.s2) {
                                    Text(session.draftRecipients(draft))
                                        .dsFont(.md, .medium)
                                        .foregroundStyle(.textStrong)
                                        .lineLimit(1)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    Text(session.draftWhen(draft)).dsFont(.xs).foregroundStyle(.textMuted)
                                }
                                Text(draft.subject.isEmpty ? "(no subject)" : draft.subject)
                                    .dsFont(.md)
                                    .foregroundStyle(.textStrong)
                                    .lineLimit(1)
                                if !draft.snippet.isEmpty {
                                    Text(draft.snippet).dsFont(.sm).foregroundStyle(.textMuted).lineLimit(1)
                                }
                            }
                            ConfirmTrashButton(label: "Discard draft", size: .sm) { session.discardDraft(draft) }
                        }
                        .padding(.horizontal, Space.s4)
                        .padding(.vertical, Space.s3)
                        .background(.surfaceCard)
                        .overlay(alignment: .bottom) { Rectangle().fill(.borderSubtle).frame(height: 1) }
                        .contentShape(Rectangle())
                        .onTapGesture { session.openDraft(draft) }
                    }
                }
            }
            .background(.surfacePage)
        }
    }
}
