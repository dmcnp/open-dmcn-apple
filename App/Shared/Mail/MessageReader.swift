import DMCNKit
import SwiftUI

/// The open message. Every decision about what may be shown is in `reader.decision`, which the
/// kit makes and tests; this file draws it and never decides anything itself.
struct MessageReader: View {
    let session: MailSession
    @Bindable var reader: ReaderModel
    @State private var confirmingHTML = false
    @State private var creating: CreateKind?
    @State private var saving: FileDocumentData?

    enum CreateKind: Identifiable {
        case label, folder
        var id: Self { self }
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            if let when = reader.deletedWhen {
                StatusStrip(
                    icon: .trash, iconColor: .textMuted,
                    text: "This message is in Deleted and will be deleted for good \(when). Restore it to keep it.")
            }
            ScrollView {
                VStack(alignment: .leading, spacing: Space.s5) {
                    Text(reader.subject)
                        .font(.system(size: TextSize.xl.rawValue, weight: .semibold))
                        .tracking(-0.42)
                        .foregroundStyle(.textStrong)
                        .textSelection(.enabled)
                    VStack(alignment: .leading, spacing: Space.s4) {
                        sender
                        filing
                        ChecksStrip(view: reader.decision.checks)
                    }
                    bodySection
                    attachments
                    actions
                    source
                }
                .padding(Space.s4)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(.surfacePage)
        }
        .gesture(backSwipe)
        .fileExporter(
            isPresented: Binding(get: { saving != nil }, set: { if !$0 { saving = nil } }), document: saving,
            contentType: .data, defaultFilename: saving?.filename
        ) { _ in }
        .task { await reader.load() }
        .sheet(item: $creating) { kind in
            CreateTagSheet(kind: kind) { name, color in
                if kind == .label {
                    await reader.createLabel(name: name, color: color)
                } else {
                    await reader.createFolder(name: name)
                }
            }
            .presentationDetents([.height(260)])
        }
    }

