import AppKit
import SwiftUI
import UniformTypeIdentifiers

// Ported from space-agent onscreen-agent.css + agent-thread.css
// https://github.com/agent0ai/space-agent

enum SpaceAgentChatTokens {
    static let avatarSize: CGFloat = 72
    static let clusterGap: CGFloat = 12
    static let shellPadding: CGFloat = 8

    static let bubbleBg = Color.white
    static let bubbleText = Color(red: 0.082, green: 0.149, blue: 0.235) // #15263c
    static let bubbleBorder = Color(red: 0.082, green: 0.149, blue: 0.235).opacity(0.16)
    static let bubbleMaxWidth: CGFloat = 300
    static let bubblePaddingH: CGFloat = 15
    static let bubblePaddingV: CGFloat = 12
    static let bubbleRadius: CGFloat = 24
    static let bubbleFontSize: CGFloat = 15
    static let bubbleLineHeight: CGFloat = 1.35

    static let panelBg = Color(red: 11 / 255, green: 18 / 255, blue: 34 / 255).opacity(0.82)
    static let panelBorder = Color(red: 168 / 255, green: 186 / 255, blue: 219 / 255).opacity(0.16)
    static let panelRadius: CGFloat = 22
    static let compactPanelRadius: CGFloat = 19
    static let panelWidth: CGFloat = 440
    static let compactPanelWidth: CGFloat = 260
    static let compactPanelHeight: CGFloat = 52
    static let composerMinHeight: CGFloat = 24
    static let composerFieldHeightCompact: CGFloat = 28
    static let composerRowHeightCompact: CGFloat = 36
    static let composerActionRowHeight: CGFloat = 36
    static let composerStackedSpacing: CGFloat = 8
    static let composerMaxLinesCompact: CGFloat = 6
    static let composerMaxHeightCompact: CGFloat = 96
    static let composerMaxHeightFull: CGFloat = 128
    static let composerChromePadding: CGFloat = 16
    static let composerHorizontalPadding: CGFloat = 10

    static func composerTextLineHeight(fontSize: CGFloat = 13) -> CGFloat {
        let font = NSFont.systemFont(ofSize: fontSize)
        return ceil(font.ascender - font.descender + font.leading)
    }

    static var composerMaxTextHeightCompact: CGFloat {
        let lineHeight = composerTextLineHeight()
        return lineHeight * composerMaxLinesCompact + 4
    }

    static let compactInterButtonSpacing: CGFloat = 6
    static let compactTextButtonSpacing: CGFloat = 8

    static var compactButtonChromeWidth: CGFloat {
        composerActionRowHeight * 2 + compactInterButtonSpacing + compactTextButtonSpacing
    }

    static var compactComposerLayoutWidth: CGFloat {
        compactPanelWidth - composerHorizontalPadding * 2
    }

    static var compactInlineTextWidth: CGFloat {
        max(96, compactComposerLayoutWidth - compactButtonChromeWidth)
    }

    static func compactBarHeight(textHeight: CGFloat, expanded: Bool) -> CGFloat {
        if expanded {
            return textHeight + composerActionRowHeight + composerStackedSpacing
        }
        return composerRowHeightCompact
    }
    static let panelBgStrong = Color(red: 18 / 255, green: 29 / 255, blue: 51 / 255).opacity(0.74)
    static let danger = Color(red: 0.92, green: 0.28, blue: 0.28)
    static let historyMinHeight: CGFloat = 140
    static let historyIdealHeight: CGFloat = 380
    static let historyMaxHeight: CGFloat = 480
    static let codeBlockFontSize: CGFloat = 12
    static let codeBlockRadius: CGFloat = 10
    static let inputBg = Color(red: 16 / 255, green: 27 / 255, blue: 45 / 255).opacity(0.92)

    static let userBubbleBg = Color(red: 19 / 255, green: 32 / 255, blue: 51 / 255)
    static let userBubbleRadius: CGFloat = 12
    static let threadGap: CGFloat = 14
    static let bubbleGap: CGFloat = 12

    static let enterDuration: Double = 0.42
    static let exitDuration: Double = 0.18
    static let modeTransition: Double = 0.26
}

enum SpaceAgentBubblePhase: Equatable {
    case entering, visible, leaving
}

// MARK: - Shared panel chrome

private struct SpaceAgentPanelChrome<Content: View>: View {
    var compact: Bool = false
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .background(
                RoundedRectangle(
                    cornerRadius: compact ? SpaceAgentChatTokens.compactPanelRadius : SpaceAgentChatTokens.panelRadius,
                    style: .continuous
                )
                .fill(SpaceAgentChatTokens.panelBg)
                .background(
                    .ultraThinMaterial,
                    in: RoundedRectangle(
                        cornerRadius: compact ? SpaceAgentChatTokens.compactPanelRadius : SpaceAgentChatTokens.panelRadius,
                        style: .continuous
                    )
                )
                .overlay(
                    RoundedRectangle(
                        cornerRadius: compact ? SpaceAgentChatTokens.compactPanelRadius : SpaceAgentChatTokens.panelRadius,
                        style: .continuous
                    )
                    .strokeBorder(SpaceAgentChatTokens.panelBorder, lineWidth: 1)
                )
                .shadow(color: Color.black.opacity(compact ? 0.12 : 0.24), radius: compact ? 10 : 18, y: compact ? 4 : 8)
            )
    }
}

// MARK: - Bubble tail

struct SpaceAgentBubbleTail: Shape {
    var pointsTowardLeft: Bool

    func path(in rect: CGRect) -> Path {
        var p = Path()
        if pointsTowardLeft {
            p.move(to: CGPoint(x: rect.minX + rect.width * 0.19, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.minX + rect.width * 0.69, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            p.closeSubpath()
        } else {
            p.move(to: CGPoint(x: rect.minX + rect.width * 0.31, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.minX + rect.width * 0.81, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            p.closeSubpath()
        }
        return p
    }
}

struct SpaceAgentBubbleChrome<Content: View>: View {
    let peekEdge: PeekEdge
    let tailPointsLeft: Bool
    /// `true` when the bubble sits below the avatar head (tail attaches to top edge).
    var tailOnTop: Bool = false
    @ViewBuilder let content: () -> Content

    private let tailWidth: CGFloat = 64
    private let tailHeight: CGFloat = 29
    private let tailSideShift: CGFloat = 9

    var body: some View {
        VStack(spacing: 0) {
            if tailOnTop { tailRow }
            content()
                .padding(.horizontal, 15)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: SpaceAgentChatTokens.bubbleRadius, style: .continuous)
                        .fill(SpaceAgentChatTokens.bubbleBg)
                        .overlay(
                            RoundedRectangle(cornerRadius: SpaceAgentChatTokens.bubbleRadius, style: .continuous)
                                .strokeBorder(SpaceAgentChatTokens.bubbleBorder, lineWidth: 1)
                        )
                )
            if !tailOnTop { tailRow.offset(y: -1) }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var tailRow: some View {
        HStack(spacing: 0) {
            if !tailPointsLeft { Spacer(minLength: 0) }
            SpaceAgentBubbleTail(pointsTowardLeft: tailPointsLeft)
                .fill(SpaceAgentChatTokens.bubbleBg)
                .frame(width: tailWidth, height: tailHeight)
                .overlay(
                    SpaceAgentBubbleTail(pointsTowardLeft: tailPointsLeft)
                        .stroke(SpaceAgentChatTokens.bubbleBorder, lineWidth: 1)
                )
                .offset(x: tailPointsLeft ? -tailSideShift : tailSideShift)
            if tailPointsLeft { Spacer(minLength: 0) }
        }
        .frame(maxWidth: .infinity, alignment: tailPointsLeft ? .leading : .trailing)
        .padding(.horizontal, 12)
    }
}

// MARK: - Land animation

struct SpaceAgentBubbleLandModifier: ViewModifier {
    let token: String
    var belowHead: Bool = false
    @State private var phase: CGFloat = 0

    private var landY: CGFloat { belowHead ? -22 : 22 }

    func body(content: Content) -> some View {
        content
            .scaleEffect(landScale)
            .offset(y: landOffsetY)
            .rotationEffect(.degrees(landRotation))
            .opacity(landOpacity)
            .onAppear { playEnter() }
            .onChange(of: token) { _, _ in playEnter() }
    }

    private var landScale: CGFloat {
        if phase <= 0.58 { return 0.72 + (1.04 - 0.72) * (phase / 0.58) }
        return 1.04 + (1.0 - 1.04) * ((phase - 0.58) / 0.42)
    }

    private var landOffsetY: CGFloat {
        if phase <= 0.58 { return landY + (-landY * 0.16 - landY) * (phase / 0.58) }
        return -landY * 0.16 * (1 - (phase - 0.58) / 0.42)
    }

    private var landRotation: CGFloat {
        if phase <= 0.58 { return -4 + (1 - (-4)) * (phase / 0.58) }
        return 1 * (1 - (phase - 0.58) / 0.42)
    }

    private var landOpacity: CGFloat { phase <= 0.01 ? 0 : 1 }

    private func playEnter() {
        phase = 0
        withAnimation(.timingCurve(0.2, 1.24, 0.32, 1, duration: 0.42)) {
            phase = 1
        }
    }
}

extension View {
    func spaceAgentBubbleLand(token: String, belowHead: Bool = false) -> some View {
        modifier(SpaceAgentBubbleLandModifier(token: token, belowHead: belowHead))
    }
}

// MARK: - Mood / usage bubbles

struct SpaceAgentSpeechBubbleView: View {
    let text: String
    var peekEdge: PeekEdge = .left
    var belowHead: Bool = false

    private var tailPointsLeft: Bool { peekEdge == .left }

    var body: some View {
        bubbleBody
            .frame(maxWidth: SpaceAgentChatTokens.bubbleMaxWidth, alignment: tailPointsLeft ? .trailing : .leading)
            .spaceAgentBubbleLand(token: text, belowHead: belowHead)
    }

    private var bubbleBody: some View {
        SpaceAgentBubbleChrome(peekEdge: peekEdge, tailPointsLeft: tailPointsLeft, tailOnTop: belowHead) {
            Text(text)
                .font(.system(size: SpaceAgentChatTokens.bubbleFontSize, weight: .medium, design: .rounded))
                .foregroundStyle(SpaceAgentChatTokens.bubbleText)
                .multilineTextAlignment(.leading)
                .lineSpacing(SpaceAgentChatTokens.bubbleFontSize * (SpaceAgentChatTokens.bubbleLineHeight - 1))
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct SpaceAgentUsageBadgeView: View {
    let stats: [UsageStat]
    let note: String?
    var peekEdge: PeekEdge = .left

    private var tailPointsLeft: Bool { peekEdge == .left }

    var body: some View {
        SpaceAgentBubbleChrome(peekEdge: peekEdge, tailPointsLeft: tailPointsLeft) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 5) {
                    HermesSparkCompact().frame(width: 13, height: 13)
                    Text("USAGE")
                        .font(.system(size: 9, weight: .heavy, design: .rounded))
                        .tracking(1.2)
                        .foregroundStyle(Palette.hermesPurple)
                }
                if let note {
                    Text(note)
                        .font(.system(size: SpaceAgentChatTokens.bubbleFontSize - 1, weight: .medium, design: .rounded))
                        .foregroundStyle(SpaceAgentChatTokens.bubbleText.opacity(0.72))
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ForEach(stats, id: \.label) { SpaceAgentUsageStatRow(stat: $0) }
                }
            }
            .frame(minWidth: 168, alignment: .leading)
        }
        .spaceAgentBubbleLand(token: note ?? stats.map(\.label).joined())
    }
}

private struct SpaceAgentUsageStatRow: View {
    let stat: UsageStat

    var body: some View {
        HStack(spacing: 8) {
            Text(stat.label)
                .font(.system(size: 13, weight: .heavy, design: .rounded))
                .foregroundStyle(SpaceAgentChatTokens.bubbleText)
                .frame(width: 20, alignment: .leading)
            SpaceAgentUsageMeter(pct: stat.pct).frame(width: 56, height: 6)
            Text("\(Int(stat.pct.rounded()))%")
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(Palette.usageFill(stat.pct))
                .frame(width: 32, alignment: .trailing)
            Text(stat.detail)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(SpaceAgentChatTokens.bubbleText.opacity(0.45))
        }
    }
}

private struct SpaceAgentUsageMeter: View {
    let pct: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.hermesPurple.opacity(0.16))
                Capsule().fill(Palette.usageFill(pct))
                    .frame(width: max(3, geo.size.width * min(1, max(0, pct / 100))))
            }
        }
    }
}

