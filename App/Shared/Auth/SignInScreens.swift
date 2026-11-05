import DMCNKit
import SwiftUI

/// Everything before the inbox. The screens are one flow, so one enum says which is up.
struct SignedOutFlow: View {
    @Environment(AppModel.self) private var model
    @State private var screen = Screen.accounts

    enum Screen { case accounts, importBackup, register }

    var body: some View {
        Group {
            switch screen {
            case .accounts:
                if model.accounts.isEmpty {
                    SetUpDeviceView(screen: $screen)
                } else {
                    ChooseAccountView(screen: $screen)
                }
            case .importBackup: ImportView(screen: $screen)
            case .register:
                if model.pendingPetition != nil {
                    PetitionWaitingView(screen: $screen)
                } else {
                    RegisterView(screen: $screen)
                }
            }
        }
        .animation(Motion.normal, value: screen)
        // A request left waiting is where someone with nothing else here picks up again.
        .onChange(of: model.pendingPetition) { _, pending in
            if pending != nil, model.accounts.isEmpty { screen = .register }
        }
    }
}

/// No identity here yet. Keys never leave a device, so there's nothing on a server to sign in
/// with: the only ways in are bringing keys over and making new ones.
struct SetUpDeviceView: View {
    @Environment(AppModel.self) private var model
    @Binding var screen: SignedOutFlow.Screen
    @State private var showingAcknowledgements = false

    var body: some View {
        AuthShell(title: "Set up this device", subtitle: "There's no identity stored in this app yet.") {
            VStack(alignment: .leading, spacing: Space.s3) {
                Text(
                    "Your keys never leave your devices, so there's nothing on the server to sign in with. Bring an existing identity onto this app:"
                )
                .dsFont(.sm)
                .foregroundStyle(.textMuted)
                DSButton("Import a backup", size: .lg, fullWidth: true) { screen = .importBackup }
                #if DEBUG
                    DSButton("Explore with sample mail", variant: .secondary, size: .lg, fullWidth: true) {
                        Task { await model.exploreSampleMail() }
                    }
                #endif
            }
        } footer: {
            VStack(alignment: .leading, spacing: Space.s3) {
                HStack(spacing: Space.s1) {
                    Text("Don't have a mailbox here yet?")
                    AuthLink("Create an account") { screen = .register }
                }
                if model.pendingPetition != nil {
                    AuthLink("See your mailbox request") { screen = .register }
                }
                AuthLink("Acknowledgements") { showingAcknowledgements = true }
            }
        }
        .sheet(isPresented: $showingAcknowledgements) {
            NavigationStack { AcknowledgementsView() }
        }
    }
}

/// The per-device account picker. Unlocking here and switching from the header are the same act.
struct ChooseAccountView: View {
    @Environment(AppModel.self) private var model
    @Binding var screen: SignedOutFlow.Screen
    @State private var expanded: String?
    @State private var passphrase = ""
    @State private var removing: DeviceAccount?

