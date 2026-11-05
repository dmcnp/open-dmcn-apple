import Foundation

// The small string rules the trust code leans on, as JavaScript has them, because the verdicts here
// have to match the browser's. Swift's own `==`, `contains` and `Character` work on grapheme clusters
// under canonical equivalence, so a look-alike that differs only in composition would compare equal,
// and "@" followed by a combining mark would not be found at all. A forged sender gets to choose
// those strings, so everything here works on scalars.

extension JSText {
    /// `a === b`.
    static func same(_ a: String, _ b: String) -> Bool {
        a.unicodeScalars.elementsEqual(b.unicodeScalars)
    }

    /// `a.toLowerCase() === b.toLowerCase()`.
    static func sameIgnoringCase(_ a: String, _ b: String) -> Bool {
        same(a.lowercased(), b.lowercased())
    }

    /// `text.includes(character)`, for a single scalar.
    static func contains(_ text: String, _ scalar: Unicode.Scalar) -> Bool {
        text.unicodeScalars.contains(scalar)
    }

    /// `text.split(/\s+/)`: an empty first or last piece when the text starts or ends in whitespace.
    static func splitOnWhitespace(_ text: String) -> [String] {
        var pieces: [String] = []
        var current = String.UnicodeScalarView()
        var inRun = false
        for scalar in text.unicodeScalars {
            if isWhitespace(scalar) {
                if !inRun {
                    pieces.append(String(current))
                    current = String.UnicodeScalarView()
                }
                inRun = true
            } else {
                current.append(scalar)
                inRun = false
            }
        }
        pieces.append(String(current))
        return pieces
    }

    /// `text.slice(0, limit)`, in UTF-16 units, dropping a surrogate the limit cut in half.
    static func prefixUTF16(_ text: String, _ limit: Int) -> String {
        var units = 0
        var out = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            units += scalar.utf16.count
            guard units <= limit else { break }
            out.append(scalar)
        }
        return String(out)
    }

    /// `new TextDecoder().decode(bytes)`: invalid sequences become U+FFFD, and a leading byte order
    /// mark is dropped.
    static func decodeUTF8(_ bytes: Data) -> String {
        let body = bytes.starts(with: [0xEF, 0xBB, 0xBF]) ? bytes.dropFirst(3) : bytes[...]
        return String(decoding: body, as: UTF8.self)
    }

    /// `atob`, which is forgiving where `Data(base64Encoded:)` isn't: ASCII whitespace is skipped
    /// and padding is optional. nil for anything else, as `atob` throws.
    static func atob(_ text: String) -> Data? {
        var symbols = text.utf8.filter { ![0x09, 0x0A, 0x0C, 0x0D, 0x20].contains($0) }
        if symbols.count % 4 == 0 {
            if symbols.last == UInt8(ascii: "=") { symbols.removeLast() }
            if symbols.last == UInt8(ascii: "=") { symbols.removeLast() }
        }
        guard symbols.count % 4 != 1 else { return nil }
        var out = Data(capacity: symbols.count * 3 / 4)
        var buffer: UInt32 = 0
        var bits = 0
        for symbol in symbols {
            guard let value = base64Value(symbol) else { return nil }
            buffer = (buffer << 6) | value
            bits += 6
            if bits >= 8 {
                bits -= 8
                out.append(UInt8((buffer >> UInt32(bits)) & 0xFF))
            }
        }
        return out
    }

    private static func base64Value(_ symbol: UInt8) -> UInt32? {
        switch symbol {
        case UInt8(ascii: "A")...UInt8(ascii: "Z"): UInt32(symbol - UInt8(ascii: "A"))
        case UInt8(ascii: "a")...UInt8(ascii: "z"): UInt32(symbol - UInt8(ascii: "a")) + 26
        case UInt8(ascii: "0")...UInt8(ascii: "9"): UInt32(symbol - UInt8(ascii: "0")) + 52
        case UInt8(ascii: "+"): 62
        case UInt8(ascii: "/"): 63
        default: nil
        }
    }
}
