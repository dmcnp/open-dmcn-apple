import DMCNKit
import SwiftUI

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
        .overlay(alignment: .bottomLeading) {
            if let notice = session.undoNotice {
                UndoBanner(session: session, notice: notice)
                    // Clear of the compose button while the list shows.
                    .padding(.trailing, session.openMessage == nil ? 88 : Space.s4)
                    .padding(.leading, Space.s4)
                    .padding(.bottom, Space.s5 + 4)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(Motion.normal, value: session.openMessage?.id)
        .animation(Motion.normal, value: session.undoNotice?.id)
        // Here rather than on the list: the open message files too. Hung on an empty view of its own
        // so its plain text colour doesn't reach anything else.
        .background { FilingQuestion(session: session).tint(.textStrong) }
    }
}

struct MailList: View {
    let session: MailSession
    @State private var folderFor: MailSession.FilingTarget?
    @State private var labelFor: MailSession.FilingTarget?

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
                        MailRowView(row: row, caution: session.filedByAddressOnly(row))
                            .contentShape(Rectangle())
                            .onTapGesture { session.open(row) }
                            .plainRow()
                            .swipeActions(edge: .leading, allowsFullSwipe: true) { sortButtons(row) }
                            // No full swipe in Deleted: from there, Delete is for good.
                            .swipeActions(edge: .trailing, allowsFullSwipe: !row.inDeleted) { tidyButtons(row) }
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(.surfacePage)
            .refreshable { await session.refresh() }
        }
        .modifier(FilingSheets(session: session, folderFor: $folderFor, labelFor: $labelFor))
    }

    /// Swipe right: Folder, then Label. A full swipe takes the first, so it opens the folder list.
    @ViewBuilder private func sortButtons(_ row: MailRow) -> some View {
        if session.canFile(row) {
            swipeButton("Folder", icon: .folder, tint: .brand) { folderFor = .init(row) }
        }
        if session.canLabel(row) {
            swipeButton("Label", icon: .tag, tint: .info) { labelFor = .init(row) }
        }
    }

    /// Swipe left. The system puts the first button at the edge, and a full swipe takes it: Delete,
    /// or Archive for those who chose it. Deleted mail offers a permanent delete and Restore.
    @ViewBuilder private func tidyButtons(_ row: MailRow) -> some View {
        if row.inDeleted {
            swipeButton("Delete forever", icon: .trash, tint: .danger, role: .destructive) {
                session.deleteForever(row)
            }
            swipeButton("Restore", icon: .undo, tint: .textMuted) { session.restore(row) }
        } else if row.isSent {
            deleteButton(row)
        } else if session.swipeFiling.fullSwipeArchives {
            archiveButton(row)
            deleteButton(row)
        } else {
            deleteButton(row)
            archiveButton(row)
        }
    }

    private func deleteButton(_ row: MailRow) -> some View {
        swipeButton("Delete", icon: .trash, tint: .danger, role: .destructive) { session.trash(row) }
    }

    private func archiveButton(_ row: MailRow) -> some View {
        swipeButton(row.inArchive ? "Unarchive" : "Archive", icon: .archive, tint: .textMuted) {
            session.toggleArchive(row)
        }
    }

    private func swipeButton(
        _ title: String, icon: Icon, tint: Color, role: ButtonRole? = nil, action: @escaping () -> Void
    ) -> some View {
        Button(role: role, action: action) {
            Label {
                Text(title)
            } icon: {
                icon.image(20)
            }
        }
        .tint(tint)
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

/// "Move mail from Ada to Projects?" An alert, not a confirmation dialog: on a phone that shows as a
/// popover, which hides Cancel.
private struct FilingQuestion: View {
    let session: MailSession

    var body: some View {
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
}

/// "Moved to Deleted · Undo", for a few seconds after deleting or archiving.
private struct UndoBanner: View {
    let session: MailSession
    let notice: MailSession.UndoNotice

    var body: some View {
        HStack(spacing: Space.s3) {
            Text(notice.text)
                .dsFont(.md, .medium)
                .foregroundStyle(.surfaceCard)
                .lineLimit(1)
            Spacer(minLength: 0)
            Button {
                session.undo(notice)
            } label: {
                Text("Undo")
                    .dsFont(.md, .semibold)
                    .foregroundStyle(.surfaceCard)
                    .padding(.horizontal, Space.s2)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, Space.s4)
        .padding(.trailing, Space.s2)
        .frame(minHeight: 48)
        .background(.textStrong, in: .dsCard)
        .dsShadow()
        .task(id: notice.id) {
            try? await Task.sleep(for: .seconds(6))
            session.dismissUndo(notice)
        }
    }
}

/// The folder and label pickers, for the list's swipe and the open message alike.
struct FilingSheets: ViewModifier {
    let session: MailSession
    @Binding var folderFor: MailSession.FilingTarget?
    @Binding var labelFor: MailSession.FilingTarget?
    /// What was chosen, acted on once the sheet is gone so the follow-up question can show.
    @State private var chosen: (target: MailSession.FilingTarget, choice: FolderPicker.Choice)?

    func body(content: Content) -> some View {
        content
            .sheet(
                item: $folderFor,
                onDismiss: {
                    guard let chosen else { return }
                    self.chosen = nil
                    switch chosen.choice {
                    case .folder(let id): session.file(chosen.target, in: id)
                    case .new(let name): Task { await session.createFolder(name: name, andFile: chosen.target) }
                    }
                }
            ) { target in
                let choices = session.filingChoices(for: target)
                FolderPicker(includeInbox: choices.includeInbox, folders: choices.folders) { choice in
                    chosen = (target, choice)
                    folderFor = nil
                }
                .presentationDetents([.medium, .large])
            }
            .sheet(item: $labelFor) { target in
                LabelPicker(session: session, target: target)
                    .presentationDetents([.medium, .large])
            }
    }
}

/// Every folder, and the Inbox to put something back, with a way to make a new folder on the spot.
struct FolderPicker: View {
    enum Choice {
        /// Nil is the Inbox.
        case folder(String?)
        case new(String)
    }

    let includeInbox: Bool
    let folders: [FolderDef]
    let pick: (Choice) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var naming = false
    @State private var name = ""
    @FocusState private var nameFocused: Bool

    private var trimmed: String { name.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        NavigationStack {
            List {
                if naming {
                    Section {
                        HStack(spacing: Space.s3) {
                            Icon.folder.image(18).foregroundStyle(.textMuted)
                            TextField("New folder name", text: $name)
                                .focused($nameFocused)
                                .submitLabel(.done)
                                .onSubmit(create)
                            Button("Create", action: create)
                                .disabled(trimmed.isEmpty)
                        }
                    }
                }
                Section {
                    if includeInbox {
                        choice(icon: .inbox, name: "Inbox") { pick(.folder(nil)) }
                    }
                    ForEach(folders, id: \.id) { folder in
                        choice(icon: .folder, name: folder.name) { pick(.folder(folder.id)) }
                    }
                }
            }
            .navigationTitle("Move to folder")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        naming = true
                        nameFocused = true
                    } label: {
                        Label("New folder", systemImage: "folder.badge.plus")
                    }
                }
            }
        }
    }

    private func create() {
        guard !trimmed.isEmpty else { return }
        pick(.new(trimmed))
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

/// Every label, ticked where the message has it. A tap puts it on or takes it off; the sheet stays
/// open for the next.
struct LabelPicker: View {
    let session: MailSession
    let target: MailSession.FilingTarget
    @Environment(\.dismiss) private var dismiss
    @State private var naming = false
    @State private var name = ""
    @State private var color = LabelColor.choices[0]
    @FocusState private var nameFocused: Bool

    private var trimmed: String { name.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        let applied = session.labelIDs(of: target)
        NavigationStack {
            List {
                if naming {
                    Section {
                        TextField("New label name", text: $name)
                            .focused($nameFocused)
                            .submitLabel(.done)
                            .onSubmit(create)
                        ColorSwatches(selected: $color)
                        Button("Create", action: create)
                            .disabled(trimmed.isEmpty)
                    }
                }
                Section {
                    if session.labels.isEmpty, !naming {
                        Text("No labels yet. Make one with the button above.")
                            .dsFont(.sm)
                            .foregroundStyle(.textMuted)
                    }
                    ForEach(session.labels, id: \.id) { label in
                        Button {
                            session.toggleLabel(label.id, on: target)
                        } label: {
                            HStack(spacing: Space.s3) {
                                Circle().fill(LabelColor.color(label.color)).frame(width: 12, height: 12)
                                Text(label.name).dsFont(.md).foregroundStyle(.textBody)
                                Spacer(minLength: 0)
                                if applied.contains(label.id) {
                                    Icon.check.image(16).foregroundStyle(.brand)
                                }
                            }
                        }
                        .accessibilityAddTraits(applied.contains(label.id) ? .isSelected : [])
                    }
                }
            }
            .navigationTitle("Labels")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        naming = true
                        nameFocused = true
                    } label: {
                        Label("New label", systemImage: "plus")
                    }
                }
            }
        }
    }

    private func create() {
        guard !trimmed.isEmpty else { return }
        let (name, color) = (trimmed, color)
        self.name = ""
        naming = false
        Task { await session.createLabel(name: name, color: color, andApply: target) }
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
