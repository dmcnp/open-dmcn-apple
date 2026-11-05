import SwiftUI

/// The layout every screen before the inbox shares, so they all match: the deployment's mark,
/// a title, the form, the line about keys, then the way out.
struct AuthShell<Content: View, Footer: View>: View {
    let title: String
    let subtitle: String
    var note: String? = Deployment.current.signInNote
    @ViewBuilder var content: Content
    @ViewBuilder var footer: Footer

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if let host = Deployment.current.defaultHost {
                    HStack(spacing: Space.s2) {
                        Icon.mail.image(20).foregroundStyle(.textMuted)
                        Text(host).dsFont(.lg, .semibold).foregroundStyle(.textStrong)
                    }
                    .padding(.bottom, Space.s6)
                }
                Text(title).dsTitle(.xxl)
                Text(subtitle).dsFont(.base).foregroundStyle(.textMuted).padding(.top, Space.s1)
                content.padding(.top, Space.s6)
                if let note {
                    HStack(alignment: .top, spacing: Space.s2) {
                        Icon.shieldCheck.image(15).foregroundStyle(.brand).padding(.top, 1)
                        Text(note).dsFont(.sm).foregroundStyle(.textMuted)
                    }
                    .padding(.top, Space.s4)
                }
                footer
                    .dsFont(.sm)
                    .foregroundStyle(.textMuted)
                    .padding(.top, Space.s6)
            }
            .frame(maxWidth: 430, alignment: .leading)
            .padding(.horizontal, Space.s5)
            .padding(.vertical, Space.s8)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(.surfacePage)
    }
}

/// An inline link in an auth footer.
struct AuthLink: View {
    let title: String
    let action: () -> Void

    init(_ title: String, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title).fontWeight(.semibold).foregroundStyle(.textLink)
        }
        .buttonStyle(.plain)
    }
}

/// A form's failure, said where the person is looking.
struct FormError: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: Space.s2) {
            Icon.alertTriangle.image(15).padding(.top, 1)
            Text(text).dsFont(.sm)
        }
        .foregroundStyle(.danger)
    }
}

/// How the keys are protected on this device: `Passkey` and `Password` on the web.
struct ProtectionPicker: View {
    let title: String
    @Binding var choice: KeyProtection

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s2) {
            Text(title).dsFont(.sm, .medium).foregroundStyle(.textBody)
            if KeyProtection.deviceAuthAvailable {
                ChoiceRow(
                    title: KeyProtection.deviceAuthName, detail: "Recommended. Unlock with your device biometrics.",
                    selected: choice == .device
                ) { choice = .device }
            }
            ChoiceRow(
                title: "Passphrase", detail: "Encrypt your keys with a passphrase on this device.",
                selected: choice == .passphrase
            ) { choice = .passphrase }
        }
    }
}
