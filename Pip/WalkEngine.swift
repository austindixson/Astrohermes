import AppKit
import QuartzCore
import Observation

/// Which screen edge Pip is peeking from.
enum PeekEdge {
    case left, right, top, bottom
}

enum ChatDisplayMode: Equatable {
    case compact, full
}

/// Everything the renderer needs to draw one frame of the mascot.
struct Pose: Equatable {
    var scaleX: CGFloat = 1          // facing (+right / −left), magnitude < 1 mid-turnaround
    var mood: Mood = .sleepy
    var walkPhase: CGFloat = -1      // stride cycle position in [0, 2): [0,1) stride A,
                                     // [1,2) stride B; -1 when not walking
    var turnPhase: CGFloat = -1      // edge-turnaround progress in [0, 1]; -1 when not turning
    var turnFromRight = false        // true: was walking right, turning to face left
    var pickupFrame = -1             // index into the pickup sheet; -1 when not grabbed/landing
    var peekFrame = -1               // index into the stable peek sheet while peeking from the edge; -1 otherwise
    var popFrame = -1                // index into the pop-out sheet while being pulled from the peek; -1 otherwise
    var fallFrame = -1               // index into the fall sheet while dropping/landing; -1 otherwise
    var airFrame = -1                // index into the selected in-air sheet; -1 otherwise
    var airSheet = 0                 // 0 base in-air set, 1 carried-right set, 2 carried-left set
    var madFrame = -1                // index into the mad sheet while fuming; -1 otherwise
    var bodySquash: CGFloat = 0      // + squashes (wider/shorter), − stretches
    var stretchY: CGFloat = 0        // peek/pop only: + stretches taller/thinner, − squashes (anchored at feet)
    var bodyLift: CGFloat = 0        // points the body rises off the ground
    var headBob: CGFloat = 0         // face offset, syncs with steps
    var phase: CGFloat = 0           // ambient clock for sway / zzz / sweat / tap
    var blink: CGFloat = 0           // 0 open .. 1 closed
    var yawn: CGFloat = 0            // 0 .. 1 mouth open
    var lookX: CGFloat = 0           // −1 .. 1 pupil shift
    var footTap: CGFloat = 0         // antsy idle foot-tap lift in points
    var sitting = false
    var weeklyPct: Double?
    var bubbleText: String?
    var showBadge = false
    var badgeStats: [UsageStat] = []
    var badgeNote: String?
    var badgeSafeMinX: CGFloat = 0     // on-screen window-x span, so the hover badge
    var badgeSafeMaxX: CGFloat = 280   // can dodge the screen edge and never clip
    var badgeDrop: CGFloat = 0         // push the badge down toward the head (peek/home)
    var peekEdge: PeekEdge = .left    // which screen edge Pip is peeking from
    var chatOpen = false               // inline chat bubble visible above Pip
    var chatDisplayMode: ChatDisplayMode = .compact
    var compactAssistantText: String?  // latest assistant reply or live trace line
    var chatTraceActive = false        // bubble shows single-line progress, not final reply
    var uiBubblePhase: SpaceAgentBubblePhase = .visible
    var chatMessages: [ChatBubbleMessage] = []
    var chatLoading = false
    var chatStatusText: String?        // shown as composer placeholder while executing
    var chatBubbleBelowHead = false    // bubble placement: below head when near top of screen
    var appearance: String = Appearance.mascot.rawValue  // "rocky" or "mascot"
    var hiddenEdge: OnscreenAgentHiddenEdge?
    var isDraggingAgent = false
}

/// A single message in Pip's inline chat bubble.
struct ChatBubbleMessage: Equatable, Identifiable {
    let id = UUID()
    let text: String
    let isUser: Bool
}

@Observable
final class PoseModel {
    var pose = Pose()
}

/// CADisplayLink-driven state machine: continuous strolling along the bottom
/// edge, edge turnarounds, randomized idle pauses, drag handling, and mood
/// flavor. Movement (px/sec) and the walk-cycle pose clock are deliberately
/// decoupled — poses are quantized to ~8–11 fps so the steps read as steps.
final class WalkEngine: NSObject {

    let physics = OnscreenAgentPhysics()

    // MARK: Tunables
    var baseSpeed: CGFloat = 34                       // points/sec at speedFactor 1.0
    var idleEvery: ClosedRange<Double> = 7...18       // seconds between idle pauses
    var idleLength: ClosedRange<Double> = 2.5...6     // seconds an idle pause lasts
    var turnDuration: Double = 0.55                   // 6 pivot frames at ~11 fps
    static let characterWidth: CGFloat = 72          // Space Agent avatar width for edge collision
    static let interactiveWidth: CGFloat = 120     // shell width when chat closed
    // Peeking "home": Pip is parked off the LEFT screen edge, poking his head
    // out from behind it. `peekInset` is the window-x coordinate that lands on
    // the screen's left edge — content left of it is hidden behind the edge.
    // The stable frames are pre-aligned with their flat cut at window-x ≈ 89,
    // so this tucks the cut a few points behind the edge (no visible seam).
    static let peekInset: CGFloat = 94
    // How far above the dock the home peek floats (the hole sits a bit up the
    // left edge, not down in the corner). Eased through the pop-out / tuck-in
    // so he descends to the ground as he emerges and rises back in going home.
    static let peekLift: CGFloat = 72
    static let peekRiseDuration: Double = 0.4   // after tucking in at the corner, rise up to the lifted peek
    private var peekRiseStart: TimeInterval = -1000   // far past → already risen (launch starts lifted)

