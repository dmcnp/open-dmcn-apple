import Foundation

// Turning text into the words the index stores, and a query into the words it looks up. Both go
// through here: the index is a set of folded tokens, and a term only finds what it was folded to
// match. Parity with the browser's lib/search/tokenize.ts, except for text written without spaces,
// below.

/// Namespace for search: the query language, the tokenizer and the on-device index.
public enum MailSearch {}

extension MailSearch {
    /// Text past this point in one message isn't indexed. Mail longer than this is almost always a
    /// pasted log or a forwarded thread.
    public static let maxIndexChars = 256 * 1024
    /// Longer "words" are base64, hashes and URLs: noise, and never typed into a search.
    public static let maxToken = 40

    /// Removes case, accents and compatibility forms ("Café" to "cafe", the "ﬁ" ligature to "fi").
    public static func fold(_ text: String) -> String {
        if text.utf8.allSatisfy({ $0 < 0x80 }) { return text.lowercased() }
        var kept = String.UnicodeScalarView()
        for scalar in text.decomposedStringWithCompatibilityMapping.unicodeScalars where !isMark(scalar) {
            kept.append(scalar)
        }
        // NFC puts back what was decomposed but not dropped: Hangul would otherwise stay as loose jamo.
        return JSText.lowercased(String(kept).precomposedStringWithCanonicalMapping)
    }

