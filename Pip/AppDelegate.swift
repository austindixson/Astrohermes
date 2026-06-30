import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var store: UsageStore?
    private var poller: HermesStatsPoller?
    private var controller: MascotController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let store = UsageStore()
        let poller = HermesStatsPoller(store: store)
        let controller = MascotController(store: store, poller: poller)

        self.store = store
        self.poller = poller
        self.controller = controller

        Self.installSlashCatalogScript()
        Self.installNativeVibeBridgeScript()
        Self.installNativeVibeHermesPlugin()
        Self.installParakeetScript()
        HermesSlashCatalog.shared.refreshIfNeeded(force: true)
        NativeVibeBridge.shared.start()

        // Debug hook: PIP_FAKE_USAGE="sessions:toolCalls:memoryPct" forces a
        // synthetic Hermes state, e.g. PIP_FAKE_USAGE="5:200:85"
        if let fake = ProcessInfo.processInfo.environment["PIP_FAKE_USAGE"] {
            let p = fake.split(separator: ":")
            if p.count == 3,
               let sessions = Int(p[0]),
               let toolCalls = Int(p[1]),
               let memPct = Double(p[2]) {
                var stats = HermesStats()
                stats.hermesRunning = true
                stats.gatewayRunning = true
                stats.activeSessions = sessions
                stats.toolCallsRecent = toolCalls
                stats.memoryPct = memPct
                stats.userProfilePct = memPct
                stats.skillsCount = 248
                stats.lastSessionSecondsAgo = 30
                stats.lastUpdated = Date()
                store.markTokenAvailable(true)
                store.ingestHermes(stats)
                controller.show()
                return
            }
        }

        poller.start()
        controller.show()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        controller?.retryRivalTimerAfterActivation()
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    private static func installParakeetScript() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dest = home.appendingPathComponent(".hermes/parakeet-transcribe.py")
        let source = home.appendingPathComponent("Desktop/pip-mascot/scripts/parakeet-transcribe.py")
        guard FileManager.default.fileExists(atPath: source.path) else { return }
        do {
            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.copyItem(at: source, to: dest)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dest.path)
        } catch {}
    }

    private static func installNativeVibeHermesPlugin() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let source = home.appendingPathComponent("Desktop/pip-mascot/hermes-plugin/nativevibe")
        let dest = home.appendingPathComponent(".hermes/plugins/nativevibe")
        guard FileManager.default.fileExists(atPath: source.path) else { return }
        do {
            try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.copyItem(at: source, to: dest)
        } catch {}
    }

    private static func installNativeVibeBridgeScript() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dest = home.appendingPathComponent(".hermes/nativevibe-bridge.py")
        let candidates = [
            home.appendingPathComponent("Desktop/pip-mascot/scripts/nativevibe-bridge.py"),
            Bundle.main.resourcePath.map { URL(fileURLWithPath: $0).appendingPathComponent("nativevibe-bridge.py") },
        ].compactMap { $0 }
        guard let source = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else { return }
        do {
            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.copyItem(at: source, to: dest)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dest.path)
        } catch {
            // Dev path still works from the repo scripts/ folder.
        }
    }

    private static func installSlashCatalogScript() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dest = home.appendingPathComponent(".hermes/pip-slash-catalog.py")
        let candidates = [
            home.appendingPathComponent("Desktop/pip-mascot/scripts/pip-slash-catalog.py"),
            Bundle.main.resourcePath.map { URL(fileURLWithPath: $0).appendingPathComponent("pip-slash-catalog.py") },
        ].compactMap { $0 }
        guard let source = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else { return }
        do {
            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.copyItem(at: source, to: dest)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dest.path)
        } catch {
            // Fall back to bundled/dev path resolution in HermesSlashCatalog.
        }
    }
}