    /// The system back-swipe doesn't exist here: the reader replaces the list in place, as on the
    /// web. A drag from the leading edge does the same job.
    private var backSwipe: some Gesture {
        DragGesture(minimumDistance: 20).onEnded { value in
            if value.startLocation.x < 24, value.translation.width > 80 { session.closeMessage() }
        }
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: 2) {
            DSButton("Back", icon: .chevronLeft, variant: .ghost, size: .sm) { session.closeMessage() }
                .accessibilityLabel("Back to inbox")
            Spacer(minLength: 0)
            if reader.deletedWhen != nil {
                DSButton("Restore", icon: .undo, variant: .ghost, size: .sm) { reader.restore() }
                ConfirmTrashButton(label: "Delete forever") { reader.delete() }
            } else {
                labelMenu
                folderMenu
                Rectangle().fill(.borderDefault).frame(width: 1, height: 20).padding(.horizontal, 6)
                DSIconButton(
                    reader.isStarred ? .starFill : .star, label: reader.isStarred ? "Unstar" : "Star",
                    tint: reader.isStarred ? .warning : nil
                ) { reader.toggleStar() }
                if reader.canArchive {
                    DSIconButton(.archive, label: reader.isArchived ? "Unarchive" : "Archive") {
                        reader.toggleArchive()
                    }
                }
                DSIconButton(.trash, label: "Delete") { reader.delete() }
            }
        }
        .padding(.horizontal, Space.s2)
        .frame(height: 52)
        .background(.surfaceCard)
        .overlay(alignment: .bottom) { Rectangle().fill(.borderDefault).frame(height: 1) }
    }

    private var labelMenu: some View {
        Menu {
            ForEach(reader.availableLabels, id: \.id) { label in
                Button(label.name) { reader.addLabel(label.id) }
            }
            Button("New label…") { creating = .label }
        } label: {
            Icon.tag.image(18).foregroundStyle(.textMuted).frame(width: 38, height: 38).contentShape(Rectangle())
        }
        .accessibilityLabel("Add label")
    }

    private var folderMenu: some View {
        Menu {
            Button("No folder") { reader.setFolder(nil) }
            ForEach(reader.folders, id: \.id) { folder in
                Button(folder.name) { reader.setFolder(folder.id) }
            }
            Button("New folder…") { creating = .folder }
        } label: {
            Icon.folder.image(18).foregroundStyle(.textMuted).frame(width: 38, height: 38).contentShape(Rectangle())
        }
        .accessibilityLabel("Move to folder")
    }

    // MARK: Header

    private var sender: some View {
        HStack(spacing: Space.s3) {
            Text(reader.initials)
                .dsFont(.sm, .semibold)
                .foregroundStyle(.brandText)
                .frame(width: 36, height: 36)
                .background(.brandSubtle, in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                reader.isSentView ? AnyView(sentLine) : AnyView(fromLine)
                if let to = reader.toLine { peopleLine("To \(to)") }
                if let cc = reader.ccLine { peopleLine("Cc \(cc)") }
                if let bcc = reader.bccLine { peopleLine("Bcc \(bcc)") }
                peopleLine(reader.metaLine)
            }
            Spacer(minLength: 0)
            DSIconButton(.reply, label: "Reply", variant: .outline) { reader.reply(all: false) }
            if reader.canReplyAll {
                DSIconButton(.replyAll, label: "Reply all", variant: .outline) { reader.reply(all: true) }
            }
        }
    }

    private var sentLine: some View {
        HStack(spacing: Space.s1) {
            Text("To").dsFont(.base, .semibold).foregroundStyle(.textStrong)
            Text(reader.counterpartyName).dsFont(.base).foregroundStyle(.textMuted).lineLimit(1)
        }
    }

    private var fromLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.s2) {
            Text(reader.counterpartyName).dsFont(.base, .semibold).foregroundStyle(.textStrong).lineLimit(1)
            if let address = reader.counterpartyAddress {
                Text(address).dsFont(.md).foregroundStyle(.textMuted).lineLimit(1)
            }
        }
    }

    private func peopleLine(_ text: String) -> some View {
        Text(text).dsFont(.sm).foregroundStyle(.textMuted).lineLimit(1)
    }

    @ViewBuilder private var filing: some View {
        if reader.currentFolder != nil || !reader.appliedLabels.isEmpty {
            FlowRow {
                if let folder = reader.currentFolder {
                    DSTag(folder.name, onRemove: { reader.setFolder(nil) }) { Icon.folder.image(12) }
                }
                ForEach(reader.appliedLabels, id: \.id) { label in
                    DSTag(label.name, onRemove: { reader.removeLabel(label.id) }) {
                        Circle().fill(LabelColor.color(label.color)).frame(width: 8, height: 8)
                    }
                }
            }
        }
    }

    // MARK: Body

    /// Four states: not settled, hidden behind the gate, shown as plain text behind it, or the
    /// message itself.
    @ViewBuilder private var bodySection: some View {
        let decision = reader.decision
        if !decision.trustReady {
            Text("Loading…").dsFont(.base).foregroundStyle(.textMuted).frame(minHeight: 80, alignment: .top)
        } else if decision.gated && !decision.plainShown {
            GatePanel(
                icon: decision.gateReason == .blocked ? .shieldOff : .eyeOff, title: decision.gateCopy.hiddenTitle,
                detail: decision.gateCopy.hiddenDetail
            ) {
                gateActions(plain: false)
            }
        } else if decision.gated {
            VStack(alignment: .leading, spacing: 0) {
                GatePanel(
                    icon: .file, title: decision.gateCopy.plainTitle, detail: decision.gateCopy.plainDetail,
                    framed: false
                ) {
                    gateActions(plain: true)
                }
                Rectangle().fill(.borderDefault).frame(height: 1)
                bodyText.dsMono(.md).lineSpacing(5).padding(Space.s4).frame(minHeight: 120, alignment: .topLeading)
            }
            .background(.surfaceCard, in: .dsCard)
            .dsBorder(.borderDefault)
        } else if decision.htmlAllowed, reader.showHTML, let html = reader.html {
            HTMLMessageBody(
                html: html, inlineImages: reader.inlineImages, allowRemoteImages: decision.remoteImagesAllowed)
        } else {
            bodyText.dsFont(.base).lineSpacing(6).frame(minHeight: 80, alignment: .topLeading)
        }
    }

    @ViewBuilder private var bodyText: some View {
        switch reader.body {
        case .loading:
            Text("Loading…").foregroundStyle(.textMuted)
        case .failed(let reason):
            Text(reason).foregroundStyle(.danger)
        case .text(let text) where !text.isEmpty:
            Text(text).foregroundStyle(.textBody).textSelection(.enabled)
        case .text:
            Text(
                reader.html == nil
                    ? "This message has no text." : "This message has no text version. Its content is in the HTML."
            )
            .foregroundStyle(.textMuted)
        }
    }

    private func gateActions(plain: Bool) -> some View {
        let decision = reader.decision
        return VStack(alignment: .leading, spacing: Space.s2) {
            FlowRow {
                if decision.trustActionable {
                    DSButton(decision.trustLabel, icon: .check) { Task { await reader.trustSender() } }
                }
                if !plain && decision.plainTextOffered {
                    DSButton("View as plain text", variant: .secondary) { reader.reveal() }
                }
                if plain && decision.overrideActionable {
                    DSButton("View HTML anyway", variant: .secondary) { confirmingHTML.toggle() }
                }
            }
            if confirmingHTML {
                VStack(alignment: .leading, spacing: Space.s2) {
                    Text(decision.htmlWarning).dsFont(.sm).foregroundStyle(.textBody)
                    HStack(spacing: Space.s2) {
                        DSButton("Cancel", variant: .secondary, size: .sm) { confirmingHTML = false }
                        DSButton("View HTML", size: .sm) {
                            confirmingHTML = false
                            reader.trustThisMessage()
                        }
                    }
                }
                .padding(Space.s3)
                .background(.surfaceSunken, in: .dsCard)
            }
            FlowRow {
                if reader.deletedWhen == nil {
                    DSButton("Delete", icon: .trash, variant: .secondary) { reader.delete() }
                }
                if decision.gateReason != .blocked {
                    DSButton("Block sender", icon: .alertOctagon, variant: .dangerOutline) {
                        Task { await reader.blockSender() }
                    }
                }
            }
        }
        .disabled(reader.isActing)
    }

    // MARK: Attachments

    @ViewBuilder private var attachments: some View {
        if !reader.attachments.isEmpty {
            let unlocked = reader.decision.downloadsUnlocked
            VStack(alignment: .leading, spacing: Space.s2) {
                HStack(spacing: Space.s2) {
                    Icon.paperclip.image(15)
                    Text(reader.attachments.count == 1 ? "1 attachment" : "\(reader.attachments.count) attachments")
                        .dsFont(.sm, .semibold)
                }
                .foregroundStyle(.textStrong)
                if !unlocked {
                    Callout(
                        tone: .warning,
                        text:
                            "Downloads are locked because you haven't trusted this sender. Files from unknown senders can be unsafe."
                    )
                }
                ForEach(reader.attachments) { attachment in
                    HStack(spacing: Space.s3) {
                        Icon.file.image(18).foregroundStyle(.textMuted)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(attachment.name).dsFont(.sm).foregroundStyle(.textStrong).lineLimit(1)
                            Text(attachment.detail).dsFont(.sm).foregroundStyle(.textMuted).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        if unlocked || reader.acknowledged.contains(attachment.id) {
                            DSButton("Download", icon: .download, variant: .secondary, size: .sm) {
                                saving = FileDocumentData(data: attachment.data, filename: attachment.name)
                            }
                        } else {
                            DSButton("Download anyway", variant: .secondary, size: .sm) {
                                reader.acknowledged.insert(attachment.id)
                            }
                        }
                    }
                    .padding(Space.s3)
                    .background(.surfaceCard, in: .dsCard)
                    .dsBorder(.borderDefault)
                }
            }
        }
    }

    // MARK: Footer

    private var actions: some View {
        FlowRow {
            DSButton("Reply", icon: .reply, variant: .secondary) { reader.reply(all: false) }
            if reader.canReplyAll {
                DSButton("Reply all", icon: .replyAll, variant: .secondary) { reader.reply(all: true) }
            }
            if reader.canForward {
                DSButton("Forward", icon: .forward, variant: .secondary) { reader.forward() }
            }
            if reader.decision.showSource {
                DSButton(reader.showingSource ? "Hide source" : "View source", variant: .secondary) {
                    reader.showingSource.toggle()
                }
            }
            if reader.decision.htmlAllowed && !reader.decision.gated {
                DSButton(reader.showHTML ? "View plain text" : "View HTML", variant: .secondary) {
                    reader.showHTML.toggle()
                }
            }
        }
    }

    @ViewBuilder private var source: some View {
        if reader.decision.showSource, reader.showingSource, let text = reader.sourceText {
            ScrollView {
                Text(text)
                    .dsMono(.xs)
                    .foregroundStyle(.textBody)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Space.s3)
            }
            .frame(maxHeight: 480)
            .background(.surfaceSunken, in: .dsCard)
        }
    }
}

