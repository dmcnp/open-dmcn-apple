import Foundation

// A received HTML part as the document the app shows in a WKWebView with JavaScript off, a blanket
// content rule on network loads, and no navigation. Parity with the browser's
// components/HtmlMessageBody.tsx for the document shell and policy, and lib/html/sanitize.ts for what
// happens to images.
//
// The browser parses with DOMPurify before any of that. There's no DOM here, so this is a second
// layer of a different kind: a tokenizer pass with DOMPurify's allowlists and URI rule, which rebuilds
// the markup from what it recognised rather than editing the original, so no tag it didn't understand
// survives in any form. Text comes back out escaped, and every attribute re-quoted.
//
// What it's weaker at than DOMPurify, plainly:
//
// - It never builds a tree, so it can't see what a browser's tree construction will do with the
//   markup it emits: foster parenting, misnested formatting, namespace changes. DOMPurify checks the
//   tree after parsing, and that's its defence against mutation attacks. This one's defence is that
//   every tag it emits has already passed on its own, whatever it ends up nested in.
// - Foreign content (svg, math) is dropped by following the break-out rules approximately. Where it
//   gets that wrong it drops too much or keeps a tag that has passed the same filter as any other.
// - `script` has no double-escaped state: `<script><!--<script></script>--></script>` ends a tag early
//   here. What follows is then read as markup and filtered, so it shows as text rather than escaping.
// - `<template>` is dropped with its contents. DOMPurify keeps and cleans it. An image in one counts
//   towards `blockedRemote` there and not here. It could never have loaded either way.
// - `style` attributes and `<style>` contents pass through unread, as they do in DOMPurify. What stops
//   a stylesheet is the policy in the document head and the content rule, not this.
// - It has no answer to a bug in WebKit itself. Neither does DOMPurify, but there it's one of three
//   layers around an origin that holds keys. Here the page has no script and no origin worth reaching.

public struct HTMLDocument: Sendable {
    public struct InlineImage: Sendable {
        public let contentID: String
        public let contentType: String
        public let data: Data

        public init(contentID: String, contentType: String, data: Data) {
            self.contentID = contentID
            self.contentType = contentType
            self.data = data
        }
    }

    /// The full document.
    public let source: String
    /// A remote image reference was found and removed.
    public let blockedRemote: Bool
    /// What to say about that, or nil when nothing was blocked. With remote images on, all that's
    /// left to block is an insecure one, and "to protect your privacy" would be the wrong reason.
    public let blockedNotice: String?

    public init(html: String, inlineImages: [InlineImage], allowRemoteImages: Bool) {
        var inline: [String: String] = [:]
        for image in inlineImages where !image.contentID.isEmpty {
            let type = image.contentType.isEmpty ? "application/octet-stream" : image.contentType
            inline[image.contentID] = "data:\(type);base64,\(image.data.base64EncodedString())"
        }
        var cleaner = HTMLCleaner(html, inline: inline, allowRemoteImages: allowRemoteImages)
        let body = cleaner.clean()
        blockedRemote = cleaner.blockedRemote
        blockedNotice =
            !cleaner.blockedRemote
            ? nil
            : allowRemoteImages
                ? "Some images were blocked because they load over an insecure connection."
                : "Remote images were blocked to protect your privacy."
        source = Self.shell(body: body, allowRemoteImages: allowRemoteImages)
    }

    /// No scripts, connections, frames, media or remote fonts, ever. Only the image source widens,
    /// and only when the reader asked for it. That also admits CSS backgrounds, since the policy
    /// governs the fetch and not the tag that caused it: once a fetch to the sender's server is
    /// allowed at all, a stylesheet can make one as an image can, and both tell them the same thing.
    static func contentSecurityPolicy(allowRemoteImages: Bool) -> String {
        "default-src 'none'; img-src \(allowRemoteImages ? "data: https:" : "data:"); style-src 'unsafe-inline'; font-src data:"
    }

