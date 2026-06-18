import Foundation
import Observation

private func clamp(_ x: Double, _ lo: Double, _ hi: Double) -> Double { min(hi, max(lo, x)) }

/// One meter for the hover card.
struct UsageStat: Equatable {
    var label: String
    var pct: Double
    var detail: String
}

/// Canonical Hermes state, source-agnostic.
@Observable
final class UsageStore {
    private(set) var stats = HermesStats()
    private(set) var tokenAvailable = false
    private(set) var lastSource = "none"
    private(set) var lastError: String?

    static let staleAfter: TimeInterval = 3 * 3600

    func ingestHermes(_ incoming: HermesStats) {
        guard incoming.lastUpdated >= stats.lastUpdated else { return }
        stats = incoming
        tokenAvailable = incoming.hermesRunning || incoming.gatewayRunning
        lastSource = "hermes"
        lastError = nil
    }

    func markTokenAvailable(_ ok: Bool) { tokenAvailable = ok }
    func noteError(_ message: String) { lastError = message }

    var hasFreshData: Bool {
        tokenAvailable
            && Date().timeIntervalSince(stats.lastUpdated) < Self.staleAfter
    }

    // MARK: - Hermes Mood

    /// Activity score 0–100 — balanced blend of session count and tool call volume.
    /// Sessions are capped at 5 pts each (max 10 sessions → 50 pts). Tool calls
    /// contribute 1 pt per 20 calls (max 1000 calls → 50 pts). This keeps the meter
    /// meaningful: casual use lands at 10–30, heavy at 50–80, and only truly extreme
    /// loads hit 90+.
    func activityScore() -> Double {
        let s = min(10, Double(stats.activeSessions))
        let t = min(1000, Double(stats.toolCallsRecent))
        return min(100, s * 5 + t / 20)
    }

    func mood(now: Date = Date()) -> Mood {
        guard hasFreshData else { return .sleepy }
        if !stats.hermesRunning && !stats.gatewayRunning { return .sleepy }

        let score = activityScore()
        let memPct = max(stats.memoryPct, stats.userProfilePct)

        // Memory critical: worried overrides everything
        if memPct >= 90 { return .worried }

        // Very busy
        if score >= 60 { return .focused }

        // Memory getting tight
        if memPct >= 80 { return .antsy }

        // Moderately active
        if score >= 20 { return .happy }

        // Kicking but not much happening
        if score > 0 || stats.lastSessionSecondsAgo < 600 { return .happy }

        // Idle — Hermes is running but nothing recent
        return .antsy
    }

    // MARK: - Display strings

    func detailLines(now: Date = Date()) -> [String] {
        var lines: [String] = []
        if stats.gatewayRunning {
            lines.append("⚡ gateway up")
        } else if stats.hermesRunning {
            lines.append("🐚 hermes running")
        } else {
            lines.append("💤 hermes is sleeping")
        }
        lines.append("📊 \(stats.activeSessions) sessions · \(stats.toolCallsRecent) tool calls (1h)")
        lines.append("🧠 skills: \(stats.skillsCount) · memory: \(Int(stats.memoryPct))%")
        if stats.cronJobsActive > 0 {
            lines.append("⏰ \(stats.cronJobsActive) cron jobs")
        }
        return lines
    }

    func usageStats(now: Date = Date()) -> [UsageStat] {
        var out: [UsageStat] = []
        out.append(UsageStat(label: "activity", pct: activityScore(),
            detail: "\(stats.activeSessions) sessions · \(stats.toolCallsRecent) calls"))
        out.append(UsageStat(label: "memory", pct: max(stats.memoryPct, stats.userProfilePct),
            detail: "skills: \(stats.skillsCount) · profile: \(Int(stats.userProfilePct))%"))
        return out
    }

    var badgeNote: String? {
        guard hasFreshData else {
            return "hermes is sleeping — start the gateway to wake me up"
        }
        return nil
    }

    func statusLine(now: Date = Date()) -> String {
        var s = "mood: \(mood(now: now).rawValue)"
        s += " · activity: \(Int(activityScore()))%"
        if stats.lastUpdated > .distantPast {
            s += " · updated \(Self.ago(stats.lastUpdated, from: now))"
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
