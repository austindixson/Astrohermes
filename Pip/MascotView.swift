import SwiftUI

// MARK: - Notification names (resize only)

extension Notification.Name {
    static let pipChatResize = Notification.Name("pipChatResize")
    static let pipChatMode = Notification.Name("pipChatMode")
    static let pipFileDrop = Notification.Name("pipFileDrop")
    static let pipComposerHeight = Notification.Name("pipComposerHeight")
}

struct MascotRootView: View {
    var model: PoseModel
    var handler: OnscreenAgentHandling?

    var body: some View {
        SpaceAgentShellView(model: model, handler: handler)
    }
}

/// Claude's sparkle mark — radiating spokes.
private struct HermesSpark: View {
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

/// Status banner for the menu bar dropdown.
struct MenuHeaderView: View {
    let mood: String
    let stats: [UsageStat]
    let note: String?
    let updated: String

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 7) {
                HermesSpark().frame(width: 13, height: 13)
                Text(mascotName)
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundStyle(.primary)
                Spacer(minLength: 10)
                Text(mood.uppercased())
                    .font(.system(size: 8.5, weight: .heavy, design: .rounded))
                    .tracking(0.7)
                    .foregroundStyle(Palette.hermesPurple)
                    .padding(.horizontal, 7).padding(.vertical, 2.5)
                    .background(Capsule().fill(Palette.hermesPurple.opacity(0.2)))
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
            Text(stat.detail)
                .font(.system(size: 9.5, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
        }
    }
}
