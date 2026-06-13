import Foundation
import Observation

private func clamp(_ x: Double, _ lo: Double, _ hi: Double) -> Double { min(hi, max(lo, x)) }
private func smoothstep(_ x: Double, _ a: Double, _ b: Double) -> Double {
    guard b > a else { return x < a ? 0 : 1 }
    let t = clamp((x - a) / (b - a), 0, 1)
    return t * t * (3 - 2 * t)
}

/// One usage meter for the hover card (5-hour window or 7-day cap).
struct UsageStat: Equatable {
    var label: String     // "5h", "7d"
    var pct: Double       // 0–100
    var resets: String    // "47m", "6d 11h"
}

/// Canonical, source-agnostic usage model. All percentages are 0–100.
struct UsageSnapshot {
    var fiveHourUsedPct: Double?
    var fiveHourResetsAt: Date?
    var weeklyUsedPct: Double?
    var weeklyResetsAt: Date?
    var lastUpdated: Date = .distantPast
}

/// Merges samples from the OAuth poller and the statusline bridge, always
/// preferring the freshest one. A failed poll never blanks anything — the last
/// good snapshot is kept until something newer arrives.
///
/// All mutation happens on the main queue (both sources dispatch to main).
@Observable
final class UsageStore {
    private(set) var snapshot = UsageSnapshot()
    private(set) var tokenAvailable = false
    private(set) var lastSource = "none"
    private(set) var lastError: String?

    /// Data older than this counts as unknown -> SLEEPY.
    static let staleAfter: TimeInterval = 3 * 3600

    func ingest(_ incoming: UsageSnapshot, source: String) {
        guard incoming.lastUpdated >= snapshot.lastUpdated else { return }
        var merged = snapshot
        if let v = incoming.fiveHourUsedPct { merged.fiveHourUsedPct = v }
        if let v = incoming.fiveHourResetsAt { merged.fiveHourResetsAt = v }
        if let v = incoming.weeklyUsedPct { merged.weeklyUsedPct = v }
        if let v = incoming.weeklyResetsAt { merged.weeklyResetsAt = v }
        merged.lastUpdated = incoming.lastUpdated
        snapshot = merged
        lastSource = source
        lastError = nil
    }

    func markTokenAvailable(_ ok: Bool) { tokenAvailable = ok }
    func noteError(_ message: String) { lastError = message }

    var hasFreshData: Bool {
        snapshot.fiveHourUsedPct != nil
            && Date().timeIntervalSince(snapshot.lastUpdated) < Self.staleAfter
    }

    // MARK: - Mood (pace delta, not a countdown)

    /// How far ahead of (+) or behind (−) the "spend it evenly" line we are.
    /// nil when the 5-hour window state is unknown.
    func paceDelta(now: Date = Date()) -> Double? {
        guard hasFreshData,
              let used = snapshot.fiveHourUsedPct,
              let resetsAt = snapshot.fiveHourResetsAt else { return nil }
        let windowLen: TimeInterval = 5 * 3600
        let start = resetsAt.timeIntervalSince1970 - windowLen
        let elapsedFrac = min(1, max(0, (now.timeIntervalSince1970 - start) / windowLen))
        return used / 100 - elapsedFrac
    }

    /// Fraction [0,1] of the current 5-hour window that has elapsed.
    private func elapsedFrac(now: Date) -> Double? {
        guard let resetsAt = snapshot.fiveHourResetsAt else { return nil }
        let windowLen: TimeInterval = 5 * 3600
        let start = resetsAt.timeIntervalSince1970 - windowLen
        return min(1, max(0, (now.timeIntervalSince1970 - start) / windowLen))
    }

    /// If usage keeps the current pace, what % of the 5-hour budget will be
    /// spent by the time it resets? (Linear extrapolation; nil if unknown or
    /// too early in the window to be meaningful.)
    func projectedFinalPct(now: Date = Date()) -> Double? {
        guard hasFreshData, let used = snapshot.fiveHourUsedPct,
              let e = elapsedFrac(now: now), e > 0.02 else { return nil }
        return min(200, used / e)
    }