    private static func shell(body: String, allowRemoteImages: Bool) -> String {
        "<!DOCTYPE html><html><head><meta charset=\"utf-8\">"
            + "<meta http-equiv=\"Content-Security-Policy\" content=\"\(contentSecurityPolicy(allowRemoteImages: allowRemoteImages))\">"
            // A remote image request must never carry where it was opened from.
            + "<meta name=\"referrer\" content=\"no-referrer\">"
            + "<base target=\"_blank\">"
            // Nothing inside may be wider than the screen: a code block wraps, a picture shrinks, and a
            // table that names its own width is capped. A word stays whole, or a narrow cell splits a
            // button's label letter by letter; a run far longer than a word breaks, which the cleaner
            // arranges. Content past the right edge of a phone isn't scrolled to, it's lost.
            + "<style>"
            + "*,*::before,*::after{box-sizing:border-box}"
            + "html,body{margin:0;padding:12px;font:14px/1.5 system-ui,-apple-system,sans-serif;color:#111;background:#fff;overflow-wrap:break-word}"
            + "pre{white-space:pre-wrap;overflow-wrap:anywhere}"
            + "img,video{max-width:100%!important;height:auto}"
            + "table,div,p,blockquote,pre,figure,td,th{max-width:100%!important;min-width:0!important}"
            + "a{color:#0b5fff}"
            + "</style>"
            + "</head><body>\(body)</body></html>"
    }

    /// What an `<img src>` resolves to.
    public enum ImageSource: Sendable, Equatable {
        /// `cid:`: resolved against the message's own attachments.
        case inline(contentID: String)
        /// Already an embedded `data:` image, with no network involved.
        case keep
        /// Absolute https, kept only when allowed.
        case remote(url: String)
        case blocked
        /// Carried no source to begin with: nothing to report.
        case empty
    }

    /// Which URLs may reach the network, as plain string logic. http isn't upgraded: a cleartext
    /// fetch would announce to every hop that this was opened, which is what the block prevents.
    /// Relative paths resolve against nothing the sender meant.
    public static func classifyImageSource(_ source: String) -> ImageSource {
        let raw = JSText.trim(source)
        if raw.isEmpty { return .empty }
        let scalars = raw.unicodeScalars
        if hasASCIIPrefix(scalars, "cid:") { return .inline(contentID: String(scalars.dropFirst(4))) }
        if hasASCIIPrefix(scalars, "data:image/") { return .keep }
        // Protocol-relative is a remote fetch in every case that matters, so its scheme is named.
        if hasASCIIPrefix(scalars, "//") { return .remote(url: "https:" + raw) }
        if hasASCIIPrefix(scalars, "https://") { return .remote(url: raw) }
        return .blocked
    }

    /// Case-insensitive for ASCII alone, as a JavaScript regex's `i` is.
    fileprivate static func hasASCIIPrefix(_ scalars: String.UnicodeScalarView, _ prefix: String) -> Bool {
        var iterator = scalars.makeIterator()
        for wanted in prefix.unicodeScalars {
            guard let scalar = iterator.next(), asciiLowered(scalar) == wanted else { return false }
        }
        return true
    }

    fileprivate static func asciiLowered(_ scalar: Unicode.Scalar) -> Unicode.Scalar {
        ("A"..."Z").contains(scalar) ? Unicode.Scalar(scalar.value + 32) ?? scalar : scalar
    }
}

private struct HTMLCleaner {
    private var tokenizer: HTMLTokenizer
    private let inline: [String: String]
    private let allowRemoteImages: Bool
    private var output = ""
    private var pending: HTMLToken?
    private(set) var blockedRemote = false

