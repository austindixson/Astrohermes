import SwiftUI
import AppKit

/// Sprite-based renderer. The walk is a hand-authored 10-frame cycle per
/// direction (5 frames per step: contact, down, passing, swing, push-off),
/// sliced from the sprite sheets in mascot/all_*.png and pre-aligned so every
/// frame shares one ground line and body center. Idle is a front-facing pose
/// per direction. Procedural motion on top is now subtle — the frames carry
/// the leg action; the engine only adds a soft bob, rock and squash — and
/// mood accessories (sweat drop, zzz, "!", the weekly aura) are drawn in
/// code so no expression depends on extra assets.
struct Sprite {
    let image: Image?
    /// Fraction of the sprite's height (from the top) where the feet rest.
    let footFrac: CGFloat
}

enum Sprites {
    static let walkRight: [Sprite] = (0..<10).map {
        Sprite(image: load("walk-right-f\($0)"), footFrac: 0.873)
    }
    static let walkLeft: [Sprite] = (0..<10).map {
        Sprite(image: load("walk-left-f\($0)"), footFrac: 0.873)
    }
    /// Edge-turnaround pivot, ordered right-profile → front → left-profile;
    /// played forward when turning right→left, reversed for left→right.
    static let turn: [Sprite] = (0..<6).map {
        Sprite(image: load("turn-\($0)"), footFrac: 0.873)
    }
    /// Pickup reaction: 0-3 snatched, 4-6 dangling while held, 7-11 landing.
    static let pickup: [Sprite] = (0..<12).map {
        Sprite(image: load("pickup-\($0)"), footFrac: 0.873)
    }
    /// Held-aloft base set: 0/10/11 calm dangle, 1 alert, 2 distressed,
    /// 5/6/9 leg kicks (also the falling paddle).
    static let air: [Sprite] = (0..<12).map {
        Sprite(image: load("air-\($0)"), footFrac: 0.873)
    }
    /// Carried sideways while held; shared ladder per direction:
    /// 0/1 gentle lean, 2/3 happy streaming, 5/8 distressed at speed.
    static let airRight: [Sprite] = (0..<12).map {
        Sprite(image: load("air-r-\($0)"), footFrac: 0.873)
    }
    static let airLeft: [Sprite] = (0..<12).map {
        Sprite(image: load("air-l-\($0)"), footFrac: 0.873)
    }
    /// Fuming-at-you set, front-facing. 3 anger tiers × 4 looping frames:
    /// 0-3 annoyed, 4-7 cross, 8-11 red-faced furious.
    static let mad: [Sprite] = (0..<12).map {
        Sprite(image: load("mad-\($0)"), footFrac: 0.873)
    }
    static let idleRight = Sprite(image: load("idle-right"), footFrac: 0.934)
    static let idleLeft = Sprite(image: load("idle-left"), footFrac: 0.934)
    /// "Home" peek from behind the left screen edge — a 10-frame stable idle
    /// sheet (mascot/side_stable.png). The half-head stays pinned to the edge
    /// (every frame pre-aligned to one flat-cut + baseline); only the face
    /// changes — neutral, smile, blink, closed-eyes, a little startled wiggle —
    /// so he keeps still on the edge while still feeling alive.
    static let stable: [Sprite] = (0..<10).map {
        Sprite(image: load("stable-\($0)"), footFrac: 0.902)
    }
    /// Pull-out-of-the-hole emergence (mascot/side_pop.png), played when Pip is
    /// dragged out of his side peek. 0 a head poking from the edge → 11 fully
    /// out, full-body front. Frames share a uniform offset so the body grows
    /// and slides out of the edge rather than re-centering each frame.
    static let pop: [Sprite] = (0..<12).map {
        Sprite(image: load("pop-\($0)"), footFrac: 0.873)
    }
    /// Dropped-and-falling sequence (mascot/fall.png), feet kept on one
    /// baseline: 0 calm release → 1-7 flailing with speed-lines as he
    /// accelerates → 8-10 impact squash → 11 stand back up.
    static let fall: [Sprite] = (0..<12).map {
        Sprite(image: load("fall-\($0)"), footFrac: 0.875)
    }

    private static func load(_ name: String) -> Image? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "png"),
              let ns = NSImage(contentsOf: url) else { return nil }
        return Image(nsImage: ns)
    }
}

struct MascotRootView: View {
    var model: PoseModel

