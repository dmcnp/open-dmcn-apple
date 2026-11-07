import Foundation
import Testing
@testable import DMCNKit

// Fixture rows were run through the browser's real sanitizeIncoming, with its DOMPurify configuration
// and a real HTML parser. The hostile strings themselves are the test: uppercase, attributes with `>`,
// unterminated tags, comments, refresh and CSP-widening metas, entity-encoded schemes, NULs.

private struct Doc: Decodable {
    struct Case: Decodable {
        let html: String
        let blocked: Bool
        let clean: String
        let allowed_blocked: Bool
        let allowed_clean: String
    }
    struct Shell: Decodable { let blocked: String; let allowed: String }
    struct Source: Decodable {
        struct Verdict: Decodable { let kind: String; let cid: String?; let url: String? }
        let src: String
        let verdict: Verdict
    }
    struct LongRun: Decodable { let html: String; let clean: String }
    let html: [Case]
    let long_runs: [LongRun]
    let shell: Shell
    let inline: [String: String]
    let image_srcs: [Source]
}

private let doc: Result<Doc, any Error> = Result { try fixture("browser-trust") }

private func images(_ map: [String: String]) -> [HTMLDocument.InlineImage] {
    map.map { id, uri in
        let parts = uri.dropFirst("data:".count).split(separator: ";", maxSplits: 1)
        let bytes = Data(base64Encoded: String(parts[1].dropFirst("base64,".count))) ?? Data()
        return HTMLDocument.InlineImage(contentID: id, contentType: String(parts[0]), data: bytes)
    }
}

private func body(_ document: String) -> String {
    let start = document.range(of: "<body>")!.upperBound
    let end = document.range(of: "</body></html>", options: .backwards)!.lowerBound
    return String(document[start..<end])
}

private func document(_ html: String, remote: Bool = false, inline: [HTMLDocument.InlineImage] = []) -> HTMLDocument {
    HTMLDocument(html: html, inlineImages: inline, allowRemoteImages: remote)
}

@Suite struct HTMLDocumentAgainstTheBrowser {
    @Test func theShellAndPolicyAreTheBrowsersToTheByte() throws {
        let d = try doc.get()
        #expect(document("@@BODY@@").source == d.shell.blocked)
        #expect(document("@@BODY@@", remote: true).source == d.shell.allowed)
        #expect(
            d.shell.blocked.contains("default-src 'none'; img-src data:; style-src 'unsafe-inline'; font-src data:"))
        #expect(d.shell.allowed.contains("img-src data: https:;"))
    }

    @Test func classifiesImageSourcesAsTheBrowserDoes() throws {
        for c in try doc.get().image_srcs {
            let want: HTMLDocument.ImageSource =
                switch c.verdict.kind {
                case "inline": .inline(contentID: c.verdict.cid ?? "")
                case "keep": .keep
                case "remote": .remote(url: c.verdict.url ?? "")
                case "blocked": .blocked
                default: .empty
                }
            #expect(HTMLDocument.classifyImageSource(c.src) == want, "\(c.src.debugDescription)")
        }
    }

    @Test func reportsABlockedRemoteImageWhereTheBrowserDoes() throws {
        let d = try doc.get()
        #expect(d.html.count > 150)
        for c in d.html {
            #expect(document(c.html, inline: images(d.inline)).blockedRemote == c.blocked, "\(c.html.debugDescription)")
            #expect(
                document(c.html, remote: true, inline: images(d.inline)).blockedRemote == c.allowed_blocked,
                "\(c.html.debugDescription)")
        }
    }

    /// A word stays whole and a run far longer than one may break, or a URL in a table cell holds the
    /// whole message wider than the screen. These are simple enough to match the browser to the byte,
    /// but for the one character it writes as an entity.
    @Test func longRunsMayBreakWhereTheBrowsersDoAndNowhereElse() throws {
        let rows = try doc.get().long_runs
        #expect(rows.count > 15)
        for row in rows {
            let browser = row.clean.replacing("&nbsp;", with: "\u{A0}")
            #expect(body(document(row.html).source) == browser, "\(row.html.debugDescription)")
        }
    }

    @Test func nothingForbiddenSurvivesAnyOfIt() throws {
        let d = try doc.get()
        let forbidden = [
            "<script", "<iframe", "<object", "<embed", "<form", "<meta", "<link", "<base", "<svg", "<math", "<input",
            "<button", "<textarea", "<select", "<noscript", "<title", "<frame", "<applet", "onerror", "onload",
            "onclick",
            "javascript:", "vbscript:", "srcset", "<!--",
        ]
        for c in d.html {
            let got = body(document(c.html, inline: images(d.inline)).source).lowercased()
            // What's text to a parser, in `&lt;img …`, is fine. An opening `<` is what mustn't appear.
            for word in forbidden {
                #expect(!got.contains(word), "\(word) in \(got.debugDescription) from \(c.html.debugDescription)")
            }
            #expect(!got.contains("<img src=\"http"), "\(got.debugDescription)")
        }
    }

    /// Writes this side's output for a real parser to compare with DOMPurify's, in node. Set
    /// DMCN_HTML_INTEROP_OUT to a file.
    @Test func writesItsOutputForTheOtherSide() throws {
        guard let path = ProcessInfo.processInfo.environment["DMCN_HTML_INTEROP_OUT"] else { return }
        let d = try doc.get()
        let out = d.html.map { c -> [String: String] in
            [
                "html": c.html, "clean": c.clean, "allowed_clean": c.allowed_clean,
                "mine": body(document(c.html, inline: images(d.inline)).source),
                "mine_allowed": body(document(c.html, remote: true, inline: images(d.inline)).source),
            ]
        }
        try JSONEncoder().encode(out).write(to: URL(fileURLWithPath: path))
    }
}