private struct HermesSparkCompact: View {
    var body: some View {
        Canvas { ctx, size in
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            let r = size.width / 2
            for i in 0..<8 {
                let a = Double(i) * .pi / 4
                var p = Path()
                p.move(to: c)
                p.addLine(to: CGPoint(x: c.x + CGFloat(cos(a)) * r, y: c.y + CGFloat(sin(a)) * r))
                ctx.stroke(p, with: .color(Palette.hermesPurple),
                           style: StrokeStyle(lineWidth: i % 2 == 0 ? 1.7 : 1.0, lineCap: .round))
            }
        }
    }
}

// MARK: - Compact response card (full panel width, stacked above composer)

struct SpaceAgentCompactResponseCard: View {
    let text: String
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            Text(text)
                .font(.system(size: SpaceAgentChatTokens.bubbleFontSize, weight: .medium, design: .rounded))
                .foregroundStyle(SpaceAgentChatTokens.bubbleText)
                .multilineTextAlignment(.leading)
                .lineSpacing(SpaceAgentChatTokens.bubbleFontSize * (SpaceAgentChatTokens.bubbleLineHeight - 1))
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, SpaceAgentChatTokens.bubblePaddingH)
                .padding(.vertical, SpaceAgentChatTokens.bubblePaddingV)
                .background(
                    RoundedRectangle(cornerRadius: SpaceAgentChatTokens.bubbleRadius, style: .continuous)
                        .fill(SpaceAgentChatTokens.bubbleBg)
                        .overlay(
                            RoundedRectangle(cornerRadius: SpaceAgentChatTokens.bubbleRadius, style: .continuous)
                                .strokeBorder(SpaceAgentChatTokens.bubbleBorder, lineWidth: 1)
                        )
                )
        }
        .buttonStyle(.plain)
        .spaceAgentBubbleLand(token: text)
    }
}

struct SpaceAgentCompactTraceCard: View {
    let text: String

    @State private var traceStartedAt = Date()

    var body: some View {
        TimelineView(.periodic(from: traceStartedAt, by: 1)) { timeline in
            let elapsed = max(0, Int(timeline.date.timeIntervalSince(traceStartedAt).rounded(.down)))

            HStack(spacing: 8) {
                Circle()
                    .fill(Palette.hermesPurple.opacity(0.85))
                    .frame(width: 6, height: 6)
                Text(text)
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .foregroundStyle(SpaceAgentChatTokens.bubbleText.opacity(0.68))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("\(elapsed)s")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Palette.hermesPurple.opacity(0.72))
                    .monospacedDigit()
                    .frame(minWidth: 28, alignment: .trailing)
            }
            .padding(.horizontal, SpaceAgentChatTokens.bubblePaddingH)
            .padding(.vertical, SpaceAgentChatTokens.bubblePaddingV)
            .background(
                RoundedRectangle(cornerRadius: SpaceAgentChatTokens.bubbleRadius, style: .continuous)
                    .fill(SpaceAgentChatTokens.bubbleBg)
                    .overlay(
                        RoundedRectangle(cornerRadius: SpaceAgentChatTokens.bubbleRadius, style: .continuous)
                            .strokeBorder(SpaceAgentChatTokens.bubbleBorder, lineWidth: 1)
                    )
            )
        }
        .animation(.easeOut(duration: 0.12), value: text)
        .onAppear { traceStartedAt = Date() }
        .onChange(of: text) { _, _ in traceStartedAt = Date() }
    }
}

struct SpaceAgentCompactResponseLoading: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 0.12)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            HStack(spacing: 5) {
                ForEach(0..<3, id: \.self) { i in
                    let pulse = sin(t * 5 + Double(i) * 0.9) * 0.5 + 0.5
                    Circle()
                        .fill(SpaceAgentChatTokens.bubbleText.opacity(0.22 + 0.45 * pulse))
                        .frame(width: 7, height: 7)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, SpaceAgentChatTokens.bubblePaddingH)
            .padding(.vertical, SpaceAgentChatTokens.bubblePaddingV)
            .background(
                RoundedRectangle(cornerRadius: SpaceAgentChatTokens.bubbleRadius, style: .continuous)
                    .fill(SpaceAgentChatTokens.bubbleBg)
                    .overlay(
                        RoundedRectangle(cornerRadius: SpaceAgentChatTokens.bubbleRadius, style: .continuous)
                            .strokeBorder(SpaceAgentChatTokens.bubbleBorder, lineWidth: 1)
                    )
            )
        }
        .spaceAgentBubbleLand(token: "loading")
    }
}

// MARK: - Assistant bubble (compact — tap to expand)

struct SpaceAgentAssistantBubbleView: View {
    let text: String
    var peekEdge: PeekEdge = .left
    var belowHead: Bool = false
    let onTap: () -> Void

    private var tailPointsLeft: Bool { peekEdge == .left }

    var body: some View {
        Button(action: onTap) {
            SpaceAgentBubbleChrome(peekEdge: peekEdge, tailPointsLeft: tailPointsLeft, tailOnTop: belowHead) {
                Text(text)
                    .font(.system(size: SpaceAgentChatTokens.bubbleFontSize, weight: .medium, design: .rounded))
                    .foregroundStyle(SpaceAgentChatTokens.bubbleText)
                    .multilineTextAlignment(.leading)
                    .lineSpacing(SpaceAgentChatTokens.bubbleFontSize * (SpaceAgentChatTokens.bubbleLineHeight - 1))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: SpaceAgentChatTokens.bubbleMaxWidth, alignment: tailPointsLeft ? .trailing : .leading)
        }
        .buttonStyle(.plain)
        .spaceAgentBubbleLand(token: text)
    }
}

struct SpaceAgentCompactLoadingBubble: View {
    var peekEdge: PeekEdge = .left
    var belowHead: Bool = false

    private var tailPointsLeft: Bool { peekEdge == .left }

    var body: some View {
        SpaceAgentBubbleChrome(peekEdge: peekEdge, tailPointsLeft: tailPointsLeft, tailOnTop: belowHead) {
            TimelineView(.animation(minimumInterval: 0.12)) { timeline in
                let t = timeline.date.timeIntervalSinceReferenceDate
                HStack(spacing: 5) {
                    ForEach(0..<3, id: \.self) { i in
                        let pulse = sin(t * 5 + Double(i) * 0.9) * 0.5 + 0.5
                        Circle()
                            .fill(SpaceAgentChatTokens.bubbleText.opacity(0.22 + 0.45 * pulse))
                            .frame(width: 7, height: 7)
                    }
                }
                .frame(minWidth: 48, alignment: .leading)
            }
        }
        .frame(maxWidth: SpaceAgentChatTokens.bubbleMaxWidth, alignment: tailPointsLeft ? .trailing : .leading)
        .spaceAgentBubbleLand(token: "loading")
    }
}