    /// DOMPurify's HTML tags, less the browser's FORBID_TAGS and what a body can't contain.
    private static let allowedTags: Set<String> = [
        "a", "abbr", "acronym", "address", "area", "article", "aside", "audio", "b", "bdi", "bdo", "big", "blink",
        "blockquote", "br", "canvas", "caption", "center", "cite", "code", "col", "colgroup", "content", "data",
        "datalist", "dd", "decorator", "del", "details", "dfn", "dialog", "dir", "div", "dl", "dt", "element", "em",
        "fieldset", "figcaption", "figure", "font", "footer", "h1", "h2", "h3", "h4", "h5", "h6", "header", "hgroup",
        "hr", "i", "img", "ins", "kbd", "label", "legend", "li", "main", "map", "mark", "marquee", "menu", "menuitem",
        "meter", "nav", "nobr", "ol", "optgroup", "option", "output", "p", "picture", "pre", "progress", "q", "rp",
        "rt",
        "ruby", "s", "samp", "search", "section", "shadow", "slot", "small", "source", "spacer", "span", "strike",
        "strong", "style", "sub", "summary", "sup", "table", "tbody", "td", "tfoot", "th", "thead", "time", "tr",
        "track", "tt", "u", "ul", "var", "video", "wbr",
    ]
    /// Dropped along with everything inside them, rather than leaving their contents behind.
    private static let droppedWithContents: Set<String> = [
        "annotation-xml", "desc", "foreignobject", "iframe", "mi", "mn", "mo", "ms", "mtext", "noembed", "noframes",
        "noscript", "plaintext", "script", "selectedcontent", "template", "title", "xmp",
    ]
    private static let allowedAttributes: Set<String> = [
        "accept", "action", "align", "alt", "autocapitalize", "autocomplete", "autopictureinpicture", "autoplay",
        "background", "bgcolor", "border", "capture", "cellpadding", "cellspacing", "checked", "cite", "class", "clear",
        "color", "cols", "colspan", "command", "commandfor", "controls", "controlslist", "coords", "crossorigin",
        "datetime", "decoding", "default", "dir", "disabled", "disablepictureinpicture", "disableremoteplayback",
        "download", "draggable", "enctype", "enterkeyhint", "exportparts", "face", "for", "headers", "height", "hidden",
        "high", "href", "hreflang", "id", "inert", "inputmode", "integrity", "ismap", "kind", "label", "lang", "list",
        "loading", "loop", "low", "max", "maxlength", "media", "method", "min", "minlength", "multiple", "muted",
        "name",
        "nonce", "noshade", "novalidate", "nowrap", "open", "optimum", "part", "pattern", "placeholder", "playsinline",
        "popover", "popovertarget", "popovertargetaction", "poster", "preload", "pubdate", "radiogroup", "readonly",
        "rel", "required", "rev", "reversed", "role", "rows", "rowspan", "spellcheck", "scope", "selected", "shape",
        "size", "sizes", "slot", "span", "srclang", "start", "src", "step", "style", "summary", "tabindex", "title",
        "translate", "type", "usemap", "valign", "value", "width", "wrap", "xmlns",
    ]
    /// Attributes whose values aren't URLs.
    private static let uriSafeAttributes: Set<String> = [
        "alt", "class", "for", "id", "label", "name", "pattern", "placeholder", "role", "summary", "title", "value",
        "style", "xmlns",
    ]
    private static let dataURITags: Set<String> = ["audio", "video", "img", "source", "image", "track"]
    private static let safeSchemes = [
        "ftp:", "ftps:", "http:", "https:", "mailto:", "tel:", "callto:", "sms:", "cid:", "xmpp:", "matrix:",
    ]

    init(_ html: String, inline: [String: String], allowRemoteImages: Bool) {
        tokenizer = HTMLTokenizer(html)
        self.inline = inline
        self.allowRemoteImages = allowRemoteImages
    }

    private mutating func next() -> HTMLToken? {
        if let token = pending {
            pending = nil
            return token
        }
        return tokenizer.next()
    }

    mutating func clean() -> String {
        readHead()
        while let token = next() {
            switch token {
            case .text(let text):
                let escaped = Self.escaped(text, quoted: false)
                output += Self.hasLongRun(text) ? "<span style=\"overflow-wrap:anywhere\">\(escaped)</span>" : escaped
            case .start(let name, let attributes, _):
                start(name == "image" ? "img" : name, attributes: attributes)
            case .end(let name):
                // A stray end tag is the browser's to ignore, or to read as `<p></p>` as it read it
                // the first time.
                if Self.allowedTags.contains(name), !HTMLElements.void.contains(name) || name == "br" {
                    output += "</\(name)>"
                }
            case .comment, .doctype: continue
            }
        }
        return output
    }

    /// `/\S{30,}/`: a run with nowhere to wrap that's longer than any word, such as a URL. A table cell
    /// is as narrow as its longest word and no narrower, so one of these would hold the whole message
    /// wider than the screen. Text holding one may break anywhere, and all other text keeps its words.
    static func hasLongRun(_ text: String) -> Bool {
        var run = 0
        for scalar in text.unicodeScalars {
            run = JSText.isWhitespace(scalar) ? 0 : run + UTF16.width(scalar)
            if run >= 30 { return true }
        }
        return false
    }

    /// Everything before the body is dropped, as it is when the browser takes `body.innerHTML`. That
    /// includes a leading `<style>`. A `<noscript>` here stops holding anything back the moment
    /// something that can't go in a head appears, so the tag alone is ignored.
    private mutating func readHead() {
        while let token = next() {
            switch token {
            case .comment, .doctype: continue
            case .text(let text):
                var scalars = Substring(text).unicodeScalars
                while let first = scalars.first, first == " " || first == "\t" || first == "\n" || first == "\u{0C}" {
                    scalars.removeFirst()
                }
                if scalars.isEmpty { continue }
                pending = .text(String(scalars))
                return
            case .end(let name):
                if name == "body" || name == "html" || name == "br" {
                    pending = token
                    return
                }
            case .start(let name, _, _):
                switch name {
                case "html", "head", "noscript": continue
                case "body": return
                case "template": skip("template")
                case _ where HTMLElements.headOnly.contains(name):
                    if let mode = HTMLElements.contentMode(of: name) {
                        tokenizer.mode = mode
                        skip(name)
                    }
                default:
                    pending = token
                    return
                }
            }
        }
    }

