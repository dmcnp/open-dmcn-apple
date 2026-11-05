import DMCNKit
import SwiftUI

/// The composer: a full-screen sheet, as on a phone on the web. Closing saves a draft.
struct ComposeView: View {
    @Environment(\.dismiss) private var dismiss
    let session: MailSession
    @Bindable var compose: ComposeModel
    @State private var showCcBcc = false
    @State private var picking = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(compose.title).dsFont(.md, .semibold)
                Spacer(minLength: 0)
                Button {
                    Task {
                        await compose.putAway()
                        dismiss()
                    }
                } label: {
                    Icon.x.image(18).frame(width: 30, height: 30).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close")
            }
            .foregroundStyle(Color(red: 0xFB / 255, green: 0xFC / 255, blue: 0xFC / 255))
            .padding(.vertical, Space.s2)
            .padding(.horizontal, Space.s4)
            .background(Color(red: 0x16 / 255, green: 0x1B / 255, blue: 0x1B / 255), ignoresSafeAreaEdges: [])

            RecipientField(label: "To", placeholder: "Add recipient", field: compose.to, compose: compose) {
                if !showCcBcc && compose.cc.recipients.isEmpty && compose.bcc.recipients.isEmpty {
                    Button("Cc/Bcc") { showCcBcc = true }
                        .buttonStyle(.plain)
                        .dsFont(.sm)
                        .foregroundStyle(.textMuted)
                }
            }
            if showCcBcc || !compose.cc.recipients.isEmpty || !compose.bcc.recipients.isEmpty {
                RecipientField(label: "Cc", placeholder: "Carbon copy", field: compose.cc, compose: compose) {
                    EmptyView()
                }
                RecipientField(
                    label: "Bcc", placeholder: "Blind carbon copy, hidden from other recipients", field: compose.bcc,
                    compose: compose
                ) { EmptyView() }
            }

            TextField("", text: $compose.subject, prompt: Text("Subject").foregroundStyle(.textSubtle))
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.textStrong)
                .padding(.vertical, Space.s3)
                .padding(.horizontal, Space.s4)
                .overlay(alignment: .bottom) { Rectangle().fill(.borderSubtle).frame(height: 1) }

            ZStack(alignment: .topLeading) {
                TextEditor(text: $compose.body)
                    .font(.system(size: 16))
                    .foregroundStyle(.textBody)
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, Space.s3)
                    .padding(.vertical, Space.s2)
                if compose.body.isEmpty {
                    Text("Write something. It's encrypted before it leaves your device.")
                        .font(.system(size: 16))
                        .foregroundStyle(.textSubtle)
                        .padding(.horizontal, Space.s4)
                        .padding(.vertical, Space.s4)
                        .allowsHitTesting(false)
                }
            }

            if !compose.attachments.isEmpty {
                FlowRow {
                    ForEach(compose.attachments, id: \.attachmentID) { attachment in
                        DSTag(
                            "\(attachment.filename) · \(MailView.formatBytes(attachment.sizeBytes))",
                            onRemove: { compose.remove(attachment) }
                        ) {
                            Icon.paperclip.image(13).foregroundStyle(.textMuted)
                        }
                    }
                }
                .padding(.vertical, Space.s2)
                .padding(.horizontal, Space.s4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .top) { Rectangle().fill(.borderSubtle).frame(height: 1) }
            }

            ForEach(compose.notices, id: \.text) { notice in
                HStack(alignment: .top, spacing: Space.s2) {
                    (notice.warning ? Icon.alertTriangle : .shieldCheck).image(15)
                        .foregroundStyle(notice.warning ? Color.warning : .brand)
                        .padding(.top, 1)
                    Text(notice.text).dsFont(.sm).foregroundStyle(.textBody)
                    Spacer(minLength: 0)
                }
                .padding(.vertical, Space.s2)
                .padding(.horizontal, Space.s4)
                .background(notice.warning ? Color.warningSubtle : .brandSubtle)
            }

            if let error = compose.error {
                Text(error)
                    .dsFont(.sm)
                    .foregroundStyle(.danger)
                    .padding(.vertical, Space.s2)
                    .padding(.horizontal, Space.s4)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let report = compose.sentReport {
                sentPanel(report)
            } else {
                sendBar
            }
        }
        .background(.surfaceCard)
        .task { await compose.reviewRecipients() }
        .fileImporter(isPresented: $picking, allowedContentTypes: [.data], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result {
                compose.add(urls.compactMap(PickedFile.init).map { ($0.name, $0.data) })
            }
        }
    }

    private var sendBar: some View {
        HStack(spacing: Space.s2) {
            DSButton(compose.isSending ? "Sending…" : "Send", icon: .send) {
                Task { await compose.send() }
            }
            .disabled(compose.isSending || !compose.canSend)
            DSIconButton(.paperclip, label: "Attach a file") { picking = true }
            Spacer(minLength: 0)
            ConfirmTrashButton(label: "Discard draft") {
                Task {
                    await compose.discard()
                    dismiss()
                }
            }
        }
        .padding(.vertical, Space.s2)
        .padding(.horizontal, Space.s4)
        .overlay(alignment: .top) { Rectangle().fill(.borderSubtle).frame(height: 1) }
    }

    private func sentPanel(_ report: [SentReport.Item]) -> some View {
        VStack(alignment: .leading, spacing: Space.s2) {
            HStack(spacing: Space.s2) {
                Icon.check.image(15).foregroundStyle(.brand)
                Text("Sent.").dsFont(.sm, .semibold)
            }
            ForEach(report, id: \.text) { line in
                FlowRow {
                    Text(line.text).dsFont(.sm)
                    if let offer = line.saveContact {
                        if compose.savedContacts.contains(offer.address.lowercased()) {
                            Text(SentReport.addedToContacts).dsFont(.sm).foregroundStyle(.textMuted)
                        } else {
                            DSButton("Add to contacts", variant: .secondary, size: .sm) {
                                Task { await compose.saveContact(offer) }
                            }
                        }
                    }
                }
                .padding(.leading, 23)
            }
            DSButton("Done", variant: .secondary, size: .sm) { dismiss() }
        }
        .foregroundStyle(.textBody)
        .padding(.vertical, Space.s3)
        .padding(.horizontal, Space.s4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.brandSubtle)
        .task {
            guard report.isEmpty else { return }
            try? await Task.sleep(for: .seconds(1))
            dismiss()
        }
    }
}