// MARK: - Composer caret (avoid select-all after file drop)

private enum SpaceAgentComposerSelection {
    static func placeCaretAtEnd() {
        DispatchQueue.main.async {
            guard let responder = NSApp.keyWindow?.firstResponder
                ?? NSApp.windows.first(where: \.isVisible)?.firstResponder else { return }
            if let view = responder as? NSTextView {
                let end = view.string.count
                view.setSelectedRange(NSRange(location: end, length: 0))
                return
            }
            if let field = responder as? NSTextField, let editor = field.currentEditor() {
                let end = field.stringValue.count
                editor.selectedRange = NSRange(location: end, length: 0)
            }
        }
    }
}

// MARK: - File drop → composer paths

private enum SpaceAgentFileDrop {
    static func append(paths: [String], to text: inout String) {
        let incoming = paths
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !incoming.isEmpty else { return }

        let chunk = incoming.joined(separator: " ")
        let existing = text.trimmingCharacters(in: .whitespacesAndNewlines)
        text = existing.isEmpty ? chunk : existing + " " + chunk
    }

    static func paths(from providers: [NSItemProvider]) async -> [String] {
        var paths: [String] = []
        for provider in providers {
            guard provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) else { continue }
            guard let item = try? await provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier),
                  let path = path(from: item) else { continue }
            paths.append(path)
        }
        return paths
    }

    private static func path(from item: NSSecureCoding?) -> String? {
        if let url = item as? URL { return url.path }
        if let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) { return url.path }
        if let raw = item as? String {
            if raw.hasPrefix("file://"), let url = URL(string: raw) { return url.path }
            if raw.hasPrefix("/") { return raw }
        }
        return nil
    }
}

private struct SpaceAgentFileDropTarget: ViewModifier {
    @Binding var text: String
    @Binding var isTargeted: Bool
    var onPathsAppended: (() -> Void)?

    func body(content: Content) -> some View {
        content
            .overlay {
                RoundedRectangle(
                    cornerRadius: SpaceAgentChatTokens.compactPanelRadius,
                    style: .continuous
                )
                .strokeBorder(Palette.hermesPurple.opacity(isTargeted ? 0.55 : 0), lineWidth: 2)
                .animation(.easeOut(duration: 0.15), value: isTargeted)
            }
            .onDrop(of: [UTType.fileURL], isTargeted: $isTargeted) { providers in
                Task {
                    let paths = await SpaceAgentFileDrop.paths(from: providers)
                    await MainActor.run {
                        guard !paths.isEmpty else { return }
                        SpaceAgentFileDrop.append(paths: paths, to: &text)
                        onPathsAppended?()
                    }
                }
                return true
            }
    }
}

private extension View {
    func spaceAgentFileDrop(
        text: Binding<String>,
        isTargeted: Binding<Bool>,
        onPathsAppended: (() -> Void)? = nil
    ) -> some View {
        modifier(SpaceAgentFileDropTarget(text: text, isTargeted: isTargeted, onPathsAppended: onPathsAppended))
    }
}

// MARK: - Composer (NSTextView — full paste, selection, auto-height)

final class SpaceAgentComposerPlaceholderLabel: NSView {
    var text = "" {
        didSet { needsDisplay = true }
    }
    var font = NSFont.systemFont(ofSize: 13) {
        didSet { needsDisplay = true }
    }
    var textColor = NSColor.white.withAlphaComponent(0.45) {
        didSet { needsDisplay = true }
    }

    override var isOpaque: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard !text.isEmpty else { return }
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: textColor,
            .paragraphStyle: style,
        ]
        NSAttributedString(string: text, attributes: attrs)
            .draw(with: bounds, options: [.usesLineFragmentOrigin, .usesFontLeading])
    }
}

final class SpaceAgentComposerScrollView: NSScrollView {
    weak var composerContainer: SpaceAgentComposerTextContainer?

    override var acceptsFirstResponder: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard let container = composerContainer else {
            super.mouseDown(with: event)
            return
        }
        container.activateComposer(at: event)
        container.textView.mouseDown(with: event)
    }
}

final class SpaceAgentComposerNSTextView: NSTextView {
    weak var composerContainer: SpaceAgentComposerTextContainer?
    weak var slashController: SlashCompletionController?

    init() {
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        layoutManager.addTextContainer(container)
        super.init(frame: .zero, textContainer: container)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func keyDown(with event: NSEvent) {
        if let slash = slashController, slash.isVisible {
            switch event.keyCode {
            case 125: slash.moveSelection(by: 1); return
            case 126: slash.moveSelection(by: -1); return
            case 48, 36: slash.applySelected(to: self); return
            case 53: slash.dismiss(); return
            default: break
            }
        }
        super.keyDown(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        composerContainer?.activateComposer(at: event)
        super.mouseDown(with: event)
    }

    override func drawInsertionPoint(in rect: NSRect, color: NSColor, turnedOn: Bool) {
        guard turnedOn else { return }
        var caret = rect
        caret.size.width = 2
        if caret.size.height < 12 {
            caret.origin.y -= (12 - caret.size.height) / 2
            caret.size.height = 12
        }
        NSColor.white.setFill()
        NSBezierPath(rect: caret).fill()
    }

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became {
            composerContainer?.isEditing = true
            composerContainer?.updatePlaceholderVisibility()
            DispatchQueue.main.async { [weak self] in
                self?.updateInsertionPointStateAndRestartTimer(true)
            }
        }
        return became
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned {
            composerContainer?.isEditing = false
            composerContainer?.updatePlaceholderVisibility()
        }
        return resigned
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.modifierFlags.contains(.command),
              let key = event.charactersIgnoringModifiers?.lowercased() else {
            return super.performKeyEquivalent(with: event)
        }
        switch key {
        case "v": return composerContainer?.pasteFromPasteboard() ?? false
        case "c": return composerContainer?.copySelection() ?? false
        case "x": return composerContainer?.cutSelection() ?? false
        case "a": composerContainer?.selectAllText(); return true
        default: return super.performKeyEquivalent(with: event)
        }
    }
}

final class SpaceAgentComposerTextContainer: NSView {
    static weak var activeComposer: SpaceAgentComposerTextContainer?

    let scrollView = SpaceAgentComposerScrollView()
    let textView = SpaceAgentComposerNSTextView()
    let placeholderLabel = SpaceAgentComposerPlaceholderLabel()

    var fontSize: CGFloat = 13
    var minFieldHeight: CGFloat = SpaceAgentChatTokens.composerMinHeight
    var maxTextHeight: CGFloat = SpaceAgentChatTokens.composerMaxHeightCompact
    var measurementWidth: CGFloat?
    var inlineLayoutWidth: CGFloat?
    var stackedLayoutWidth: CGFloat?
    var contentInsets = NSEdgeInsets(top: 2, left: 0, bottom: 2, right: 0)
    var onActivate: (() -> Void)?
    var onHeightChange: ((CGFloat) -> Void)?
    var onExpandedLayoutChange: ((Bool) -> Void)?

    private var usesExpandedLayout = false
    private var isRecalculatingHeight = false
    private var lastReportedHeight: CGFloat = SpaceAgentChatTokens.composerRowHeightCompact
    private var lastLayoutWidth: CGFloat = 0

    var isEditing = false
    private var windowKeyObserver: NSObjectProtocol?

    static func pasteIntoActiveComposer() -> Bool {
        guard let composer = activeComposer else { return false }
        NSApp.activate(ignoringOtherApps: true)
        composer.window?.makeKey()
        composer.window?.makeFirstResponder(composer.textView)
        return composer.pasteFromPasteboard()
    }

    static func copyFromActiveComposer() -> Bool {
        activeComposer?.copySelection() ?? false
    }

    static func cutFromActiveComposer() -> Bool {
        activeComposer?.cutSelection() ?? false
    }

    static func selectAllInActiveComposer() -> Bool {
        activeComposer?.selectAllText()
        return activeComposer != nil
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = false
        clipsToBounds = true

        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.clipsToBounds = true
        scrollView.wantsLayer = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        textView.wantsLayer = false
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.isEditable = true
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.isVerticallyResizable = false
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineBreakMode = .byWordWrapping
        textView.textContainer?.lineFragmentPadding = 0
        textView.autoresizingMask = [.width]
        textView.insertionPointColor = .white

        textView.composerContainer = self
        scrollView.composerContainer = self
        scrollView.documentView = textView

        addSubview(placeholderLabel)
        addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        applyContentInsets()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let windowKeyObserver {
            NotificationCenter.default.removeObserver(windowKeyObserver)
            self.windowKeyObserver = nil
        }
        guard let window else { return }
        Self.activeComposer = self
        windowKeyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            self?.refreshInsertionPoint()
        }
    }

    deinit {
        if let windowKeyObserver {
            NotificationCenter.default.removeObserver(windowKeyObserver)
        }
    }

    func isTextViewFocused() -> Bool {
        guard let window else { return isEditing }
        let responder = window.firstResponder as AnyObject?
        if responder === textView { return true }
        if let editor = window.fieldEditor(false, for: textView) as AnyObject?, responder === editor {
            return true
        }
        return isEditing
    }

