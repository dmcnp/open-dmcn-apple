import Foundation

// A tokenizer for the HTML that arrives in mail, after the HTML standard's states. No DOM exists here
// to parse into, and what a browser makes of a string is exactly what a hostile sender plays with, so
// this follows the standard where a regex wouldn't: `>` inside a quoted attribute, a tag with no end,
// `--!>` closing a comment, the first of two `src` attributes winning, and raw text elements whose
// contents aren't markup at all.
//
// It works on scalars, never on `Character`: a Swift character can be CR LF as one unit, or `<` with
// a combining mark on it, and neither is what a browser sees.

struct HTMLAttribute: Sendable, Equatable {
    let name: String
    var value: String
}

enum HTMLToken: Sendable, Equatable {
    /// Text with its character references decoded.
    case text(String)
    case start(name: String, attributes: [HTMLAttribute], selfClosing: Bool)
    case end(name: String)
    case comment
    case doctype(quirks: Bool)
}

struct HTMLTokenizer {
    enum Mode: Equatable {
        case data
        /// Text with character references, up to its end tag: `textarea`, `title`.
        case rcdata(String)
        /// Text as it stands, up to its end tag: `style`, `script`, `xmp`, `iframe`, `noembed`, `noframes`.
        case rawtext(String)
        /// Everything to the end of the input.
        case plaintext
    }

    /// The tree builder sets this after a start tag, as the standard has it. It goes back to `.data`
    /// on its own once the end tag is reached.
    var mode = Mode.data
    /// `<![CDATA[` is a section in foreign content and a bogus comment everywhere else.
    var allowsCDATA = false

    private let input: [Unicode.Scalar]
    private var pos = 0

    init(_ html: String) {
        // The standard's input preprocessing: CR LF and lone CR are both LF.
        var scalars: [Unicode.Scalar] = []
        scalars.reserveCapacity(html.unicodeScalars.count)
        var lastWasCR = false
        for scalar in html.unicodeScalars {
            if scalar == "\r" {
                scalars.append("\n")
            } else if scalar != "\n" || !lastWasCR {
                scalars.append(scalar)
            }
            lastWasCR = scalar == "\r"
        }
        input = scalars
    }

    /// The next token, or nil at the end. A tag the input ends inside of is dropped whole, as the
    /// standard does: nothing of `<img src=x` reaches anything.
    mutating func next() -> HTMLToken? {
        switch mode {
        case .data: nextInData()
        case .rcdata(let name): nextUntilEndTag(name, decoding: true)
        case .rawtext(let name): nextUntilEndTag(name, decoding: false)
        case .plaintext: nextPlaintext()
        }
    }

    // MARK: Data

    private mutating func nextInData() -> HTMLToken? {
        var text = String.UnicodeScalarView()
        while pos < input.count {
            let scalar = input[pos]
            if scalar == "<" {
                guard let opens = peekMarkup() else {
                    text.append("<")
                    pos += 1
                    continue
                }
                if !text.isEmpty { return .text(String(text)) }
                if let token = readMarkup(opens) { return token }
                continue
            }
            if scalar == "&" {
                appendReference(to: &text, inAttribute: false)
                continue
            }
            // A NUL in body text is dropped by the tree construction stage.
            if scalar != "\0" { text.append(scalar) }
            pos += 1
        }
        return text.isEmpty ? nil : .text(String(text))
    }

    private enum Markup {
        case tag, endTag, emptyEndTag, declaration, bogus
    }

    /// What the `<` at `pos` opens, or nil when it's only a less-than sign.
    private func peekMarkup() -> Markup? {
        guard pos + 1 < input.count else { return nil }
        let next = input[pos + 1]
        if isASCIILetter(next) { return .tag }
        switch next {
        case "!": return .declaration
        case "?": return .bogus
        case "/":
            guard pos + 2 < input.count else { return nil }
            let after = input[pos + 2]
            if isASCIILetter(after) { return .endTag }
            return after == ">" ? .emptyEndTag : .bogus
        default: return nil
        }
    }

    private mutating func readMarkup(_ kind: Markup) -> HTMLToken? {
        switch kind {
        case .tag:
            pos += 1
            return readTag(isEnd: false)
        case .endTag:
            pos += 2
            return readTag(isEnd: true)
        case .emptyEndTag:
            pos += 3
            return nil
        case .bogus:
            pos += 1
            skipBogusComment()
            return .comment
        case .declaration:
            pos += 2
            return readDeclaration()
        }
    }

    private mutating func readDeclaration() -> HTMLToken? {
        if startsWith("--") {
            pos += 2
            skipComment()
            return .comment
        }
        if startsWithIgnoringCase("doctype") {
            pos += 7
            return readDoctype()
        }
        if allowsCDATA, startsWith("[CDATA[") {
            pos += 7
            var text = String.UnicodeScalarView()
            while pos < input.count, !startsWith("]]>") {
                text.append(input[pos])
                pos += 1
            }
            pos = min(pos + 3, input.count)
            return .text(String(text))
        }
        skipBogusComment()
        return .comment
    }

