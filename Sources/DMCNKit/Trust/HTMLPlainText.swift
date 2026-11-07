import Foundation

// HTML rendered down to text/plain: what the gated peek reads when a bridged message carries no text
// part of its own. Received mail is arbitrary markup, so this has to be a real rendering rather than
// a tag strip, and the browser gets its tree from DOMParser. So here is a small tree builder, keeping
// the parts of the standard's tree construction that change what the text says: implied end tags,
// tables, content the parser moves out of a table, and what goes in the head. Nothing here inserts
// HTML anywhere, and only text comes back out. Parity with the browser's lib/html/toPlainText.ts.
//
// Not modelled: the adoption agency's reconstruction of formatting elements. A link left open across
// a paragraph break isn't re-opened in the next one, so that next paragraph's text is plain rather
// than repeating the link's URL.

private final class Node {
    let name: String?
    var text = ""
    var attributes: [HTMLAttribute] = []
    var children: [Node] = []
    weak var parent: Node?
    /// In an svg or math subtree, where names mean nothing to the rendering below.
    var foreign = false

    init(name: String?) { self.name = name }

    func attribute(_ wanted: String) -> String? { attributes.first { $0.name == wanted }?.value }

    func append(_ child: Node) {
        child.parent = self
        children.append(child)
    }

    func insert(_ child: Node, before sibling: Node) {
        child.parent = self
        children.insert(child, at: children.firstIndex { $0 === sibling } ?? children.count)
    }
}

private struct TreeBuilder {
    private var tokenizer: HTMLTokenizer
    private let body = Node(name: "body")
    private var open: [Node]
    private var quirks = true
    private var pending: HTMLToken?

    private static let special: Set<String> = [
        "address", "applet", "area", "article", "aside", "base", "basefont", "bgsound", "blockquote", "body", "br",
        "button", "caption", "center", "col", "colgroup", "dd", "details", "dir", "div", "dl", "dt", "embed",
        "fieldset",
        "figcaption", "figure", "footer", "form", "frame", "frameset", "h1", "h2", "h3", "h4", "h5", "h6", "head",
        "header", "hgroup", "hr", "html", "iframe", "img", "input", "keygen", "li", "link", "listing", "main",
        "marquee",
        "menu", "meta", "nav", "noembed", "noframes", "noscript", "object", "ol", "p", "param", "plaintext", "pre",
        "script", "search", "section", "select", "source", "style", "summary", "table", "tbody", "td", "template",
        "textarea", "tfoot", "th", "thead", "title", "tr", "track", "ul", "wbr", "xmp",
    ]
    private static let scopeMarkers: Set<String> = [
        "applet", "caption", "html", "table", "td", "th", "marquee", "object", "template", "body",
    ]
    private static let closesParagraph: Set<String> = [
        "address", "article", "aside", "blockquote", "center", "details", "dialog", "dir", "div", "dl", "fieldset",
        "figcaption", "figure", "footer", "header", "hgroup", "main", "menu", "nav", "ol", "p", "search", "section",
        "summary", "ul", "form", "pre", "listing", "hr", "xmp", "plaintext",
    ]
    private static let headings: Set<String> = ["h1", "h2", "h3", "h4", "h5", "h6"]
    private static let tableParts: Set<String> = [
        "caption", "col", "colgroup", "tbody", "td", "tfoot", "th", "thead", "tr",
    ]
    private static let tableContext: Set<String> = ["table", "tbody", "thead", "tfoot", "tr"]

    init(_ html: String) {
        tokenizer = HTMLTokenizer(html)
        open = [body]
    }

    mutating func build() -> Node {
        guard readHead() else { return Node(name: "body") }
        while let token = nextToken() { process(token) }
        return body
    }

    private mutating func nextToken() -> HTMLToken? {
        if let token = pending {
            pending = nil
            return token
        }
        return tokenizer.next()
    }

    private var current: Node { open[open.count - 1] }

    // MARK: Head

