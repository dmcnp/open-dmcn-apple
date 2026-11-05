import DMCNKit
import SwiftUI

/// The address book, one contact per full-width row.
struct ContactsView: View {
    let session: MailSession
    @State private var query = ""
    @State private var searching = false
    @State private var editing: ContactEdit?

    private var shown: [ContactRecord] { session.contacts(matching: query) }
    private var count: String {
        let people = session.allContacts.count == 1 ? "person" : "people"
        return query.isEmpty
            ? "\(session.allContacts.count) \(people)" : "\(shown.count) of \(session.allContacts.count) \(people)"
    }

    var body: some View {
        VStack(spacing: 0) {
            PageHeader(title: "Contacts", count: count, onBack: { session.section = .mail }) {
                HStack(spacing: Space.s1) {
                    DSIconButton(.search, label: "Search", variant: searching || !query.isEmpty ? .active : .plain) {
                        searching.toggle()
                    }
                    DSIconButton(.plus, label: "Add contact", variant: .solid) {
                        editing = ContactEdit(typed: query)
                    }
                }
            }
            if searching {
                DSTextField(
                    placeholder: "Search contacts", text: $query, leading: .search, capitalization: .never,
                    autocorrect: false
                )
                .padding(Space.s3)
                .background(.surfaceCard)
            }
            ScrollView {
                Group {
                    if shown.isEmpty {
                        EmptyState(
                            icon: .users,
                            text: query.isEmpty
                                ? "No contacts yet. Add someone to start an encrypted thread."
                                : "No contacts match your search.")
                    } else {
                        LazyVStack(spacing: 0) {
                            ForEach(shown, id: \.address) { contact in
                                row(contact)
                                if contact.address != shown.last?.address {
                                    Rectangle().fill(.borderSubtle).frame(height: 1)
                                }
                            }
                        }
                        .background(.surfaceCard)
                        .dsBorder()
                    }
                }
                .padding(Space.s4)
            }
            .background(.surfacePage)
        }
        .sheet(item: $editing) { edit in
            ContactEditor(session: session, edit: edit).presentationDetents([.medium, .large])
        }
    }

    private func row(_ contact: ContactRecord) -> some View {
        let label = session.name(for: contact.address)
        return HStack(spacing: Space.s3) {
            KindIcon(kind: session.kind(of: contact), size: 16)
            if !session.hasPinnedKey(contact) {
                Icon.shieldOff.image(14)
                    .foregroundStyle(.textSubtle)
                    .accessibilityHidden(false)
                    .accessibilityLabel(
                        "No key pinned yet. A key change for this contact would not be detected. Pins itself the next time you read a message from them or address one to them."
                    )
            }
            VStack(alignment: .leading, spacing: 0) {
                Text(label).dsFont(.md, .semibold).foregroundStyle(.textStrong).lineLimit(1)
                if label != contact.address {
                    Text(contact.address).dsFont(.sm).foregroundStyle(.textMuted).lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            DSIconButton(.pencil, label: "Edit \(label)", size: .sm) { editing = ContactEdit(contact: contact) }
            ConfirmTrashButton(label: "Remove \(label)", size: .sm) { session.removeContact(contact) }
        }
        .padding(.vertical, Space.s3)
        .padding(.horizontal, Space.s4)
    }
}

/// What the contact sheet is open on: someone existing, or the start of someone new.
struct ContactEdit: Identifiable {
    let id = UUID()
    var contact: ContactRecord?
    var address = ""
    var name = ""

    init(contact: ContactRecord) {
        self.contact = contact
        self.address = contact.address
        self.name = contact.name == contact.address ? "" : contact.name
    }

    /// Whatever was typed into the search starts the new contact.
    init(typed: String) {
        let text = typed.trimmingCharacters(in: .whitespaces)
        if text.contains("@") { address = text } else { name = text }
    }
}

private struct ContactEditor: View {
    @Environment(\.dismiss) private var dismiss
    let session: MailSession
    @State var edit: ContactEdit
    @State private var error: String?
    @State private var legacyPrompt = false
    @State private var working = false

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s4) {
            Text(edit.contact == nil ? "Add contact" : "Edit contact").dsTitle(.lg)
            if let contact = edit.contact {
                VStack(alignment: .leading, spacing: Space.s2) {
                    HStack(spacing: Space.s2) {
                        KindIcon(kind: session.kind(of: contact), size: 16)
                        Text(contact.address).dsFont(.md).foregroundStyle(.textStrong).lineLimit(1)
                    }
                    if !contact.fingerprint.isEmpty {
                        Text(contact.fingerprint).dsMono(.xs).foregroundStyle(.textSubtle)
                    }
                }
            } else {
                DSTextField(
                    "Email address", placeholder: "name@example.org", text: $edit.address, error: error,
                    keyboard: .emailAddress, contentType: .emailAddress, capitalization: .never,
                    autocorrect: false
                )
                .onChange(of: edit.address) { legacyPrompt = false }
            }
            DSTextField("Name", placeholder: "Bob Vos", text: $edit.name, capitalization: .words)
            Text(
                legacyPrompt
                    ? "No DMCN identity is published for this address. Add it as a legacy email contact. Mail to it is delivered over a bridge and cannot be end-to-end encrypted."
                    : "The name you set here is what this app shows for this address everywhere: inbox, message headers and compose."
            )
            .dsFont(.sm)
            .foregroundStyle(.textMuted)
            HStack(spacing: Space.s2) {
                DSButton("Cancel", variant: .secondary) { dismiss() }
                DSButton(buttonTitle) { save() }
                    .disabled(working || edit.address.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            Spacer(minLength: 0)
        }
        .padding(Space.s4)
        .background(.surfacePage)
    }

    private var buttonTitle: String {
        if edit.contact != nil { return working ? "Saving…" : "Save" }
        return working ? "Adding…" : legacyPrompt ? "Add as legacy contact" : "Add contact"
    }

    private func save() {
        working = true
        error = nil
        Task {
            do {
                switch try await session.saveContact(
                    existing: edit.contact, address: edit.address, name: edit.name, asLegacy: legacyPrompt)
                {
                case .saved: dismiss()
                case .noIdentity: legacyPrompt = true
                }
            } catch {
                self.error = error.localizedDescription
            }
            working = false
        }
    }
}