    private mutating func skipBogusComment() {
        while pos < input.count, input[pos] != ">" { pos += 1 }
        pos = min(pos + 1, input.count)
    }

    /// `pos` is just past `<!--`. A comment closes at `-->` or `--!>`, and also, abruptly, right at
    /// `>` or `->`. One that never closes runs to the end of the input.
    private mutating func skipComment() {
        if startsWith(">") {
            pos += 1
            return
        }
        if startsWith("->") {
            pos += 2
            return
        }
        while pos < input.count {
            if startsWith("-->") {
                pos += 3
                return
            }
            if startsWith("--!>") {
                pos += 4
                return
            }
            pos += 1
        }
    }

    private mutating func readDoctype() -> HTMLToken {
        var body = String.UnicodeScalarView()
        while pos < input.count, input[pos] != ">" {
            body.append(input[pos])
            pos += 1
        }
        pos = min(pos + 1, input.count)
        return .doctype(quirks: Self.isQuirks(doctype: String(body).lowercased()))
    }

    /// Whether a doctype puts the document in quirks mode, where `<table>` doesn't close `<p>`. Only
    /// the ones mail actually carries.
    private static func isQuirks(doctype: String) -> Bool {
        let words = JSText.splitOnWhitespace(JSText.trim(doctype))
        guard words.first == "html" else { return true }
        guard doctype.contains("public") else { return false }
        let hasSystemID =
            doctype.components(separatedBy: "\"").count >= 5 || doctype.components(separatedBy: "'").count >= 5
        if doctype.contains("//dtd html 3") || doctype.contains("//dtd html 2") || doctype.contains("-//ietf//dtd html")
        {
            return true
        }
        if doctype.contains("//dtd html 4.0 ") || doctype.contains("//dtd html 4.01 ") {
            return !hasSystemID && (doctype.contains("transitional") || doctype.contains("frameset"))
        }
        return false
    }

    // MARK: Tags

    /// `pos` is on the tag name's first letter.
    private mutating func readTag(isEnd: Bool) -> HTMLToken? {
        var name = String.UnicodeScalarView()
        while pos < input.count {
            let scalar = input[pos]
            if isTagSpace(scalar) || scalar == "/" || scalar == ">" { break }
            name.append(lowered(scalar == "\0" ? "\u{FFFD}" : scalar))
            pos += 1
        }
        guard let (attributes, selfClosing) = readAttributes() else { return nil }
        let tag = String(name)
        return isEnd ? .end(name: tag) : .start(name: tag, attributes: attributes, selfClosing: selfClosing)
    }

    /// From just after the tag name through its `>`. nil when the input ends first.
    private mutating func readAttributes() -> (attributes: [HTMLAttribute], selfClosing: Bool)? {
        var attributes: [HTMLAttribute] = []
        var seen = Set<String>()
        while true {
            while pos < input.count, isTagSpace(input[pos]) { pos += 1 }
            guard pos < input.count else { return nil }
            let scalar = input[pos]
            if scalar == ">" {
                pos += 1
                return (attributes, false)
            }
            if scalar == "/" {
                pos += 1
                guard pos < input.count else { return nil }
                if input[pos] == ">" {
                    pos += 1
                    return (attributes, true)
                }
                continue
            }
            guard let attribute = readAttribute() else { return nil }
            // The first of two with the same name wins, whichever the sender hoped would be read.
            if seen.insert(attribute.name).inserted { attributes.append(attribute) }
        }
    }

    private mutating func readAttribute() -> HTMLAttribute? {
        var name = String.UnicodeScalarView()
        // A leading `=` is part of the name, and only there.
        if input[pos] == "=" {
            name.append("=")
            pos += 1
        }
        while pos < input.count {
            let scalar = input[pos]
            if isTagSpace(scalar) || scalar == "/" || scalar == ">" || scalar == "=" { break }
            name.append(lowered(scalar == "\0" ? "\u{FFFD}" : scalar))
            pos += 1
        }
        while pos < input.count, isTagSpace(input[pos]) { pos += 1 }
        guard pos < input.count else { return nil }
        guard input[pos] == "=" else { return HTMLAttribute(name: String(name), value: "") }
        pos += 1
        while pos < input.count, isTagSpace(input[pos]) { pos += 1 }
        guard pos < input.count else { return nil }

        var value = String.UnicodeScalarView()
        let quote = input[pos]
        if quote == "\"" || quote == "'" {
            pos += 1
            while pos < input.count, input[pos] != quote { appendAttributeScalar(to: &value) }
            guard pos < input.count else { return nil }
            pos += 1
        } else if quote != ">" {
            while pos < input.count, !isTagSpace(input[pos]), input[pos] != ">" { appendAttributeScalar(to: &value) }
        }
        return HTMLAttribute(name: String(name), value: String(value))
    }

