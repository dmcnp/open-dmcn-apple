import SwiftUI
import UIKit

// The web client's design tokens (cmd/dmcnd/web/src/styles/tokens.css in open-dmcn), value for
// value, so the two clients read as one product. Change a value there first, then here.
//
// Light and dark are one colour each: `Color.surfaceCard` follows the colour scheme on its own,
// and the app's theme setting picks the scheme.

// MARK: Colour

extension Color {
    fileprivate init(hex: UInt32) {
        self.init(uiColor: UIColor(hex: hex))
    }

    fileprivate static func scheme(light: UInt32, dark: UInt32) -> Color {
        Color(
            uiColor: UIColor { traits in
                UIColor(hex: traits.userInterfaceStyle == .dark ? dark : light)
            })
    }
}

extension UIColor {
    fileprivate convenience init(hex: UInt32) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

/// The base palette. Screens use the semantic colours below; this is what those are made from.
private enum Palette {
    static let teal50: UInt32 = 0xE7F7F2
    static let teal100: UInt32 = 0xC6ECE1
    static let teal200: UInt32 = 0x93DAC8
    static let teal300: UInt32 = 0x58C4AC
    static let teal400: UInt32 = 0x28AC90
    static let teal500: UInt32 = 0x0E9E86
    static let teal600: UInt32 = 0x0A8270
    static let teal700: UInt32 = 0x0A685A

    static let neutral0: UInt32 = 0xFFFFFF
    static let neutral25: UInt32 = 0xFBFCFC
    static let neutral50: UInt32 = 0xF5F7F7
    static let neutral100: UInt32 = 0xECEFEF
    static let neutral150: UInt32 = 0xE2E6E6
    static let neutral200: UInt32 = 0xD5DBDB
    static let neutral300: UInt32 = 0xBAC2C2
    static let neutral400: UInt32 = 0x939D9D
    static let neutral500: UInt32 = 0x6C7676
    static let neutral600: UInt32 = 0x4E5757
    static let neutral700: UInt32 = 0x373F3F
    static let neutral800: UInt32 = 0x232A2A
    static let neutral900: UInt32 = 0x161B1B
    static let neutral950: UInt32 = 0x0C1010
}

extension ShapeStyle where Self == Color {
    static var surfacePage: Color { .scheme(light: Palette.neutral50, dark: Palette.neutral950) }
    static var surfaceCard: Color { .scheme(light: Palette.neutral0, dark: Palette.neutral900) }
    static var surfaceRaised: Color { .scheme(light: Palette.neutral0, dark: Palette.neutral800) }
    static var surfaceSunken: Color { .scheme(light: Palette.neutral100, dark: Palette.neutral950) }
    static var surfaceHover: Color { .scheme(light: Palette.neutral100, dark: Palette.neutral800) }
    static var surfaceActive: Color { .scheme(light: Palette.neutral150, dark: Palette.neutral700) }

    static var textStrong: Color { .scheme(light: Palette.neutral900, dark: Palette.neutral25) }
    static var textBody: Color { .scheme(light: Palette.neutral800, dark: Palette.neutral150) }
    static var textMuted: Color { .scheme(light: Palette.neutral500, dark: Palette.neutral400) }
    static var textSubtle: Color { .scheme(light: Palette.neutral400, dark: Palette.neutral500) }
    static var textOnBrand: Color { .scheme(light: Palette.neutral0, dark: Palette.neutral950) }
    static var textLink: Color { .scheme(light: Palette.teal700, dark: Palette.teal300) }

    static var borderSubtle: Color { .scheme(light: Palette.neutral150, dark: Palette.neutral800) }
    static var borderDefault: Color { .scheme(light: Palette.neutral200, dark: Palette.neutral700) }
    static var borderStrong: Color { .scheme(light: Palette.neutral300, dark: Palette.neutral600) }
    static var borderFocus: Color { .scheme(light: Palette.teal500, dark: Palette.teal400) }

    static var brand: Color { .scheme(light: Palette.teal500, dark: Palette.teal400) }
    static var brandHover: Color { .scheme(light: Palette.teal600, dark: Palette.teal300) }
    static var brandActive: Color { .scheme(light: Palette.teal700, dark: Palette.teal200) }
    static var brandSubtle: Color { .scheme(light: Palette.teal50, dark: 0x0E2622) }
    static var brandSubtle2: Color { .scheme(light: Palette.teal100, dark: 0x103029) }
    static var brandText: Color { .scheme(light: Palette.teal700, dark: Palette.teal300) }