@Suite struct HTMLDocumentHostileInput {
    @Test func scriptInAnyCaseOrShapeIsGone() {
        for hostile in [
            "<SCRIPT>alert(1)</SCRIPT>y", "<sCrIpT src=https://t/x.js></sCrIpT>y", "<script/x>a</script>y",
            "<script\n>a</script\n>y",
        ] {
            #expect(body(document(hostile).source) == "y", "\(hostile)")
        }
    }

    @Test func aTagWithNoEndIsDropped() {
        for hostile in ["<script", "<script src=x", "<img src=\"https://t/x", "<img src=https://t/x", "<a href=\"x"] {
            #expect(body(document(hostile).source) == "", "\(hostile)")
            #expect(!document(hostile).blockedRemote)
        }
        #expect(body(document("<script>never closed <img src=https://t/x>").source) == "")
    }

    @Test func aGreaterThanInsideAnAttributeDoesntEndTheTag() {
        let quoted = document("<img alt=\">\" src=\"https://t/gt\">")
        #expect(quoted.blockedRemote)
        #expect(body(quoted.source) == "<img alt=\"&gt;\">")
        // The other way round: what looks like a tag inside an attribute isn't one.
        let inside = body(document("<a title='x\"><img src=https://t/q>'>y</a>").source)
        #expect(inside.hasPrefix("<a title=\"x&quot;&gt;&lt;img"))
        #expect(!document("<a title='x\"><img src=https://t/q>'>y</a>").blockedRemote)
    }

    @Test func commentsEndWhereABrowserEndsThem() {
        #expect(body(document("<!-- <img src=https://t/c> -->y").source) == "y")
        #expect(!document("<!-- <img src=https://t/c> -->y").blockedRemote)
        // Each of these closes earlier than `-->`, so what follows is real.
        for early in [
            "<!--><img src=https://t/x>-->", "<!---><img src=https://t/x>-->", "<!-- a --!><img src=https://t/x>",
        ] {
            #expect(document(early).blockedRemote, "\(early)")
        }
        #expect(body(document("<!-- unterminated <img src=https://t/x>").source) == "")
    }

