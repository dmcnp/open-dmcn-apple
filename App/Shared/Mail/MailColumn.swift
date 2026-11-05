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
        .animation(Motion.normal, value: session.openMessage?.id)
    }
}

struct MailList: View {
    let session: MailSession

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
                        MailRowView(row: row)
                            .contentShape(Rectangle())
                            .onTapGesture { session.open(row) }
                            .plainRow()
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) { swipeButtons(row) }
                    }
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(.surfacePage)
            .refreshable { await session.refresh() }
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

    /// Deleted mail offers Restore and a permanent delete; everything else, Archive and Delete.
    @ViewBuilder private func swipeButtons(_ row: MailRow) -> some View {
        if row.inDeleted {
            Button(role: .destructive) {
                session.deleteForever(row)
            } label: {
                Label {
                    Text("Delete forever")
                } icon: {
                    Icon.trash.image(20)
                }
            }
            .tint(.danger)
            Button {
                session.restore(row)
            } label: {
                Label {
                    Text("Restore")
                } icon: {
                    Icon.undo.image(20)
                }
            }
            .tint(.textMuted)
        } else {
            Button(role: .destructive) {
                session.trash(row)
            } label: {
                Label {
                    Text("Delete")
                } icon: {
                    Icon.trash.image(20)
                }
            }
            .tint(.danger)
            if !row.isSent {
                Button {
                    session.toggleArchive(row)
                } label: {
                    Label {
                        Text(row.inArchive ? "Unarchive" : "Archive")
                    } icon: {
                        Icon.archive.image(20)
                    }
                }
                .tint(.textMuted)
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
                if row.isNewSender { SmallTag(text: "NEW", weight: .semibold) }
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