    /// Reads up to where the body starts, leaving that token pending. False for a frameset document,
    /// which has no body to read.
    private mutating func readHead() -> Bool {
        while let token = nextToken() {
            switch token {
            case .comment: continue
            case .doctype(let isQuirks): quirks = isQuirks
            case .text(let text):
                let trimmed = Self.droppingLeadingTagSpace(text)
                if trimmed.isEmpty { continue }
                pending = .text(trimmed)
                return true
            case .end(let name):
                if name == "body" || name == "html" || name == "br" {
                    pending = token
                    return true
                }
            case .start(let name, _, _):
                switch name {
                case "html", "head", "noscript": continue
                case "body": return true
                case "frameset": return false
                case "template": skipElement("template")
                case _ where HTMLElements.headOnly.contains(name):
                    if let mode = HTMLElements.contentMode(of: name) {
                        tokenizer.mode = mode
                        skipElement(name)
                    }
                default:
                    pending = token
                    return true
                }
            }
        }
        return true
    }

    private static func droppingLeadingTagSpace(_ text: String) -> String {
        var scalars = Substring(text).unicodeScalars
        while let first = scalars.first, first == " " || first == "\t" || first == "\n" || first == "\u{0C}" {
            scalars.removeFirst()
        }
        return String(scalars)
    }

    private mutating func skipElement(_ name: String) {
        var depth = 1
        while depth > 0, let token = nextToken() {
            switch token {
            case .start(let inner, _, _):
                if inner == name { depth += 1 }
                if let mode = HTMLElements.contentMode(of: inner) { tokenizer.mode = mode }
            case .end(let inner):
                if inner == name { depth -= 1 }
            default: continue
            }
        }
    }

    // MARK: Body

    private mutating func process(_ token: HTMLToken) {
        switch token {
        case .text(let text): insertText(text)
        case .start(let name, let attributes, let selfClosing):
            if current.foreign {
                foreignStart(name, attributes: attributes, selfClosing: selfClosing)
            } else {
                start(name == "image" ? "img" : name, attributes: attributes)
            }
        case .end(let name):
            if current.foreign {
                foreignEnd(name)
            } else {
                end(name)
            }
        case .comment, .doctype: break
        }
    }