    var body: some View {
        AuthShell(title: "Choose an account", subtitle: "Unlock an identity stored on this device.") {
            VStack(alignment: .leading, spacing: Space.s3) {
                if let reason = model.lockReason {
                    Text(reason.message)
                        .dsFont(.sm)
                        .foregroundStyle(.textMuted)
                        .padding(Space.s3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(reason == .rekeyed ? Color.warningSubtle : .surfaceSunken, in: .dsCard)
                }
                if let error = model.authError { FormError(text: error) }
                VStack(spacing: 0) {
                    ForEach(model.accounts) { account in
                        row(account)
                        if account.id != model.accounts.last?.id {
                            Rectangle().fill(.borderSubtle).frame(height: 1)
                        }
                    }
                }
                .background(.surfaceCard, in: .dsCard)
                .dsBorder()
            }
        } footer: {
            HStack(spacing: Space.s1) {
                if model.pendingPetition != nil {
                    AuthLink("See your mailbox request") { screen = .register }
                } else {
                    Text("Add another:")
                    AuthLink("create") { screen = .register }
                    Text("·")
                    AuthLink("import") { screen = .importBackup }
                }
            }
        }
        .alert(
            "Remove this account from this device?",
            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
            presenting: removing
        ) { account in
            Button("Keep it", role: .cancel) {}
            Button("Remove", role: .destructive) { model.forget(account) }
        } message: { account in
            Text(
                "This is not signing out. It deletes the keys for \(account.address) from this app. If you have no backup file and the account is not on another device, you lose the account and its mail for good. To keep it, unlock it and download a backup from Settings first."
            )
        }
    }

    @ViewBuilder private func row(_ account: DeviceAccount) -> some View {
        let isExpanded = expanded == account.address && account.protection == .passphrase
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Space.s3) {
                AccountMonogram(initials: MailView.initialsOf(account.address))
                VStack(alignment: .leading, spacing: 3) {
                    Text(account.address).dsMono(.md).foregroundStyle(.textStrong).lineLimit(1).truncationMode(.middle)
                    HStack(spacing: Space.s1) {
                        Icon.lock.image(11)
                        Text("Locked")
                    }
                    .dsFont(.xs)
                    .foregroundStyle(.warning)
                }
                Spacer(minLength: 0)
                if !isExpanded {
                    DSButton("Unlock", icon: .key, size: .sm) {
                        if account.protection == .passphrase {
                            passphrase = ""
                            expanded = account.address
                        } else {
                            Task { await model.unlock(account, passphrase: nil) }
                        }
                    }
                    .disabled(model.isBusy)
                }
                DSIconButton(.trash, label: "Remove from this device", size: .sm) { removing = account }
                    .disabled(model.isBusy)
            }
            .padding(.vertical, 11)
            .padding(.horizontal, 14)
            if isExpanded {
                VStack(alignment: .leading, spacing: Space.s2) {
                    DSTextField("Passphrase", text: $passphrase, secure: true, contentType: .password) {
                        Task { await model.unlock(account, passphrase: passphrase) }
                    }
                    HStack(spacing: Space.s2) {
                        DSButton(model.isBusy ? "Unlocking…" : "Unlock", size: .sm) {
                            Task { await model.unlock(account, passphrase: passphrase) }
                        }
                        DSButton("Cancel", variant: .secondary, size: .sm) { expanded = nil }
                    }
                    .disabled(model.isBusy)
                }
                .padding(.leading, 58)
                .padding(.trailing, 14)
                .padding(.bottom, 14)
            }
        }
    }
}

/// Brings a backup onto this device, in the web's two steps: open the file, then choose how
/// it's protected here.
struct ImportView: View {
    @Environment(AppModel.self) private var model
    @Binding var screen: SignedOutFlow.Screen
    @State private var host = Deployment.current.defaultHost ?? ""
    @State private var picking = false
    @State private var file: PickedFile?
    @State private var passphrase = ""
    @State private var opened: OpenedBackup?
    @State private var protection = KeyProtection.preferred
    @State private var newPassphrase = ""
    @State private var error: String?
    @State private var working = false

    var body: some View {
        AuthShell(title: "Import an identity", subtitle: "Bring a backup file into this app.") {
            VStack(alignment: .leading, spacing: Space.s4) {
                Text("Your keys are decrypted here, from a DMCN backup file, and never sent unencrypted.")
                    .dsFont(.sm)
                    .foregroundStyle(.textMuted)
                if let opened { protectStep(opened) } else { unlockStep }
            }
        } footer: {
            AuthLink("Back to sign in") { screen = .accounts }
        }
        .fileImporter(isPresented: $picking, allowedContentTypes: [.json, .data]) { result in
            if case .success(let url) = result { file = PickedFile(url) }
            error = file == nil ? "That file couldn't be read." : nil
        }
    }

