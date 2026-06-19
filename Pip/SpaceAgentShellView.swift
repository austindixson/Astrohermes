import SwiftUI
import AppKit
import ImageIO

// Port of space-agent onscreen_agent/panel.html + onscreen-agent.css + store.js
// https://github.com/agent0ai/space-agent

enum SpaceAgentAssets {
    static func nsImage(named name: String) -> NSImage? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "webp"),
              let data = try? Data(contentsOf: url),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cg = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        return NSImage(cgImage: cg, size: .zero)
    }

    static func image(named name: String) -> Image? {
        guard let ns = nsImage(named: name) else { return nil }
        return Image(nsImage: ns)
    }

    static var avatar: Image? { image(named: "astronaut_no_bg") }
    static var helmet: Image? { image(named: "helmet_no_bg_256") }
}

// MARK: - Handler bridge

protocol OnscreenAgentHandling: AnyObject {
    func onscreenSend(_ text: String)
    func onscreenStopChat()
    func onscreenCloseChat()
    func onscreenExpandChat()
    func onscreenCollapseChat()
    func onscreenComposerActivated()
    func onscreenAvatarHover(_ hovering: Bool)
    func onscreenAvatarDragBegan()
    func onscreenAvatarDragChanged(translation: CGSize)
    func onscreenAvatarDragEnded()
}

// MARK: - Layout tokens (onscreen-agent.css)

private enum SpaceAgentBubbleLayout {
    static let tailOverhang: CGFloat = 4
    static let offsetAbove: CGFloat = 50
    static let offsetBelow: CGFloat = 50
    static let anchorY: CGFloat = 25
    static let sideGap: CGFloat = 10
    /// Extra window height above the 72px cluster for multi-line bubbles.
    static let headroom: CGFloat = 130
    /// CSS: bottom = avatar + tail-overhang + offset-above − anchor-y
    static var aboveBottom: CGFloat {
        SpaceAgentChatTokens.avatarSize + tailOverhang + offsetAbove - anchorY
    }
}

// MARK: - Avatar float (onscreen-agent-avatar-float @ 8.4s linear)

private enum SpaceAgentAvatarFloat {
    private struct Keyframe {
        let t: CGFloat
        let x: CGFloat
        let y: CGFloat
        let degrees: CGFloat
    }

    private static let frames: [Keyframe] = [
        .init(t: 0.00, x: 0, y: 0, degrees: -6),
        .init(t: 0.25, x: 5, y: -5, degrees: -2),
        .init(t: 0.50, x: 0, y: -8, degrees: 5),
        .init(t: 0.75, x: -5, y: -4, degrees: 1),
        .init(t: 1.00, x: 0, y: 0, degrees: -6),
    ]

    static func sample(at elapsed: TimeInterval) -> (offset: CGSize, rotation: Angle) {
        let phase = CGFloat(elapsed / 8.4).truncatingRemainder(dividingBy: 1)
        let idx = frames.lastIndex(where: { $0.t <= phase }) ?? 0
        let a = frames[idx]
        let b = frames[min(idx + 1, frames.count - 1)]
        let span = max(0.0001, b.t - a.t)
        let u = (phase - a.t) / span
        let x = a.x + (b.x - a.x) * u
        let y = a.y + (b.y - a.y) * u
        let deg = a.degrees + (b.degrees - a.degrees) * u
        return (CGSize(width: x, height: y), .degrees(deg))
    }
}

struct SpaceAgentHelmetAvatar: View {
    var size: CGFloat = 34

    var body: some View {
        Group {
            if let helmet = SpaceAgentAssets.helmet {
                helmet.resizable().scaledToFit()
            } else {
                Image(systemName: "helm")
                    .font(.system(size: size * 0.55))
                    .foregroundStyle(.white.opacity(0.7))
            }
        }
        .frame(width: size, height: size)
    }
}

