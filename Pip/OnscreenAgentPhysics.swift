import AppKit
import CoreGraphics

// Ported from space-agent onscreen_agent/store.js + config.js
// https://github.com/agent0ai/space-agent

enum OnscreenAgentHiddenEdge: String, Equatable {
    case left, right, top, bottom
}

/// Space Agent shell positioning, edge-hide physics, and animated moves.
final class OnscreenAgentPhysics {

    static let positionMargin: CGFloat = 16
    static let dragClickThreshold: CGFloat = 6
    static let hiddenEdgeVisibleRatio: CGFloat = 0.6
    static let hiddenEdgeRevealThresholdRatio: CGFloat = 0.17
    static let hiddenEdgeRevealThresholdMin: CGFloat = 8
    static let hiddenEdgeSnapDeadZoneMin: CGFloat = 4
    static let sideShiftDuration: TimeInterval = 0.28
    static let avatarSize: CGFloat = 72

    /// Agent shell top-left in viewport coordinates (CSS-style: y increases downward).
    private(set) var agentX: CGFloat = 0
    private(set) var agentY: CGFloat = 0
    private(set) var hiddenEdge: OnscreenAgentHiddenEdge?
    private(set) var isDragging = false

    var windowSize = NSSize(width: 360, height: 88)
    var moveWindow: ((NSPoint) -> Void)?
    var visibleFrameProvider: (() -> NSRect)?

    private var dragOriginX: CGFloat = 0
    private var dragOriginY: CGFloat = 0
    private var dragStartMouse = NSPoint.zero
    private var dragMoved = false

  // Position animation (side-shift ease)
    private var animFrom = NSPoint.zero
    private var animTo = NSPoint.zero
    private var animStartTime: TimeInterval = 0
    private var animating = false

    // MARK: - Viewport

    private func viewportSize(in visible: NSRect) -> CGSize {
        CGSize(width: visible.width, height: visible.height)
    }

    private func hiddenVisibleInset() -> CGFloat {
        max(1, round(Self.avatarSize * Self.hiddenEdgeVisibleRatio))
    }

    private func hiddenHiddenOffset() -> CGFloat {
        max(1, round(Self.avatarSize * (1 - Self.hiddenEdgeVisibleRatio)))
    }

    private func revealThreshold() -> CGFloat {
        max(Self.hiddenEdgeRevealThresholdMin, round(Self.avatarSize * Self.hiddenEdgeRevealThresholdRatio))
    }

    private func snapDeadZone() -> CGFloat {
        max(Self.hiddenEdgeSnapDeadZoneMin, revealThreshold())
    }

    // MARK: - Coordinate conversion

    /// Window origin (AppKit) from agent top-left (CSS viewport coords).
    func windowOrigin(agentX: CGFloat, agentY: CGFloat, in visible: NSRect) -> NSPoint {
        NSPoint(
            x: visible.minX + agentX,
            y: visible.maxY - agentY - windowSize.height
        )
    }

    func agentPosition(from windowOrigin: NSPoint, in visible: NSRect) -> (x: CGFloat, y: CGFloat) {
        (
            x: windowOrigin.x - visible.minX,
            y: visible.maxY - windowOrigin.y - windowSize.height
        )
    }

    func windowOrigin(in visible: NSRect) -> NSPoint {
        windowOrigin(agentX: agentX, agentY: agentY, in: visible)
    }

    // MARK: - Placement

    func placeInitial(in visible: NSRect) {
        let vp = viewportSize(in: visible)
        let gap: CGFloat = 12
        let panelW = SpaceAgentChatTokens.compactPanelWidth
        let overlayW = Self.avatarSize + gap + panelW
        let rootFont: CGFloat = 16
        let sevenEmAboveBottom = vp.height - rootFont * 7
        let ninetyPercentBottom = vp.height * 0.9
        let targetBottom = max(Self.positionMargin, max(sevenEmAboveBottom, ninetyPercentBottom))
        let x = (vp.width - overlayW) / 2
        let y = targetBottom - Self.avatarSize
        setPosition(x: x, y: y, hiddenEdge: nil, animate: false, in: visible)
    }

    func defaultPosition(in visible: NSRect) -> (x: CGFloat, y: CGFloat) {
        let vp = viewportSize(in: visible)
        return (
            x: 40,
            y: max(Self.positionMargin, vp.height - 132)
        )
    }