    func refreshInsertionPoint() {
        guard isTextViewFocused() else { return }
        textView.updateInsertionPointStateAndRestartTimer(true)
        textView.setNeedsDisplay(textView.visibleRect)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard bounds.contains(point) else { return nil }
        for subview in subviews.reversed() {
            let local = convert(point, to: subview)
            if let hit = subview.hitTest(local) { return hit }
        }
        return self
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        activateComposer(at: event)
    }

    func activateComposer(at event: NSEvent) {
        onActivate?()
        let windowPoint = event.locationInWindow
        DispatchQueue.main.async { [weak self] in
            self?.claimFocus(placeCaretAt: windowPoint)
        }
    }

    func focusTextView(placeCaretAtEnd: Bool = false, notifyActivate: Bool = false) {
        if notifyActivate {
            onActivate?()
            DispatchQueue.main.async { [weak self] in
                self?.claimFocus(placeCaretAt: nil, placeCaretAtEnd: placeCaretAtEnd)
            }
            return
        }
        claimFocus(placeCaretAt: nil, placeCaretAtEnd: placeCaretAtEnd)
    }

    static func focusActiveComposer(placeCaretAtEnd: Bool = true) {
        activeComposer?.claimFocus(placeCaretAt: nil, placeCaretAtEnd: placeCaretAtEnd)
    }

    fileprivate func claimFocus(placeCaretAt windowPoint: NSPoint?, placeCaretAtEnd: Bool = false) {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(textView)
        if let windowPoint {
            placeCaret(atWindowPoint: windowPoint)
        } else if placeCaretAtEnd {
            let end = (textView.string as NSString).length
            textView.setSelectedRange(NSRange(location: end, length: 0))
            textView.scrollRangeToVisible(NSRange(location: end, length: 0))
        }
        isEditing = window?.firstResponder === textView
            || window?.firstResponder === window?.fieldEditor(false, for: textView)
        updatePlaceholderVisibility()
        textView.updateInsertionPointStateAndRestartTimer(true)
        refreshInsertionPoint()
    }

    private func placeCaret(atWindowPoint windowPoint: NSPoint) {
        let point = textView.convert(windowPoint, from: nil)
        let index = textView.characterIndexForInsertion(at: point)
        textView.setSelectedRange(NSRange(location: index, length: 0))
        textView.scrollRangeToVisible(NSRange(location: index, length: 0))
    }

    func applyContentInsets() {
        _ = recalculateHeight()
    }

    private func singleLineVerticalInset(forFieldHeight fieldHeight: CGFloat, wrapWidth: CGFloat) -> CGFloat {
        let lineHeight = measuredContentLineHeight(wrapWidth: wrapWidth)
        let targetHeight = max(minFieldHeight, fieldHeight)
        guard usesSingleLineVerticalCentering(wrapWidth: wrapWidth) else { return contentInsets.top }
        return max(contentInsets.top, floor((targetHeight - lineHeight) / 2))
    }

    private func layoutWidth() -> CGFloat {
        max(1, activeLayoutWidth())
    }

    private func emptyFieldHeight() -> CGFloat {
        let width = layoutWidth()
        let wrapWidth = max(1, width - contentInsets.left - contentInsets.right)
        let lineHeight = measuredContentLineHeight(wrapWidth: wrapWidth)
        return min(
            maxTextHeight,
            max(minFieldHeight, lineHeight + contentInsets.top + contentInsets.bottom)
        )
    }

    private func placeholderRect(forFieldHeight fieldHeight: CGFloat, wrapWidth: CGFloat) -> NSRect {
        let lineHeight = measuredContentLineHeight(wrapWidth: wrapWidth)
        let verticalInset = singleLineVerticalInset(forFieldHeight: fieldHeight, wrapWidth: wrapWidth)
        let width = max(1, bounds.width - contentInsets.left - contentInsets.right)
        return NSRect(
            x: contentInsets.left,
            y: verticalInset,
            width: width,
            height: lineHeight
        )
    }

    private func layoutPlaceholder(forFieldHeight fieldHeight: CGFloat, wrapWidth: CGFloat) {
        placeholderLabel.frame = placeholderRect(forFieldHeight: fieldHeight, wrapWidth: wrapWidth)
    }

    private func singleLineTextHeight() -> CGFloat {
        let font = textView.font ?? NSFont.systemFont(ofSize: fontSize)
        return ceil(font.ascender - font.descender + font.leading)
    }

    private func wrapWidth(for layoutWidth: CGFloat) -> CGFloat {
        max(1, layoutWidth - contentInsets.left - contentInsets.right)
    }