struct SpaceAgentAvatarView: View {
    let dockedRight: Bool
    let edgeHidden: Bool
    let hiddenEdge: PeekEdge
    var onHover: ((Bool) -> Void)?
    var onDragBegan: (() -> Void)?
    var onDragChanged: ((CGSize) -> Void)?
    var onDragEnded: (() -> Void)?

    @State private var dragActive = false

    var body: some View {
        TimelineView(.animation) { timeline in
            let elapsed = timeline.date.timeIntervalSinceReferenceDate
            let motion = edgeHidden ? (offset: CGSize.zero, rotation: edgeRotation) : {
                let f = SpaceAgentAvatarFloat.sample(at: elapsed)
                return (offset: f.offset, rotation: f.rotation + edgeRotation)
            }()

            Group {
                if let avatar = SpaceAgentAssets.avatar {
                    avatar.resizable().scaledToFit()
                } else {
                    Image(systemName: "figure.stand")
                        .font(.system(size: 40))
                        .foregroundStyle(.white.opacity(0.5))
                }
            }
            .scaleEffect(x: dockedRight ? -1 : 1, y: 1)
            .rotationEffect(motion.rotation)
            .offset(motion.offset)
        }
        .frame(width: SpaceAgentChatTokens.avatarSize, height: SpaceAgentChatTokens.avatarSize)
        .contentShape(Rectangle())
        .onHover { onHover?($0) }
        .gesture(avatarDragGesture)
    }

    private var edgeRotation: Angle {
        guard edgeHidden else { return .zero }
        switch hiddenEdge {
        case .left: return .degrees(90)
        case .right: return .degrees(-90)
        case .top: return .degrees(180)
        case .bottom: return .zero
        }
    }

    private var avatarDragGesture: some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                if !dragActive {
                    dragActive = true
                    onDragBegan?()
                }
                onDragChanged?(value.translation)
            }
            .onEnded { _ in
                dragActive = false
                onDragEnded?()
            }
    }
}

/// Window dimensions for the onscreen Space Agent shell.
enum SpaceAgentLayout {
    static let compactStackGap: CGFloat = 8

    static let responseHeightBuffer: CGFloat = 24

    static func estimatedResponseHeight(text: String) -> CGFloat {
        let width = SpaceAgentChatTokens.compactPanelWidth
        let lineHeight = SpaceAgentChatTokens.bubbleFontSize * SpaceAgentChatTokens.bubbleLineHeight
        let usable = max(120, width - SpaceAgentChatTokens.bubblePaddingH * 2)
        let charsPerLine = max(16, Int(usable / (SpaceAgentChatTokens.bubbleFontSize * 0.52)))
        let wrappedLines = max(1, Int(ceil(Double(text.count) / Double(charsPerLine))))
        let explicitLines = max(1, text.components(separatedBy: "\n").count)
        let lines = max(wrappedLines, explicitLines)
        return SpaceAgentChatTokens.bubblePaddingV * 2
            + CGFloat(lines) * lineHeight
            + responseHeightBuffer
    }

    static let traceBubbleHeight: CGFloat = 48

    static func composerPanelHeight(textHeight: CGFloat) -> CGFloat {
        max(SpaceAgentChatTokens.compactPanelHeight, textHeight + SpaceAgentChatTokens.composerChromePadding)
    }

    static func compactStackHeight(
        assistantText: String?,
        isLoading: Bool,
        chatTraceActive: Bool = false,
        composerTextHeight: CGFloat = SpaceAgentChatTokens.composerMinHeight,
        uiBubblePhase: SpaceAgentBubblePhase
    ) -> CGFloat {
        let showsResponse = uiBubblePhase != .leaving
            && ((assistantText?.isEmpty == false) || isLoading)
        let panelH = composerPanelHeight(textHeight: composerTextHeight)
        guard showsResponse else { return panelH }
        let bubbleH: CGFloat
        if isLoading, chatTraceActive {
            bubbleH = traceBubbleHeight
        } else if let text = assistantText, !text.isEmpty {
            bubbleH = estimatedResponseHeight(text: text)
        } else {
            bubbleH = 52 + responseHeightBuffer * 0.5
        }
        return bubbleH + compactStackGap + panelH
    }

