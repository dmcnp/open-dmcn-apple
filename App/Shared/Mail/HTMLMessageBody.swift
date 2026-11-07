import DMCNKit
import SwiftUI
import WebKit

/// A received HTML part, shown with the same layers as the web's sandboxed frame: scripts off,
/// a content policy inside the document, every network load blocked by a content rule (unless
/// the reader opted in, for a sender they trust), and no navigation inside the view.
struct HTMLMessageBody: View {
    let html: String
    let inlineImages: [HTMLDocument.InlineImage]
    let allowRemoteImages: Bool
    @State private var height: CGFloat = SandboxedWebView.shortest

    private var document: HTMLDocument {
        HTMLDocument(html: html, inlineImages: inlineImages, allowRemoteImages: allowRemoteImages)
    }

    /// The kit's document is the browser's to the byte, and a browser's frame takes its width from
    /// its parent. A web view lays out at desktop width and shrinks the page unless it's told. The
    /// document's padding goes too: on a phone it's width a message laid out for a desktop can't spare.
    private var phoneDocument: String {
        document.source
            .replacing(
                "<head>", with: "<head><meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">",
                maxReplacements: 1
            )
            .replacing("</head>", with: "<style>html,body{padding:0}</style></head>", maxReplacements: 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s2) {
            if document.blockedRemote {
                HStack(spacing: Space.s2) {
                    Icon.eyeOff.image(15)
                    Text("Remote images were blocked to protect your privacy.").dsFont(.sm)
                }
                .foregroundStyle(.textMuted)
                .padding(.vertical, Space.s2)
                .padding(.horizontal, Space.s3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.surfaceSunken, in: .dsCard)
            }
            SandboxedWebView(document: phoneDocument, blockNetwork: !allowRemoteImages, height: $height)
                .frame(height: height)
                .clipShape(.dsCard)
                .dsBorder()
        }
    }
}

private struct SandboxedWebView: UIViewRepresentable {
    /// Where a message's height starts, and where it restarts when it's zoomed.
    static let shortest: CGFloat = 120

    let document: String
    let blockNetwork: Bool
    @Binding var height: CGFloat

    /// Blocks every load but `data:`, so a remote image can't reach out whatever the HTML says.
    private static let blockEverything = """
        [{"trigger":{"url-filter":".*"},"action":{"type":"block"}},
         {"trigger":{"url-filter":"^data:"},"action":{"type":"ignore-previous-rules"}}]
        """

    func makeCoordinator() -> Coordinator { Coordinator(height: $height) }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.scrollView.isScrollEnabled = false
        context.coordinator.followContent(of: view)
        view.isOpaque = false
        view.backgroundColor = .white
        guard blockNetwork else {
            view.loadHTMLString(document, baseURL: nil)
            return view
        }
        // The document mustn't load until the rule is in place, and if it can't be compiled the
        // message isn't shown: the rule is what stands behind the promise of no remote loads.
        WKContentRuleListStore.default().compileContentRuleList(
            forIdentifier: "dmcn-block-all", encodedContentRuleList: Self.blockEverything
        ) { list, _ in
            guard let list else { return }
            view.configuration.userContentController.add(list)
            view.loadHTMLString(document, baseURL: nil)
        }
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {}

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        @Binding var height: CGFloat
        private var contentWatch: NSKeyValueObservation?

        /// Past this, text is too small to read. A message wider than this much scrolls sideways.
        private static let smallestScale: CGFloat = 0.4
        /// The width the page lays out at, once it has outgrown the view's.
        private var layoutWidth: CGFloat?

        init(height: Binding<CGFloat>) {
            _height = height
        }

        /// The view doesn't scroll, so anything past its edges can't be reached. The page lays out
        /// after it finishes loading, and again as pictures decode, so one measurement isn't enough.
        func followContent(of view: WKWebView) {
            contentWatch = view.scrollView.observe(\.contentSize, options: [.new]) { [weak self, weak view] _, change in
                guard let content = change.newValue else { return }
                Task { @MainActor in
                    guard let self, let view else { return }
                    self.fit(content, in: view)
                }
            }
        }

        /// A newsletter built as a fixed-width table ignores the document's `max-width`, so it's
        /// shown whole, as Apple Mail does: the page is told to lay out as wide as it needs, and
        /// WebKit scales that to the view. The app's own scripts run with the message's scripts off.
        private func fit(_ content: CGSize, in view: WKWebView) {
            if view.bounds.width > 0, content.width > view.bounds.width + 1 {
                // The content size is in scaled points, and moves while the page lays out again. This
                // is in the page's own pixels, so asking twice gets the same answer.
                view.evaluateJavaScript("document.documentElement.scrollWidth") { [weak self, weak view] result, _ in
                    guard let measured = result as? Double ?? (result as? Int).map(Double.init) else { return }
                    Task { @MainActor in
                        guard let self, let view else { return }
                        self.layOut(at: CGFloat(measured), in: view)
                    }
                }
            } else if content.height > height {
                height = content.height
            }
        }

        /// Only ever growing is safe for the height: the content size is never less than the view's
        /// own. So a new width starts it over, because the page is about to get shorter and nothing
        /// else could say so. Once the width has settled, the page's height comes through here too.
        private func layOut(at measured: CGFloat, in view: WKWebView) {
            let widest = view.bounds.width / Self.smallestScale
            let wanted = min(widest, measured.rounded(.up))
            guard wanted > layoutWidth ?? view.bounds.width else {
                height = max(height, view.scrollView.contentSize.height)
                return
            }
            layoutWidth = wanted
            view.scrollView.isScrollEnabled = measured > widest
            height = SandboxedWebView.shortest
            view.evaluateJavaScript(
                "document.querySelector('meta[name=viewport]').setAttribute('content','width=\(Int(wanted))')",
                completionHandler: nil)
        }
    }
}
