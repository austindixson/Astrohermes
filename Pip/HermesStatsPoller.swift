import Foundation

/// Polls the local Hermes stats script every 30 seconds. No API keys, no network
/// — just a shell script that reads state.db and config.
final class HermesStatsPoller {

    var pollInterval: TimeInterval = 30

    private let store: UsageStore
    private let workQueue = DispatchQueue(label: "pip.hermes-poller", qos: .utility)
    private var timer: Timer?
    private let scriptPath: String

    init(store: UsageStore) {
        self.store = store
        self.scriptPath = (NSHomeDirectory() as NSString)
            .appendingPathComponent(".hermes/pip-hermes-stats.sh")
    }

    func start() {
        pollNow()
        let t = Timer(timeInterval: pollInterval, repeats: true) { [weak self] _ in
            self?.pollNow()
        }
        t.tolerance = 5
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func pollNow() {
        workQueue.async { [weak self] in self?.poll() }
    }

    private func poll() {
        guard FileManager.default.isExecutableFile(atPath: scriptPath) else {
            onMain { store in
                store.markTokenAvailable(false)
                store.noteError("hermes stats script not found at \(self.scriptPath)")
            }
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [scriptPath]
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err

        do {
            try process.run()
        } catch {
            onMain { store in store.noteError("failed to run stats script: \(error.localizedDescription)") }
            return
        }
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let errStr = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "unknown"
            onMain { store in store.noteError("stats script exit \(process.terminationStatus): \(errStr)") }
            return
        }

        let data = out.fileHandleForReading.readDataToEndOfFile()
        guard let json = String(data: data, encoding: .utf8),
              let stats = parseStats(json) else {
            onMain { store in store.noteError("malformed stats output") }
            return
        }

        onMain { store in store.ingestHermes(stats) }
    }

    private func parseStats(_ json: String) -> HermesStats? {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        var stats = HermesStats()
        stats.gatewayRunning     = obj["gateway_running"] as? Bool ?? false
        stats.hermesRunning      = obj["hermes_running"] as? Bool ?? false
        stats.activeSessions     = obj["active_sessions"] as? Int ?? 0
        stats.toolCallsRecent    = obj["tool_calls_recent"] as? Int ?? 0
        stats.skillsCount        = obj["skills_count"] as? Int ?? 0
        stats.memoryPct          = obj["memory_pct"] as? Double ?? 0
        stats.userProfilePct     = obj["user_profile_pct"] as? Double ?? 0
        stats.cronJobsActive     = obj["cron_jobs_active"] as? Int ?? 0
        stats.lastSessionSecondsAgo = obj["last_session_seconds_ago"] as? Double ?? 999999
        stats.lastUpdated = Date()
        return stats
    }

    private func onMain(_ body: @escaping (UsageStore) -> Void) {
        let store = self.store
        DispatchQueue.main.async { body(store) }
    }
}