    // MARK: - Clamp & edge detection (store.js)

    func clampPosition(x: CGFloat, y: CGFloat, hiddenEdge: OnscreenAgentHiddenEdge?, in visible: NSRect) -> (x: CGFloat, y: CGFloat) {
        let vp = viewportSize(in: visible)
        let nx = round(x)
        let ny = round(y)
        let inset = hiddenVisibleInset()
        let offset = hiddenHiddenOffset()
        let maxX = max(Self.positionMargin, vp.width - Self.avatarSize - Self.positionMargin)
        let maxY = max(Self.positionMargin, vp.height - Self.avatarSize - Self.positionMargin)
        let clampX = { (v: CGFloat) in min(maxX, max(Self.positionMargin, v)) }
        let clampY = { (v: CGFloat) in min(maxY, max(Self.positionMargin, v)) }

        switch hiddenEdge {
        case .left:
            return (x: -offset, y: clampY(ny))
        case .right:
            return (x: vp.width - inset, y: clampY(ny))
        case .top:
            return (x: clampX(nx), y: -offset)
        case .bottom:
            return (x: clampX(nx), y: vp.height - inset)
        case nil:
            return (x: clampX(nx), y: clampY(ny))
        }
    }

    private func hiddenEdgeOverflow(x: CGFloat, y: CGFloat, in visible: NSRect) -> [OnscreenAgentHiddenEdge: CGFloat] {
        let vp = viewportSize(in: visible)
        let nx = round(x)
        let ny = round(y)
        let size = Self.avatarSize
        return [
            .left: max(0, -nx),
            .right: max(0, nx + size - vp.width),
            .bottom: max(0, ny + size - vp.height)
        ]
    }

    func hiddenEdgeForPosition(x: CGFloat, y: CGFloat, current: OnscreenAgentHiddenEdge?, in visible: NSRect) -> OnscreenAgentHiddenEdge? {
        let vp = viewportSize(in: visible)
        let nx = round(x)
        let ny = round(y)
        let threshold = revealThreshold()
        let size = Self.avatarSize

        if let current {
            let revealed: Bool
            switch current {
            case .left: revealed = nx >= threshold
            case .right: revealed = nx <= vp.width - size - threshold
            case .top: revealed = ny >= threshold
            case .bottom: revealed = ny <= vp.height - size - threshold
            }
            if revealed { return nil }

            let overflow = hiddenEdgeOverflow(x: nx, y: ny, in: visible)
            if let next = overflow.max(by: { $0.value < $1.value }), next.value > 0 {
                return next.key
            }
            return current
        }

        let overflow = hiddenEdgeOverflow(x: nx, y: ny, in: visible)
        guard let worst = overflow.max(by: { $0.value < $1.value }), worst.value > snapDeadZone() else {
            return nil
        }
        return worst.key
    }

    func revealedPosition(for edge: OnscreenAgentHiddenEdge, in visible: NSRect) -> (x: CGFloat, y: CGFloat) {
        let vp = viewportSize(in: visible)
        let fallback = defaultPosition(in: visible)
        var x = agentX.isFinite ? agentX : fallback.x
        var y = agentY.isFinite ? agentY : fallback.y
        let threshold = revealThreshold()
        let size = Self.avatarSize

        switch edge {
        case .left: x = threshold
        case .right: x = vp.width - size - threshold
        case .top: y = threshold
        case .bottom: y = vp.height - size - threshold
        }
        return clampPosition(x: x, y: y, hiddenEdge: nil, in: visible)
    }

    // MARK: - Set position

    @discardableResult
    func setPosition(
        x: CGFloat,
        y: CGFloat,
        hiddenEdge: OnscreenAgentHiddenEdge?,
        animate: Bool,
        in visible: NSRect
    ) -> Bool {
        let clamped = clampPosition(x: x, y: y, hiddenEdge: hiddenEdge, in: visible)
        let target = windowOrigin(agentX: clamped.x, agentY: clamped.y, in: visible)

        if animate, !isDragging {
            animFrom = windowOrigin(in: visible)
            animTo = target
            animStartTime = CACurrentMediaTime()
            animating = true
        } else {
            animating = false
            applyAgent(clamped.x, clamped.y, hiddenEdge: hiddenEdge)
            moveWindow?(target)
        }
        return true
    }