    private mutating func appendAttributeScalar(to value: inout String.UnicodeScalarView) {
        let scalar = input[pos]
        if scalar == "&" {
            appendReference(to: &value, inAttribute: true)
            return
        }
        value.append(scalar == "\0" ? "\u{FFFD}" : scalar)
        pos += 1
    }

    // MARK: Raw text

    private mutating func nextUntilEndTag(_ name: String, decoding: Bool) -> HTMLToken? {
        var text = String.UnicodeScalarView()
        while pos < input.count {
            if input[pos] == "<", isEndTag(name) {
                mode = .data
                if !text.isEmpty { return .text(String(text)) }
                pos += 2
                return readTag(isEnd: true)
            }
            if decoding, input[pos] == "&" {
                appendReference(to: &text, inAttribute: false)
                continue
            }
            text.append(input[pos] == "\0" ? "\u{FFFD}" : input[pos])
            pos += 1
        }
        mode = .data
        return text.isEmpty ? nil : .text(String(text))
    }

    private mutating func nextPlaintext() -> HTMLToken? {
        guard pos < input.count else { return nil }
        var text = String.UnicodeScalarView()
        text.append(contentsOf: input[pos...].map { $0 == "\0" ? "\u{FFFD}" : $0 })
        pos = input.count
        return .text(String(text))
    }

    /// `</name` at `pos`, followed by something that ends a tag name. `</styled>` doesn't close a style.
    private func isEndTag(_ name: String) -> Bool {
        let scalars = Array(name.unicodeScalars)
        guard pos + 2 + scalars.count < input.count, input[pos + 1] == "/" else { return false }
        for (offset, scalar) in scalars.enumerated() where lowered(input[pos + 2 + offset]) != scalar { return false }
        let after = input[pos + 2 + scalars.count]
        return isTagSpace(after) || after == "/" || after == ">"
    }

    // MARK: Character references

    /// `pos` is on an `&`. Appends what it decodes to, or the `&` itself, and moves past it.
    private mutating func appendReference(to out: inout String.UnicodeScalarView, inAttribute: Bool) {
        if pos + 1 < input.count, input[pos + 1] == "#" {
            appendNumericReference(to: &out)
            return
        }
        // The longest name that matches. The input is scanned for alphanumerics first, so `&notin;`
        // finds "notin" rather than stopping at the older "not".
        var end = pos + 1
        while end < input.count, end - pos <= HTMLEntities.longestName, isASCIIAlphanumeric(input[end]) { end += 1 }
        var length = end - (pos + 1)
        while length > 0 {
            var name = String.UnicodeScalarView()
            name.append(contentsOf: input[(pos + 1)..<(pos + 1 + length)])
            let key = String(name)
            let after = pos + 1 + length
            let hasSemicolon = after < input.count && input[after] == ";"
            if let value = HTMLEntities.named[key], hasSemicolon || HTMLEntities.legacy.contains(key) {
                // An unterminated reference in an attribute is left alone when text follows it, so
                // `?a=1&copy=2` in a URL keeps its meaning.
                if !hasSemicolon, inAttribute, after < input.count,
                    input[after] == "=" || isASCIIAlphanumeric(input[after])
                {
                    break
                }
                out.append(contentsOf: value.unicodeScalars)
                pos = after + (hasSemicolon ? 1 : 0)
                return
            }
            length -= 1
        }
        out.append("&")
        pos += 1
    }

    private mutating func appendNumericReference(to out: inout String.UnicodeScalarView) {
        var cursor = pos + 2
        let hexadecimal = cursor < input.count && (input[cursor] == "x" || input[cursor] == "X")
        if hexadecimal { cursor += 1 }
        let digitsStart = cursor
        var value: UInt32 = 0
        while cursor < input.count, let digit = digitValue(input[cursor], hexadecimal: hexadecimal) {
            // Saturates: anything past the top of Unicode reads as a bad reference.
            value = min(value &* (hexadecimal ? 16 : 10) &+ digit, 0x0011_0000)
            cursor += 1
        }
        guard cursor > digitsStart else {
            out.append("&")
            pos += 1
            return
        }
        if cursor < input.count, input[cursor] == ";" { cursor += 1 }
        pos = cursor
        out.append(Self.scalar(forReference: value))
    }

    private func digitValue(_ scalar: Unicode.Scalar, hexadecimal: Bool) -> UInt32? {
        switch scalar {
        case "0"..."9": scalar.value - 0x30
        case "a"..."f" where hexadecimal: scalar.value - 0x61 + 10
        case "A"..."F" where hexadecimal: scalar.value - 0x41 + 10
        default: nil
        }
    }

