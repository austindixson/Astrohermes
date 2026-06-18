import Foundation

/// Hermes agent activity snapshot — replaces Claude quota model.
struct HermesStats {
    var gatewayRunning: Bool = false
    var hermesRunning: Bool = false
    var activeSessions: Int = 0
    var toolCallsRecent: Int = 0
    var skillsCount: Int = 0
    var memoryPct: Double = 0
    var userProfilePct: Double = 0
    var cronJobsActive: Int = 0
    var lastSessionSecondsAgo: Double = 999999
    var lastUpdated: Date = .distantPast
}