    static func windowSize(
        chatOpen: Bool,
        mode: ChatDisplayMode,
        compactAssistantText: String? = nil,
        compactLoading: Bool = false,
        chatTraceActive: Bool = false,
        composerTextHeight: CGFloat = SpaceAgentChatTokens.composerMinHeight,
        uiBubblePhase: SpaceAgentBubblePhase = .visible
    ) -> NSSize {
        if !chatOpen {
            return NSSize(width: 120, height: 150)
        }
        if mode == .compact {
            let stackH = compactStackHeight(
                assistantText: compactAssistantText,
                isLoading: compactLoading,
                chatTraceActive: chatTraceActive,
                composerTextHeight: composerTextHeight,
                uiBubblePhase: uiBubblePhase
            )
            let w = SpaceAgentChatTokens.shellPadding * 2
                + SpaceAgentChatTokens.avatarSize
                + SpaceAgentChatTokens.clusterGap
                + SpaceAgentChatTokens.compactPanelWidth
            let h = SpaceAgentChatTokens.shellPadding * 2
                + max(SpaceAgentChatTokens.avatarSize, stackH)
            return NSSize(width: w, height: h)
        }
        let w = SpaceAgentChatTokens.shellPadding * 2
            + SpaceAgentChatTokens.avatarSize
            + SpaceAgentChatTokens.clusterGap
            + SpaceAgentChatTokens.panelWidth
        let h = SpaceAgentChatTokens.shellPadding * 2
            + SpaceAgentChatTokens.historyIdealHeight
            + 64
            + SpaceAgentChatTokens.avatarSize
        return NSSize(width: w, height: h)
    }
}

/// Root onscreen shell: avatar cluster + chat body panel (Space Agent layout).
struct SpaceAgentShellView: View {
    var model: PoseModel
    var handler: OnscreenAgentHandling?

    @State private var panelVisible = false

    var body: some View {
        let pose = model.pose
        let dockedRight = pose.peekEdge == .right
        let edgeHidden = pose.hiddenEdge != nil
        let showsMoodBubble = shouldShowMoodBubble(pose: pose, edgeHidden: edgeHidden)

        horizontalShell(
            pose: pose,
            dockedRight: dockedRight,
            edgeHidden: edgeHidden,
            showsMoodBubble: showsMoodBubble
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: dockedRight ? .bottomTrailing : .bottomLeading)
        .padding(SpaceAgentChatTokens.shellPadding)
        .opacity(edgeHidden ? 0.72 : 1)
        .onAppear {
            withAnimation(.timingCurve(0.2, 0.9, 0.25, 1, duration: SpaceAgentChatTokens.modeTransition)) {
                panelVisible = true
            }
        }
    }

    /// Space-agent CSS: 72×72 cluster, bubble absolute above-right, panel beside avatar (bottom-aligned).
    private func horizontalShell(
        pose: Pose,
        dockedRight: Bool,
        edgeHidden: Bool,
        showsMoodBubble: Bool
    ) -> some View {
        HStack(alignment: .bottom, spacing: SpaceAgentChatTokens.clusterGap) {
            if dockedRight {
                if pose.chatOpen, !edgeHidden { chatBody(pose: pose) }
                agentCluster(pose: pose, dockedRight: dockedRight, edgeHidden: edgeHidden, showsMoodBubble: showsMoodBubble)
            } else {
                agentCluster(pose: pose, dockedRight: dockedRight, edgeHidden: edgeHidden, showsMoodBubble: showsMoodBubble)
                if pose.chatOpen, !edgeHidden { chatBody(pose: pose) }
            }
        }
    }