    /// How annoyed Pip should be that the window will go under-used, 0…1.
    /// Zero until we're far enough into the window to judge; ramps up the
    /// further the projected finish falls below "basically used it all".
    /// Returns 0 once usage is healthy or already near the cap (that's worry,
    /// not anger).
    func angerLevel(now: Date = Date()) -> Double {
        guard let used = snapshot.fiveHourUsedPct, used < 90,
              let e = elapsedFrac(now: now),
              let projected = projectedFinalPct(now: now) else { return 0 }
        // Confidence: a quiet first half-hour is normal, so don't judge before
        // ~30% in; trust the projection fully past ~55%.
        let confidence = smoothstep(e, 0.30, 0.55)
        // Waste: projected 90%+ is fine (0 anger); 30% projected is maximal.
        let waste = clamp((90 - projected) / 60, 0, 1)
        return confidence * waste
    }

    func mood(now: Date = Date()) -> Mood {
        guard hasFreshData, let used = snapshot.fiveHourUsedPct,
              let delta = paceDelta(now: now) else { return .sleepy }
        if used >= 90 { return .worried }
        if angerLevel(now: now) >= 0.40 { return .mad }   // confidently wasting the window
        if delta <= -0.25 { return .antsy }               // mildly behind
        if delta >= 0.10 { return .focused }
        return .happy
    }

    // MARK: - Display strings

    func detailLines(now: Date = Date()) -> [String] {
        var lines: [String] = []
        if let p = snapshot.fiveHourUsedPct {
            var s = "5h \(Int(p.rounded()))%"
            if let r = snapshot.fiveHourResetsAt { s += " · resets in \(Self.countdown(to: r, from: now))" }
            lines.append(s)
        }
        if let p = snapshot.weeklyUsedPct {
            var s = "7d \(Int(p.rounded()))%"
            if let r = snapshot.weeklyResetsAt { s += " · resets in \(Self.countdown(to: r, from: now))" }
            lines.append(s)
        }
        if lines.isEmpty {
            lines.append(tokenAvailable ? "no usage data yet" : "log into claude code to wake me up")
        }
        return lines
    }

    /// Structured meters for the hover card.
    func usageStats(now: Date = Date()) -> [UsageStat] {
        var out: [UsageStat] = []
        if let p = snapshot.fiveHourUsedPct {
            out.append(UsageStat(label: "5h", pct: p,
                resets: snapshot.fiveHourResetsAt.map { Self.countdown(to: $0, from: now) } ?? "—"))
        }
        if let p = snapshot.weeklyUsedPct {
            out.append(UsageStat(label: "7d", pct: p,
                resets: snapshot.weeklyResetsAt.map { Self.countdown(to: $0, from: now) } ?? "—"))
        }
        return out
    }

    /// Fallback line for the hover card when there are no meters yet.
    var badgeNote: String? {
        snapshot.fiveHourUsedPct != nil ? nil
            : (tokenAvailable ? "no usage data yet" : "log into Claude Code to wake me up")
    }

    func statusLine(now: Date = Date()) -> String {
        var s = "mood: \(mood(now: now).rawValue)"
        if let delta = paceDelta(now: now) {
            s += String(format: " · pace %+.2f", delta)
        }
        if snapshot.lastUpdated > .distantPast {
            s += " · updated \(Self.ago(snapshot.lastUpdated, from: now)) via \(lastSource)"
        }
        return s
    }

    static func countdown(to date: Date, from now: Date) -> String {
        let s = max(0, Int(date.timeIntervalSince(now)))
        let d = s / 86400, h = (s % 86400) / 3600, m = (s % 3600) / 60
        if d > 0 { return "\(d)d \(h)h" }
        if h > 0 { return "\(h)h \(m)m" }
        return "\(m)m"
    }

    static func ago(_ date: Date, from now: Date) -> String {
        let s = max(0, Int(now.timeIntervalSince(date)))
        if s < 60 { return "\(s)s ago" }
        if s < 3600 { return "\(s / 60)m ago" }
        return "\(s / 3600)h ago"
    }
}
