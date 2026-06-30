import SwiftUI

enum NativeVibeTheme {
    static let accent = Color(red: 0.55, green: 0.42, blue: 0.98)
    static let accentSoft = accent.opacity(0.18)
    static let canvasBase = Color(red: 0.06, green: 0.07, blue: 0.10)
    static let tileChrome = Color.white.opacity(0.06)
    static let tileBorder = Color.white.opacity(0.12)
    static let tileTitle = Color.white.opacity(0.92)
    static let tileMuted = Color.white.opacity(0.55)
    static let gridLine = Color.white.opacity(0.04)
    static let voiceActive = Color(red: 0.98, green: 0.45, blue: 0.55)

    static let panelRadius: CGFloat = 14
    static let tileRadius: CGFloat = 12
    static let chromePadding: CGFloat = 10
}

struct NativeVibeCanvasBackground: View {
    let preset: String

    var body: some View {
        ZStack {
            NativeVibeTheme.canvasBase
            RadialGradient(
                colors: gradientColors,
                center: .topLeading,
                startRadius: 40,
                endRadius: 900
            )
            .blendMode(.plusLighter)
            .opacity(0.55)
        }
        .ignoresSafeArea()
    }

    private var gradientColors: [Color] {
        switch preset {
        case "ember":
            return [Color(red: 0.9, green: 0.35, blue: 0.2), Color.clear, NativeVibeTheme.accent.opacity(0.35)]
        case "ocean":
            return [Color(red: 0.1, green: 0.55, blue: 0.85), Color.clear, Color(red: 0.2, green: 0.2, blue: 0.7).opacity(0.4)]
        default:
            return [NativeVibeTheme.accent, Color.clear, Color(red: 0.2, green: 0.75, blue: 0.85).opacity(0.35)]
        }
    }
}