    private func textUsedHeight(forLayoutWidth layoutWidth: CGFloat) -> CGFloat {
        guard !textView.string.isEmpty else { return 0 }
        let resolvedWrapWidth = wrapWidth(for: layoutWidth)
        let font = textView.font ?? NSFont.systemFont(ofSize: fontSize)
        let attrs: [NSAttributedString.Key: Any] = [.font: font]
        let rect = (textView.string as NSString).boundingRect(
            with: NSSize(width: resolvedWrapWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attrs
        )
        return ceil(rect.height)
    }

    private func measuredContentLineHeight(forLayoutWidth layoutWidth: CGFloat) -> CGFloat {
        if textView.string.isEmpty { return singleLineTextHeight() }
        return max(singleLineTextHeight(), textUsedHeight(forLayoutWidth: layoutWidth))
    }

    private func measuredContentLineHeight(wrapWidth: CGFloat) -> CGFloat {
        let layoutWidth = wrapWidth + contentInsets.left + contentInsets.right
        return measuredContentLineHeight(forLayoutWidth: layoutWidth)
    }

    private func usesSingleLineVerticalCentering(wrapWidth: CGFloat? = nil) -> Bool {
        if textView.string.contains("\n") { return false }
        if textView.string.isEmpty { return true }
        let width = layoutWidth()
        return textUsedHeight(forLayoutWidth: width) <= singleLineTextHeight() + 1
    }

    private func fitsSingleLine(atLayoutWidth layoutWidth: CGFloat) -> Bool {
        if textView.string.contains("\n") { return false }
        if textView.string.isEmpty { return true }
        return textUsedHeight(forLayoutWidth: layoutWidth) <= singleLineTextHeight() + 1
    }

    @discardableResult
    private func updateExpandedLayoutState() -> Bool {
        let inlineWidth = inlineLayoutWidth ?? measurementWidth ?? bounds.width
        let shouldExpand: Bool
        if textView.string.isEmpty {
            shouldExpand = false
        } else if textView.string.contains("\n") || !fitsSingleLine(atLayoutWidth: inlineWidth) {
            shouldExpand = true
        } else {
            shouldExpand = false
        }
        guard shouldExpand != usesExpandedLayout else { return false }
        usesExpandedLayout = shouldExpand
        let callback = onExpandedLayoutChange
        DispatchQueue.main.async {
            callback?(shouldExpand)
        }
        return true
    }

    private func activeLayoutWidth() -> CGFloat {
        if usesExpandedLayout {
            return stackedLayoutWidth ?? measurementWidth ?? bounds.width
        }
        return inlineLayoutWidth ?? measurementWidth ?? bounds.width
    }

    private func displayHeight(forReported reported: CGFloat, singleLineCentered: Bool) -> CGFloat {
        guard singleLineCentered else { return reported }
        return bounds.height > 1 ? bounds.height : reported
    }

    private func updateVerticalAlignment(forFieldHeight fieldHeight: CGFloat, wrapWidth: CGFloat) {
        let verticalInset = singleLineVerticalInset(forFieldHeight: fieldHeight, wrapWidth: wrapWidth)
        let inset = NSSize(width: contentInsets.left, height: verticalInset)
        if abs(textView.textContainerInset.width - inset.width) > 0.5
            || abs(textView.textContainerInset.height - inset.height) > 0.5 {
            textView.textContainerInset = inset
            refreshTextLayout()
        }
        layoutPlaceholder(forFieldHeight: fieldHeight, wrapWidth: wrapWidth)
    }

    private func refreshTextLayout() {
        guard let layoutManager = textView.layoutManager,
              let container = textView.textContainer else { return }
        let length = (textView.string as NSString).length
        if length > 0 {
            var actualRange = NSRange(location: 0, length: 0)
            layoutManager.invalidateLayout(
                forCharacterRange: NSRange(location: 0, length: length),
                actualCharacterRange: &actualRange
            )
        }
        layoutManager.ensureLayout(for: container)
        textView.needsDisplay = true
    }

    @discardableResult
    func pasteFromPasteboard() -> Bool {
        guard let paste = NSPasteboard.general.string(forType: .string) else { return false }
        textView.insertText(paste, replacementRange: textView.selectedRange())
        textDidChange()
        return true
    }

    @discardableResult
    func copySelection() -> Bool {
        let range = textView.selectedRange()
        guard range.length > 0 else { return false }
        let copy = (textView.string as NSString).substring(with: range)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(copy, forType: .string)
        return true
    }

    @discardableResult
    func cutSelection() -> Bool {
        guard copySelection() else { return false }
        textView.insertText("", replacementRange: textView.selectedRange())
        textDidChange()
        return true
    }

    func selectAllText() {
        focusTextView()
        textView.selectAll(nil)
    }

    private func textDidChange() {
        updatePlaceholderVisibility()
        _ = recalculateHeight()
    }

    func applyStyle(fontSize: CGFloat) {
        self.fontSize = fontSize
        let font = NSFont.systemFont(ofSize: fontSize)
        textView.font = font
        textView.textColor = NSColor.white.withAlphaComponent(0.92)
        textView.typingAttributes = [
            .font: font,
            .foregroundColor: NSColor.white.withAlphaComponent(0.92),
        ]
        placeholderLabel.font = font
        placeholderLabel.textColor = NSColor.white.withAlphaComponent(0.45)
        _ = recalculateHeight()
    }

    func setPlaceholder(_ text: String) {
        placeholderLabel.text = text
        updatePlaceholderVisibility()
    }

    func updatePlaceholderVisibility() {
        let hidden = isTextViewFocused() || !textView.string.isEmpty
        placeholderLabel.isHidden = hidden
        if !hidden { _ = recalculateHeight() }
    }

    @discardableResult
    func recalculateHeight() -> CGFloat {
        guard !isRecalculatingHeight else { return lastReportedHeight }
        isRecalculatingHeight = true
        defer { isRecalculatingHeight = false }

        _ = updateExpandedLayoutState()
        let width = max(1, activeLayoutWidth())
        let resolvedWrapWidth = wrapWidth(for: width)
        let reported: CGFloat
        let singleLineCentered: Bool
        let contentNaturalHeight: CGFloat

        if textView.string.isEmpty {
            reported = emptyFieldHeight()
            singleLineCentered = true
            contentNaturalHeight = reported
        } else if usesSingleLineVerticalCentering(wrapWidth: resolvedWrapWidth) {
            reported = emptyFieldHeight()
            singleLineCentered = true
            contentNaturalHeight = reported
        } else {
            let verticalPad = contentInsets.top + contentInsets.bottom
            let usedHeight = textUsedHeight(forLayoutWidth: width)
            contentNaturalHeight = usedHeight + verticalPad + 4
            reported = min(max(minFieldHeight, contentNaturalHeight), maxTextHeight)
            singleLineCentered = false
        }

        if let layoutManager = textView.layoutManager,
           let container = textView.textContainer {
            container.containerSize = NSSize(width: resolvedWrapWidth, height: CGFloat.greatestFiniteMagnitude)
            layoutManager.ensureLayout(for: container)
        }

        let visibleHeight = displayHeight(forReported: reported, singleLineCentered: singleLineCentered)
        let documentHeight = singleLineCentered
            ? visibleHeight
            : max(visibleHeight, contentNaturalHeight)
        scrollView.hasVerticalScroller = documentHeight > visibleHeight + 0.5
        updateVerticalAlignment(forFieldHeight: visibleHeight, wrapWidth: resolvedWrapWidth)
        syncTextViewFrame(visibleHeight: visibleHeight, documentHeight: documentHeight)
        if singleLineCentered {
            scrollView.contentView.scroll(to: .zero)
        } else {
            let caret = textView.selectedRange()
            textView.scrollRangeToVisible(caret)
        }

        lastReportedHeight = reported
        onHeightChange?(reported)
        return reported
    }

    private func syncTextViewFrame(visibleHeight: CGFloat, documentHeight: CGFloat) {
        let width = max(1, bounds.width)
        let clampedVisible = min(max(minFieldHeight, visibleHeight), maxTextHeight)
        let clampedDocument = max(clampedVisible, documentHeight)
        textView.minSize = NSSize(width: width, height: minFieldHeight)
        textView.maxSize = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        let needsResize = abs(textView.frame.width - width) > 0.5
            || abs(textView.frame.height - clampedDocument) > 0.5
        if needsResize {
            textView.setFrameSize(NSSize(width: width, height: clampedDocument))
            textView.frame.origin = .zero
            refreshTextLayout()
        }
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    override func layout() {
        super.layout()
        let width = bounds.width
        guard width > 1, abs(width - lastLayoutWidth) > 0.5 else { return }
        lastLayoutWidth = width
        DispatchQueue.main.async { [weak self] in
            _ = self?.recalculateHeight()
        }
    }
}

private struct SpaceAgentComposerTextView: NSViewRepresentable {
    @Binding var text: String
    @Binding var measuredHeight: CGFloat
    @ObservedObject var slashController: SlashCompletionController
    var placeholder: String
    var fontSize: CGFloat
    var maxTextHeight: CGFloat
    var minFieldHeight: CGFloat = SpaceAgentChatTokens.composerMinHeight
    var contentInsets: NSEdgeInsets = NSEdgeInsets(top: 2, left: 0, bottom: 2, right: 0)
    var measurementWidth: CGFloat?
    var inlineLayoutWidth: CGFloat?
    var stackedLayoutWidth: CGFloat?
    var postsComposerHeightNotification = true
    var onExpandedLayoutChange: ((Bool) -> Void)?
    var focus: FocusState<Bool>.Binding
    var onActivate: (() -> Void)?
    var onSubmit: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    private func handleHeightChange(_ height: CGFloat) {
        if abs(measuredHeight - height) > 0.5 {
            measuredHeight = height
            if postsComposerHeightNotification {
                NotificationCenter.default.post(name: .pipComposerHeight, object: height)
            }
        }
    }

    func makeNSView(context: Context) -> SpaceAgentComposerTextContainer {
        let container = SpaceAgentComposerTextContainer()
        container.maxTextHeight = maxTextHeight
        container.minFieldHeight = minFieldHeight
        container.measurementWidth = measurementWidth
        container.inlineLayoutWidth = inlineLayoutWidth
        container.stackedLayoutWidth = stackedLayoutWidth
        container.contentInsets = contentInsets
        container.applyContentInsets()
        container.applyStyle(fontSize: fontSize)
        container.setPlaceholder(placeholder)
        container.textView.delegate = context.coordinator
        container.onActivate = onActivate
        container.onExpandedLayoutChange = onExpandedLayoutChange
        container.onHeightChange = { [self] height in
            handleHeightChange(height)
        }
        container.textView.string = text
        container.textView.slashController = slashController
        container.setContentHuggingPriority(.defaultLow, for: .horizontal)
        container.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        SpaceAgentComposerTextContainer.activeComposer = container
        return container
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: SpaceAgentComposerTextContainer, context: Context) -> CGSize? {
        let width = proposal.width ?? max(nsView.bounds.width, 1)
        let height = max(minFieldHeight, min(measuredHeight, maxTextHeight))
        return CGSize(width: width, height: height)
    }

    func updateNSView(_ container: SpaceAgentComposerTextContainer, context: Context) {
        context.coordinator.parent = self
        container.maxTextHeight = maxTextHeight
        container.minFieldHeight = minFieldHeight
        container.measurementWidth = measurementWidth
        container.inlineLayoutWidth = inlineLayoutWidth
        container.stackedLayoutWidth = stackedLayoutWidth
        container.contentInsets = contentInsets
        container.applyContentInsets()
        container.applyStyle(fontSize: fontSize)
        container.setPlaceholder(placeholder)
        container.onActivate = onActivate
        container.onExpandedLayoutChange = onExpandedLayoutChange
        container.onHeightChange = { [self] height in
            handleHeightChange(height)
        }

        container.textView.slashController = slashController

        if !context.coordinator.isUpdating, container.textView.string != text {
            container.textView.string = text
            container.updatePlaceholderVisibility()
        }

        if focus.wrappedValue, !container.isTextViewFocused() {
            SpaceAgentComposerTextContainer.activeComposer = container
            DispatchQueue.main.async {
                guard !container.isTextViewFocused() else { return }
                container.claimFocus(placeCaretAt: nil)
            }
        }

        DispatchQueue.main.async {
            _ = container.recalculateHeight()
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: SpaceAgentComposerTextView
        var isUpdating = false

        init(_ parent: SpaceAgentComposerTextView) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            isUpdating = true
            parent.text = view.string
            isUpdating = false
            parent.slashController.refresh(text: view.string, caret: view.selectedRange().location)
            if let container = (view as? SpaceAgentComposerNSTextView)?.composerContainer {
                container.updatePlaceholderVisibility()
                _ = container.recalculateHeight()
            }
        }

        func textDidBeginEditing(_ notification: Notification) {
            if let view = notification.object as? SpaceAgentComposerNSTextView {
                SpaceAgentComposerTextContainer.activeComposer = view.composerContainer
                view.composerContainer?.isEditing = true
                view.composerContainer?.updatePlaceholderVisibility()
                view.updateInsertionPointStateAndRestartTimer(true)
            }
        }

        func textDidEndEditing(_ notification: Notification) {
            if let view = notification.object as? SpaceAgentComposerNSTextView {
                view.composerContainer?.isEditing = false
                view.composerContainer?.updatePlaceholderVisibility()
            }
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if parent.slashController.isVisible,
               commandSelector == #selector(NSResponder.insertTab(_:)) {
                parent.slashController.applySelected(to: textView)
                return true
            }
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                if NSEvent.modifierFlags.contains(.shift) { return false }
                parent.slashController.dismiss()
                parent.onSubmit()
                return true
            }
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                if parent.slashController.isVisible {
                    parent.slashController.dismiss()
                    return true
                }
            }
            return false
        }
    }
}

// MARK: - Slash completion popover

private struct SpaceAgentSlashPopover: View {
    @ObservedObject var controller: SlashCompletionController
    let onPick: (HermesSlashItem) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if controller.items.isEmpty {
                Text("No matching commands")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white.opacity(0.45))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
            } else {
                ForEach(Array(controller.items.enumerated()), id: \.element.id) { index, item in
                    Button {
                        onPick(item)
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(item.command)
                                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                .foregroundStyle(
                                    item.kind == .skill ? Palette.hermesPurple : .white.opacity(0.92)
                                )
                            Text(item.description)
                                .font(.system(size: 11))
                                .foregroundStyle(.white.opacity(0.5))
                                .lineLimit(1)
                            Spacer(minLength: 0)
                            if item.kind == .skill {
                                Text("skill")
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(.white.opacity(0.35))
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(index == controller.selectedIndex
                                    ? Color.white.opacity(0.12)
                                    : Color.clear)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(width: SpaceAgentChatTokens.compactPanelWidth - 20)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(red: 14 / 255, green: 22 / 255, blue: 38 / 255).opacity(0.96))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(SpaceAgentChatTokens.panelBorder, lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.28), radius: 14, y: 6)
        )
        .onAppear { HermesSlashCatalog.shared.refreshIfNeeded() }
    }
}