    var body: some View {
        let pose = model.pose
        GeometryReader { geo in
            let w = geo.size.width
            // Keep the bubble/badge inside the part of the window that's actually
            // on screen (the window can hang off the left edge while peeking), so
            // text never clips at the screen edge.
            let lo = max(0, min(w, pose.badgeSafeMinX))
            let hi = max(lo, min(w, pose.badgeSafeMaxX))
            let safeCenter = (lo + hi) / 2
            let safeWidth = max(80, hi - lo - 12)
            ZStack(alignment: .top) {
                Canvas(rendersAsynchronously: false) { context, size in
                    var ctx = context
                    drawMascot(&ctx, size: size, pose: pose)
                }
                .frame(width: w, height: geo.size.height)
                VStack(spacing: 5) {
                    // The hover card takes over the spot — never show both.
                    if let text = pose.bubbleText, !pose.showBadge {
                        SpeechBubbleView(text: text)
                            .transition(.opacity)
                    }
                    if pose.showBadge {
                        UsageBadgeView(stats: pose.badgeStats, note: pose.badgeNote)
                    }
                }
                .frame(maxWidth: safeWidth)
                .padding(.top, 2)
                .offset(x: safeCenter - w / 2, y: pose.badgeDrop)
            }
            .frame(width: w, height: geo.size.height)
        }
    }
}

struct SpeechBubbleView: View {
    let text: String
    var body: some View {
        VStack(spacing: -1) {
            Text(text)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(Palette.claudeInk)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 11)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Palette.claudeCream)
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(Palette.claudeClay.opacity(0.22), lineWidth: 1))
                        .shadow(color: Palette.claudeInk.opacity(0.20), radius: 4, y: 1.5)
                )
            Triangle()
                .fill(Palette.claudeCream)
                .frame(width: 13, height: 7)
        }
        .frame(maxWidth: 240)
    }

    struct Triangle: Shape {
        func path(in rect: CGRect) -> Path {
            var p = Path()
            p.move(to: CGPoint(x: rect.minX, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
            p.closeSubpath()
            return p
        }
    }
}

/// Claude-themed hover card: warm clay-on-ivory with a sparkle mark, a meter
/// bar per usage window, and the reset countdown.
struct UsageBadgeView: View {
    let stats: [UsageStat]
    let note: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                ClaudeSpark().frame(width: 11, height: 11)
                Text("USAGE")
                    .font(.system(size: 8.5, weight: .heavy, design: .rounded))
                    .tracking(1.4)
                    .foregroundStyle(Palette.claudeClay)
            }
            if let note {
                Text(note)
                    .font(.system(size: 10.5, weight: .medium, design: .rounded))
                    .foregroundStyle(Palette.claudeInk.opacity(0.7))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 150, alignment: .leading)
            } else {
                ForEach(stats, id: \.label) { UsageStatRow(stat: $0) }
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .fill(Palette.claudeCream)
                .overlay(
                    RoundedRectangle(cornerRadius: 13, style: .continuous)
                        .strokeBorder(Palette.claudeClay.opacity(0.22), lineWidth: 1))
                .shadow(color: Palette.claudeInk.opacity(0.20), radius: 6, y: 2)
        )
        .fixedSize()
    }
}

private struct UsageStatRow: View {
    let stat: UsageStat
    var body: some View {
        HStack(spacing: 6) {
            Text(stat.label)
                .font(.system(size: 11, weight: .heavy, design: .rounded))
                .foregroundStyle(Palette.claudeInk)
                .frame(width: 17, alignment: .leading)
            UsageMeter(pct: stat.pct).frame(width: 46, height: 6)
            Text("\(Int(stat.pct.rounded()))%")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(Palette.usageFill(stat.pct))
                .frame(width: 28, alignment: .trailing)
            Text(stat.resets)
                .font(.system(size: 9, weight: .semibold, design: .rounded))
                .foregroundStyle(Palette.claudeInk.opacity(0.45))
                .frame(minWidth: 34, alignment: .trailing)
        }
    }
}

private struct UsageMeter: View {
    let pct: Double
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.claudeClay.opacity(0.16))
                Capsule().fill(Palette.usageFill(pct))
                    .frame(width: max(3, geo.size.width * min(1, max(0, pct / 100))))
            }
        }
    }
}

/// Claude's sparkle mark — radiating spokes, echoing the mascot's belly star.
private struct ClaudeSpark: View {
    var body: some View {
        Canvas { ctx, size in
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            let r = size.width / 2
            for i in 0..<8 {
                let a = Double(i) * .pi / 4
                var p = Path()
                p.move(to: c)
                p.addLine(to: CGPoint(x: c.x + CGFloat(cos(a)) * r, y: c.y + CGFloat(sin(a)) * r))
                ctx.stroke(p, with: .color(Palette.claudeClay),
                           style: StrokeStyle(lineWidth: i % 2 == 0 ? 1.7 : 1.0, lineCap: .round))
            }
        }
    }
}