    static var success: Color { .scheme(light: 0x1F9D57, dark: 0x35B36B) }
    static var successSubtle: Color { .scheme(light: 0xDAF1E2, dark: 0x10271A) }
    static var warning: Color { .scheme(light: 0xC7860B, dark: 0xE0A53A) }
    static var warningSubtle: Color { .scheme(light: 0xF8EBCB, dark: 0x2C2410) }
    static var danger: Color { .scheme(light: 0xD33C3C, dark: 0xE85D5D) }
    static var dangerHover: Color { .scheme(light: 0xBC2E2E, dark: 0xF07070) }
    static var dangerSubtle: Color { .scheme(light: 0xF8DADA, dark: 0x2C1414) }
    static var info: Color { .scheme(light: 0x2D7FF0, dark: 0x589BF5) }
    static var infoSubtle: Color { .scheme(light: 0xDAE8FD, dark: 0x11203A) }

    /// A DMCN identity. Same teal as the brand, named for what it means.
    static var trustDMCN: Color { .brand }
    /// Someone in your contacts whose key still holds.
    static var trustContact: Color { .info }
    static var trustContactSubtle: Color { .infoSubtle }
}

// MARK: Spacing and shape

/// The 4-point grid.
enum Space {
    static let s1: CGFloat = 4
    static let s2: CGFloat = 8
    static let s3: CGFloat = 12
    static let s4: CGFloat = 16
    static let s5: CGFloat = 20
    static let s6: CGFloat = 24
    static let s8: CGFloat = 32
    static let s16: CGFloat = 64
}

enum Radius {
    /// Every corner in the product is this, on purpose: square reads as precise, not soft.
    static let standard: CGFloat = 4
    /// The checks strip alone is rounder, so it reads as a panel about the message.
    static let strip: CGFloat = 8
}

enum Motion {
    static let fast = Animation.timingCurve(0.2, 0, 0, 1, duration: 0.12)
    static let normal = Animation.timingCurve(0.16, 1, 0.3, 1, duration: 0.18)
}

extension Shape where Self == RoundedRectangle {
    /// The product's standard corner.
    static var dsCard: RoundedRectangle { RoundedRectangle(cornerRadius: Radius.standard, style: .continuous) }
}

extension View {
    /// A 1-point border following the standard corner.
    func dsBorder(_ color: Color = .borderSubtle, width: CGFloat = 1) -> some View {
        overlay(
            RoundedRectangle(cornerRadius: Radius.standard, style: .continuous).strokeBorder(color, lineWidth: width))
    }

    /// `--shadow-md`, used by anything floating over the page.
    func dsShadow() -> some View {
        shadow(color: .black.opacity(0.08), radius: 5, y: 4).shadow(color: .black.opacity(0.12), radius: 14, y: 12)
    }
}

// MARK: Type

/// The type scale, in points at the default text size. The web's sans falls back to the system
/// font, so on an iPhone both clients are already set in the same face.
enum TextSize: CGFloat {
    case xxs = 11
    case xs = 12
    case sm = 13
    case md = 14
    case base = 15
    case lg = 17
    case xl = 21
    case xxl = 26
}

private struct ScaledFont: ViewModifier {
    @ScaledMetric private var size: CGFloat
    private let weight: Font.Weight
    private let design: Font.Design

    init(_ text: TextSize, weight: Font.Weight, design: Font.Design) {
        _size = ScaledMetric(wrappedValue: text.rawValue, relativeTo: .body)
        self.weight = weight
        self.design = design
    }

    func body(content: Content) -> some View {
        content.font(.system(size: size, weight: weight, design: design))
    }
}

extension View {
    /// Text at a step of the scale, following the person's Dynamic Type setting.
    func dsFont(_ size: TextSize, _ weight: Font.Weight = .regular) -> some View {
        modifier(ScaledFont(size, weight: weight, design: .default))
    }

    /// Addresses and key material, which the web sets in its mono face.
    func dsMono(_ size: TextSize, _ weight: Font.Weight = .regular) -> some View {
        modifier(ScaledFont(size, weight: weight, design: .monospaced))
    }

    /// A heading: tighter tracking, as `--tracking-tight`.
    func dsTitle(_ size: TextSize) -> some View {
        modifier(ScaledFont(size, weight: .semibold, design: .default)).tracking(-0.02 * size.rawValue)
            .foregroundStyle(.textStrong)
    }
}