    enum IdleKind { case breathe, lookAround, yawn }

    private enum State {
        case peeking                            // default: hiding off the left edge, head poked out, facing in
        case walking
        case turning(start: TimeInterval, fromFacing: CGFloat)
        case idling(kind: IdleKind, start: TimeInterval, until: TimeInterval)
        case sitting
        case dragging(start: TimeInterval)
        case falling(vy: CGFloat, bounced: Bool)
        case landing(start: TimeInterval)
        case fuming(start: TimeInterval)        // mad: planted, facing you, simmering
        case tuckingIn(start: TimeInterval)     // "go home": reverse side-pop, backing into the edge hole
    }

    /// Cartoon gravity for the released drop — gentle enough to read every
    /// frame on the way down, with one soft bounce after a hard fall.
    private static let gravity: CGFloat = 2000
    private static let terminalFall: CGFloat = 1250

    /// Pickup timing (seconds per drawn frame).
    private static let grabFrameDur = 0.08      // pickup frames 0-3: snatched off the ground
    private static let alertDur = 0.30          // in-air frame 1: startled beat after the snatch
    private static let landFrameDur = 0.11      // pickup frames 7-11: impact + brush-off
    static let landDuration = 5 * landFrameDur

    // Smoothed cursor velocity while held (window points/sec); drives which
    // in-air frame shows: calm dangle, trailing swing, or shaken-distress.
    private var dragVX: CGFloat = 0
    private var dragVY: CGFloat = 0
    private var lastDragOrigin: NSPoint?
    private var lastDragMoveAt: TimeInterval = 0
    private var dragInstVX: CGFloat = 0
    private var dragInstVY: CGFloat = 0
    private var airHeight: CGFloat = 0       // window-bottom height above the ground line
    private var tossVX: CGFloat = 0          // horizontal momentum carried into the drop

    // Pop-out-of-the-hole: grabbing him out of the side peek plays the side-pop
    // emergence over a fixed time, while he stays STUCK at the edge (the window
    // only does a tiny scripted settle, never chasing the cursor) so no frame
    // ever clips off-screen. Cursor-following only begins once he's fully out.
    private var poppingOut = false
    private var dragFromPeek = false
    static let popDuration: Double = 0.62       // seconds for the whole pull-out
    static let popPullFrac: Double = 0.42       // first part: yanked down to the corner, stretching
    static let popStretchMax: CGFloat = 0.4     // how far he stretches while stuck
    static let popSquashMax: CGFloat = 0.16     // touchdown squash at the corner
    // Window inset (window-x landing on the screen's left edge) for the fully
    // emerged frame — the widest frame sits flush here with nothing clipped.
    static let popEmergeInset: CGFloat = 84
    var isPoppingOut: Bool { poppingOut }

    // "Go home": walk back to the left edge, then play the side-pop emergence in
    // reverse to back into the hole, settling into the peek.
    private var goingHome = false
    static let tuckDuration: Double = 0.7
    static let goHomeSpeedFactor: CGFloat = 2.2   // brisk purposeful march home

    enum Pin: Int { case none, left, right }

    // MARK: Wiring
    private let store: UsageStore
    private let model: PoseModel
    var visibleFrameProvider: (() -> NSRect)?
    /// Returns the top edge (AppKit y) of a revealed auto-hide Dock so he can
    /// stand ON it like a platform; nil when there's no Dock to stand on.
    var dockGroundProvider: (() -> CGFloat?)?
    private var smoothGround: CGFloat = 0
    private var smoothGroundReady = false
    var moveWindow: ((NSPoint) -> Void)?
    var windowSize = NSSize(width: 280, height: 230)

    // MARK: State
    private var state: State = .peeking
    private(set) var facing: CGFloat = 1
    private var x: CGFloat = 0
    private var peekEdge: PeekEdge = .left   // which edge Pip is currently peeking from
    private var lastSentOrigin = NSPoint(x: -99999, y: -99999)
    private var lastTimestamp: TimeInterval = 0
    private var walkClock: Double = 0
    private var animClock: Double = 0
    private var nextIdleAt: TimeInterval = 0
    private var nextBlinkAt: TimeInterval = 0
    private var blinkStart: TimeInterval = -1
    private var currentMoodValue: Mood = .sleepy
    private var currentAnger: Double = 0          // 0…1, how badly the window is being wasted
    private var lastMoodCheck: TimeInterval = 0
    private var fumeUntil: TimeInterval = 0       // end of the current fuming fit
    private var madStompUntil: TimeInterval = 0   // end of the angry stomp between fits

    static let fumeDuration: ClosedRange<Double> = 2.6...4.4    // a fuming fit, planted at you
    static let madStompRange: ClosedRange<Double> = 1.0...2.0   // brief angry stomp between fits