    private mutating func insertText(_ text: String) {
        let blank = text.unicodeScalars.allSatisfy { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\u{0C}" }
        let node = Node(name: nil)
        node.text = text
        if Self.tableContext.contains(current.name ?? ""), !blank, let table = lastOpen("table") {
            table.parent?.insert(node, before: table)
        } else {
            current.append(node)
        }
    }

    @discardableResult
    private mutating func push(_ name: String, attributes: [HTMLAttribute] = [], foreign: Bool = false) -> Node {
        let node = Node(name: name)
        node.attributes = attributes
        node.foreign = foreign
        // In a table but outside a cell, anything but the table's own parts is moved out in front.
        if !foreign, Self.tableContext.contains(current.name ?? ""), !Self.tableParts.contains(name), name != "table",
            !["style", "script", "template", "form", "input"].contains(name), let table = lastOpen("table")
        {
            table.parent?.insert(node, before: table)
        } else {
            current.append(node)
        }
        if !HTMLElements.void.contains(name) { open.append(node) }
        return node
    }

    private func lastOpen(_ name: String) -> Node? { open.last { $0.name == name } }

    /// Whether `name` is open with no scope boundary above it.
    private func inScope(_ names: Set<String>, extra: Set<String> = []) -> Bool {
        for node in open.reversed() {
            guard let tag = node.name else { continue }
            if names.contains(tag) { return true }
            if Self.scopeMarkers.contains(tag) || extra.contains(tag) { return false }
        }
        return false
    }

    /// Pops through the nearest element named in `names`.
    private mutating func popThrough(_ names: Set<String>) {
        while open.count > 1 {
            let popped = open.removeLast()
            if names.contains(popped.name ?? "") { return }
        }
    }

    private mutating func closeParagraph() {
        if inScope(["p"], extra: ["button"]) { popThrough(["p"]) }
    }

    private mutating func start(_ name: String, attributes: [HTMLAttribute]) {
        if Self.tableParts.contains(name) {
            startTablePart(name, attributes: attributes)
            return
        }
        switch name {
        case "html", "head", "body", "frameset", "frame": return
        case "table":
            if Self.tableContext.contains(current.name ?? "") {
                popThrough(["table"])  // a table can't start inside a table outside a cell
            } else if !quirks {
                closeParagraph()
            }
            push(name, attributes: attributes)
        case "li": closeListItem(["li"], then: name, attributes: attributes)
        case "dd", "dt": closeListItem(["dd", "dt"], then: name, attributes: attributes)
        case "a":
            if let index = open.lastIndex(where: { $0.name == "a" }),
                !open[index...].contains(where: { Self.scopeMarkers.contains($0.name ?? "") })
            {
                open.removeSubrange(index...)
            }
            push(name, attributes: attributes)
        case "option":
            if current.name == "option" { open.removeLast() }
            push(name, attributes: attributes)
        case "optgroup":
            if current.name == "option" { open.removeLast() }
            if current.name == "optgroup" { open.removeLast() }
            push(name, attributes: attributes)
        case "button":
            if inScope(["button"]) { popThrough(["button"]) }
            push(name, attributes: attributes)
        case "svg", "math":
            push(name, attributes: attributes, foreign: true)
            tokenizer.allowsCDATA = true
        case _ where Self.headings.contains(name):
            closeParagraph()
            if Self.headings.contains(current.name ?? "") { open.removeLast() }
            push(name, attributes: attributes)
        default:
            if Self.closesParagraph.contains(name) { closeParagraph() }
            push(name, attributes: attributes)
            if let mode = HTMLElements.contentMode(of: name) { tokenizer.mode = mode }
        }
    }

    private mutating func closeListItem(_ items: Set<String>, then name: String, attributes: [HTMLAttribute]) {
        for node in open.reversed() {
            guard let tag = node.name else { continue }
            if items.contains(tag) {
                popThrough(items)
                break
            }
            if Self.special.contains(tag), !["address", "div", "p"].contains(tag) { break }
        }
        closeParagraph()
        push(name, attributes: attributes)
    }

    /// Table structure, with the parts the source left out filled in. Outside a table it's ignored.
    private mutating func startTablePart(_ name: String, attributes: [HTMLAttribute]) {
        guard lastOpen("table") != nil else { return }
        func currentIs(_ names: Set<String>) -> Bool { names.contains(current.name ?? "") }
        switch name {
        case "caption", "colgroup", "tbody", "thead", "tfoot":
            while !currentIs(["table"]), open.count > 1 { open.removeLast() }
            push(name, attributes: attributes)
        case "col":
            if current.name != "colgroup" {
                while !currentIs(["table"]), open.count > 1 { open.removeLast() }
                push("colgroup")
            }
            push(name, attributes: attributes)
        case "tr":
            while !currentIs(["table", "tbody", "thead", "tfoot"]), open.count > 1 { open.removeLast() }
            if current.name == "table" { push("tbody") }
            push(name, attributes: attributes)
        default:  // td, th
            while !currentIs(["table", "tbody", "thead", "tfoot", "tr"]), open.count > 1 { open.removeLast() }
            if current.name == "table" { push("tbody") }
            if current.name != "tr" { push("tr") }
            push(name, attributes: attributes)
        }
    }

    private mutating func end(_ name: String) {
        switch name {
        case "body", "html": return  // content after them still lands in the body
        case "p":
            if !inScope(["p"], extra: ["button"]) { push("p") }
            popThrough(["p"])
        case "br": push("br")
        case "li":
            if inScope(["li"], extra: ["ol", "ul"]) { popThrough(["li"]) }
        case "dd", "dt":
            if inScope([name]) { popThrough([name]) }
        case _ where Self.headings.contains(name):
            if inScope(Self.headings) { popThrough(Self.headings) }
        case "table", "tbody", "thead", "tfoot", "tr", "td", "th", "caption", "colgroup":
            if open.contains(where: { $0.name == name }) { popThrough([name]) }
        default:
            if Self.special.contains(name) {
                if inScope([name]) { popThrough([name]) }
                return
            }
            // Any other end tag closes its element, unless something structural is in the way.
            for node in open.reversed() {
                if node.name == name {
                    popThrough([name])
                    return
                }
                if Self.special.contains(node.name ?? "") { return }
            }
        }
    }

    // MARK: Foreign content

    private var inIntegrationPoint: Bool {
        open.contains { $0.foreign && HTMLElements.integrationPoints.contains($0.name ?? "") }
    }

    private mutating func foreignStart(_ name: String, attributes: [HTMLAttribute], selfClosing: Bool) {
        if HTMLElements.breaksOutOfForeign.contains(name), !inIntegrationPoint {
            leaveForeign()
            start(name, attributes: attributes)
            return
        }
        let node = Node(name: name)
        node.foreign = true
        node.attributes = attributes
        current.append(node)
        if !selfClosing { open.append(node) }
    }

    private mutating func foreignEnd(_ name: String) {
        if name == "p" || name == "br", !inIntegrationPoint {
            leaveForeign()
            end(name)
            return
        }
        guard open.contains(where: { $0.foreign && $0.name == name }) else { return }
        popThrough([name])
        tokenizer.allowsCDATA = current.foreign
    }

    private mutating func leaveForeign() {
        while current.foreign { open.removeLast() }
        tokenizer.allowsCDATA = false
    }
}

public enum HTMLPlainText {
    /// Elements that start and end a line. Table rows and cells are here because mail is overwhelmingly
    /// laid out in tables: without them a newsletter renders as one unbroken paragraph.
    private static let block: Set<String> = [
        "p", "div", "li", "ul", "ol", "blockquote", "pre", "h1", "h2", "h3", "hr", "h4", "h5", "h6", "table", "tr",
        "td",
        "th", "section", "article", "header", "footer", "center", "address", "dt", "dd",
    ]
    /// Elements whose text isn't message content.
    private static let skipped: Set<String> = [
        "script", "style", "head", "title", "noscript", "template", "iframe", "object", "embed",
    ]

