import SwiftUI

/// The DMCN action button: square corners, teal primary. See `ds/components/buttons` on the web.
struct DSButtonStyle: ButtonStyle {
    enum Variant { case primary, secondary, ghost, danger, dangerOutline }
    enum Size {
        case sm, md, lg

        var height: CGFloat {
            switch self {
            case .sm: 30
            case .md: 38
            case .lg: 46
            }
        }
        var padding: CGFloat {
            switch self {
            case .sm: Space.s3
            case .md: Space.s4
            case .lg: Space.s6
            }
        }
        var text: TextSize {
            switch self {
            case .sm: .sm
            case .md: .md
            case .lg: .base
            }
        }
    }

    var variant: Variant = .primary
    var size: Size = .md
    var fullWidth = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .dsFont(size.text, .medium)
            .lineLimit(1)
            .padding(.horizontal, size.padding)
            .frame(maxWidth: fullWidth ? .infinity : nil, minHeight: size.height)
            .foregroundStyle(foreground)
            .background(background(pressed: configuration.isPressed), in: .dsCard)
            .dsBorder(border, width: 1)
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(Rectangle())
            .animation(Motion.fast, value: configuration.isPressed)
    }

    private var foreground: Color {
        switch variant {
        case .primary: .textOnBrand
        case .secondary, .ghost: .textBody
        case .danger: .white
        case .dangerOutline: .danger
        }
    }

    private func background(pressed: Bool) -> Color {
        switch variant {
        case .primary: pressed ? .brandActive : .brand
        case .secondary, .dangerOutline: pressed ? .surfaceActive : .surfaceCard
        case .ghost: pressed ? .surfaceActive : .clear
        case .danger: pressed ? .dangerHover : .danger
        }
    }

    private var border: Color {
        switch variant {
        case .secondary: .borderDefault
        case .dangerOutline: .danger.opacity(0.45)
        case .primary, .ghost, .danger: .clear
        }
    }
}

struct DSButton: View {
    let title: String
    var icon: Icon?
    var variant: DSButtonStyle.Variant = .primary
    var size: DSButtonStyle.Size = .md
    var fullWidth = false
    let action: () -> Void

    init(
        _ title: String, icon: Icon? = nil, variant: DSButtonStyle.Variant = .primary,
        size: DSButtonStyle.Size = .md, fullWidth: Bool = false, action: @escaping () -> Void
    ) {
        self.title = title
        self.icon = icon
        self.variant = variant
        self.size = size
        self.fullWidth = fullWidth
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: Space.s2) {
                if let icon { icon.image(size == .sm ? 14 : 16) }
                Text(title)
            }
        }
        .buttonStyle(DSButtonStyle(variant: variant, size: size, fullWidth: fullWidth))
    }
}

/// A glyph-only button. `label` is what VoiceOver says, so it is required.
struct DSIconButton: View {
    enum Size {
        case sm, md, lg

        var box: CGFloat {
            switch self {
            case .sm: 30
            case .md: 38
            case .lg: 44
            }
        }
        var glyph: CGFloat { self == .sm ? 16 : 18 }
    }
    enum Variant { case plain, outline, solid, active }

    let icon: Icon
    let label: String
    var size: Size = .md
    var variant: Variant = .plain
    var tint: Color?
    let action: () -> Void

    init(
        _ icon: Icon, label: String, size: Size = .md, variant: Variant = .plain, tint: Color? = nil,
        action: @escaping () -> Void
    ) {
        self.icon = icon
        self.label = label
        self.size = size
        self.variant = variant
        self.tint = tint
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            icon.image(size.glyph)
                .foregroundStyle(tint ?? foreground)
                .frame(width: size.box, height: size.box)
                .background(background, in: .dsCard)
                .dsBorder(variant == .outline ? .borderDefault : .clear)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    private var foreground: Color {
        switch variant {
        case .plain: .textMuted
        case .outline: .textBody
        case .solid: .textOnBrand
        case .active: .brandText
        }
    }

    private var background: Color {
        switch variant {
        case .plain, .outline: .clear
        case .solid: .brand
        case .active: .brandSubtle
        }
    }
}

/// A destructive icon button that asks a second time on the same spot: the first press arms it,
/// and it disarms itself if nothing follows. Only for what can't be undone.
struct ConfirmTrashButton: View {
    let label: String
    var size: DSIconButton.Size = .md
    let onConfirm: () -> Void
    @State private var armed = false

    var body: some View {
        DSIconButton(
            .trash, label: armed ? "Tap again to \(label.lowercased())" : label, size: size,
            tint: armed ? .danger : nil
        ) {
            if armed {
                armed = false
                onConfirm()
            } else {
                armed = true
            }
        }
        .task(id: armed) {
            guard armed else { return }
            try? await Task.sleep(for: .seconds(3))
            if !Task.isCancelled { armed = false }
        }
    }
}