    private static func isMark(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .nonspacingMark, .spacingMark, .enclosingMark: true
        default: false
        }
    }

    private static func isWordScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
            .decimalNumber, .letterNumber, .otherNumber:
            true
        default: false
        }
    }

    /// `\p{Script=Han}`, Hiragana, Katakana and Hangul, as the browser's regex matches them: scripts
    /// where one character is routinely a whole word. Everywhere else it's noise and is dropped.
    /// Swift has no script property, and these ranges came out of that regex. Sorted, for the search.
    private static let ideographic: [ClosedRange<UInt32>] = [
        0x1100...0x11FF, 0x2E80...0x2E99, 0x2E9B...0x2EF3, 0x2F00...0x2FD5, 0x3005...0x3005, 0x3007...0x3007,
        0x3021...0x3029, 0x302E...0x302F, 0x3038...0x303B, 0x3041...0x3096, 0x309D...0x309F, 0x30A1...0x30FA,
        0x30FD...0x30FF, 0x3131...0x318E, 0x31F0...0x321E, 0x3260...0x327E, 0x32D0...0x32FE, 0x3300...0x3357,
        0x3400...0x4DBF, 0x4E00...0x9FFF, 0xA960...0xA97C, 0xAC00...0xD7A3, 0xD7B0...0xD7C6, 0xD7CB...0xD7FB,
        0xF900...0xFA6D, 0xFA70...0xFAD9, 0xFF66...0xFF6F, 0xFF71...0xFF9D, 0xFFA0...0xFFBE, 0xFFC2...0xFFC7,
        0xFFCA...0xFFCF, 0xFFD2...0xFFD7, 0xFFDA...0xFFDC, 0x16FE2...0x16FE3, 0x16FF0...0x16FF6, 0x1AFF0...0x1AFF3,
        0x1AFF5...0x1AFFB, 0x1AFFD...0x1AFFE, 0x1B000...0x1B122, 0x1B132...0x1B132, 0x1B150...0x1B152,
        0x1B155...0x1B155, 0x1B164...0x1B167, 0x1F200...0x1F200, 0x20000...0x2A6DF, 0x2A700...0x2B81D,
        0x2B820...0x2CEAD, 0x2CEB0...0x2EBE0, 0x2EBF0...0x2EE5D, 0x2F800...0x2FA1D, 0x30000...0x3134A,
        0x31350...0x33479,
    ]

    private static func isIdeographic(_ scalar: Unicode.Scalar) -> Bool {
        let value = scalar.value
        if value < 0x1100 { return false }
        var low = 0
        var high = ideographic.count - 1
        while low <= high {
            let middle = (low + high) / 2
            let range = ideographic[middle]
            if range.contains(value) { return true }
            if value < range.lowerBound { high = middle - 1 } else { low = middle + 1 }
        }
        return false
    }

    /// Scripts written without spaces between words. Hangul isn't one: Korean has spaces.
    private static func isUnspaced(_ scalar: Unicode.Scalar) -> Bool {
        let value = scalar.value
        // The Katakana length mark belongs to no script, but it's inside the words.
        if value == 0x30FC { return true }
        switch value {
        case 0x0E00...0x0EFF, 0x1000...0x109F, 0x1780...0x17FF, 0x19E0...0x19FF, 0xA9E0...0xA9FF, 0xAA60...0xAA7F:
            return true  // Thai, Lao, Myanmar, Khmer
        default:
            guard value >= 0x2E80, isIdeographic(scalar) else { return false }
            return !(0xAC00...0xD7FB).contains(value) && !(0x3131...0x318E).contains(value)
                && !(0xA960...0xA97C).contains(value)
        }
    }

    private static func keep(_ token: ArraySlice<Unicode.Scalar>) -> Bool {
        if token.count > maxToken { return false }
        return token.count >= 2 || token.contains(where: isIdeographic)
    }

    /// Every distinct token in text, in first-seen order.
    ///
    /// The browser finds words in unspaced text with `Intl.Segmenter`, which has a dictionary. Swift
    /// has no such thing on every platform, and a tokenizer that differs by platform can't be tested
    /// here. So a run of unspaced script becomes one token per position, each two characters long
    /// and the last one alone. Lookups are prefix matches and a term is tokenized the same way, so
    /// any word the dictionary would find is still found, and some it wouldn't be asked for too.
    public static func tokenize(_ text: String) -> [String] {
        let clipped =
            text.utf16.count > maxIndexChars
            ? String(text[..<text.utf16.index(text.startIndex, offsetBy: maxIndexChars)]) : text
        var seen = Set<String>()
        var tokens: [String] = []
        func take(_ token: ArraySlice<Unicode.Scalar>) {
            guard keep(token) else { return }
            var out = String.UnicodeScalarView()
            out.append(contentsOf: token)
            let word = String(out)
            if seen.insert(word).inserted { tokens.append(word) }
        }
        func takeRun(_ run: ArraySlice<Unicode.Scalar>) {
            var start = run.startIndex
            while start < run.endIndex {
                let unspaced = isUnspaced(run[start])
                let end = run[start...].firstIndex { isUnspaced($0) != unspaced } ?? run.endIndex
                if unspaced {
                    for i in start..<end { take(run[i..<min(i + 2, end)]) }
                } else {
                    take(run[start..<end])
                }
                start = end
            }
        }
        let scalars = Array(fold(clipped).unicodeScalars)
        var i = 0
        while i < scalars.count {
            guard isWordScalar(scalars[i]) else {
                i += 1
                continue
            }
            let end = scalars[i...].firstIndex { !isWordScalar($0) } ?? scalars.count
            takeRun(scalars[i..<end])
            i = end
        }
        return tokens
    }

    /// The shard a token lives in: its first two characters. A term is a prefix of the tokens it
    /// finds, and every token sharing its first two characters is in one shard, so a term of two or
    /// more reads exactly one.
    public static func shardOf(_ token: String) -> String {
        var out = String.UnicodeScalarView()
        out.append(contentsOf: token.unicodeScalars.prefix(2))
        return String(out)
    }
}

extension JSText {
    /// `text.toLowerCase()`. `lowercased()` has no idea of context, so it misses the one rule that
    /// needs it: a Greek capital sigma ending a word becomes the final form, which is how "ΣΑΣ"
    /// comes to match "σας".
    static func lowercased(_ text: String) -> String {
        guard text.unicodeScalars.contains("\u{3A3}") else { return text.lowercased() }
        let scalars = Array(text.unicodeScalars)
        var out = ""
        for (i, scalar) in scalars.enumerated() {
            out += scalar == "\u{3A3}" && isFinalSigma(scalars, i) ? "\u{3C2}" : scalar.properties.lowercaseMapping
        }
        return out
    }

    private static func isFinalSigma(_ s: [Unicode.Scalar], _ i: Int) -> Bool {
        let before = s[..<i].last { !$0.properties.isCaseIgnorable }
        let after = s[(i + 1)...].first { !$0.properties.isCaseIgnorable }
        return before?.properties.isCased == true && after?.properties.isCased != true
    }
}
