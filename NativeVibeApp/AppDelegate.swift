import AppKit

final class NativeVibeAppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.installHermesPlugin()
        Self.installBridgeScripts()
        NativeVibeBridge.shared.start()
        setUpStatusItem()
        Task { @MainActor in
            NativeVibeWindowController.shared.open()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "NV"
        item.button?.toolTip = "NativeVibe"
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Open Canvas", action: #selector(openIDE), keyEquivalent: "o"))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit NativeVibe", action: #selector(quit), keyEquivalent: "q"))
        for entry in menu.items {
            entry.target = self
        }
        item.menu = menu
        statusItem = item
    }

    @objc private func openIDE() {
        Task { @MainActor in
            NativeVibeWindowController.shared.open()
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private static func installBridgeScripts() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let repo = home.appendingPathComponent("Desktop/pip-mascot/scripts")
        let pairs: [(String, String)] = [
            ("nativevibe-bridge.py", ".hermes/nativevibe-bridge.py"),
            ("parakeet-transcribe.py", ".hermes/parakeet-transcribe.py"),
        ]
        for (name, destRel) in pairs {
            let source = repo.appendingPathComponent(name)
            let dest = home.appendingPathComponent(destRel)
            guard FileManager.default.fileExists(atPath: source.path) else { continue }
            try? FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: dest)
            try? FileManager.default.copyItem(at: source, to: dest)
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dest.path)
        }
    }

    private static func installHermesPlugin() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let source = home.appendingPathComponent("Desktop/pip-mascot/hermes-plugin/nativevibe")
        let dest = home.appendingPathComponent(".hermes/plugins/nativevibe")
        guard FileManager.default.fileExists(atPath: source.path) else { return }
        try? FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: dest.path) {
            try? FileManager.default.removeItem(at: dest)
        }
        try? FileManager.default.copyItem(at: source, to: dest)
        enablePluginInConfig()
    }

    private static func enablePluginInConfig() {
        let config = homeDirectoryConfig()
        guard var text = try? String(contentsOf: config, encoding: .utf8) else { return }
        if text.contains("nativevibe") { return }
        if text.contains("plugins:\n  enabled:") {
            text = text.replacingOccurrences(of: "plugins:\n  enabled: []", with: "plugins:\n  enabled:\n  - nativevibe")
        } else if text.contains("enabled: []") {
            text = text.replacingOccurrences(of: "enabled: []", with: "enabled:\n  - nativevibe")
        } else {
            text += "\nplugins:\n  enabled:\n  - nativevibe\n"
        }
        if !text.contains("known_plugin_toolsets:") {
            text += "known_plugin_toolsets:\n  cli:\n  - nativevibe\n"
        } else if !text.contains("- nativevibe") {
            text = text.replacingOccurrences(
                of: "known_plugin_toolsets:\n  cli:\n  - spotify",
                with: "known_plugin_toolsets:\n  cli:\n  - spotify\n  - nativevibe"
            )
        }
        try? text.write(to: config, atomically: true, encoding: .utf8)
    }

    private static func homeDirectoryConfig() -> URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".hermes/config.yaml")
    }
}