    // Easter egg: drag a rival app icon (ChatGPT, Codex) near Pip and he loses it.
    private var provokedUntil: TimeInterval = 0
    private var rivalBubbleNextAt: TimeInterval = 0
    static let provokeHold: Double = 4.0
    static let rivalLines = [
        "ChatGPT?! not in MY house.",
        "keep that thing away from me",
        "ugh. GPT. really?",
        "we don't say that name here",
        "get that traitor away!",
        "i'm telling Claude.",
    ]

    private var bubbleUntil: TimeInterval = 0
    private var bubbleText: String?
    private var nextBubbleAt: TimeInterval = 60       // first candidate a minute in
    private var hovering = false
    private var tickCount = 0
    private var lastVisible: NSRect = .zero

    var paused = false
    var showBadgePersistent = false
    var pin: Pin = .none {
        didSet {
            if pin == .none, case .sitting = state, currentMoodValue != .sleepy {
                state = .walking
            }
        }
    }

    var currentMood: Mood { currentMoodValue }
    var isDragging: Bool { if case .dragging = state { return true } else { return false } }
    var isPeeking: Bool { if case .peeking = state { return true } else { return false } }
    var currentPeekEdge: PeekEdge { peekEdge }
    /// Roaming on the open floor (so he should ride the Dock platform) — not
    /// tucked at his edge home or being carried.
    private var onOpenGround: Bool {
        switch state {
        case .peeking, .tuckingIn, .dragging: return false
        default: return true
        }
    }

    /// Easter egg: the ChatGPT app icon was dragged near him — he loses it.
    /// Forces a furious fume for a few seconds, storming out of his hole if home.
    func provokeByRival() {
        let now = CACurrentMediaTime()
        provokedUntil = now + Self.provokeHold
        currentMoodValue = .antsy
        currentAnger = 1.0
        if isPeeking, !goingHome { state = .walking }   // storm out to confront the rival
        if now >= rivalBubbleNextAt {
            bubbleText = Self.rivalLines.randomElement()
            bubbleUntil = now + 3.5
            rivalBubbleNextAt = now + 5
        }
    }
    /// True while heading back to / tucking into the edge (so the menu can hide
    /// the option once he's already home or on his way).
    var isHomeOrHeading: Bool { physics.hiddenEdge != nil }

    /// Send Pip back to his side-edge home: walk to the left edge, then play the
    /// pop-out emergence in reverse to back into the hole.
    func goHome() {
        guard let visible = visibleFrameProvider?() else { return }
        goingHome = false
        physics.goHome(in: visible)
    }

    init(store: UsageStore, model: PoseModel) {
        self.store = store
        self.model = model
        super.init()
    }

    func startPosition(in visible: NSRect) -> NSPoint {
        physics.windowSize = windowSize
        physics.placeInitial(in: visible)
        state = .peeking
        peekEdge = .left
        facing = 1
        x = physics.windowOrigin(in: visible).x
        return physics.windowOrigin(in: visible)
    }

    /// Window origin x parked at the given screen edge (fully on-screen).
    private func peekX(for edge: PeekEdge, in visible: NSRect) -> CGFloat {
        switch edge {
        case .left:
            return visible.minX
        case .right:
            return visible.maxX - windowSize.width
        case .top, .bottom:
            return visible.minX + (visible.width - windowSize.width) / 2
        }
    }

    /// Legacy convenience — defaults to the current peekEdge.
    private func peekX(in visible: NSRect) -> CGFloat {
        return peekX(for: peekEdge, in: visible)
    }

    /// Window inset for a given pop/tuck frame, tied to the frame itself (no
    /// frame↔position desync). The round-bodied frames (≥4) sit FLUSH at the
    /// edge so the body is never sliced; only the flat-cut peek frames (0-3,
    /// which are drawn to meet a wall) ease the rest of the way to the edge.
    private static func popInset(forFrame f: Int) -> CGFloat {
        let t = max(0, min(1, CGFloat(4 - f) / 4))
        return popEmergeInset + (peekInset - popEmergeInset) * t
    }

    /// Vertical lift while peeking — disabled for the on-screen Space Agent shell.
    private func peekYLift(now: TimeInterval) -> CGFloat { 0 }

    /// Stable edge-peek idle: the body never moves (the frames are pre-aligned
    /// to the edge), only the face changes. A calm timeline of (frame, seconds)
    /// — long neutral holds, a quick blink (2→3→2), the occasional smile, look
    /// and a little startled wiggle (7) — loops to keep him alive but settled.
    /// Frame map: 0/4/5/8/9 neutral · 1 smile · 2 half-blink · 3 eyes-shut ·
    /// 6 glance · 7 wiggle.
    private static let peekTimeline: [(frame: Int, dur: Double)] = [
        (0, 2.4), (2, 0.09), (3, 0.13), (2, 0.07),    // settle, blink
        (5, 1.9), (6, 1.2),                            // neutral, glance
        (1, 1.3),                                      // smile
        (8, 1.7), (2, 0.09), (3, 0.13), (2, 0.07),     // neutral, blink
        (7, 0.45), (8, 0.16), (7, 0.45),               // startled wiggle
        (9, 2.1),                                      // long neutral
    ]
    private static let peekTimelineTotal: Double = peekTimeline.reduce(0) { $0 + $1.dur }