    /// The text/plain rendering of received HTML.
    public static func render(_ html: String) -> String {
        guard !html.isEmpty else { return "" }
        var builder = TreeBuilder(html)
        let out = renderChildren(of: builder.build(), pre: false)
        return trimmingEnd(stripLeadingNewlines(collapseBlankLines(stripSpacesBeforeNewlines(out))))
    }

    private static func renderChildren(of node: Node, pre: Bool) -> String {
        node.children.map { render($0, pre: pre) }.joined()
    }

    private static func render(_ node: Node, pre: Bool) -> String {
        guard let name = node.name else {
            // Outside <pre>, whitespace is insignificant: runs collapse to one space so the source's
            // own indentation doesn't leak into the rendering.
            return pre ? node.text : collapsingWhitespace(node.text)
        }
        guard !node.foreign else { return renderChildren(of: node, pre: pre) }
        if skipped.contains(name) { return "" }
        switch name {
        case "br": return "\n"
        case "hr": return "\n---\n"
        case "img":
            // Only images with alt text say anything. Mail is full of spacers and tracking pixels.
            let alt = JSText.trim(node.attribute("alt") ?? "")
            return alt.isEmpty ? "" : "[image: \(alt)]"
        case "a": return renderLink(node, pre: pre)
        case "pre": return "\n" + trimmingNewlines(renderChildren(of: node, pre: true)) + "\n"
        case "blockquote":
            let inner = trimmingNewlines(renderChildren(of: node, pre: pre))
            return "\n" + prefixingLines(inner, "> ") + "\n"
        case "ul", "ol":
            // Only the direct <li> children count, so a nested list restarts at 1.
            let items = node.children.filter { $0.name == "li" && !$0.foreign }
            let lines = items.enumerated().map { index, item in
                let marker = name == "ol" ? "\(index + 1). " : "- "
                let body = JSText.trim(trimmingNewlines(renderChildren(of: item, pre: pre)))
                // Continuation lines align under the marker's text.
                return replacingLeadingSpaces(
                    prefixingLines(body, String(repeating: " ", count: marker.count)), with: marker)
            }
            return "\n" + lines.joined(separator: "\n") + "\n"
        default:
            let inner = renderChildren(of: node, pre: pre)
            return block.contains(name) ? "\n" + trimmingEdges(inner) + "\n" : inner
        }
    }

