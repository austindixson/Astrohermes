import SwiftUI

/// Rename the mascot here — used in the menu, speech bubbles, and bridge script comments.
let mascotName = "Pip"

enum Mood: String {
    case mad        // confidently wasting the window — stops and fumes at you
    case antsy      // loafing — quota about to be wasted
    case happy      // on pace
    case focused    // burning hot but fine
    case worried    // lockout risk (>= 90% of 5h window)
    case sleepy     // no data / not logged in

    /// Multiplier on the base stroll speed.
    var speedFactor: CGFloat {
        switch self {
        case .mad:     return 1.5    // stomps fast between fuming fits
        case .antsy:   return 1.35
        case .happy:   return 1.0
        case .focused: return 1.15
        case .worried: return 0.75
        case .sleepy:  return 0
        }
    }

    /// Walk cadence in steps (footfalls) per second — decoupled from movement
    /// speed, so step length = speed / cadence varies by mood (worried takes
    /// quick little shuffling steps, happy an easy stroll).
    var strideHz: Double {
        switch self {
        case .worried: return 3.0
        case .mad:     return 3.2    // angry stomp
        case .antsy:   return 2.4
        case .focused: return 2.1
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

    // Claude brand — warm clay on ivory, for the hover usage card.
    static let claudeClay  = Color(red: 0.80, green: 0.47, blue: 0.36)    // #CC785C
    static let claudeCream = Color(red: 0.972, green: 0.965, blue: 0.945) // ivory card
    static let claudeInk   = Color(red: 0.20, green: 0.19, blue: 0.17)    // warm near-black
    static let claudeAmber = Color(red: 0.87, green: 0.55, blue: 0.27)
    static let claudeAlert = Color(red: 0.78, green: 0.29, blue: 0.25)

    /// Usage-bar fill: calm clay → amber → alert as the meter fills.
    static func usageFill(_ pct: Double) -> Color {
        if pct >= 90 { return claudeAlert }
        if pct >= 70 { return claudeAmber }
        return claudeClay
    }

    /// Scarf tint for the weekly cap: calm teal -> amber -> warning red past ~80%.
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