    private func peekFramePick() -> Int {
        var t = animClock.truncatingRemainder(dividingBy: Self.peekTimelineTotal)
        for step in Self.peekTimeline {
            if t < step.dur { return step.frame }
            t -= step.dur
        }
        return 0
    }

    // MARK: - Display link tick

    @objc func tick(_ link: CADisplayLink) {
        let now = link.timestamp
        var dt = now - lastTimestamp
        if lastTimestamp == 0 || dt < 0 || dt > 0.1 { dt = 1.0 / 60.0 }
        if lastTimestamp == 0 { scheduleNextIdle(now: now) }   // nextIdleAt starts at 0, which would idle on the very first tick
        lastTimestamp = now
        tickCount &+= 1

        animClock += dt

        if isDragging {
            // Smooth (and decay, once move events stop) the held velocity.
            if now - lastDragMoveAt > 0.08 { dragInstVX = 0; dragInstVY = 0 }
            let k = CGFloat(min(1, dt * 10))
            dragVX += (dragInstVX - dragVX) * k
            dragVY += (dragInstVY - dragVY) * k
        }

        // Mood is cheap but no need to recompute 60×/sec.
        if now - lastMoodCheck > 1.0 {
            lastMoodCheck = now
            let provoked = now < provokedUntil          // rival brought near him
            currentAnger = provoked ? 1.0 : min(1, max(0, store.stats.memoryPct / 100))   // drives the fuming tier
            let newMood = provoked ? .antsy : store.mood()
            if newMood != currentMoodValue {
                currentMoodValue = newMood
                switch newMood {
                case .sleepy:
                    if !isDragging, !isPeeking, !goingHome { state = .sitting }
                case .antsy:
                    break   // advance() keeps him fuming in fits (below)
                default:
                    if case .sitting = state, pin == .none { state = .walking }
                    if case .fuming = state { state = .walking }
                }
            }
        }

        let visible = visibleFrameProvider?() ?? .zero
        guard visible.width > 10 else { return }
        lastVisible = visible

        physics.windowSize = windowSize
        physics.tick(dt: dt, now: now)
        x = physics.windowOrigin(in: visible).x

        updateBlink(now: now)
        updateBubble(now: now)

        // Avatar hover is driven by SwiftUI .onHover on the onscreen shell. than the window moves: the window
        // translates at full display-link rate so traversal stays smooth, but
        // drawn poses are quantized (steps at ~8–11 fps, ambient motion at
        // 12 fps via the rounded phase clock), and identical poses are not
        // re-published — SwiftUI only redraws when something visibly changed.
        // That keeps CPU low, especially when idle.
        let divisor: Int
        switch state {
        case .walking, .turning, .dragging, .falling, .landing, .fuming, .peeking, .tuckingIn: divisor = 2
        case .idling, .sitting: divisor = 4
        }
        if tickCount % divisor == 0 {
            let pose = makePose(now: now)
            if pose != model.pose { model.pose = pose }
        }
    }

    // MARK: - Movement state machine