    /// The standard's numeric reference rules: nothing invalid gets through as itself, and the C1
    /// range means what Windows-1252 meant by it, as it did on the web that wrote those references.
    private static func scalar(forReference value: UInt32) -> Unicode.Scalar {
        if value == 0 || value > 0x10_FFFF || (0xD800...0xDFFF).contains(value) { return "\u{FFFD}" }
        if (0x80...0x9F).contains(value), let mapped = windows1252[value] { return mapped }
        return Unicode.Scalar(value) ?? "\u{FFFD}"
    }

    private static let windows1252: [UInt32: Unicode.Scalar] = [
        0x80: "\u{20AC}", 0x82: "\u{201A}", 0x83: "\u{0192}", 0x84: "\u{201E}", 0x85: "\u{2026}", 0x86: "\u{2020}",
        0x87: "\u{2021}", 0x88: "\u{02C6}", 0x89: "\u{2030}", 0x8A: "\u{0160}", 0x8B: "\u{2039}", 0x8C: "\u{0152}",
        0x8E: "\u{017D}", 0x91: "\u{2018}", 0x92: "\u{2019}", 0x93: "\u{201C}", 0x94: "\u{201D}", 0x95: "\u{2022}",
        0x96: "\u{2013}", 0x97: "\u{2014}", 0x98: "\u{02DC}", 0x99: "\u{2122}", 0x9A: "\u{0161}", 0x9B: "\u{203A}",
        0x9C: "\u{0153}", 0x9E: "\u{017E}", 0x9F: "\u{0178}",
    ]

    // MARK: Scanning

    private func startsWith(_ text: String) -> Bool {
        var cursor = pos
        for scalar in text.unicodeScalars {
            guard cursor < input.count, input[cursor] == scalar else { return false }
            cursor += 1
        }
        return true
    }

    private func startsWithIgnoringCase(_ text: String) -> Bool {
        var cursor = pos
        for scalar in text.unicodeScalars {
            guard cursor < input.count, lowered(input[cursor]) == scalar else { return false }
            cursor += 1
        }
        return true
    }

    private func isTagSpace(_ scalar: Unicode.Scalar) -> Bool {
        scalar == " " || scalar == "\t" || scalar == "\n" || scalar == "\u{0C}"
    }

    private func isASCIILetter(_ scalar: Unicode.Scalar) -> Bool {
        ("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar)
    }

    private func isASCIIAlphanumeric(_ scalar: Unicode.Scalar) -> Bool {
        isASCIILetter(scalar) || ("0"..."9").contains(scalar)
    }

    /// ASCII only: `K` (the Kelvin sign) is not a `k`, and tag names aren't Unicode-folded.
    private func lowered(_ scalar: Unicode.Scalar) -> Unicode.Scalar {
        ("A"..."Z").contains(scalar) ? Unicode.Scalar(scalar.value + 32) ?? scalar : scalar
    }
}

/// What the tokenizer can't know: which elements end up where. Shared by the reader's plain-text
/// rendering and the document it builds for HTML.
enum HTMLElements {
    /// Tags that stay in a document's head, so nothing before them starts its body.
    static let headOnly: Set<String> = [
        "base", "basefont", "bgsound", "link", "meta", "noframes", "script", "style", "template", "title",
    ]
    /// Elements with no end tag.
    static let void: Set<String> = [
        "area", "base", "basefont", "bgsound", "br", "col", "embed", "hr", "img", "input", "keygen", "link", "meta",
        "param", "source", "track", "wbr",
    ]

    /// The mode an element's contents are read in. Set right after its start tag.
    static func contentMode(of name: String) -> HTMLTokenizer.Mode? {
        switch name {
        case "title", "textarea": .rcdata(name)
        case "style", "script", "xmp", "iframe", "noembed", "noframes": .rawtext(name)
        case "plaintext": .plaintext
        default: nil
        }
    }

    /// Start tags that end foreign content, however deep: what lets `<svg><img>` be an image.
    static let breaksOutOfForeign: Set<String> = [
        "b", "big", "blockquote", "body", "br", "center", "code", "dd", "div", "dl", "dt", "em", "embed", "h1", "h2",
        "h3", "h4", "h5", "h6", "head", "hr", "i", "img", "li", "listing", "menu", "meta", "nobr", "ol", "p", "pre",
        "ruby", "s", "small", "span", "strong", "strike", "sub", "sup", "table", "tt", "u", "ul", "var",
    ]
    /// Inside these, foreign content holds HTML again, which doesn't break out of anything.
    static let integrationPoints: Set<String> = [
        "mi", "mo", "mn", "ms", "mtext", "annotation-xml", "foreignobject", "desc", "title",
    ]
}
