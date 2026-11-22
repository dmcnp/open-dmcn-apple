import DMCNKit
import SwiftUI
import UIKit
import UIKit.UIGestureRecognizerSubclass

/// The persistent shell around every signed-in screen: the top bar, the drawer, the strips that
/// say something standing about this session, and the composer floating over all of it.
struct AppShell: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var colorScheme
    let session: MailSession

    @State private var drawerOpen = false
    @State private var searchOpen = false
    @State private var showingAccounts = false

    var body: some View {
        ZStack(alignment: .leading) {
            VStack(spacing: 0) {
                switch session.section {
                case .mail:
                    if !session.isReading { header }
                    strips
                    MailColumn(session: session)
                case .contacts:
                    ContactsView(session: session)
                case .settings:
                    SettingsView(session: session)
                }
            }
            .background(.surfacePage)

            drawer
        }
        // A swipe in from the left edge opens the menu, where the menu button is: on the mail list,
        // not over an open message, whose edge swipe goes back.
        .modifier(
            EdgeSwipeOpens(enabled: session.section == .mail && !session.isReading && !drawerOpen) {
                if !drawerOpen { setDrawer(true) }
            }
        )
        .sheet(isPresented: $showingAccounts) {
            AccountSheet(session: session).presentationDetents([.medium, .large])
        }
        .fullScreenCover(item: Binding(get: { session.composing }, set: { session.composing = $0 })) { draft in
            ComposeView(session: session, compose: draft)
        }
        .alert(
            "Something went wrong",
            isPresented: Binding(get: { session.errorMessage != nil }, set: { if !$0 { session.errorMessage = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(session.errorMessage ?? "")
        }
    }

    // MARK: Top bar

    @ViewBuilder private var header: some View {
        Group {
            if searchOpen {
                HStack(spacing: Space.s2) {
                    DSIconButton(.chevronLeft, label: "Close search") {
                        searchOpen = false
                        session.query = ""
                    }
                    SearchBox(session: session)
                    SearchHelpButton()
                }
                .padding(.horizontal, Space.s3)
            } else {
                HStack(spacing: Space.s3) {
                    DSIconButton(.menu, label: "Open menu") { setDrawer(true) }
                    HStack(spacing: 6) {
                        Icon.mail.image(17).foregroundStyle(.textMuted)
                        Text(session.host).dsFont(.md, .semibold).foregroundStyle(.textStrong).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    DSIconButton(.search, label: "Open search") { searchOpen = true }
                    DSIconButton(colorScheme == .dark ? .sun : .moon, label: "Toggle theme") {
                        model.theme = colorScheme == .dark ? .light : .dark
                    }
                    Button {
                        showingAccounts = true
                    } label: {
                        AccountMonogram(initials: MailView.initialsOf(session.address))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Account: \(session.address)")
                }
                .padding(.horizontal, Space.s4)
            }
        }
        .frame(height: 60)
        .background(.surfaceCard)
        .overlay(alignment: .bottom) { Rectangle().fill(.borderDefault).frame(height: 1) }
    }

    @ViewBuilder private var strips: some View {
        if session.storageIsLocalOnly {
            StatusStrip(
                text:
                    "This server doesn't store your mailbox state, so your sent mail, contacts and settings are saved in this app only. They won't appear on your other devices."
            )
        }
    }

    // MARK: Drawer

    @ViewBuilder private var drawer: some View {
        Color(red: 12 / 255, green: 16 / 255, blue: 16 / 255)
            .opacity(drawerOpen ? 0.45 : 0)
            .ignoresSafeArea()
            .allowsHitTesting(drawerOpen)
            .onTapGesture { setDrawer(false) }
            .accessibilityHidden(true)
        NavRail(
            session: session,
            onChoose: { setDrawer(false) },
            onSwitchAccount: {
                setDrawer(false)
                showingAccounts = true
            }
        )
        .frame(width: 248)
        .background {
            // On the panel, not the rail: on a container, every row would cast its own blur.
            Rectangle().fill(.surfaceCard)
                .overlay(alignment: .trailing) { Rectangle().fill(.borderDefault).frame(width: 1) }
                .ignoresSafeArea()
                .shadow(color: .black.opacity(drawerOpen ? 0.18 : 0), radius: 28, y: 12)
        }
        .offset(x: drawerOpen ? 0 : -260)
        .accessibilityHidden(!drawerOpen)
    }

    private func setDrawer(_ open: Bool) {
        withAnimation(Motion.normal) { drawerOpen = open }
    }
}

/// Opens the menu on a swipe that starts at the screen's left edge. A touch further in is left to
/// the row it lands on, so its swipe still opens Folder and Label. iOS 18 and later; on 17 the menu
/// button is the way in.
private struct EdgeSwipeOpens: ViewModifier {
    let enabled: Bool
    let open: () -> Void

    func body(content: Content) -> some View {
        if #available(iOS 18, *) {
            content.gesture(EdgePan(enabled: enabled, onOpen: open))
        } else {
            content
        }
    }
}

@available(iOS 18, *)
private struct EdgePan: UIGestureRecognizerRepresentable {
    /// How far in from the edge a touch may start and still open the menu.
    static let edgeWidth: CGFloat = 24

    let enabled: Bool
    let onOpen: () -> Void

    func makeUIGestureRecognizer(context: Context) -> EdgeDrag {
        let pan = EdgeDrag()
        pan.delegate = context.coordinator
        return pan
    }

    func makeCoordinator(converter: CoordinateSpaceConverter) -> EdgeOnly { EdgeOnly() }

    /// A drag that gives up the moment a touch lands away from the edge, so the list's scroll and
    /// a row's swipe, which wait for it, aren't held up.
    final class EdgeDrag: UIPanGestureRecognizer {
        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
            if let touch = touches.first, touch.location(in: touch.window).x > EdgePan.edgeWidth {
                state = .failed
                return
            }
            super.touchesBegan(touches, with: event)
        }
    }

    /// Takes a drag from the edge only when it heads right; one heading up or down is a scroll.
    /// Other drags (a row's swipe, the list's scroll) wait for it to say no.
    final class EdgeOnly: NSObject, UIGestureRecognizerDelegate {
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return false }
            let speed = pan.velocity(in: pan.view)
            return speed.x > abs(speed.y)
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer, shouldBeRequiredToFailBy other: UIGestureRecognizer
        ) -> Bool {
            other is UIPanGestureRecognizer
        }

        /// A row with its Folder and Label buttons out takes the next touch to close them. Running
        /// alongside that, one swipe from the edge closes the row and opens the menu.
        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
        ) -> Bool {
            true
        }
    }

    func updateUIGestureRecognizer(_ recognizer: EdgeDrag, context: Context) {
        recognizer.isEnabled = enabled
    }

    func handleUIGestureRecognizerAction(_ recognizer: EdgeDrag, context: Context) {
        let moved = recognizer.translation(in: recognizer.view).x
        let speed = recognizer.velocity(in: recognizer.view).x
        switch recognizer.state {
        case .changed where moved > 40: onOpen()
        case .ended where moved > 16 || speed > 300: onOpen()
        default: break
        }
    }
}