    @Test func aRefreshMetaGoes() {
        for hostile in [
            "<meta http-equiv=\"refresh\" content=\"0;url=https://t/x\">y",
            "<META HTTP-EQUIV=REFRESH CONTENT=\"0;URL=https://t/x\">y",
            "<p>x</p><meta http-equiv=refresh content=0>y",
        ] {
            #expect(!body(document(hostile).source).lowercased().contains("refresh"), "\(hostile)")
        }
    }

    @Test func aCSPWideningMetaGoesAndTheShellsIsTheOnlyOne() {
        let d = document("<p>x</p><meta http-equiv=\"Content-Security-Policy\" content=\"img-src *\">").source
        #expect(d.components(separatedBy: "Content-Security-Policy").count == 2)
        #expect(!d.contains("img-src *"))
    }

    @Test func theFirstOfTwoSourcesIsTheOneRead() {
        #expect(document("<img src=\"https://t/2\" src=\"cid:logo\">").blockedRemote)
        #expect(!document("<img src=\"cid:logo\" src=\"https://t/2\">").blockedRemote)
    }

    @Test func anEncodedSchemeIsStillThatScheme() {
        for hostile in [
            "<img src=\"&#104;ttps://t/enc\">", "<img src=\"https&colon;//t/enc\">", "<image src=\"https://t/i\">",
        ] {
            #expect(document(hostile).blockedRemote, "\(hostile)")
        }
        #expect(body(document("<a href=\"&#106;avascript:alert(1)\">l</a>").source).hasPrefix("<a target"))
        #expect(body(document("<a href=\"java\nscript:alert(1)\">l</a>").source).hasPrefix("<a target"))
    }

    @Test func contentsThatArentMarkupStayThatWay() {
        #expect(!document("<textarea><img src=https://t/ta></textarea>").blockedRemote)
        #expect(body(document("<textarea><img src=https://t/ta></textarea>").source).hasPrefix("&lt;img"))
        #expect(!document("<p>x</p><style><img src=https://t/s></style>").blockedRemote)
    }

    @Test func foreignContentCantHideARealImage() {
        // `img` breaks out of svg, so this one loads, and the style around it never was a style.
        #expect(document("<svg><style><img src=https://t/x></style></svg>").blockedRemote)
    }

    @Test func aStylesheetCantSwallowTheShell() {
        let d = document("<p>x</p><style>a{}").source
        #expect(d.hasSuffix("<style>a{}</style></body></html>"))
    }

    @Test func anInlineImagesTypeCantBreakOutOfTheAttribute() {
        let image = HTMLDocument.InlineImage(
            contentID: "x", contentType: "image/png\" onload=\"evil", data: Data([1]))
        let got = body(document("<img src=\"cid:x\">", inline: [image]).source)
        #expect(!got.contains("onload=\""))
        #expect(got.contains("&quot;"))
    }

    @Test func aContentIDWithAQuoteResolvesAndStaysQuoted() {
        let image = HTMLDocument.InlineImage(contentID: "q\"x", contentType: "image/png", data: Data([1]))
        #expect(
            body(document("<img src=\"cid:q&quot;x\">", inline: [image]).source).hasPrefix("<img src=\"data:image/png"))
    }

    @Test func remoteImagesAreKeptOnlyWhenAllowedAndNeverOverHTTP() {
        let allowed = document("<img src=https://t/a><img src=//t/b><img src=http://t/c>", remote: true)
        #expect(body(allowed.source) == "<img src=\"https://t/a\"><img src=\"https://t/b\"><img>")
        #expect(allowed.blockedRemote)
    }

    @Test func saysWhyAnImageWasBlocked() {
        #expect(document("<p>x</p>").blockedNotice == nil)
        #expect(
            document("<img src=https://t/a>").blockedNotice == "Remote images were blocked to protect your privacy.")
        #expect(
            document("<img src=http://t/a>", remote: true).blockedNotice
                == "Some images were blocked because they load over an insecure connection.")
    }

    @Test func linksOpenOutsideWithNoReferrer() {
        #expect(
            body(document("<a target=_self rel=opener href=\"https://x\">t</a>").source)
                == "<a href=\"https://x\" target=\"_blank\" rel=\"noopener noreferrer nofollow\">t</a>")
    }
}