/// A line of recipient chips with the field that adds to it. A chip wears its counterparty's
/// kind, and whatever's typed is matched against the contacts as you go.
private struct RecipientField<Trailing: View>: View {
    let label: String
    let placeholder: String
    @Bindable var field: RecipientList
    let compose: ComposeModel
    @ViewBuilder var trailing: Trailing

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: Space.s2) {
                Text(label).dsFont(.sm).foregroundStyle(.textMuted).frame(minWidth: 26, alignment: .leading).padding(
                    .top, 6)
                FlowRow(spacing: Space.s1, lineSpacing: Space.s1) {
                    ForEach(field.recipients, id: \.self) { address in
                        DSTag(compose.name(for: address), onRemove: { field.remove(address) }) {
                            KindIcon(kind: compose.kind(of: address), trusted: compose.isTrusted(address), size: 13)
                        }
                    }
                    TextField(
                        "", text: $field.pending,
                        prompt: Text(field.recipients.isEmpty ? placeholder : "Add recipient").foregroundStyle(
                            .textSubtle)
                    )
                    .font(.system(size: 16))
                    .foregroundStyle(.textStrong)
                    .keyboardType(.emailAddress)
                    .textContentType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .frame(minWidth: 180)
                    .padding(.vertical, Space.s1)
                    .onSubmit { field.commit() }
                    .onChange(of: field.pending) { _, text in
                        if text.hasSuffix(",") || text.hasSuffix(" ") { field.commit() }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                trailing.padding(.top, 6)
            }
            .padding(.vertical, Space.s2)
            .padding(.horizontal, Space.s4)
            ForEach(compose.suggestions(for: field.pending), id: \.address) { contact in
                Button {
                    field.pick(contact.address)
                } label: {
                    HStack(spacing: Space.s2) {
                        KindIcon(kind: compose.kind(of: contact.address), trusted: true)
                        Text(contact.name).dsFont(.sm, .medium).foregroundStyle(.textStrong)
                        Text(contact.address).dsFont(.sm).foregroundStyle(.textMuted).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, Space.s2)
                    .padding(.horizontal, Space.s4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .overlay(alignment: .bottom) { Rectangle().fill(.borderSubtle).frame(height: 1) }
    }
}
