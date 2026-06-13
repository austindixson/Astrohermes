import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var store: UsageStore?
    private var poller: OAuthUsagePoller?
    private var bridge: StatuslineBridge?
    private var controller: MascotController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let store = UsageStore()
        let poller = OAuthUsagePoller(store: store)
        let bridge = StatuslineBridge(store: store)
        let controller = MascotController(store: store, poller: poller, bridge: bridge)

        self.store = store
        self.poller = poller
        self.bridge = bridge
        self.controller = controller

        // Debug hook: PIP_FAKE_USAGE="usedPct:minutesUntilReset" forces a
        // synthetic 5-hour window (and skips the live sources so it sticks),
        // e.g. PIP_FAKE_USAGE="5:120" to rehearse the mad/fuming behavior.
        if let fake = ProcessInfo.processInfo.environment["PIP_FAKE_USAGE"] {
            let p = fake.split(separator: ":")
            if p.count == 2, let used = Double(p[0]), let mins = Double(p[1]) {
                var snap = UsageSnapshot()
                snap.fiveHourUsedPct = used
                snap.fiveHourResetsAt = Date().addingTimeInterval(mins * 60)
                snap.weeklyUsedPct = 35
                snap.weeklyResetsAt = Date().addingTimeInterval(3 * 86400)
                snap.lastUpdated = Date()
                store.markTokenAvailable(true)
                store.ingest(snap, source: "fake")
                controller.show()
                return                                   // don't start live pollers
            }
        }

        poller.start()
        bridge.start()
        controller.show()
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }
}