// MARK: - Composer

private struct SpaceAgentInlineButton<Label: View>: View {
    let action: () -> Void
    var disabled: Bool = false
    @ViewBuilder let label: () -> Label

    var body: some View {
        Button(action: action) {
            label()
                .frame(width: 36, height: 36)
                .background(
                    Circle()
                        .fill(SpaceAgentChatTokens.panelBgStrong)
                        .overlay(Circle().strokeBorder(SpaceAgentChatTokens.panelBorder, lineWidth: 1))
                )
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.6 : 1)
    }
}

private struct SpaceAgentComposerBar: View {
    @Binding var inputText: String
    var isFocused: FocusState<Bool>.Binding
    let isLoading: Bool
    let canSend: Bool
    let compact: Bool
    var statusText: String? = nil
    let onSend: () -> Void
    var onStop: (() -> Void)? = nil
    let onClose: () -> Void
    var onCollapse: (() -> Void)? = nil
    var onExpand: (() -> Void)? = nil
    var onActivate: (() -> Void)? = nil
    @Binding var composerHeight: CGFloat
    @StateObject private var slashController = SlashCompletionController()
    @State private var composerExpandedLayout = false

    private var isStopMode: Bool { compact && isLoading && inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var maxComposerHeight: CGFloat {
        compact
            ? SpaceAgentChatTokens.composerMaxTextHeightCompact
            : SpaceAgentChatTokens.composerMaxHeightFull
    }

    private var compactBarHeight: CGFloat {
        SpaceAgentChatTokens.compactBarHeight(
            textHeight: composerHeight,
            expanded: composerExpandedLayout
        )
    }

    private var placeholder: String {
        if let status = statusText?.trimmingCharacters(in: .whitespacesAndNewlines), !status.isEmpty {
            return status
        }
        return compact ? "Message…" : "Message Hermes…"
    }

    var body: some View {
        if compact {
            compactBody
        } else {
            fullBody
        }
    }

    private var compactBody: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
                .frame(maxWidth: .infinity)
                .frame(height: compactBarHeight)
                .contentShape(Rectangle())
                .onTapGesture { focusComposer() }

            compactComposerChrome
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .frame(height: compactBarHeight, alignment: .top)
                .padding(.horizontal, SpaceAgentChatTokens.composerHorizontalPadding)
                .padding(.vertical, 8)

            if slashController.isVisible {
                SpaceAgentSlashPopover(controller: slashController, onPick: applySlashItem)
                    .offset(y: -(compactBarHeight + 10))
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .frame(maxWidth: .infinity)
        .onChange(of: composerHeight) { _, _ in
            postCompactBarHeight()
        }
        .onChange(of: composerExpandedLayout) { _, _ in
            DispatchQueue.main.async {
                SpaceAgentComposerTextContainer.activeComposer.map { _ = $0.recalculateHeight() }
            }
        }
        .onChange(of: inputText) { _, text in
            if text.isEmpty {
                composerExpandedLayout = false
            }
        }
        .onAppear {
            postCompactBarHeight()
        }
    }

    private var compactComposerTextView: some View {
        SpaceAgentComposerTextView(
            text: $inputText,
            measuredHeight: $composerHeight,
            slashController: slashController,
            placeholder: placeholder,
            fontSize: 13,
            maxTextHeight: maxComposerHeight,
            minFieldHeight: SpaceAgentChatTokens.composerRowHeightCompact,
            inlineLayoutWidth: SpaceAgentChatTokens.compactInlineTextWidth,
            stackedLayoutWidth: SpaceAgentChatTokens.compactComposerLayoutWidth,
            postsComposerHeightNotification: false,
            onExpandedLayoutChange: { expanded in
                DispatchQueue.main.async {
                    composerExpandedLayout = expanded
                    postCompactBarHeight()
                }
            },
            focus: isFocused,
            onActivate: onActivate,
            onSubmit: { if isStopMode { onStop?() } else { onSend() } }
        )
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture().onEnded { focusComposer() })
    }

    @ViewBuilder
    private var compactComposerChrome: some View {
        if composerExpandedLayout {
            VStack(alignment: .leading, spacing: SpaceAgentChatTokens.composerStackedSpacing) {
                compactComposerTextView
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .frame(height: composerHeight, alignment: .top)
                    .clipped()

                HStack(spacing: 0) {
                    Spacer(minLength: 0)
                    compactActionButtons
                }
                .frame(height: SpaceAgentChatTokens.composerActionRowHeight)
            }
        } else {
            HStack(alignment: .center, spacing: SpaceAgentChatTokens.compactTextButtonSpacing) {
                compactComposerTextView
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(height: SpaceAgentChatTokens.composerRowHeightCompact)
                    .clipped()

                compactActionButtons
            }
        }
    }

    private func postCompactBarHeight() {
        NotificationCenter.default.post(name: .pipComposerHeight, object: compactBarHeight)
    }

    private func focusComposer() {
        onActivate?()
        isFocused.wrappedValue = true
        DispatchQueue.main.async {
            SpaceAgentComposerTextContainer.focusActiveComposer(placeCaretAtEnd: true)
        }
    }

    private func applySlashItem(_ item: HermesSlashItem) {
        guard let container = SpaceAgentComposerTextContainer.activeComposer else { return }
        slashController.apply(item, to: container.textView)
        inputText = container.textView.string
    }

    @ViewBuilder
    private var compactActionButtons: some View {
        HStack(spacing: 6) {
            SpaceAgentInlineButton(
                action: { isStopMode ? onStop?() : onSend() },
                disabled: !isStopMode && !canSend
            ) {
                if isStopMode {
                    RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                        .fill(SpaceAgentChatTokens.danger)
                        .frame(width: 12, height: 12)
                } else {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(canSend ? Palette.hermesPurple : Palette.hermesPurple.opacity(0.28))
                }
            }

            if let onExpand {
                SpaceAgentInlineButton(action: onExpand) {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.55))
                }
            }
        }
    }

    private var fullBody: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if let onCollapse {
                Button(action: onCollapse) {
                    Image(systemName: "arrow.down.right.and.arrow.up.left")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.45))
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
            }

            ZStack(alignment: .bottomLeading) {
                Color.clear
                    .frame(maxWidth: .infinity)
                    .frame(height: composerHeight)
                    .contentShape(Rectangle())
                    .onTapGesture { focusComposer() }

                SpaceAgentComposerTextView(
                    text: $inputText,
                    measuredHeight: $composerHeight,
                    slashController: slashController,
                    placeholder: placeholder,
                    fontSize: 14,
                    maxTextHeight: maxComposerHeight,
                    contentInsets: NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12),
                    focus: isFocused,
                    onActivate: onActivate,
                    onSubmit: onSend
                )
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: composerHeight)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(SpaceAgentChatTokens.inputBg)
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .strokeBorder(SpaceAgentChatTokens.panelBorder, lineWidth: 1)
                        )
                )
                .contentShape(Rectangle())
                .simultaneousGesture(TapGesture().onEnded { focusComposer() })

                if slashController.isVisible {
                    SpaceAgentSlashPopover(controller: slashController, onPick: applySlashItem)
                        .offset(y: -(composerHeight + 14))
                }
            }

            Button(action: onSend) {
                Image(systemName: isLoading ? "hourglass" : "arrow.up.circle.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(canSend ? Palette.hermesPurple : Palette.hermesPurple.opacity(0.28))
            }
            .buttonStyle(.plain)
            .disabled(!canSend)

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white.opacity(0.45))
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(Color.white.opacity(0.08)))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 10)
    }
}

// MARK: - Onscreen chat (Space Agent compact ↔ full)

/// Chat body panel (composer + optional history). Assistant bubble lives on the avatar cluster.
struct SpaceAgentOnscreenChat: View {
    let mode: ChatDisplayMode
    let messages: [ChatBubbleMessage]
    var liveTranscript: String? = nil
    let isLoading: Bool
    var statusText: String? = nil
    var compactAssistantText: String? = nil
    var chatTraceActive: Bool = false
    var uiBubblePhase: SpaceAgentBubblePhase = .visible
    var peekEdge: PeekEdge = .left
    let onSend: (String) -> Void
    var onStop: (() -> Void)? = nil
    let onClose: () -> Void
    let onBubbleTap: () -> Void
    let onCollapse: () -> Void
    var onActivate: (() -> Void)? = nil

    private var showsCompactResponse: Bool {
        guard mode == .compact, uiBubblePhase != .leaving else { return false }
        if let text = compactAssistantText, !text.isEmpty { return true }
        return isLoading
    }

    @State private var inputText = ""
    @State private var composerHeight = SpaceAgentChatTokens.composerRowHeightCompact
    @FocusState private var isFocused: Bool
    @State private var panelExpanded = false
    @State private var fileDropTargeted = false