    private mutating func start(_ name: String, attributes: [HTMLAttribute]) {
        if name == "svg" || name == "math" {
            skipForeign(name)
            return
        }
        if Self.droppedWithContents.contains(name) {
            if let mode = HTMLElements.contentMode(of: name) { tokenizer.mode = mode }
            skip(name)
            return
        }
        if name == "style" {
            style(attributes: attributes)
            return
        }
        // A textarea's contents are text to the parser. They survive as text, with the tag gone.
        if let mode = HTMLElements.contentMode(of: name) { tokenizer.mode = mode }
        guard Self.allowedTags.contains(name) else { return }
        emit(name, attributes: cleanAttributes(attributes, of: name))
    }

    private mutating func emit(_ name: String, attributes: [HTMLAttribute]) {
        var kept = attributes
        if name == "img" { rewriteImage(&kept) }
        if name == "a" {
            kept.removeAll { $0.name == "target" || $0.name == "rel" }
            kept.append(HTMLAttribute(name: "target", value: "_blank"))
            kept.append(HTMLAttribute(name: "rel", value: "noopener noreferrer nofollow"))
        }
        output += "<\(name)"
        for attribute in kept { output += " \(attribute.name)=\"\(Self.escaped(attribute.value, quoted: true))\"" }
        output += ">"
    }

    /// A stylesheet is copied as it stands, because to the parser it isn't markup, and it's closed
    /// even if the source never did, so the document shell after it can't be swallowed. One with
    /// markup-like text in it is dropped, as DOMPurify treats that as a mutation attempt.
    private mutating func style(attributes: [HTMLAttribute]) {
        tokenizer.mode = .rawtext("style")
        var css = ""
        if let token = next() {
            if case .text(let text) = token {
                css = text
                if let closing = next(), closing != .end(name: "style") { pending = closing }
            } else if token != .end(name: "style") {
                pending = token
            }
        }
        guard !Self.hasMarkup(css) else { return }
        emit("style", attributes: cleanAttributes(attributes, of: "style"))
        output += css + "</style>"
    }

    /// `/<[/\w!]/`.
    private static func hasMarkup(_ text: String) -> Bool {
        let scalars = Array(text.unicodeScalars)
        for index in scalars.indices.dropLast() where scalars[index] == "<" {
            let next = scalars[index + 1]
            if next == "/" || next == "!" || next == "_" || ("0"..."9").contains(next) || ("a"..."z").contains(next)
                || ("A"..."Z").contains(next)
            {
                return true
            }
        }
        return false
    }