/// The search field. Typing takes the shell to the Search view; emptying it comes back.
struct SearchBox: View {
    @Bindable var session: MailSession
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: Space.s2) {
            Icon.search.image(16).foregroundStyle(.textSubtle)
            TextField("", text: $session.query, prompt: Text("Search encrypted mail").foregroundStyle(.textSubtle))
                .focused($focused)
                .font(.system(size: 16))
                .foregroundStyle(.textStrong)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
                .accessibilityLabel("Search mail")
            if !session.query.isEmpty {
                DSIconButton(.x, label: "Clear search", size: .sm) { session.query = "" }
            }
        }
        .padding(.leading, Space.s3)
        .padding(.trailing, Space.s1)
        .frame(height: 38)
        .background(.surfaceCard, in: .dsCard)
        .dsBorder(focused ? .borderFocus : .borderDefault)
        .onAppear { focused = true }
    }
}

/// The (i) beside the search box: every search option, each with an example.
struct SearchHelpButton: View {
    @State private var open = false

    private static let options: [(example: String, meaning: String)] = [
        ("invoice", "Sender, recipients, subject, message text or attachment names. The start of a word is enough."),
        ("from:alice", "Who sent it, by name or address."),
        ("to:bob", "Who it went to, Cc included."),
        ("subject:report", "Words in the subject."),
        ("has:attachment", "Has an attachment."),
        ("filename:*.pdf", "Attachment name. * stands for anything."),
        ("is:unread", "Also is:read and is:starred."),
        ("label:work", "Has this label."),
        ("in:archive", "Where it is: inbox, archive, sent, deleted, or a folder name."),
        ("after:2026-01-31", "Sent on or after that day. before: means sent before it."),
        ("-from:alice", "A minus in front leaves those out."),
        ("from:\"Alice Smith\"", "Quotes keep a value with spaces together."),
    ]

    var body: some View {
        DSIconButton(.info, label: "Search options", variant: open ? .active : .plain) { open.toggle() }
            .popover(isPresented: $open) {
                ScrollView {
                    VStack(alignment: .leading, spacing: Space.s2) {
                        Text("Search options").dsFont(.sm, .semibold).foregroundStyle(.textStrong)
                        ForEach(Self.options, id: \.example) { option in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(option.example)
                                    .dsMono(.xs)
                                    .foregroundStyle(.textStrong)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(.surfaceSunken, in: .dsCard)
                                    .dsBorder()
                                Text(option.meaning).dsFont(.sm).foregroundStyle(.textMuted)
                            }
                        }
                        Text(
                            "Combine as many as you like: a message has to match all of them. Searching happens on this device."
                        )
                        .dsFont(.xs)
                        .foregroundStyle(.textMuted)
                        .padding(.top, Space.s1)
                    }
                    .padding(.vertical, Space.s3)
                    .padding(.horizontal, Space.s4)
                }
                .frame(minWidth: 300, maxHeight: 520)
                .presentationCompactAdaptation(.popover)
            }
    }
}
