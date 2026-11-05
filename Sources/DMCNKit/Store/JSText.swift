import Foundation

// Keys and previews are computed from text on both clients, so the small text rules have to be
// JavaScript's: its idea of whitespace differs from Foundation's (U+0085 is not whitespace to it,
// U+FEFF is), and its string lengths count UTF-16 units.

enum JSText {
    /// What JavaScript's `\s` and `String.prototype.trim` treat as whitespace.
    static func isWhitespace(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x09...0x0D, 0x20, 0xA0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF:
            return true
        default:
            return false
        }
    }

    static func trim(_ text: String) -> String {
        var scalars = Substring(text).unicodeScalars
        while let first = scalars.first, isWhitespace(first) { scalars.removeFirst() }
        while let last = scalars.last, isWhitespace(last) { scalars.removeLast() }
        return String(scalars)
    }

    /// The form both clients key an address by.
    static func normalizedAddress(_ address: String) -> String {
        trim(address).lowercased()
    }

    /// `text.replace(/\s+/g, ' ').trim()`.
    static func foldedWhitespace(_ text: String) -> String {
        var out = String.UnicodeScalarView()
        var inRun = false
        for scalar in text.unicodeScalars {
            if isWhitespace(scalar) {
                if !inRun { out.append(" ") }
                inRun = true
            } else {
                out.append(scalar)
                inRun = false
            }
        }
        return trim(String(out))
    }
}