    var body: some View {
        Group {
            if mode == .compact {
                compactPanel
            } else {
                fullPanel
            }
        }
        .animation(.timingCurve(0.2, 0.9, 0.25, 1, duration: SpaceAgentChatTokens.modeTransition), value: mode)
        .onAppear {
            isFocused = true
            postComposerHeight()
            withAnimation(.timingCurve(0.2, 0.9, 0.25, 1, duration: SpaceAgentChatTokens.modeTransition)) {
                panelExpanded = true
            }
        }
        .onChange(of: mode) { _, newMode in
            composerHeight = newMode == .compact
                ? SpaceAgentChatTokens.composerRowHeightCompact
                : SpaceAgentChatTokens.composerMinHeight
            postComposerHeight()
        }
        .onReceive(NotificationCenter.default.publisher(for: .pipFileDrop)) { note in
            guard let paths = note.object as? [String] else { return }
            acceptDroppedFiles(paths)
        }
    }

    private var compactPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            if showsCompactResponse {
                Group {
                    if isLoading, chatTraceActive, let text = compactAssistantText, !text.isEmpty {
                        SpaceAgentCompactTraceCard(text: text)
                    } else if let text = compactAssistantText, !text.isEmpty {
                        SpaceAgentCompactResponseCard(text: text, onTap: onBubbleTap)
                    } else if isLoading {
                        SpaceAgentCompactResponseLoading()
                    }
                }
                .frame(width: SpaceAgentChatTokens.compactPanelWidth)
            }

            SpaceAgentPanelChrome(compact: true) {
                SpaceAgentComposerBar(
                    inputText: $inputText,
                    isFocused: $isFocused,
                    isLoading: isLoading,
                    canSend: canSend,
                    compact: true,
                    statusText: statusText,
                    onSend: send,
                    onStop: onStop,
                    onClose: onClose,
                    onExpand: onBubbleTap,
                    onActivate: activateComposer,
                    composerHeight: $composerHeight
                )
            }
            .frame(width: SpaceAgentChatTokens.compactPanelWidth)
        }
        .scaleEffect(panelExpanded ? 1 : 0.94)
        .opacity(panelExpanded ? 1 : 0)
        .spaceAgentFileDrop(text: $inputText, isTargeted: $fileDropTargeted, onPathsAppended: afterFilePathsAppended)
    }

    private var fullPanel: some View {
        SpaceAgentPanelChrome {
            VStack(spacing: 0) {
                if !messages.isEmpty {
                    historyList
                    Rectangle()
                        .fill(SpaceAgentChatTokens.panelBorder)
                        .frame(height: 1)
                }
                SpaceAgentComposerBar(
                    inputText: $inputText,
                    isFocused: $isFocused,
                    isLoading: isLoading,
                    canSend: canSend,
                    compact: false,
                    statusText: statusText,
                    onSend: send,
                    onStop: onStop,
                    onClose: onClose,
                    onCollapse: onCollapse,
                    onActivate: activateComposer,
                    composerHeight: $composerHeight
                )
            }
        }
        .frame(width: SpaceAgentChatTokens.panelWidth)
        .scaleEffect(panelExpanded ? 1 : 0.94)
        .opacity(panelExpanded ? 1 : 0)
        .spaceAgentFileDrop(text: $inputText, isTargeted: $fileDropTargeted, onPathsAppended: afterFilePathsAppended)
    }

    private func acceptDroppedFiles(_ paths: [String]) {
        HermesChatClient.shared.adoptWorkspace(paths: paths)
        SpaceAgentFileDrop.append(paths: paths, to: &inputText)
        afterFilePathsAppended()
    }

    private func activateComposer() {
        onActivate?()
        isFocused = true
        DispatchQueue.main.async {
            SpaceAgentComposerTextContainer.focusActiveComposer(placeCaretAtEnd: false)
        }
    }

    private func afterFilePathsAppended() {
        activateComposer()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            SpaceAgentComposerSelection.placeCaretAtEnd()
        }
    }

    private var historyList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: SpaceAgentChatTokens.threadGap) {
                    ForEach(messages) { msg in
                        SpaceAgentMessageRow(message: msg).id(msg.id)
                    }
                    if let liveTranscript, !liveTranscript.isEmpty {
                        SpaceAgentHermesLiveTranscriptRow(text: liveTranscript)
                            .id("live-transcript")
                    } else if isLoading, mode == .full {
                        SpaceAgentHermesLiveTranscriptRow(text: "Initializing agent…")
                            .id("loading")
                    } else if isLoading {
                        SpaceAgentTypingIndicator().id("loading")
                    }
                    Color.clear.frame(height: 4).id("bottom")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
            .frame(minHeight: SpaceAgentChatTokens.historyMinHeight,
                   idealHeight: SpaceAgentChatTokens.historyIdealHeight,
                   maxHeight: SpaceAgentChatTokens.historyMaxHeight)
            .onChange(of: messages.count) { _, _ in
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: liveTranscript) { _, _ in
                withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: isLoading) { _, loading in
                if loading {
                    withAnimation { proxy.scrollTo(mode == .full ? "live-transcript" : "loading", anchor: .bottom) }
                }
            }
        }
    }

    private var canSend: Bool {
        !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isLoading
    }

    private func send() {
        let text = inputText
        guard canSend else { return }
        onSend(text)
        inputText = ""
        composerHeight = mode == .compact
            ? SpaceAgentChatTokens.composerRowHeightCompact
            : SpaceAgentChatTokens.composerMinHeight
        postComposerHeight()
    }

    private func postComposerHeight() {
        let height: CGFloat
        if mode == .compact {
            let expanded = composerHeight > SpaceAgentChatTokens.composerRowHeightCompact + 0.5
            height = SpaceAgentChatTokens.compactBarHeight(textHeight: composerHeight, expanded: expanded)
        } else {
            height = composerHeight
        }
        NotificationCenter.default.post(name: .pipComposerHeight, object: height)
    }
}

// MARK: - Full-thread markdown (code blocks, diffs)

private enum SpaceAgentMarkdownBlock: Equatable {
    case paragraph(String)
    case code(language: String?, content: String)
    case diff(String)
}

private enum SpaceAgentMarkdownParser {
    static func parse(_ text: String) -> [SpaceAgentMarkdownBlock] {
        var blocks: [SpaceAgentMarkdownBlock] = []
        var remainder = text[...]

        while !remainder.isEmpty {
            if let fence = remainder.range(of: "```") {
                let before = String(remainder[..<fence.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !before.isEmpty {
                    appendParagraphs(before, to: &blocks)
                }
                remainder = remainder[fence.upperBound...]
                let lineBreak = remainder.firstIndex(of: "\n")
                let header = lineBreak.map { String(remainder[..<$0]) } ?? String(remainder)
                let language = header.trimmingCharacters(in: .whitespaces).lowercased()
                let lang = language.isEmpty ? nil : language
                if let lineBreak {
                    remainder = remainder[remainder.index(after: lineBreak)...]
                } else {
                    remainder = ""
                }
                if let end = remainder.range(of: "```") {
                    let body = String(remainder[..<end.lowerBound]).trimmingCharacters(in: .newlines)
                    if lang == "diff" || looksLikeDiff(body) {
                        blocks.append(.diff(body))
                    } else {
                        blocks.append(.code(language: lang, content: body))
                    }
                    remainder = remainder[end.upperBound...]
                } else {
                    let body = String(remainder).trimmingCharacters(in: .newlines)
                    if lang == "diff" || looksLikeDiff(body) {
                        blocks.append(.diff(body))
                    } else {
                        blocks.append(.code(language: lang, content: body))
                    }
                    remainder = ""
                }
            } else {
                appendParagraphs(String(remainder).trimmingCharacters(in: .whitespacesAndNewlines), to: &blocks)
                remainder = ""
            }
        }
        return blocks
    }

    private static func appendParagraphs(_ text: String, to blocks: inout [SpaceAgentMarkdownBlock]) {
        guard !text.isEmpty else { return }
        let parts = text.components(separatedBy: "\n\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        for part in parts where !part.isEmpty {
            if looksLikeDiff(part) {
                blocks.append(.diff(part))
            } else {
                blocks.append(.paragraph(part))
            }
        }
    }

    private static func looksLikeDiff(_ text: String) -> Bool {
        if text.contains("diff --git") { return true }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count >= 2 else { return false }
        var hits = 0
        for line in lines {
            let raw = String(line)
            let t = raw.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("- ") || t.hasPrefix("* ") || t.hasPrefix("• ") { continue }
            if t.hasPrefix("diff --git") || t.hasPrefix("+++") || t.hasPrefix("@@") {
                hits += 2
                continue
            }
            if t.hasPrefix("---"), t.count > 3 {
                let after = t.dropFirst(3)
                if after.first == " " || after.first == "/" {
                    hits += 1
                    continue
                }
            }
            if raw.hasPrefix("+") && !t.hasPrefix("+++") { hits += 1 }
            else if raw.hasPrefix("-") { hits += 1 }
        }
        return hits >= 2
    }
}

private struct SpaceAgentHermesReplyBody: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .prose(let copy):
                    Text(copy)
                        .font(.system(size: 14, design: .rounded))
                        .foregroundStyle(SpaceAgentHermesTheme.prose)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                case .code(let language, let content):
                    SpaceAgentCodeBlockView(language: language, content: content)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private enum Block: Equatable {
        case prose(String)
        case code(language: String?, content: String)
    }

    private var blocks: [Block] {
        var result: [Block] = []
        var remainder = text[...]
        while !remainder.isEmpty {
            if let fence = remainder.range(of: "```") {
                let before = String(remainder[..<fence.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !before.isEmpty { result.append(.prose(before)) }
                remainder = remainder[fence.upperBound...]
                let lineBreak = remainder.firstIndex(of: "\n")
                let header = lineBreak.map { String(remainder[..<$0]) } ?? String(remainder)
                let language = header.trimmingCharacters(in: .whitespaces)
                let lang = language.isEmpty ? nil : language
                if let lineBreak {
                    remainder = remainder[remainder.index(after: lineBreak)...]
                } else {
                    remainder = ""
                }
                if let end = remainder.range(of: "```") {
                    let body = String(remainder[..<end.lowerBound]).trimmingCharacters(in: .newlines)
                    result.append(.code(language: lang, content: body))
                    remainder = remainder[end.upperBound...]
                } else {
                    result.append(.code(language: lang, content: String(remainder).trimmingCharacters(in: .newlines)))
                    remainder = ""
                }
            } else {
                let tail = String(remainder).trimmingCharacters(in: .whitespacesAndNewlines)
                if !tail.isEmpty { result.append(.prose(tail)) }
                remainder = ""
            }
        }
        return result
    }
}

private enum SpaceAgentHermesTheme {
    static let prose = Color.white.opacity(0.9)
    static let diffAdd = Color(red: 0.62, green: 0.88, blue: 0.72)
    static let diffRemove = Color(red: 0.82, green: 0.78, blue: 0.88)
    static let diffAddBg = Color(red: 0.35, green: 0.72, blue: 0.48).opacity(0.12)
    static let diffRemoveBg = Palette.hermesPurple.opacity(0.14)
    static let diffMeta = Color.white.opacity(0.5)
}

private struct SpaceAgentAssistantMessageBody: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .paragraph(let copy):
                    Text(copy)
                        .font(.system(size: 14, design: .rounded))
                        .foregroundStyle(.white.opacity(0.92))
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                case .code(let language, let content):
                    SpaceAgentCodeBlockView(language: language, content: content)
                case .diff(let content):
                    SpaceAgentDiffBlockView(content: content)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var blocks: [SpaceAgentMarkdownBlock] {
        SpaceAgentMarkdownParser.parse(text)
    }
}

private struct SpaceAgentCodeBlockView: View {
    let language: String?
    let content: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let language, !language.isEmpty {
                Text(language.uppercased())
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.45))
            }
            ScrollView(.horizontal, showsIndicators: false) {
                Text(content)
                    .font(.system(size: SpaceAgentChatTokens.codeBlockFontSize, design: .monospaced))
                    .foregroundStyle(Color(red: 0.82, green: 0.9, blue: 0.98))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: true)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: SpaceAgentChatTokens.codeBlockRadius, style: .continuous)
                .fill(Color.black.opacity(0.38))
                .overlay(
                    RoundedRectangle(cornerRadius: SpaceAgentChatTokens.codeBlockRadius, style: .continuous)
                        .strokeBorder(SpaceAgentChatTokens.panelBorder, lineWidth: 1)
                )
        )
    }
}