    /// Reads past an element and everything in it.
    private mutating func skip(_ name: String) {
        var depth = 1
        while depth > 0, let token = next() {
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

    /// Reads past an svg or math element. Its contents aren't raw text, which is the whole trick of
    /// `<svg><style><img …>`: that image is a real one, because `img` breaks out of foreign content
    /// and lands in the body. So a tag that breaks out comes back to the main loop to be cleaned.
    private mutating func skipForeign(_ name: String) {
        var open = [name]
        tokenizer.allowsCDATA = true
        defer { tokenizer.allowsCDATA = false }
        while !open.isEmpty, let token = next() {
            let integrated = open.contains { HTMLElements.integrationPoints.contains($0) }
            switch token {
            case .start(let inner, _, let selfClosing):
                if !integrated, HTMLElements.breaksOutOfForeign.contains(inner) {
                    pending = token
                    return
                }
                if integrated, let mode = HTMLElements.contentMode(of: inner) { tokenizer.mode = mode }
                if !selfClosing { open.append(inner) }
            case .end(let inner):
                if !integrated, inner == "p" || inner == "br" {
                    pending = token
                    return
                }
                if let index = open.lastIndex(of: inner) { open.removeSubrange(index...) }
            default: continue
            }
        }
    }

    // MARK: Attributes

    private func cleanAttributes(_ attributes: [HTMLAttribute], of tag: String) -> [HTMLAttribute] {
        attributes.compactMap { attribute in
            let value = attribute.name == "value" ? attribute.value : JSText.trim(attribute.value)
            guard !Self.isUnsafeValue(value), Self.isValid(tag: tag, name: attribute.name, value: value) else {
                return nil
            }
            return HTMLAttribute(name: attribute.name, value: value)
        }
    }

    /// `/((--!?|])>)|<\/(style|script|…)/i`: a value that could close the construct it sits in if it
    /// were ever read in the wrong state.
    private static func isUnsafeValue(_ value: String) -> Bool {
        let lower = value.lowercased()
        if lower.contains("-->") || lower.contains("--!>") || lower.contains("]>") { return true }
        return ["style", "script", "title", "xmp", "textarea", "noscript", "iframe", "noembed", "noframes"]
            .contains { lower.contains("</\($0)") }
    }

    /// DOMPurify's `_isValidAttribute`, under the browser's configuration.
    private static func isValid(tag: String, name: String, value: String) -> Bool {
        // FORBID_ATTR in lib/html/sanitize.ts. `for` links a part of the page elsewhere outside these two.
        if ["srcset", "ping", "formaction", "patchsrc"].contains(name) { return false }
        if name == "for", tag != "label", tag != "output" { return false }
        if isARIAName(name) { return true }
        guard allowedAttributes.contains(name) else { return false }
        if uriSafeAttributes.contains(name) { return true }
        if isAllowedURI(value.unicodeScalars.filter { !isURIWhitespace($0) }) { return true }
        if name == "src" || name == "href", value.unicodeScalars.starts(with: "data:".unicodeScalars),
            dataURITags.contains(tag)
        {
            return true
        }
        return value.isEmpty
    }

    /// `/^aria-[\-\w]+$/`.
    private static func isARIAName(_ name: String) -> Bool {
        let scalars = Array(name.unicodeScalars)
        guard scalars.count > 5, scalars.starts(with: "aria-".unicodeScalars) else { return false }
        return scalars[5...].allSatisfy {
            $0 == "-" || $0 == "_" || ("0"..."9").contains($0) || ("a"..."z").contains($0) || ("A"..."Z").contains($0)
        }
    }

    /// `/[\u0000-   ᠎ -  　]/`, which browsers ignore in places
    /// inside a URL, so `java\nscript:` is judged as what it would become.
    private static func isURIWhitespace(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x00...0x20, 0xA0, 0x1680, 0x180E, 0x2000...0x2029, 0x205F, 0x3000: true
        default: false
        }
    }

    /// DOMPurify's IS_ALLOWED_URI: a known scheme, or something that isn't a scheme at all.
    private static func isAllowedURI(_ scalars: [Unicode.Scalar]) -> Bool {
        var text = String.UnicodeScalarView()
        text.append(contentsOf: scalars)
        if safeSchemes.contains(where: { HTMLDocument.hasASCIIPrefix(text, $0) }) { return true }
        guard let first = scalars.first else { return false }
        if !isASCIILetter(first) { return true }
        // A run of scheme characters that doesn't end in a colon isn't a scheme.
        let run = scalars.prefix { isASCIILetter($0) || $0 == "+" || $0 == "." || $0 == "-" }
        return run.count == scalars.count || scalars[run.count] != ":"
    }

    private static func isASCIILetter(_ scalar: Unicode.Scalar) -> Bool {
        ("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar)
    }

    private mutating func rewriteImage(_ attributes: inout [HTMLAttribute]) {
        guard let index = attributes.firstIndex(where: { $0.name == "src" }) else { return }
        switch HTMLDocument.classifyImageSource(attributes[index].value) {
        case .inline(let contentID):
            if let uri = inline[contentID] {
                attributes[index].value = uri
            } else {
                attributes.remove(at: index)
            }
        case .remote(let url):
            if allowRemoteImages {
                attributes[index].value = url
            } else {
                attributes.remove(at: index)
                blockedRemote = true
            }
        case .blocked:
            attributes.remove(at: index)
            blockedRemote = true
        case .keep, .empty:
            break
        }
    }

    private static func escaped(_ text: String, quoted: Bool) -> String {
        var out = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            switch scalar {
            case "&": out.append(contentsOf: "&amp;".unicodeScalars)
            case "<": out.append(contentsOf: "&lt;".unicodeScalars)
            case ">": out.append(contentsOf: "&gt;".unicodeScalars)
            case "\"" where quoted: out.append(contentsOf: "&quot;".unicodeScalars)
            default: out.append(scalar)
            }
        }
        return String(out)
    }
}
