import DMCNKit
import SwiftUI

/// Who's signed in, the other accounts on this device, and the ways out.
struct AccountSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let session: MailSession

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s4) {
            HStack(spacing: Space.s3) {
                AccountMonogram(initials: MailView.initialsOf(session.address), size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.address).dsMono(.md).foregroundStyle(.textStrong).lineLimit(1)
                    Text(session.host).dsFont(.sm).foregroundStyle(.textMuted)
                }
            }
            let others = model.accounts.filter { $0.address != session.address }
            if !others.isEmpty {
                VStack(spacing: 0) {
                    ForEach(others) { account in
                        Button {
                            dismiss()
                            Task { await model.lockForSwitch(to: account) }
                        } label: {
                            HStack(spacing: Space.s3) {
                                AccountMonogram(initials: MailView.initialsOf(account.address))
                                Text(account.address).dsMono(.sm).foregroundStyle(.textBody).lineLimit(1)
                                Spacer(minLength: 0)
                                Icon.chevronRight.image(16).foregroundStyle(.textSubtle)
                            }
                            .padding(Space.s3)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .background(.surfaceCard, in: .dsCard)
                .dsBorder()
            }
            DSButton("Add another account", icon: .plus, variant: .secondary, fullWidth: true) {
                dismiss()
                Task { await model.signOut() }
            }
            DSButton("Sign out", icon: .logOut, variant: .ghost, fullWidth: true) {
                dismiss()
                Task { await model.signOut() }
            }
            Spacer(minLength: 0)
        }
        .padding(Space.s4)
        .background(.surfacePage)
    }
}
