import DMCNKit
import SwiftUI

/// The reader's checks strip: where the message came from, then up to four plain words with a
/// tick or a cross, then the one sentence a failed check earns. The words come from the kit;
/// this only draws them. A tap on a word opens its explanation underneath, spanning the strip,
/// so a word near the edge of a phone never pushes its tip off the screen.
struct ChecksStrip: View {
    let view: MessageChecksView?
    @State private var open: Int?

    var body: some View {
        if let view {
            strip(view)
        } else {
            Text("Checking the sender…")
                .dsFont(.sm)
                .foregroundStyle(.textMuted)
                .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
                .padding(.vertical, Space.s3)
                .padding(.horizontal, Space.s4)
                .background(.surfaceCard, in: RoundedRectangle(cornerRadius: Radius.strip))
                .overlay(RoundedRectangle(cornerRadius: Radius.strip).strokeBorder(.borderSubtle))
        }
    }

    private func strip(_ view: MessageChecksView) -> some View {
        let tone = view.notice.map { Tone($0.tone) }
        return VStack(alignment: .leading, spacing: 0) {
            FlowRow(spacing: 22, lineSpacing: 6) {
                Button {
                    toggle(-1)
                } label: {
                    HStack(spacing: 7) {
                        if let source = sourceIcon(view.source.kind) {
                            source.icon.image(16).foregroundStyle(source.color)
                        }
                        Text(view.source.label).dsFont(.sm, .medium).foregroundStyle(.textStrong)
                    }
                    .frame(minHeight: 28)
                }
                .buttonStyle(.plain)
                .accessibilityHint(view.source.tip)

                ForEach(Array(view.checks.enumerated()), id: \.offset) { index, check in
                    Button {
                        toggle(index)
                    } label: {
                        HStack(spacing: 6) {
                            (check.ok ? Icon.checkHeavy : .xHeavy).image(16)
                                .foregroundStyle(check.ok ? Color.brand : .danger)
                            Text(check.word.rawValue).dsFont(.md, .semibold).foregroundStyle(.textStrong)
                        }
                        .frame(minHeight: 28)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(check.word.rawValue): \(check.ok ? "passed" : "failed")")
                    .accessibilityHint(check.tip)
                }
            }
            .padding(.vertical, Space.s3)
            .padding(.horizontal, Space.s4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(tone == .danger ? Color.dangerSubtle.opacity(0.45) : .surfaceCard)
            .overlay(TopRounded(flat: view.notice != nil).stroke(tone?.border ?? .borderSubtle))
            .clipShape(TopRounded(flat: view.notice != nil))

            if let notice = view.notice, let tone {
                HStack(alignment: .top, spacing: 10) {
                    (notice.tone == .neutral ? Icon.info : .alertTriangle).image(18)
                        .foregroundStyle(tone.icon)
                        .padding(.top, 1)
                    Text(notice.text)
                        .dsFont(.md)
                        .foregroundStyle(.textBody)
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(.vertical, Space.s3)
                .padding(.horizontal, Space.s4)
                .background(tone.fill)
                .clipShape(BottomRounded())
                .overlay(BottomRounded().stroke(tone.border))
            }

            if let open, let tip = tip(view, open) {
                Text(tip)
                    .dsFont(.sm)
                    .foregroundStyle(.surfaceCard)
                    .padding(.vertical, Space.s2)
                    .padding(.horizontal, Space.s3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.textStrong, in: .dsCard)
                    .padding(.top, 6)
                    .transition(.opacity)
            }
        }
        .animation(Motion.fast, value: open)
    }

    private func toggle(_ index: Int) {
        open = open == index ? nil : index
    }

    private func tip(_ view: MessageChecksView, _ index: Int) -> String? {
        if index == -1 { return view.source.tip }
        return view.checks.indices.contains(index) ? view.checks[index].tip : nil
    }

    private func sourceIcon(_ kind: MessageChecksView.SourceKind) -> (icon: Icon, color: Color)? {
        switch kind {
        case .regular, .receipt: (.mail, .textMuted)
        case .dmcn: (.shieldCheck, .trustDMCN)
        case .contact: (.shieldCheck, .trustContact)
        case .own: nil
        }
    }

    private struct Tone: Equatable {
        let isDanger: Bool
        let fill: Color
        let border: Color
        let icon: Color
        static func == (a: Tone, b: Tone) -> Bool { a.isDanger == b.isDanger }
        static var danger: Tone { Tone(.danger) }

        init(_ tone: MessageChecksView.Notice.Tone) {
            isDanger = tone == .danger
            switch tone {
            case .danger:
                (fill, border, icon) = (.dangerSubtle, Color.danger.opacity(0.4), .danger)
            case .warning:
                (fill, border, icon) = (.warningSubtle, Color.warning.opacity(0.4), .warning)
            case .neutral:
                (fill, border, icon) = (.surfaceSunken, .borderSubtle, .textMuted)
            }
        }
    }
}

/// The strip's corners: all four alone, the top two when a notice hangs underneath.
private struct TopRounded: Shape {
    let flat: Bool

    func path(in rect: CGRect) -> Path {
        let radius = Radius.strip
        return UnevenRoundedRectangle(
            topLeadingRadius: radius, bottomLeadingRadius: flat ? 0 : radius, bottomTrailingRadius: flat ? 0 : radius,
            topTrailingRadius: radius, style: .continuous
        ).path(in: rect)
    }
}

private struct BottomRounded: Shape {
    func path(in rect: CGRect) -> Path {
        UnevenRoundedRectangle(
            topLeadingRadius: 0, bottomLeadingRadius: Radius.strip, bottomTrailingRadius: Radius.strip,
            topTrailingRadius: 0, style: .continuous
        ).path(in: rect)
    }
}

/// Lays children out in rows, wrapping when the next one won't fit: the web's `flex-wrap`.
struct FlowRow: Layout {
    var spacing: CGFloat = Space.s2
    var lineSpacing: CGFloat = Space.s2

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var line: CGFloat = 0
        var widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                y += line + lineSpacing
                x = 0
                line = 0
            }
            x += size.width + spacing
            widest = max(widest, x - spacing)
            line = max(line, size.height)
        }
        return CGSize(width: widest, height: y + line)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        var x = bounds.minX
        var y = bounds.minY
        var line: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                y += line + lineSpacing
                x = bounds.minX
                line = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            line = max(line, size.height)
        }
    }
}