/// Minimal status banner for the (Liquid Glass) status-bar menu: it stays
/// transparent so the menu's glass material shows through, with adaptive text
/// and the Claude coral accents (sparkle, meters, mood pill).
struct MenuHeaderView: View {
    let mood: String
    let stats: [UsageStat]
    let note: String?
    let updated: String

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 7) {
                ClaudeSpark().frame(width: 13, height: 13)
                Text(mascotName)
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary)
                Spacer(minLength: 10)
                Text(mood.uppercased())
                    .font(.system(size: 8.5, weight: .heavy, design: .rounded))
                    .tracking(0.7)
                    .foregroundStyle(Palette.claudeClay)
                    .padding(.horizontal, 7).padding(.vertical, 2.5)
                    .background(Capsule().fill(Palette.claudeClay.opacity(0.2)))
            }
            if let note {
                Text(note)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(stats, id: \.label) { MenuStatRow(stat: $0) }
                }
            }
            if !updated.isEmpty {
                Text(updated)
                    .font(.system(size: 9, weight: .medium, design: .rounded))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 11)
        .padding(.bottom, 8)
        .frame(width: 250, alignment: .leading)
    }
}

/// Glass-friendly meter row (adaptive label + neutral track) for the menu.
private struct MenuStatRow: View {
    let stat: UsageStat
    var body: some View {
        HStack(spacing: 9) {
            Text(stat.label)
                .font(.system(size: 11.5, weight: .bold, design: .rounded))
                .foregroundStyle(.primary)
                .frame(width: 18, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.14))
                    Capsule().fill(Palette.usageFill(stat.pct))
                        .frame(width: max(3, geo.size.width * min(1, max(0, stat.pct / 100))))
                }
            }
            .frame(width: 64, height: 6)
            Text("\(Int(stat.pct.rounded()))%")
                .font(.system(size: 11.5, weight: .bold, design: .rounded))
                .foregroundStyle(Palette.usageFill(stat.pct))
                .frame(width: 32, alignment: .trailing)
            Text(stat.resets)
                .font(.system(size: 9.5, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Canvas drawing

private func drawMascot(_ ctx: inout GraphicsContext, size: CGSize, pose: Pose) {
    let cx = size.width / 2
    let ground = size.height - 5

    // Peeking "home": the side-pop frames carry the whole performance, and the
    // window is parked mostly off the left screen edge — so just draw the frame
    // (no ground shadow / aura / accessories, which are centered in the window
    // and would float on-screen detached from him).
    if pose.peekFrame >= 0 || pose.popFrame >= 0 {
        let side: CGFloat = 200
        let s = pose.popFrame >= 0
            ? Sprites.pop[min(Sprites.pop.count - 1, pose.popFrame)]
            : Sprites.stable[min(Sprites.stable.count - 1, pose.peekFrame)]
        if let image = s.image {
            // Squash-and-stretch about the feet (used while he's pulled out of
            // the hole: stretches tall as he's yanked, squashes on touchdown).
            if pose.stretchY != 0 {
                ctx.translateBy(x: cx, y: ground)
                ctx.scaleBy(x: 1 - pose.stretchY * 0.4, y: 1 + pose.stretchY)
                ctx.translateBy(x: -cx, y: -ground)
            }
            ctx.draw(image, in: CGRect(x: cx - side / 2,
                                       y: ground - s.footFrac * side,
                                       width: side, height: side))
        }
        return
    }

    let facingRight = pose.scaleX >= 0
    let walking = pose.walkPhase >= 0
    let turning = pose.turnPhase >= 0
    let turnScale = min(1, abs(pose.scaleX))
    let useFrontPose = !turning && !walking

    // Sprite selection. While walking, walkPhase ∈ [0, 2) spans the full
    // two-step cycle; each step holds 5 of the 10 hand-drawn frames. The
    // edge turnaround plays 6 hand-drawn pivot frames instead of flipping.
    let sprite: Sprite
    if pose.fallFrame >= 0 {
        sprite = Sprites.fall[min(Sprites.fall.count - 1, pose.fallFrame)]
    } else if pose.madFrame >= 0 {
        sprite = Sprites.mad[min(Sprites.mad.count - 1, pose.madFrame)]
    } else if pose.airFrame >= 0 {
        let set = pose.airSheet == 1 ? Sprites.airRight
                : pose.airSheet == 2 ? Sprites.airLeft : Sprites.air
        sprite = set[min(set.count - 1, pose.airFrame)]
    } else if pose.pickupFrame >= 0 {
        sprite = Sprites.pickup[min(Sprites.pickup.count - 1, pose.pickupFrame)]
    } else if turning {
        let p = pose.turnFromRight ? pose.turnPhase : 1 - pose.turnPhase
        let idx = min(Sprites.turn.count - 1, max(0, Int(p * CGFloat(Sprites.turn.count))))
        sprite = Sprites.turn[idx]
    } else if useFrontPose {
        sprite = facingRight ? Sprites.idleRight : Sprites.idleLeft
    } else {
        let set = facingRight ? Sprites.walkRight : Sprites.walkLeft
        let idx = min(set.count - 1, max(0, Int(pose.walkPhase * 5)))
        sprite = set[idx]
    }

    let spriteSide: CGFloat = 200                      // square frame; content ~150 pt tall
    let lift = pose.bodyLift + pose.footTap * 0.5
    // Each frame carries its own foot line, so rects are computed per sprite.
    func frameRect(_ s: Sprite) -> CGRect {
        CGRect(x: cx - spriteSide / 2,
               y: ground - lift - s.footFrac * spriteSide,
               width: spriteSide,
               height: spriteSide)
    }
    let rect = frameRect(sprite)

    // Weekly-cap aura: a soft glow behind the character that fades in past
    // ~50% of the 7-day cap and shifts toward a warning hue near the limit.
    if let weekly = pose.weeklyPct, weekly > 50 {
        let strength = min(1, (weekly - 50) / 50)
        let auraColor = Palette.scarf(weeklyPct: weekly).opacity(0.12 + 0.22 * strength)
        let auraRect = CGRect(x: cx - 75, y: ground - 150, width: 150, height: 150)
        ctx.drawLayer { layer in
            layer.addFilter(.blur(radius: 16))
            layer.fill(Path(ellipseIn: auraRect), with: .color(auraColor))
        }
    }

    // Ground shadow, thinner when the body bounces up. None while Pip is
    // snatched off the ground and dangling, nor while he's airborne mid-fall
    // (frames 0-7); the impact/recover frames (8-11) get a wide ground shadow.
    let airborneFall = (0...7).contains(pose.fallFrame)
    if !(3...6).contains(pose.pickupFrame), pose.airFrame < 0, !airborneFall {
        let shadowW: CGFloat = (pose.fallFrame >= 8 ? 124
                                : useFrontPose ? 112 : (turning ? 108 : 96)) * (1 - lift * 0.02)
        ctx.fill(
            Path(ellipseIn: CGRect(x: cx - shadowW / 2, y: ground - 5, width: shadowW, height: 9)),
            with: .color(Palette.shadow))
    }

    // Body transform about the ground contact point: squash-and-stretch plus
    // a continuous step rock while walking — the body sways once per stride,
    // leaning into each footfall.
    var rockDegrees: CGFloat = 0
    if walking, !useFrontPose {
        // The drawn frames carry the lean; only a whisper of extra rock.
        rockDegrees = 1.5 * cos(.pi * pose.walkPhase)
        if !facingRight { rockDegrees = -rockDegrees }
    }
    if pose.footTap > 0.1 { rockDegrees += pose.footTap * 0.4 }   // antsy jiggle
    if pose.sitting { rockDegrees = facingRight ? 2 : -2 }        // dozing slump

    // turnScale < 1 only mid-turnaround: squish horizontally through the swing.
    let xScale = (1 + pose.bodySquash) * (turnScale < 1 ? max(0.45, turnScale) : 1)
    let yScale = 1 - pose.bodySquash

    ctx.translateBy(x: cx, y: ground)
    ctx.rotate(by: .degrees(rockDegrees))
    ctx.scaleBy(x: xScale, y: yScale)
    ctx.translateBy(x: -cx, y: -ground)

    if let image = sprite.image {
        ctx.draw(image, in: rect)
    } else {
        // Sprites missing from the bundle — draw a placeholder blob so the
        // app still shows something instead of an empty window.
        let blob = CGRect(x: cx - 55, y: ground - 110, width: 110, height: 105)
        ctx.fill(Path(roundedRect: blob, cornerRadius: 45), with: .color(Palette.body))
        for ex in [cx - 18, cx + 18] {
            ctx.fill(Path(ellipseIn: CGRect(x: ex - 8, y: ground - 80, width: 16, height: 16)),
                     with: .color(Palette.eye))
        }
    }

    // Accessories track the (transformed) head position.
    let headTop = rect.minY + spriteSide * 0.12
    switch pose.mood {
    case .worried:
        drawSweatDrop(&ctx, head: CGPoint(x: cx + (facingRight ? 42 : -42), y: headTop + 34),
                      phase: pose.phase)
    case .sleepy where pose.sitting:
        drawZzz(&ctx, head: CGPoint(x: cx + 38, y: headTop + 6), phase: pose.phase)
    case .antsy where pose.footTap > 0.5:
        ctx.draw(
            Text("!").font(.system(size: 17, weight: .heavy, design: .rounded))
                .foregroundStyle(Palette.bodyEdge),
            at: CGPoint(x: cx + 42, y: headTop - 4))
    case .mad where pose.madFrame >= 0:
        // Throbbing manga anger marks while he fumes at you.
        drawAngerMark(&ctx, at: CGPoint(x: cx + 47, y: headTop + 2), phase: pose.phase, size: 1.0)
        drawAngerMark(&ctx, at: CGPoint(x: cx - 46, y: headTop + 14), phase: pose.phase + 0.4, size: 0.75)
    default:
        break
    }
}

private func drawAngerMark(_ ctx: inout GraphicsContext, at c: CGPoint, phase: CGFloat, size: CGFloat) {
    let pulse = (0.78 + 0.3 * abs(sin(Double(phase) * 2 * .pi * 2.2))) * Double(size)
    let col = Color(red: 0.85, green: 0.20, blue: 0.16)
    // Four bent "vein" strokes radiating from a center — the 💢 anger mark.
    for i in 0..<4 {
        let a = Double(i) * .pi / 2 + .pi / 4
        let inner = CGPoint(x: c.x + CGFloat(cos(a)) * 2, y: c.y + CGFloat(sin(a)) * 2)
        let outer = CGPoint(x: c.x + CGFloat(cos(a) * 9 * pulse), y: c.y + CGFloat(sin(a) * 9 * pulse))
        let bend = a + .pi / 2
        let ctrl = CGPoint(x: (inner.x + outer.x) / 2 + CGFloat(cos(bend) * 3.6 * pulse),
                           y: (inner.y + outer.y) / 2 + CGFloat(sin(bend) * 3.6 * pulse))
        var p = Path()
        p.move(to: inner)
        p.addQuadCurve(to: outer, control: ctrl)
        ctx.stroke(p, with: .color(col), style: StrokeStyle(lineWidth: CGFloat(2.6 * size), lineCap: .round))
    }
}

private func drawSweatDrop(_ ctx: inout GraphicsContext, head: CGPoint, phase: CGFloat) {
    // A drop forming at the temple and sliding down, on loop.
    let t = (phase * 0.7).truncatingRemainder(dividingBy: 1)
    let origin = CGPoint(x: head.x, y: head.y + t * 14)
    let s: CGFloat = 0.7 + t * 0.4
    var drop = Path()
    drop.move(to: CGPoint(x: origin.x, y: origin.y - 7 * s))
    drop.addQuadCurve(to: CGPoint(x: origin.x + 5 * s, y: origin.y + 3 * s),
                      control: CGPoint(x: origin.x + 6 * s, y: origin.y - 3 * s))
    drop.addQuadCurve(to: CGPoint(x: origin.x - 5 * s, y: origin.y + 3 * s),
                      control: CGPoint(x: origin.x, y: origin.y + 9 * s))
    drop.addQuadCurve(to: CGPoint(x: origin.x, y: origin.y - 7 * s),
                      control: CGPoint(x: origin.x - 6 * s, y: origin.y - 3 * s))
    ctx.fill(drop, with: .color(Palette.sweat.opacity(0.55 + 0.35 * Double(1 - t))))
}

private func drawZzz(_ ctx: inout GraphicsContext, head: CGPoint, phase: CGFloat) {
    for i in 0..<3 {
        let t = (phase * 0.35 + CGFloat(i) * 0.33).truncatingRemainder(dividingBy: 1)
        let alpha = Double(sin(.pi * t)) * 0.85
        guard alpha > 0.05 else { continue }
        let pt = CGPoint(
            x: head.x + t * 16 + CGFloat(i) * 4,
            y: head.y - t * 26)
        ctx.draw(
            Text("z")
                .font(.system(size: 10 + CGFloat(i) * 3, weight: .bold, design: .rounded))
                .foregroundStyle(Palette.eye.opacity(alpha)),
            at: pt)
    }
}
