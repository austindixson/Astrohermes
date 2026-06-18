import SwiftUI

/// Rename the onscreen agent here — used in the menu and speech bubbles.
let mascotName = "Space Agent"

/// Which character to show: the sprite-based mascot or a procedurally drawn rock.
enum Appearance: String, CaseIterable {
    case rocky
    case mascot
}

/// UserDefaults key for the current appearance preference.
let appearanceKey = "pipAppearance"
func currentAppearanceName() -> String {
    UserDefaults.standard.string(forKey: appearanceKey) ?? Appearance.mascot.rawValue
}
func displayName(for raw: String) -> String {
    switch raw {
    case Appearance.rocky.rawValue: return "Rocky"
    case Appearance.mascot.rawValue: return mascotName
    default: return mascotName
    }
}

enum Mood: String {
    case antsy      // idle — Hermes is running but nothing's happening ("use me!")
    case happy      // moderately active — humming along
    case focused    // busy — lots of sessions and tool calls
    case worried    // memory nearly full — needs pruning
    case sleepy     // Hermes gateway/process is down

    /// Multiplier on the base stroll speed.
    var speedFactor: CGFloat {
        switch self {
        case .antsy:   return 1.3
        case .happy:   return 1.0
        case .focused: return 1.2
        case .worried: return 0.7
        case .sleepy:  return 0
        }
    }

    /// Walk cadence in steps (footfalls) per second.
    var strideHz: Double {
        switch self {
        case .worried: return 2.8
        case .antsy:   return 2.2
        case .focused: return 2.4
        case .happy:   return 1.8
        case .sleepy:  return 0
        }
    }
}

enum Palette {
    static let body      = Color(red: 1.00, green: 0.63, blue: 0.55)  // soft coral
    static let bodyEdge  = Color(red: 0.88, green: 0.46, blue: 0.40)
    static let belly     = Color(red: 1.00, green: 0.93, blue: 0.85)  // cream
    static let feet      = Color(red: 0.86, green: 0.44, blue: 0.38)
    static let eye       = Color(red: 0.26, green: 0.17, blue: 0.17)
    static let blush     = Color(red: 1.00, green: 0.45, blue: 0.50)
    static let leaf      = Color(red: 0.45, green: 0.72, blue: 0.45)
    static let stem      = Color(red: 0.38, green: 0.60, blue: 0.38)
    static let sweat     = Color(red: 0.45, green: 0.70, blue: 0.95)
    static let shadow    = Color.black.opacity(0.13)

    // Hermes brand — warm purple on ivory
    static let hermesPurple = Color(red: 0.60, green: 0.40, blue: 0.75)   // #9966BF
    static let hermesCream  = Color(red: 0.972, green: 0.965, blue: 0.945) // ivory card
    static let hermesInk    = Color(red: 0.20, green: 0.19, blue: 0.17)    // warm near-black
    static let hermesAmber  = Color(red: 0.87, green: 0.55, blue: 0.27)
    static let hermesAlert  = Color(red: 0.78, green: 0.29, blue: 0.25)

    /// Usage-bar fill: calm purple → amber → alert as the meter fills.
    static func usageFill(_ pct: Double) -> Color {
        if pct >= 90 { return hermesAlert }
        if pct >= 70 { return hermesAmber }
        return hermesPurple
    }

    /// Scarf tint for memory fullness.
    static func scarf(weeklyPct: Double) -> Color {
        let p = min(100, max(0, weeklyPct))
        if p < 50 {
            return Color(red: 0.45, green: 0.75, blue: 0.72)
        } else if p < 80 {
            let t = (p - 50) / 30
            return Color(red: 0.45 + 0.50 * t, green: 0.75 - 0.05 * t, blue: 0.72 - 0.42 * t)
        } else {
            let t = min(1, (p - 80) / 20)
            return Color(red: 0.95, green: 0.70 - 0.40 * t, blue: 0.30 - 0.05 * t)
        }
    }
}