    private func advance(dt: Double, now: TimeInterval, minX: CGFloat, maxX: CGFloat) {
        if paused {
            if case .dragging = state { return }
            return // pose still renders breathing via makePose
        }

        // Chat open: hold still — stop walking/idling/sitting, but let
        // transitional states (falling, landing, dragging, fuming, tuckingIn)
        // finish naturally so he doesn't get stuck mid-air.
        if model.pose.chatOpen {
            switch state {
            case .falling, .landing, .dragging, .fuming, .tuckingIn: break
            default: return
            }
        }

        // Mad: plant and FUME (mad sheet, trembling) in fits, with brief angry
        // stomps between them — re-asserted every tick so he's actually mad the
        // whole time, even after being dropped back down or pulled around.
        if currentMoodValue == .antsy, !goingHome {
            switch state {
            case .fuming, .dragging, .falling, .landing, .peeking, .tuckingIn: break
            case .walking where now < madStompUntil: break              // mid-stomp
            default: enterFuming(now: now)
            }
        }

        switch state {
        case .peeking:
            // Rests here until the user grabs him and drops him out to roam.
            break

        case .walking:
            if goingHome {
                // March briskly straight to the left edge (no idle/turnaround),
                // then back into the hole.
                walkClock += dt * max(1.4, currentMoodValue.strideHz)
                facing = -1
                x += facing * baseSpeed * Self.goHomeSpeedFactor * dt
                if x <= minX + 2 {
                    x = minX
                    state = .tuckingIn(start: now)
                }
                return
            }
            if currentMoodValue == .sleepy { state = .sitting; return }
            let speedFactor = currentMoodValue.speedFactor
            // walkClock counts strides directly (mood cadence), independent of
            // the movement speed below.
            walkClock += dt * currentMoodValue.strideHz
            x += facing * baseSpeed * speedFactor * dt

            if let target = pinTarget(minX: minX, maxX: maxX) {
                // Walk toward the pinned corner, then settle.
                let dir: CGFloat = target > x ? 1 : -1
                if facing != dir { facing = dir }
                if abs(target - x) < 2 { x = target; state = .sitting }
                return
            }

            if (facing > 0 && x >= maxX) || (facing < 0 && x <= minX) {
                state = .turning(start: now, fromFacing: facing)
            } else if now >= nextIdleAt {
                let kind = randomIdleKind()
                var length = Double.random(in: idleLength)
                if currentMoodValue == .antsy { length *= 0.5 }   // too impatient to stand still
                state = .idling(kind: kind, start: now, until: now + length)
            }

        case .turning(let start, let fromFacing):
            let p = (now - start) / turnDuration
            if p >= 1 {
                facing = -fromFacing
                state = .walking
                scheduleNextIdle(now: now)
            }

        case .idling(_, _, let until):
            if currentMoodValue == .sleepy { state = .sitting; return }
            if now >= until {
                state = .walking
                scheduleNextIdle(now: now)
            }

        case .sitting:
            if goingHome { state = .walking; return }
            if currentMoodValue != .sleepy, pinTarget(minX: minX, maxX: maxX) == nil, pin == .none {
                state = .walking
            }

        case .dragging(let start):
            // Pop-out emergence: keep him pinned at the edge (a tiny scripted
            // settle from the peek spot to the flush-emerged spot — never the
            // cursor) so nothing clips. The controller starts cursor-following
            // only after this finishes.
            if poppingOut {
                let p = min(1, (now - start) / Self.popDuration)
                let visMinX = minX + (windowSize.width - Self.characterWidth) / 2
                if p < Self.popPullFrac {
                    x = visMinX
                } else {
                    let ep = (p - Self.popPullFrac) / (1 - Self.popPullFrac)
                    let frame = min(11, Int((ep * 11).rounded()))
                    x = visMinX - Self.popInset(forFrame: frame)
                }
                if p >= 1 { poppingOut = false }
            }

        case .falling(var vy, let bounced):
            vy = max(vy - Self.gravity * CGFloat(dt), -Self.terminalFall)
            airHeight += vy * CGFloat(dt)
            x += tossVX * CGFloat(dt)                  // a fling carries sideways momentum
            tossVX *= CGFloat(exp(-2.5 * dt))

            let charW = Self.characterWidth
            let winH = windowSize.height
            let groundY = lastVisible.minY

            // Wall collision detection — in falling state, check all four edges.
            // Hit priority: ground first, then side walls, then ceiling.
            let hitGround  = airHeight <= 0
            let hitLeft    = x <= lastVisible.minX - (windowSize.width - charW) / 2
            let hitRight   = x + windowSize.width >= lastVisible.maxX + (windowSize.width - charW) / 2
            let peakY      = groundY + airHeight + winH
            let hitTop     = peakY >= lastVisible.maxY

            if hitGround {
                let speed = abs(tossVX) + abs(vy)
                // Bounce if carrying enough momentum to reach a side or top wall
                if !bounced && speed > 200 {
                    airHeight = 0
                    vy = abs(vy) * 0.45               // dampened upward bounce
                    // Bias toss toward the nearest side wall if already heading that way
                    let midX = (lastVisible.minX + lastVisible.maxX) / 2
                    if abs(tossVX) < 150 && hitLeft {
                        tossVX = 400                   // bounce right from left edge
                    } else if abs(tossVX) < 150 && hitRight {
                        tossVX = -400                  // bounce left from right edge
                    } else if abs(tossVX) < 80 {
                        tossVX = x < midX ? 400 : -400 // bounce toward the far side
                    }
                    state = .falling(vy: vy, bounced: true)
                } else {
                    airHeight = 0
                    state = .landing(start: now)
                }
            } else if hitLeft {
                airHeight = 0
                peekEdge = .left
                facing = 1
                x = peekX(for: .left, in: lastVisible)
                state = .peeking
                peekRiseStart = now
            } else if hitRight {
                airHeight = 0
                peekEdge = .right
                facing = -1
                x = peekX(for: .right, in: lastVisible)
                state = .peeking
                peekRiseStart = now
            } else if hitTop {
                airHeight = max(0, lastVisible.maxY - groundY - winH)
                peekEdge = .top
                facing = 1
                x = peekX(for: .top, in: lastVisible)
                state = .peeking
                peekRiseStart = now
            } else {
                state = .falling(vy: vy, bounced: bounced)
            }

        case .landing(let start):
            if now - start >= Self.landDuration {
                state = currentMoodValue == .sleepy ? .sitting : .walking
                scheduleNextIdle(now: now)
            }

        case .tuckingIn(let start):
            // Reverse pop, pinned at the edge: a tiny scripted settle from the
            // flush-emerged spot back to the peek spot (never off-screen), so the
            // reverse frames never clip. makePose plays them 11 → 0.
            let p = min(1, (now - start) / Self.tuckDuration)
            let eased = p * p * (3 - 2 * p)
            let frame = max(0, 11 - Int((eased * 11).rounded()))
            let visMinX = minX + (windowSize.width - Self.characterWidth) / 2
            x = visMinX - Self.popInset(forFrame: frame)
            if p >= 1 {
                goingHome = false
                facing = 1
                peekRiseStart = now        // now rise up from the corner to the lifted peek
                state = .peeking
            }

        case .fuming:
            if currentMoodValue != .antsy { state = .walking; return }
            // After a fit, stomp off angrily for a beat (the mad block re-fumes
            // once madStompUntil passes), turning around if he's at an edge.
            if now >= fumeUntil {
                madStompUntil = now + Double.random(in: Self.madStompRange)
                if (facing > 0 && x >= maxX - 1) || (facing < 0 && x <= minX + 1) { facing = -facing }
                state = .walking
            }
        }
    }