    /// Mood / usage bubbles only — compact assistant replies live above the composer.
    private func shouldShowMoodBubble(pose: Pose, edgeHidden: Bool) -> Bool {
        guard !edgeHidden, !pose.chatOpen else { return false }
        return pose.bubbleText != nil || pose.showBadge
    }

    @ViewBuilder
    private func agentCluster(pose: Pose, dockedRight: Bool, edgeHidden: Bool, showsMoodBubble: Bool) -> some View {
        ZStack(alignment: .bottomLeading) {
            SpaceAgentAvatarView(
                dockedRight: dockedRight,
                edgeHidden: edgeHidden,
                hiddenEdge: pose.peekEdge,
                onHover: { handler?.onscreenAvatarHover($0) },
                onDragBegan: { handler?.onscreenAvatarDragBegan() },
                onDragChanged: { handler?.onscreenAvatarDragChanged(translation: $0) },
                onDragEnded: { handler?.onscreenAvatarDragEnded() }
            )

            if showsMoodBubble, !edgeHidden {
                moodBubbles(pose: pose, dockedRight: dockedRight)
                    .offset(bubbleOffset(dockedRight: dockedRight, belowHead: pose.chatBubbleBelowHead))
            }
        }
        .frame(width: SpaceAgentChatTokens.avatarSize, height: SpaceAgentChatTokens.avatarSize, alignment: .bottomLeading)
    }

    /// CSS: is-right { left: 100% + 10px }, is-above { bottom: avatar + tail + offset − anchor }.
    private func bubbleOffset(dockedRight: Bool, belowHead: Bool) -> CGSize {
        let bubbleOnLeft = dockedRight
        let x = bubbleOnLeft
            ? -(SpaceAgentChatTokens.avatarSize + SpaceAgentBubbleLayout.sideGap)
            : (SpaceAgentChatTokens.avatarSize + SpaceAgentBubbleLayout.sideGap)

        let y: CGFloat
        if belowHead {
            y = SpaceAgentChatTokens.avatarSize
                + SpaceAgentBubbleLayout.tailOverhang
                + SpaceAgentBubbleLayout.offsetBelow
                - SpaceAgentBubbleLayout.anchorY
        } else {
            y = -SpaceAgentBubbleLayout.aboveBottom
        }
        return CGSize(width: x, height: y)
    }

    @ViewBuilder
    private func moodBubbles(pose: Pose, dockedRight: Bool) -> some View {
        let belowHead = pose.chatBubbleBelowHead
        let peek: PeekEdge = dockedRight ? .right : .left

        if let text = pose.bubbleText, !pose.showBadge {
            SpaceAgentSpeechBubbleView(text: text, peekEdge: peek, belowHead: belowHead)
        } else if pose.showBadge {
            SpaceAgentUsageBadgeView(stats: pose.badgeStats, note: pose.badgeNote, peekEdge: peek)
        }
    }

    private func chatBody(pose: Pose) -> some View {
        SpaceAgentOnscreenChat(
            mode: pose.chatDisplayMode,
            messages: pose.chatMessages,
            liveTranscript: pose.chatLiveTranscript,
            isLoading: pose.chatLoading,
            statusText: pose.chatStatusText,
            compactAssistantText: pose.compactAssistantText,
            chatTraceActive: pose.chatTraceActive,
            uiBubblePhase: pose.uiBubblePhase,
            onSend: { handler?.onscreenSend($0) },
            onStop: { handler?.onscreenStopChat() },
            onClose: { handler?.onscreenCloseChat() },
            onBubbleTap: { handler?.onscreenExpandChat() },
            onCollapse: { handler?.onscreenCollapseChat() },
            onActivate: { handler?.onscreenComposerActivated() }
        )
        .scaleEffect(panelVisible ? 1 : 0.968)
        .opacity(panelVisible ? 1 : 0.88)
        .offset(y: panelVisible ? 0 : (pose.chatDisplayMode == .compact ? 6 : 12))
    }
}