    private static func renderLink(_ node: Node, pre: Bool) -> String {
        let text = JSText.trim(renderChildren(of: node, pre: pre))
        let href = JSText.trim(node.attribute("href") ?? "")
        // Spelled out only when it adds something: a bare link, an in-page anchor or a cid: reference
        // would otherwise read "https://x <https://x>".
        let scalars = href.unicodeScalars
        let local = scalars.first == "#" || scalars.starts(with: "cid:".unicodeScalars)
        let bare = href.isEmpty || local ? "" : href
        if href.isEmpty || JSText.same(href, text) || bare.isEmpty { return text.isEmpty ? bare : text }
        return text.isEmpty ? "<\(href)>" : "\(text) <\(href)>"
    }

    // The string passes below are JavaScript's regexes, on scalars, so CR LF stays two characters.

    /// `replace(/\s+/g, ' ')`.
    private static func collapsingWhitespace(_ text: String) -> String {
        var out = String.UnicodeScalarView()
        var inRun = false
        for scalar in text.unicodeScalars {
            if JSText.isWhitespace(scalar) {
                if !inRun { out.append(" ") }
                inRun = true
            } else {
                out.append(scalar)
                inRun = false
            }
        }
        return String(out)
    }

    /// Strips spaces and tabs, never newlines, from both ends of a block.
    private static func trimmingEdges(_ text: String) -> String {
        var scalars = Substring(text).unicodeScalars
        while let first = scalars.first, first == " " || first == "\t" { scalars.removeFirst() }
        while let last = scalars.last, last == " " || last == "\t" { scalars.removeLast() }
        return String(scalars)
    }

    /// `replace(/^\n+|\n+$/g, '')`.
    private static func trimmingNewlines(_ text: String) -> String {
        var scalars = Substring(text).unicodeScalars
        while scalars.first == "\n" { scalars.removeFirst() }
        while scalars.last == "\n" { scalars.removeLast() }
        return String(scalars)
    }

    private static func lines(_ text: String) -> [String] {
        text.unicodeScalars.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    }

    /// Prefixes every line of a block, the blockquote's "> " or a list item's indent.
    private static func prefixingLines(_ text: String, _ prefix: String) -> String {
        let blankPrefix = String(trimmingTrailingWhitespace(prefix))
        return lines(text).map { $0.isEmpty ? blankPrefix : prefix + $0 }.joined(separator: "\n")
    }

    /// `trimEnd()`.
    private static func trimmingTrailingWhitespace(_ text: String) -> String {
        var scalars = Substring(text).unicodeScalars
        while let last = scalars.last, JSText.isWhitespace(last) { scalars.removeLast() }
        return String(scalars)
    }

    /// `replace(/^ +/, marker)`, which leaves a line without leading spaces as it is.
    private static func replacingLeadingSpaces(_ text: String, with marker: String) -> String {
        var scalars = Substring(text).unicodeScalars
        guard scalars.first == " " else { return text }
        while scalars.first == " " { scalars.removeFirst() }
        return marker + String(scalars)
    }

    /// `replace(/[ \t]+\n/g, '\n')`.
    private static func stripSpacesBeforeNewlines(_ text: String) -> String {
        var out = String.UnicodeScalarView()
        var run = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            if scalar == " " || scalar == "\t" {
                run.append(scalar)
            } else {
                if scalar != "\n" { out.append(contentsOf: run) }
                run = String.UnicodeScalarView()
                out.append(scalar)
            }
        }
        out.append(contentsOf: run)
        return String(out)
    }

    /// `replace(/\n{3,}/g, '\n\n')`.
    private static func collapseBlankLines(_ text: String) -> String {
        var out = String.UnicodeScalarView()
        var newlines = 0
        for scalar in text.unicodeScalars {
            newlines = scalar == "\n" ? newlines + 1 : 0
            if newlines <= 2 { out.append(scalar) }
        }
        return String(out)
    }

    /// `replace(/^\n+/, '')`.
    private static func stripLeadingNewlines(_ text: String) -> String {
        var scalars = Substring(text).unicodeScalars
        while scalars.first == "\n" { scalars.removeFirst() }
        return String(scalars)
    }

    /// `replace(/\s+$/, '')`.
    private static func trimmingEnd(_ text: String) -> String { trimmingTrailingWhitespace(text) }
}