    private func enterFuming(now: TimeInterval) {
        fumeUntil = now + Double.random(in: Self.fumeDuration)
        state = .fuming(start: now)
    }

    private func pinTarget(minX: CGFloat, maxX: CGFloat) -> CGFloat? {
        switch pin {
        case .none: return nil
        case .left: return minX
        case .right: return maxX
        }
    }

    private func scheduleNextIdle(now: TimeInterval) {
        nextIdleAt = now + Double.random(in: idleEvery)
    }

    private func randomIdleKind() -> IdleKind {
        let r = Double.random(in: 0..<1)
        if r < 0.50 { return .breathe }
        if r < 0.85 { return .lookAround }
        return .yawn
    }

    // MARK: - Drag support (interactive mode)

    func beginDrag() {
        dragVX = 0; dragVY = 0
        dragInstVX = 0; dragInstVY = 0
        lastDragOrigin = nil
        // Grabbing him out of the side peek plays the timed pop-out emergence
        // (he stays put at the edge) instead of the off-the-ground snatch.
        dragFromPeek = isPeeking
        poppingOut = isPeeking
        state = .dragging(start: CACurrentMediaTime())
    }

    /// Called from the controller on every mouse-drag window move.
    func noteDragMove(origin: NSPoint) {
        let now = CACurrentMediaTime()
        if let prev = lastDragOrigin {
            let dt = now - lastDragMoveAt
            if dt > 0.001 {
                dragInstVX = (origin.x - prev.x) / dt
                dragInstVY = (origin.y - prev.y) / dt
            }
        }
        lastDragOrigin = origin
        lastDragMoveAt = now
    }

    /// Release: Pip keeps the throw's momentum and falls under gravity from
    /// wherever it was let go; landing frames play on touchdown.
    func endDrag(atOrigin origin: NSPoint) {
        poppingOut = false
        dragFromPeek = false
        x = origin.x
        let visible = visibleFrameProvider?() ?? .zero
        airHeight = max(0, origin.y - (visible.minY + 1))
        tossVX = max(-700, min(700, dragVX))
        let vy0 = max(-200, min(500, dragVY * 0.35))   // an upward fling arcs up first
        lastTimestamp = 0
        lastSentOrigin = NSPoint(x: -99999, y: -99999)
        if airHeight > 2 {
            state = .falling(vy: vy0, bounced: false)
        } else {
            state = .landing(start: CACurrentMediaTime())
        }
    }

    /// Pick the in-air sheet + frame from how the cursor is moving. The
    /// carried-right/left sheets share an intensity ladder: 0/1 gentle lean,
    /// 2/3 happy streaming, 5/8 distressed at speed.
    private func airFramePick(now: TimeInterval, heldSince: TimeInterval) -> (sheet: Int, frame: Int) {
        let h = abs(dragVX), v = abs(dragVY)
        let speed = max(h, v * 0.6)
        let dir = dragVX >= 0 ? 1 : 2
        if speed > 1100 {
            if h > v * 0.8 {                           // dragged hard sideways
                return (dir, [5, 8][Int(now / 0.15) % 2])
            }
            return (0, Int(now / 0.15) % 2 == 0 ? 2 : 1)   // shaken vertically
        }
        if speed > 550 {                               // brisk carry — streaming along
            return (dir, [2, 3][Int(now / 0.18) % 2])
        }
        if speed > 180 {                               // gentle carry — soft lean
            return (dir, [0, 1][Int(now / 0.22) % 2])
        }
        // Held still: slow breathing dangle, with a little leg kick every few
        // seconds (rotating through the three kick poses).
        let t = now - heldSince
        let cycle = t.truncatingRemainder(dividingBy: 3.2)
        if cycle > 2.75 {
            let kicks = [5, 9, 6]
            return (0, kicks[Int(t / 3.2) % kicks.count])
        }
        let calm = [0, 10, 11, 10]
        return (0, calm[Int(t / 0.45) % calm.count])
    }

    // MARK: - Bubbles

    // MARK: - Inline chat

    var chatExtraHeight: CGFloat { 0 }

    func toggleChat() {
        let newState = !model.pose.chatOpen
        var pose = model.pose
        pose.chatOpen = newState
        if newState {
            pose.chatDisplayMode = .compact
        } else {
            pose.chatMessages = []
            pose.compactAssistantText = nil
            pose.chatStatusText = nil
            pose.chatTraceActive = false
            pose.chatLoading = false
            pose.chatDisplayMode = .compact
            pose.uiBubblePhase = .visible
        }
        model.pose = pose
        NotificationCenter.default.post(name: .pipChatResize, object: newState)
    }

    func expandChat() {
        guard model.pose.chatOpen else { return }
        var pose = model.pose
        pose.chatDisplayMode = .full
        pose.uiBubblePhase = .leaving
        model.pose = pose
        NotificationCenter.default.post(name: .pipChatMode, object: nil)
    }