private struct SpaceAgentDiffBlockView: View {
    let content: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Text(line.text)
                    .font(.system(size: SpaceAgentChatTokens.codeBlockFontSize, design: .monospaced))
                    .foregroundStyle(line.color)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 1)
                    .background(line.background)
            }
        }
        .textSelection(.enabled)
        .clipShape(RoundedRectangle(cornerRadius: SpaceAgentChatTokens.codeBlockRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: SpaceAgentChatTokens.codeBlockRadius, style: .continuous)
                .strokeBorder(SpaceAgentChatTokens.panelBorder, lineWidth: 1)
        )
    }

    private struct DiffLine {
        let text: String
        let color: Color
        let background: Color
    }

    private var lines: [DiffLine] {
        content.components(separatedBy: "\n").map { raw in
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("+++") || trimmed.hasPrefix("---") || trimmed.hasPrefix("@@") {
                return DiffLine(text: raw, color: SpaceAgentHermesTheme.diffMeta, background: Color.white.opacity(0.04))
            }
            if raw.hasPrefix("+") {
                return DiffLine(text: raw, color: SpaceAgentHermesTheme.diffAdd, background: SpaceAgentHermesTheme.diffAddBg)
            }
            if raw.hasPrefix("-") {
                return DiffLine(text: raw, color: SpaceAgentHermesTheme.diffRemove, background: SpaceAgentHermesTheme.diffRemoveBg)
            }
            return DiffLine(text: raw, color: SpaceAgentHermesTheme.diffMeta, background: Color.black.opacity(0.28))
        }
    }
}

private struct SpaceAgentHermesTranscriptView: View {
    let text: String
    var live = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if blocks.isEmpty {
                Text(text.isEmpty ? "Initializing agent…" : text)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.55))
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                    SpaceAgentHermesTranscriptBlockView(
                        block: block,
                        showActivity: live && index == blocks.count - 1
                    )
                }
            }
        }
        .textSelection(.enabled)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: SpaceAgentChatTokens.codeBlockRadius, style: .continuous)
                .fill(Color.black.opacity(live ? 0.4 : 0.32))
                .overlay(
                    RoundedRectangle(cornerRadius: SpaceAgentChatTokens.codeBlockRadius, style: .continuous)
                        .strokeBorder(
                            live ? Palette.hermesPurple.opacity(0.35) : SpaceAgentChatTokens.panelBorder,
                            lineWidth: 1
                        )
                )
        )
    }

    private var blocks: [HermesTranscriptBlock] {
        HermesTranscriptParser.parse(text)
    }
}

private struct SpaceAgentHermesTranscriptBlockView: View {
    let block: HermesTranscriptBlock
    var showActivity = false

    var body: some View {
        switch block {
        case .status(let text):
            HStack(spacing: 6) {
                if showActivity {
                    ProgressView()
                        .controlSize(.small)
                        .tint(Palette.hermesPurple.opacity(0.8))
                }
                Text(text)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.5))
            }

        case .toolTrace(let text):
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: toolIcon(for: text))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Palette.hermesPurple.opacity(0.9))
                    .frame(width: 14)
                Text(text)
                    .font(.system(size: SpaceAgentChatTokens.codeBlockFontSize, design: .monospaced))
                    .foregroundStyle(Palette.hermesPurple.opacity(0.88))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Palette.hermesPurple.opacity(0.1))
            )

        case .reply(let text):
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 5) {
                    HermesSparkCompact().frame(width: 12, height: 12)
                    Text("HERMES")
                        .font(.system(size: 9, weight: .heavy, design: .rounded))
                        .tracking(1.1)
                        .foregroundStyle(Palette.hermesPurple)
                }
                SpaceAgentHermesReplyBody(text: text)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.white.opacity(0.05))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(SpaceAgentChatTokens.panelBorder, lineWidth: 1)
                    )
            )

        case .sessionMeta(let session, let duration, let messages):
            HStack(spacing: 6) {
                Text(shortSessionID(session))
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.42))
                if let duration {
                    Text("·").foregroundStyle(.white.opacity(0.22))
                    Text(duration)
                }
                if let messages {
                    Text("·").foregroundStyle(.white.opacity(0.22))
                    Text(messages)
                }
            }
            .font(.system(size: 10, weight: .medium, design: .rounded))
            .foregroundStyle(.white.opacity(0.38))
            .padding(.top, 2)
        }
    }

    private func shortSessionID(_ session: String) -> String {
        guard session.count > 14 else { return session }
        return String(session.suffix(12))
    }

    private func toolIcon(for text: String) -> String {
        let lower = text.lowercased()
        if lower.contains("search") || lower.contains("find") || lower.contains("🔎") { return "magnifyingglass" }
        if lower.contains("diff") || lower.contains("review") { return "doc.text.magnifyingglass" }
        if lower.contains("$") || lower.contains("terminal") || lower.contains("💻") { return "terminal" }
        if lower.contains("write") || lower.contains("edit") { return "pencil" }
        return "gearshape.2"
    }
}

private struct SpaceAgentHermesLiveTranscriptRow: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: SpaceAgentChatTokens.bubbleGap) {
            SpaceAgentHelmetAvatar()
            SpaceAgentHermesTranscriptView(text: text, live: true)
            Spacer(minLength: 0)
        }
    }
}

private struct SpaceAgentMessageRow: View {
    let message: ChatBubbleMessage

    var body: some View {
        HStack(alignment: .top, spacing: SpaceAgentChatTokens.bubbleGap) {
            if message.isUser {
                Spacer(minLength: 40)
                Text(message.text)
                    .font(.system(size: 14, design: .rounded))
                    .foregroundStyle(.white.opacity(0.95))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: SpaceAgentChatTokens.userBubbleRadius, style: .continuous)
                            .fill(SpaceAgentChatTokens.userBubbleBg)
                    )
                    .frame(maxWidth: 280, alignment: .trailing)
            } else if message.isHermesTranscript {
                SpaceAgentHelmetAvatar()
                SpaceAgentHermesTranscriptView(text: message.text)
                Spacer(minLength: 0)
            } else {
                SpaceAgentHelmetAvatar()
                SpaceAgentAssistantMessageBody(text: message.text)
                Spacer(minLength: 8)
            }
        }
        .spaceAgentBubbleLand(token: message.id.uuidString)
    }
}

private struct SpaceAgentTypingIndicator: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 0.12)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            HStack(spacing: 5) {
                SpaceAgentHelmetAvatar()
                HStack(spacing: 4) {
                    ForEach(0..<3, id: \.self) { i in
                        let pulse = sin(t * 5 + Double(i) * 0.9) * 0.5 + 0.5
                        Circle()
                            .fill(Palette.hermesPurple.opacity(0.35 + 0.45 * pulse))
                            .frame(width: 6, height: 6)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                Spacer()
            }
        }
    }
}

typealias InlineChatView = SpaceAgentOnscreenChat