/// The panel that holds a message back, and offers the decision it needs.
private struct GatePanel<Actions: View>: View {
    let icon: Icon
    let title: String
    let detail: String
    var framed = true
    @ViewBuilder var actions: Actions

    var body: some View {
        let content = VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                icon.image(18)
                Text(title).dsFont(.lg, .semibold)
            }
            .foregroundStyle(.textStrong)
            Text(detail).dsFont(.md).foregroundStyle(.textMuted).lineSpacing(4)
            actions.padding(.top, Space.s1)
        }
        .padding(Space.s4)
        .frame(maxWidth: .infinity, alignment: .leading)
        if framed {
            content.background(.surfaceCard, in: .dsCard).dsBorder(.borderDefault)
        } else {
            content
        }
    }
}

/// Naming a label or folder in the moment it's wanted, on the message that wanted it.
private struct CreateTagSheet: View {
    @Environment(\.dismiss) private var dismiss
    let kind: MessageReader.CreateKind
    let onCreate: (String, String) async -> Void
    @State private var name = ""
    @State private var color = LabelColor.choices[0]

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s4) {
            Text(kind == .label ? "New label" : "New folder").dsTitle(.lg)
            DSTextField(placeholder: kind == .label ? "New label name" : "New folder name", text: $name)
            if kind == .label { ColorSwatches(selected: $color) }
            HStack(spacing: Space.s2) {
                DSButton("Create") {
                    Task {
                        await onCreate(name.trimmingCharacters(in: .whitespaces), color)
                        dismiss()
                    }
                }
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                DSButton("Cancel", variant: .secondary) { dismiss() }
            }
        }
        .padding(Space.s4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.surfacePage)
    }
}

/// The label colours, as swatches to pick from.
struct ColorSwatches: View {
    @Binding var selected: String

    var body: some View {
        HStack(spacing: Space.s2) {
            ForEach(LabelColor.choices, id: \.self) { choice in
                Button {
                    selected = choice
                } label: {
                    Circle()
                        .fill(LabelColor.color(choice))
                        .frame(width: 22, height: 22)
                        .overlay(Circle().strokeBorder(Color.textStrong, lineWidth: selected == choice ? 2 : 0))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(choice)
            }
        }
    }
}
