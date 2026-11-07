import SwiftUI

/// The DMCN text input: a 1-point border that turns teal with a soft ring while focused.
/// Sixteen points on a phone, as on the web, where anything smaller makes iOS zoom the page.
struct DSTextField: View {
    let label: String?
    let placeholder: String
    @Binding var text: String
    var secure = false
    var hint: String?
    var error: String?
    var leading: Icon?
    var keyboard: UIKeyboardType = .default
    var contentType: UITextContentType?
    var capitalization: TextInputAutocapitalization = .sentences
    var autocorrect = true
    var onSubmit: () -> Void = {}

    @FocusState private var focused: Bool
    @State private var revealed = false

    init(
        _ label: String? = nil, placeholder: String = "", text: Binding<String>, secure: Bool = false,
        hint: String? = nil, error: String? = nil, leading: Icon? = nil, keyboard: UIKeyboardType = .default,
        contentType: UITextContentType? = nil, capitalization: TextInputAutocapitalization = .sentences,
        autocorrect: Bool = true, onSubmit: @escaping () -> Void = {}
    ) {
        self.label = label
        self.placeholder = placeholder
        self._text = text
        self.secure = secure
        self.hint = hint
        self.error = error
        self.leading = leading
        self.keyboard = keyboard
        self.contentType = contentType
        self.capitalization = capitalization
        self.autocorrect = autocorrect
        self.onSubmit = onSubmit
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s2) {
            if let label {
                Text(label).dsFont(.sm, .medium).foregroundStyle(.textBody)
            }
            HStack(spacing: Space.s2) {
                if let leading { leading.image(16).foregroundStyle(.textSubtle) }
                field
                    .focused($focused)
                    .onSubmit(onSubmit)
                    .font(.system(size: 16))
                    .foregroundStyle(.textStrong)
                    .keyboardType(keyboard)
                    .textContentType(contentType)
                    .textInputAutocapitalization(capitalization)
                    .autocorrectionDisabled(secure || !autocorrect)
                if secure {
                    DSIconButton(
                        revealed ? .eyeOff : .eye, label: revealed ? "Hide passphrase" : "Show passphrase", size: .sm
                    ) { revealed.toggle() }
                }
            }
            .padding(.horizontal, Space.s3)
            .frame(minHeight: 40)
            .background(.surfaceCard, in: .dsCard)
            .dsBorder(borderColor)
            .background(
                RoundedRectangle(cornerRadius: Radius.standard + 3, style: .continuous)
                    .fill(focused ? (error == nil ? Color.brandSubtle2 : .dangerSubtle) : .clear)
                    .padding(-3)
            )
            .animation(Motion.fast, value: focused)
            if let error {
                Text(error).dsFont(.xs).foregroundStyle(.danger)
            } else if let hint {
                Text(hint).dsFont(.xs).foregroundStyle(.textMuted)
            }
        }
    }

    @ViewBuilder private var field: some View {
        if secure && !revealed {
            SecureField("", text: $text, prompt: prompt)
        } else {
            TextField("", text: $text, prompt: prompt)
        }
    }

    private var prompt: Text { Text(placeholder).foregroundStyle(.textSubtle) }

    private var borderColor: Color {
        if error != nil { return .danger }
        return focused ? .borderFocus : .borderDefault
    }
}

/// A radio-style option: a title and a line of explanation, teal when it's the one chosen.
struct ChoiceRow: View {
    let title: String
    let detail: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: Space.s3) {
                Circle()
                    .strokeBorder(selected ? Color.brand : .borderStrong, lineWidth: selected ? 5 : 1.5)
                    .frame(width: 18, height: 18)
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).dsFont(.md, .semibold).foregroundStyle(.textStrong)
                    Text(detail).dsFont(.sm).foregroundStyle(.textMuted).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(Space.s3)
            .background(selected ? Color.brandSubtle : .surfaceCard, in: .dsCard)
            .dsBorder(selected ? .brand : .borderDefault)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// An on/off setting in the brand colour.
struct DSToggle: View {
    let title: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(title, isOn: $isOn).labelsHidden().tint(.brand)
    }
}