    @ViewBuilder private var unlockStep: some View {
        DSTextField(
            "Server", placeholder: "mail.example.org", text: $host, keyboard: .URL, contentType: .URL,
            capitalization: .never, autocorrect: false)
        VStack(alignment: .leading, spacing: Space.s2) {
            Text("Backup file").dsFont(.sm, .medium).foregroundStyle(.textBody)
            if let file {
                HStack(spacing: Space.s3) {
                    Icon.file.image(18)
                        .foregroundStyle(.brandText)
                        .frame(width: 36, height: 36)
                        .background(.brandSubtle, in: .dsCard)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(file.name).dsMono(.md).foregroundStyle(.textStrong).lineLimit(1)
                        Text(file.size).dsFont(.xs).foregroundStyle(.textMuted)
                    }
                    Spacer(minLength: 0)
                    DSIconButton(.x, label: "Remove file", size: .sm) { self.file = nil }
                }
                .padding(Space.s4)
                .background(.surfaceCard, in: .dsCard)
                .dsBorder(.borderDefault)
            } else {
                Button {
                    picking = true
                } label: {
                    VStack(spacing: 10) {
                        Icon.key.image(26).foregroundStyle(.textSubtle)
                        Text("Browse").dsFont(.md, .semibold).foregroundStyle(.brandText)
                        Text(".dmcn or .json backup").dsMono(.xs).foregroundStyle(.textSubtle)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 30)
                    .background(.surfaceCard, in: .dsCard)
                    .overlay(
                        RoundedRectangle(cornerRadius: Radius.standard)
                            .strokeBorder(Color.borderDefault, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        DSTextField(
            "Backup passphrase", placeholder: "Enter your passphrase", text: $passphrase, secure: true,
            contentType: .password)
        if let error { FormError(text: error) }
        DSButton(working ? "Unlocking…" : "Unlock", icon: .lock, size: .lg, fullWidth: true) {
            guard let file else { return }
            run { opened = try await model.openBackup(file.data, passphrase: passphrase, host: host) }
        }
        .disabled(working || file == nil || host.isEmpty)
    }

    @ViewBuilder private func protectStep(_ opened: OpenedBackup) -> some View {
        VStack(alignment: .leading, spacing: Space.s2) {
            Text("Identity").dsFont(.sm, .medium).foregroundStyle(.textBody)
            Text(opened.address).dsMono(.md).foregroundStyle(.textStrong)
        }
        ProtectionPicker(title: "Protect on this device", choice: $protection)
        if protection == .passphrase {
            DSTextField("Passphrase", text: $newPassphrase, secure: true, contentType: .newPassword)
        }
        if let error { FormError(text: error) }
        DSButton(working ? "Importing…" : "Import", size: .lg, fullWidth: true) {
            run {
                try await model.finishImport(
                    opened, protection: protection, passphrase: protection == .passphrase ? newPassphrase : nil)
            }
        }
        .disabled(working || (protection == .passphrase && newPassphrase.isEmpty))
    }

    private func run(_ work: @escaping () async throws -> Void) {
        working = true
        error = nil
        Task {
            do {
                try await work()
            } catch {
                self.error = error.localizedDescription
            }
            working = false
        }
    }
}

/// A file chosen in the document picker, read at once: its security scope ends with the callback.
struct PickedFile {
    let name: String
    let data: Data
    var size: String { MailView.formatBytes(data.count) }

    init?(_ url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { return nil }
        self.name = url.lastPathComponent
        self.data = data
    }
}

/// Getting a mailbox: signing up where a server offers it, asking an admin where it doesn't. Which
/// is the server's to say, so the form follows what it answers for the host typed in. The keys are
/// made here and never leave.
struct RegisterView: View {
    @Environment(AppModel.self) private var model
    @Binding var screen: SignedOutFlow.Screen
    @State private var host = Deployment.current.defaultHost ?? ""
    @State private var localPart = ""
    @State private var protection = KeyProtection.preferred
    @State private var passphrase = ""
    @State private var confirmation = ""
    @State private var error: String?
    @State private var working = false
    /// What the server said. nil until it does, and the signup form is what's shown until then.
    @State private var signup: SignupMode?

    private var domain: String { AppModel.hostURL(host)?.host(percentEncoded: false) ?? "" }
    private var mismatch: Bool { !confirmation.isEmpty && confirmation != passphrase }
    private var asking: Bool { signup == .petition }

    private var title: String { asking ? "Ask for a mailbox" : "Create your account" }

    private var subtitle: String {
        if asking { return "\(domain) is administered by a person, not a sign-up form" }
        return domain.isEmpty ? "Your end-to-end encrypted inbox" : "Your end-to-end encrypted inbox on \(domain)"
    }

    private var submitTitle: String {
        if asking { return working ? "Requesting…" : "Request a mailbox" }
        return working ? "Creating account…" : "Create account"
    }

    var body: some View {
        AuthShell(title: title, subtitle: subtitle) {
            VStack(alignment: .leading, spacing: Space.s4) {
                DSTextField(
                    "Server", placeholder: "mail.example.org", text: $host, keyboard: .URL, contentType: .URL,
                    capitalization: .never, autocorrect: false)
                if signup == .closed {
                    Text("\(domain) isn't taking new accounts here. Ask whoever runs it how to get a mailbox.")
                        .dsFont(.sm)
                        .foregroundStyle(.textBody)
                } else {
                    form
                }
            }
        } footer: {
            VStack(alignment: .leading, spacing: Space.s2) {
                HStack(spacing: Space.s1) {
                    Text("Already have an account?")
                    AuthLink("Sign in") { screen = .accounts }
                }
                HStack(spacing: Space.s1) {
                    Text("Have a backup file?")
                    AuthLink("Import it") { screen = .importBackup }
                }
            }
        }
        .task(id: domain) {
            signup = nil
            // Not on every letter of a host being typed.
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled, !domain.isEmpty else { return }
            let mode = await model.signupMode(host: host)
            if !Task.isCancelled { signup = mode }
        }
    }

    @ViewBuilder private var form: some View {
        if asking {
            Text(
                "Your keys are made here, on this device, and never leave it. We will give you a short code to pass to whoever runs \(domain). They choose your address and set it up."
            )
            .dsFont(.sm)
            .foregroundStyle(.textBody)
        } else {
            addressField
        }
        ProtectionPicker(title: "How do you want to secure your account?", choice: $protection)
        if protection == .passphrase {
            DSTextField(
                "Passphrase", placeholder: "At least 8 characters", text: $passphrase, secure: true,
                contentType: .newPassword)
            if !passphrase.isEmpty { StrengthMeter(strength: PassphraseStrength(passphrase)) }
            DSTextField(
                "Confirm passphrase", text: $confirmation, secure: true,
                error: mismatch ? "Passphrases do not match" : nil)
        }
        if let error { FormError(text: error) }
        DSButton(submitTitle, size: .lg, fullWidth: true) { submit() }
            .disabled(working || (!asking && localPart.isEmpty) || domain.isEmpty)
    }

    private var addressField: some View {
        VStack(alignment: .leading, spacing: Space.s2) {
            Text("Choose your address").dsFont(.sm, .medium).foregroundStyle(.textBody)
            HStack(spacing: 0) {
                TextField("", text: $localPart, prompt: Text("you").foregroundStyle(.textSubtle))
                    .font(.system(size: 16))
                    .foregroundStyle(.textStrong)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .padding(.horizontal, Space.s3)
                    .frame(height: 40)
                    .background(.surfaceCard)
                Text("@\(domain)")
                    .dsMono(.md)
                    .foregroundStyle(.textMuted)
                    .lineLimit(1)
                    .padding(.horizontal, Space.s3)
                    .frame(height: 40)
                    .background(.surfaceSunken)
            }
            .clipShape(.dsCard)
            .dsBorder(.borderDefault)
        }
    }

    private func submit() {
        guard !mismatch else { return }
        working = true
        error = nil
        Task {
            do {
                let secret = protection == .passphrase ? passphrase : nil
                if asking {
                    try await model.requestMailbox(host: host, protection: protection, passphrase: secret)
                } else {
                    try await model.register(
                        localPart: localPart.trimmingCharacters(in: .whitespaces), host: host, protection: protection,
                        passphrase: secret)
                }
            } catch {
                self.error = error.localizedDescription
            }
            working = false
        }
    }
}

/// A request for a mailbox, waiting on a person. It checks by itself and says when the admin has
/// acted, but only ever claims the address from a tap: that's what may raise a Face ID prompt.
struct PetitionWaitingView: View {
    @Environment(AppModel.self) private var model
    @Binding var screen: SignedOutFlow.Screen
    @State private var passphrase = ""
    @State private var error: String?
    @State private var working = false
    @State private var copied = false

    private var pending: DeviceAccount? { model.pendingPetition }
    private var code: String { pending?.petitionCode ?? "" }
    private var needsPassphrase: Bool { pending?.protection == .passphrase }

    var body: some View {
        Group {
            if let address = model.assignedAddress {
                ready(address)
            } else {
                waiting
            }
        }
        .task {
            while !Task.isCancelled, model.assignedAddress == nil, model.pendingPetition != nil {
                await model.checkPetition()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    private var waiting: some View {
        AuthShell(
            title: "Give this code to your administrator",
            subtitle: "They will use it to set up your mailbox on \(pending?.host ?? "this server")"
        ) {
            VStack(alignment: .leading, spacing: Space.s4) {
                Text(code)
                    .font(.system(size: 26, design: .monospaced))
                    .tracking(1.5)
                    .foregroundStyle(.textStrong)
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .padding(Space.s4)
                    .frame(maxWidth: .infinity)
                    .background(.surfaceSunken, in: .dsCard)
                    .dsBorder(.borderDefault)
                DSButton(
                    copied ? "Copied" : "Copy code", icon: copied ? .check : .copy, variant: .secondary, fullWidth: true
                ) {
                    UIPasteboard.general.string = code
                    copied = true
                }
                Text(
                    "Read this code to your administrator however you normally reach them. They pick your address. You do not choose it here, and nothing is created until they act."
                )
                .dsFont(.sm)
                .foregroundStyle(.textBody)
                Text(waitingNote).dsFont(.sm).foregroundStyle(.textMuted)
                HStack(spacing: Space.s2) {
                    Icon.lock.image(14)
                    Text("Your keys were made on this device and stay here. Only the public half was sent.")
                }
                .dsFont(.xs)
                .foregroundStyle(.textSubtle)
            }
        } footer: {
            HStack(spacing: Space.s1) {
                Text("Changed your mind?")
                AuthLink("Start over") { startOver() }
            }
        }
    }

    private var waitingNote: String {
        let note =
            "This screen checks every few seconds and will tell you as soon as it is approved. You can close the app and come back on this device."
        guard let expires = pending?.petitionExpires else { return note }
        return "\(note) The request expires \(expires.formatted(date: .abbreviated, time: .shortened))."
    }

    private func ready(_ address: String) -> some View {
        AuthShell(title: "Your mailbox is ready", subtitle: "\(address) was assigned to you") {
            VStack(alignment: .leading, spacing: Space.s4) {
                HStack(spacing: Space.s3) {
                    Icon.shieldCheck.image(20).foregroundStyle(.success)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(address).dsMono(.md).foregroundStyle(.textStrong)
                        Text("Approved by your administrator").dsFont(.sm).foregroundStyle(.textMuted)
                    }
                }
                .padding(Space.s4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.surfaceSunken, in: .dsCard)
                .dsBorder(.borderDefault)
                Text(
                    needsPassphrase
                        ? "Enter the passphrase you chose when you made this request, to unlock your keys and finish."
                        : "Unlock with \(KeyProtection.deviceAuthName) to finish setting up and open your mailbox."
                )
                .dsFont(.sm)
                .foregroundStyle(.textBody)
                if needsPassphrase {
                    DSTextField("Passphrase", text: $passphrase, secure: true)
                }
                if let error { FormError(text: error) }
                DSButton(working ? "Setting up…" : "Open my mailbox", size: .lg, fullWidth: true) { claim() }
                    .disabled(working || (needsPassphrase && passphrase.isEmpty))
            }
        } footer: {
            HStack(spacing: Space.s1) {
                Text("Not what you expected?")
                AuthLink("Start over") { startOver() }
            }
        }
    }

    private func claim() {
        working = true
        error = nil
        Task {
            do {
                try await model.claimPetition(passphrase: needsPassphrase ? passphrase : nil)
            } catch {
                self.error = error.localizedDescription
            }
            working = false
        }
    }

    private func startOver() {
        Task {
            await model.cancelPetition()
            screen = .accounts
        }
    }
}

private struct StrengthMeter: View {
    let strength: PassphraseStrength

    private var color: Color {
        switch strength {
        case .weak: .danger
        case .fair: .warning
        case .strong: .success
        }
    }

    var body: some View {
        HStack(spacing: Space.s2) {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(.surfaceSunken)
                    Capsule().fill(color).frame(width: geometry.size.width * strength.fraction)
                }
            }
            .frame(height: 4)
            Text(strength.label).dsFont(.xs).foregroundStyle(color)
        }
    }
}

#Preview("Set up") {
    SignedOutFlow().environment(AppModel())
}

#Preview("Mailbox request") {
    @Previewable @State var screen = SignedOutFlow.Screen.register
    let vault = InMemoryVault()
    let model = AppModel(vault: vault)
    PetitionWaitingView(screen: $screen)
        .environment(model)
        .task {
            let request = DeviceAccount.petition(
                code: "0428-9173-5560", host: "mail.example.org", protection: .passphrase,
                expires: .now.addingTimeInterval(86_400))
            await vault.save(request, secret: Data())
            await model.loadAccounts()
        }
}