    private func applyAgent(_ x: CGFloat, _ y: CGFloat, hiddenEdge: OnscreenAgentHiddenEdge?) {
        agentX = x
        agentY = y
        self.hiddenEdge = hiddenEdge
    }

    func tick(dt: TimeInterval, now: TimeInterval) {
        guard let visible = visibleFrameProvider?(), visible.width > 10 else { return }

        if animating, !isDragging {
            let elapsed = now - animStartTime
            let t = min(1, elapsed / Self.sideShiftDuration)
            let eased = cubicBezier(t, p1: 0.22, p2: 1, p3: 0.36, p4: 1)
            let x = animFrom.x + (animTo.x - animFrom.x) * eased
            let y = animFrom.y + (animTo.y - animFrom.y) * eased
            moveWindow?(NSPoint(x: x, y: y))
            if t >= 1 {
                animating = false
                let pos = agentPosition(from: animTo, in: visible)
                applyAgent(pos.x, pos.y, hiddenEdge: hiddenEdge)
            }
        }
    }

    /// Cubic-bezier easing approximation (side-shift-ease).
    private func cubicBezier(_ t: CGFloat, p1: CGFloat, p2: CGFloat, p3: CGFloat, p4: CGFloat) -> CGFloat {
        // De Casteljau for (0,0)-(p1,p2)-(p3,p4)-(1,1)
        let u = 1 - t
        let a = u * u * u
        let b = 3 * u * u * t * p2
        let c = 3 * u * t * t * p4
        let d = t * t * t
        return a + b + c + d
    }

    func syncFromWindow(in visible: NSRect) {
        let pos = agentPosition(from: windowOrigin(in: visible), in: visible)
        agentX = pos.x
        agentY = pos.y
    }

    // MARK: - Drag (handleAgentPointerDown/Move/Up)

    func beginDrag(mouse: NSPoint) {
        guard let visible = visibleFrameProvider?() else { return }
        syncFromWindow(in: visible)
        isDragging = true
        dragMoved = false
        dragOriginX = agentX
        dragOriginY = agentY
        dragStartMouse = mouse
        animating = false
        _ = visible
    }

    func updateDrag(mouse: NSPoint) {
        guard isDragging, let visible = visibleFrameProvider?() else { return }
        let dx = mouse.x - dragStartMouse.x
        let dy = dragStartMouse.y - mouse.y
        if !dragMoved, hypot(dx, dy) >= Self.dragClickThreshold {
            dragMoved = true
        }
        let nextX = dragOriginX + dx
        let nextY = dragOriginY + dy
        let nextEdge = hiddenEdgeForPosition(x: nextX, y: nextY, current: hiddenEdge, in: visible)
        let clamped = clampPosition(x: nextX, y: nextY, hiddenEdge: nextEdge, in: visible)
        applyAgent(clamped.x, clamped.y, hiddenEdge: nextEdge)
        moveWindow?(windowOrigin(in: visible))
    }

    struct DragEndResult {
        var wasDrag: Bool
        var tappedHiddenEdge: Bool
        var tappedAvatar: Bool
    }

    func endDrag() -> DragEndResult {
        isDragging = false
        let wasDrag = dragMoved
        dragMoved = false

        if wasDrag {
            return DragEndResult(wasDrag: true, tappedHiddenEdge: false, tappedAvatar: false)
        }

        if hiddenEdge != nil {
            return DragEndResult(wasDrag: false, tappedHiddenEdge: true, tappedAvatar: false)
        }
        return DragEndResult(wasDrag: false, tappedHiddenEdge: false, tappedAvatar: true)
    }

    func revealHiddenEdge(in visible: NSRect) {
        guard let edge = hiddenEdge else { return }
        let pos = revealedPosition(for: edge, in: visible)
        setPosition(x: pos.x, y: pos.y, hiddenEdge: nil, animate: true, in: visible)
    }

    func goHome(in visible: NSRect) {
        let pos = defaultPosition(in: visible)
        setPosition(x: pos.x, y: pos.y, hiddenEdge: nil, animate: true, in: visible)
    }

    var isDockedRight: Bool {
        guard let visible = visibleFrameProvider?() else { return false }
        return agentX > viewportSize(in: visible).width / 2
    }
}
