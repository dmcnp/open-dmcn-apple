import SwiftUI

/// A small rounded label: `Badge` on the web. Counts, states, the "New" marker.
struct DSBadge: View {
    enum Tone { case neutral, brand, success, warning, danger, info, trustContact, trustDMCN }

    let text: String
    var tone: Tone = .neutral

    var body: some View {
        Text(text)
            .dsFont(.xs, .medium)
            .foregroundStyle(colors.text)
            .padding(.horizontal, Space.s2)
            .padding(.vertical, 3)
            .background(colors.fill, in: .dsCard)
    }

    private var colors: (text: Color, fill: Color) {
        switch self.tone {
        case .neutral: (.textMuted, .surfaceSunken)
        case .brand: (.brandText, .brandSubtle)
        case .success: (.success, .successSubtle)
        case .warning: (.warning, .warningSubtle)
        case .danger: (.danger, .dangerSubtle)
        case .info: (.info, .infoSubtle)
        case .trustContact: (.trustContact, .trustContactSubtle)
        case .trustDMCN: (.trustDMCN, .brandSubtle)
        }
    }
}

/// A bordered chip: a label or folder on a message, a recipient in the composer.
struct DSTag<Leading: View>: View {
    let text: String
    @ViewBuilder var leading: Leading
    var onRemove: (() -> Void)?

    init(_ text: String, onRemove: (() -> Void)? = nil, @ViewBuilder leading: () -> Leading) {
        self.text = text
        self.onRemove = onRemove
        self.leading = leading()
    }

    var body: some View {
        HStack(spacing: 6) {
            leading
            Text(text).dsFont(.sm).foregroundStyle(.textBody).lineLimit(1)
            if let onRemove {
                Button(action: onRemove) {
                    Icon.x.image(11).foregroundStyle(.textSubtle).frame(width: 18, height: 18).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove \(text)")
            }
        }
        .padding(.horizontal, Space.s2)
        .padding(.vertical, 3)
        .background(.surfaceCard, in: .dsCard)
        .dsBorder(.borderDefault)
    }
}

extension DSTag where Leading == EmptyView {
    init(_ text: String, onRemove: (() -> Void)? = nil) {
        self.init(text, onRemove: onRemove) { EmptyView() }
    }
}

/// A one-line strip across the page saying something standing about this session.
struct StatusStrip<Action: View>: View {
    var icon: Icon = .alertTriangle
    var iconColor: Color = .warning
    let text: String
    @ViewBuilder var action: Action

    var body: some View {
        HStack(spacing: Space.s2) {
            icon.image(15).foregroundStyle(iconColor)
            Text(text).dsFont(.sm).foregroundStyle(.textBody).frame(maxWidth: .infinity, alignment: .leading)
            action
        }
        .padding(.horizontal, Space.s4)
        .padding(.vertical, Space.s2)
        .background(.surfaceSunken)
        .overlay(alignment: .bottom) { Rectangle().fill(.borderDefault).frame(height: 1) }
    }
}

extension StatusStrip where Action == EmptyView {
    init(icon: Icon = .alertTriangle, iconColor: Color = .warning, text: String) {
        self.init(icon: icon, iconColor: iconColor, text: text) { EmptyView() }
    }
}

/// A boxed note inside a page, in the warning, danger or quiet tone.
struct Callout: View {
    enum Tone { case danger, warning, neutral }

    let tone: Tone
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: Space.s2) {
            (tone == .neutral ? Icon.info : .alertTriangle).image(16).foregroundStyle(iconColor).padding(.top, 1)
            Text(text).dsFont(.sm).foregroundStyle(.textBody).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(Space.s3)
        .background(fill, in: .dsCard)
    }

    private var iconColor: Color {
        switch tone {
        case .danger: .danger
        case .warning: .warning
        case .neutral: .textMuted
        }
    }
    private var fill: Color {
        switch tone {
        case .danger: .dangerSubtle
        case .warning: .warningSubtle
        case .neutral: .surfaceSunken
        }
    }
}

/// What an empty list says.
struct EmptyState: View {
    let icon: Icon
    let text: String

    var body: some View {
        VStack(spacing: Space.s3) {
            icon.image(28).foregroundStyle(.textSubtle)
            Text(text).dsFont(.base).foregroundStyle(.textMuted).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Space.s16)
        .padding(.horizontal, Space.s4)
    }
}

/// Two initials from an address: a stable, offline way to tell accounts apart at a glance. No
/// image, nothing fetched.
struct AccountMonogram: View {
    let initials: String
    var size: CGFloat = 32

    var body: some View {
        Text(initials)
            .font(.system(size: (size * 0.375).rounded(), weight: .semibold, design: .monospaced))
            .foregroundStyle(.brandText)
            .frame(width: size, height: size)
            .background(.brandSubtle, in: .dsCard)
            .accessibilityHidden(true)
    }
}

/// A title and count in one line: the heading of a list or page.
struct PageTitle: View {
    let title: String
    var count: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.s2) {
            Text(title).dsTitle(.lg)
            if let count { Text(count).dsFont(.sm).foregroundStyle(.textMuted) }
        }
    }
}

/// The bar across the top of a pushed page: back, title, then whatever acts on the page.
struct PageHeader<Actions: View>: View {
    let title: String
    var count: String?
    let onBack: () -> Void
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(spacing: Space.s3) {
            DSIconButton(.chevronLeft, label: "Back to inbox", action: onBack)
            PageTitle(title: title, count: count)
            Spacer(minLength: 0)
            actions
        }
        .padding(.horizontal, Space.s4)
        .frame(height: 60)
        .background(.surfaceCard)
        .overlay(alignment: .bottom) { Rectangle().fill(.borderDefault).frame(height: 1) }
    }
}

extension PageHeader where Actions == EmptyView {
    init(title: String, count: String? = nil, onBack: @escaping () -> Void) {
        self.init(title: title, count: count, onBack: onBack) { EmptyView() }
    }
}

/// A group of settings rows in a bordered card.
struct SettingsCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) { content }
            .background(.surfaceCard, in: .dsCard)
            .dsBorder(.borderSubtle)
    }
}

/// One setting: what it is on the left, its control on the right or underneath.
struct SettingsRow<Control: View>: View {
    let title: String
    var detail: String?
    var stacked = false
    @ViewBuilder var control: Control

    var body: some View {
        let layout =
            stacked
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: Space.s3))
            : AnyLayout(HStackLayout(spacing: Space.s3))
        layout {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).dsFont(.md, .medium).foregroundStyle(.textStrong)
                if let detail {
                    Text(detail).dsFont(.sm).foregroundStyle(.textMuted).fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: stacked ? nil : .infinity, alignment: .leading)
            control
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Space.s4)
        .overlay(alignment: .bottom) { Rectangle().fill(.borderSubtle).frame(height: 1) }
    }
}

struct SectionHeading: View {
    let title: String

    var body: some View {
        Text(title).dsTitle(.base).padding(.top, Space.s2)
    }
}