    func collapseChat() {
        guard model.pose.chatOpen else { return }
        var pose = model.pose
        pose.chatDisplayMode = .compact
        if let last = pose.chatMessages.last(where: { !$0.isUser }) {
            pose.compactAssistantText = last.text
            pose.chatTraceActive = false
            pose.uiBubblePhase = .visible
        }
        model.pose = pose
        NotificationCenter.default.post(name: .pipChatMode, object: nil)
    }

    func dismissCompactAssistantBubble() {
        var pose = model.pose
        pose.compactAssistantText = nil
        pose.uiBubblePhase = .leaving
        model.pose = pose
    }

    // MARK: - Appearance

    func cycleAppearance() {
        let current = currentAppearanceName()
        let next: String
        if current == Appearance.rocky.rawValue {
            next = Appearance.mascot.rawValue
        } else {
            next = Appearance.rocky.rawValue
        }
        UserDefaults.standard.set(next, forKey: appearanceKey)
        // Push into the pose so it takes effect immediately
        var pose = model.pose
        pose.appearance = next
        model.pose = pose
    }

    func stopChat() {
        HermesChatClient.shared.cancel()
        var pose = model.pose
        pose.chatLoading = false
        pose.chatStatusText = nil
        pose.chatTraceActive = false
        model.pose = pose
    }

    func sendChat(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !model.pose.chatLoading else { return }
        let lower = trimmed.lowercased()
        if lower == "/stop" || lower.hasPrefix("/stop ") {
            stopChat()
            return
        }
        if lower == "/help" || lower == "/commands" {
            var pose = model.pose
            pose.chatMessages.append(ChatBubbleMessage(text: trimmed, isUser: true))
            let help = HermesSlashCatalog.shared.helpText()
            pose.chatMessages.append(ChatBubbleMessage(text: help, isUser: false))
            if pose.chatDisplayMode == .compact {
                pose.compactAssistantText = help
                pose.uiBubblePhase = .visible
            }
            model.pose = pose
            NotificationCenter.default.post(name: .pipChatResize, object: false)
            return
        }
        var pose = model.pose
        pose.chatMessages.append(ChatBubbleMessage(text: trimmed, isUser: true))
        pose.chatLoading = true
        pose.chatStatusText = "Thinking…"
        pose.compactAssistantText = "Thinking…"
        pose.chatTraceActive = true
        pose.uiBubblePhase = .visible
        model.pose = pose
        NotificationCenter.default.post(name: .pipChatResize, object: false)

        HermesChatClient.shared.send(trimmed, onPartial: { [weak self] chunk in
            guard let self, let chunk else { return }
            var pose = self.model.pose
            guard pose.chatOpen, pose.chatDisplayMode == .compact else { return }
            pose.chatTraceActive = chunk.isTrace
            pose.compactAssistantText = chunk.text
            pose.chatStatusText = chunk.isTrace ? "Working…" : "Writing reply…"
            pose.uiBubblePhase = .visible
            self.model.pose = pose
            NotificationCenter.default.post(name: .pipChatResize, object: false)
        }) { [weak self] result in
            guard let self else { return }
            var pose = self.model.pose
            pose.chatLoading = false
            pose.chatStatusText = nil
            pose.chatTraceActive = false
            switch result {
            case .success(let response):
                let clean = response.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    ? ""
                    : response
                if !clean.isEmpty {
                    pose.chatMessages.append(ChatBubbleMessage(text: clean, isUser: false))
                    if pose.chatDisplayMode == .compact {
                        pose.compactAssistantText = clean
                        pose.uiBubblePhase = .visible
                    }
                }
            case .failure:
                let err = "oops — hermes didn't answer"
                pose.chatMessages.append(ChatBubbleMessage(text: err, isUser: false))
                if pose.chatDisplayMode == .compact {
                    pose.compactAssistantText = err
                    pose.uiBubblePhase = .visible
                }
            }
            self.model.pose = pose
            NotificationCenter.default.post(name: .pipChatResize, object: false)
        }
    }

    // MARK: - Bubbles (speech)

    func dismissBubble() {
        bubbleText = nil
        bubbleUntil = 0
    }

    func setAvatarHovered(_ hovered: Bool) {
        hovering = hovered
    }

    private func updateBubble(now: TimeInterval) {
        if bubbleText != nil, now > bubbleUntil {
            bubbleText = nil
        }
        guard bubbleText == nil, now >= nextBubbleAt, !paused else { return }
        let line: String?
        switch currentMoodValue {
        case .antsy:
            // Pointed, frequent, and quantified — name the projected waste and
            // the time left so the nudge is actionable.
            let options = [
                "hermes is idle — give me something to do!",
                "tick tock — I'm ready, what are we building?",
                "we're just sitting here. ship something!",
            ]
            line = options.randomElement()

        case .worried:
            line = "almost out for this window — maybe wrap up"
        case .happy:
            line = Double.random(in: 0..<1) < 0.3 ? "nice pace today" : nil
        default:
            line = nil
        }
        if let line {
            bubbleText = line
            bubbleUntil = now + (currentMoodValue == .antsy ? 6 : 8)
        }
        // Mad nags often (it's the whole point); every other mood stays rare.
        nextBubbleAt = now + (currentMoodValue == .antsy
            ? Double.random(in: 20...45)
            : Double.random(in: 600...1500))
    }

    // MARK: - Small animations

    private func updateBlink(now: TimeInterval) {
        if now >= nextBlinkAt {
            blinkStart = now
            nextBlinkAt = now + Double.random(in: 2.2...6.0)
        }
    }

    private func updateHover(visible: NSRect) {
        let charX: CGFloat
        let charY: CGFloat
        switch (state, peekEdge) {
        case (.peeking, .left):
            charX = x + (windowSize.width - Self.characterWidth) / 2
            charY = visible.minY + Self.peekLift
        case (.peeking, .right):
            charX = x + (windowSize.width - Self.characterWidth) / 2
            charY = visible.minY + Self.peekLift
        case (.peeking, .top):
            charX = x + (windowSize.width - Self.characterWidth) / 2
            charY = visible.maxY - 165
        case (.peeking, .bottom):
            charX = x + (windowSize.width - Self.characterWidth) / 2
            charY = visible.minY
        default:
            charX = x + (windowSize.width - Self.characterWidth) / 2
            charY = visible.minY
        }
        let charRect = NSRect(
            x: charX,
            y: charY,
            width: Self.characterWidth,
            height: 165)
        hovering = charRect.contains(NSEvent.mouseLocation)
    }

    // MARK: - Pose assembly

    private func makePose(now: TimeInterval) -> Pose {
        var pose = Pose()
        pose.mood = currentMoodValue
        // Quantized to 12 fps so unchanged poses can be skipped entirely.
        pose.phase = CGFloat((animClock * 12).rounded() / 12)
        pose.scaleX = facing
        pose.weeklyPct = store.stats.memoryPct
        pose.bubbleText = bubbleText
        pose.showBadge = hovering || showBadgePersistent
        if pose.showBadge {
            pose.badgeStats = store.usageStats()
            pose.badgeNote = store.badgeNote
        }
        // The window can sit mostly off the left edge (peeking at home), so tell
        // the renderer which window-x span is actually on screen; the badge keeps
        // itself inside that span instead of clipping at the edge.
        if lastVisible.width > 10 {
            pose.badgeSafeMinX = max(0, lastVisible.minX - x)
            pose.badgeSafeMaxX = min(windowSize.width, lastVisible.maxX - x)
        }
        // Badge stays at top of window — never drops onto Pip's face
        pose.badgeDrop = 0

        // Blink (suppressed while asleep — lids already shut).
        if blinkStart > 0 {
            let t = now - blinkStart
            if t < 0.14 { pose.blink = CGFloat(sin(.pi * t / 0.14)) }
        }

        // Breathing derives from the quantized phase so calm poses repeat
        // exactly between visible changes (and get skipped by the publisher).
        let breath = (sin(Double(pose.phase) * 2 * .pi / 3.2) + 1) / 2   // slow 3.2 s cycle

        func applyWalkCycle() {
            // walkClock counts footfalls; the full drawn cycle is two steps
            // (10 frames). walkPhase is held at the current frame boundary so
            // identical poses dedup and each hand-drawn frame displays
            // cleanly — no blending between frames.
            let raw = walkClock.truncatingRemainder(dividingBy: 2)
            pose.walkPhase = CGFloat((raw * 5).rounded(.down) / 5)

            // The frames carry the leg action; add only a soft bounce arc
            // per step (quantized to 1/12 stride for pose dedup).
            let f = ((raw * 12).rounded() / 12).truncatingRemainder(dividingBy: 1)
            let arc = sin(.pi * f) * sin(.pi * f)
            pose.bodyLift = CGFloat(arc) * 2.5
            pose.bodySquash = CGFloat(0.03 - 0.05 * arc)        // light squash/stretch
            pose.headBob = CGFloat(0.8 - 2 * arc)
            if currentMoodValue == .focused {                   // determined march: bigger bounce
                pose.bodyLift *= 1.4
                pose.bodySquash *= 1.3
            }
        }

        pose.chatBubbleBelowHead = false
        if lastVisible.width > 10 {
            let midY = physics.agentY + windowSize.height / 2
            pose.chatBubbleBelowHead = midY > lastVisible.height * 0.55
        }

        pose.hiddenEdge = physics.hiddenEdge
        pose.isDraggingAgent = physics.isDragging
        pose.peekEdge = physics.isDockedRight ? .right : .left
        if let edge = physics.hiddenEdge {
            switch edge {
            case .left: pose.peekEdge = .left
            case .right: pose.peekEdge = .right
            case .top: pose.peekEdge = .top
            case .bottom: pose.peekEdge = .bottom
            }
        }
        pose.chatOpen = model.pose.chatOpen
        pose.chatDisplayMode = model.pose.chatDisplayMode
        pose.compactAssistantText = model.pose.compactAssistantText
        pose.chatTraceActive = model.pose.chatTraceActive
        pose.uiBubblePhase = model.pose.uiBubblePhase
        pose.chatMessages = model.pose.chatMessages
        pose.chatLoading = model.pose.chatLoading
        pose.chatStatusText = model.pose.chatStatusText

        return pose
    }

}
