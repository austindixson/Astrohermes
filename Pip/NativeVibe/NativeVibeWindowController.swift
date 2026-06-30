import AppKit
import SwiftUI

/// Hermes-spawnable native IDE window (separate from the floating mascot panel).
@MainActor
final class NativeVibeWindowController: NSWindowController {
    static let shared = NativeVibeWindowController()

    private let canvasStore = NativeVibeCanvasStore()
    private let voiceCoordinator = NativeVibeVoiceCoordinator()
    private var hostingView: NSHostingView<NativeVibeRootView>?
    private var resizeObserver: NSObjectProtocol?
    private var fullScreenObservers: [NSObjectProtocol] = []

    private init() {
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let width = min(1280, screen.width * 0.82)
        let height = min(860, screen.height * 0.82)
        let origin = NSPoint(
            x: screen.midX - width / 2,
            y: screen.midY - height / 2
        )

        let window = NSWindow(
            contentRect: NSRect(origin: origin, size: NSSize(width: width, height: height)),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "NativeVibe"
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.backgroundColor = NSColor(red: 0.06, green: 0.07, blue: 0.10, alpha: 1)
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.fullScreenPrimary, .managed]

        super.init(window: window)
        rebuildContent()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    var isOpen: Bool { window?.isVisible == true }

    func open() {
        if window == nil {
            rebuildContent()
        }
        if !NativeVibeRuntime.isStandalone {
            NSApp.setActivationPolicy(.regular)
        }
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        syncViewportFromWindow()
        canvasStore.statusMessage = "NativeVibe IDE ready"
    }

    func closeIDE() {
        window?.orderOut(nil)
        if !NativeVibeRuntime.isStandalone {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    func handleBridge(_ request: NativeVibeBridgeRequest) -> NativeVibeBridgeResponse {
        switch request.command {
        case .spawnWindow:
            open()
            canvasStore.statusMessage = "Window opened via bridge"
            return .success(id: request.id, message: "window_opened")

        case .closeWindow:
            closeIDE()
            canvasStore.statusMessage = "Window closed via bridge"
            return .success(id: request.id, message: "window_closed")

        case .addTile:
            let kind = NativeVibeTileKind(rawValue: request.payload["kind"] ?? "agent") ?? .agent
            let x = CGFloat(Double(request.payload["x"] ?? "120") ?? 120)
            let y = CGFloat(Double(request.payload["y"] ?? "120") ?? 120)
            let tile = canvasStore.addTile(
                kind: kind,
                at: CGPoint(x: x, y: y),
                title: request.payload["title"],
                workspacePath: request.payload["workspace"],
                url: request.payload["url"]
            )
            NativeVibeOrchestrator.shared.record(source: "bridge", action: "add_tile", tileID: tile.id)
            canvasStore.statusMessage = "Bridge added \(tile.title)"
            return .success(id: request.id, message: "tile_added", data: ["tile_id": tile.id.uuidString])

        case .removeTile:
            guard let idStr = request.payload["tile_id"], let id = UUID(uuidString: idStr) else {
                return .failure(id: request.id, message: "tile_id required")
            }
            canvasStore.removeTile(id: id)
            canvasStore.statusMessage = "Bridge removed tile"
            return .success(id: request.id, message: "tile_removed")

        case .focusTile:
            guard let idStr = request.payload["tile_id"], let id = UUID(uuidString: idStr) else {
                return .failure(id: request.id, message: "tile_id required")
            }
            canvasStore.bringToFront(id: id)
            canvasStore.statusMessage = "Bridge focused tile"
            return .success(id: request.id, message: "tile_focused")

        case .setCanvas:
            let panX = CGFloat(Double(request.payload["pan_x"] ?? "") ?? Double(canvasStore.document.panX))
            let panY = CGFloat(Double(request.payload["pan_y"] ?? "") ?? Double(canvasStore.document.panY))
            let zoom = CGFloat(Double(request.payload["zoom"] ?? "") ?? Double(canvasStore.document.zoom))
            canvasStore.setCanvas(
                pan: CGPoint(x: panX, y: panY),
                zoom: zoom,
                background: request.payload["background"]
            )
            canvasStore.statusMessage = "Canvas updated via bridge"
            return .success(id: request.id, message: "canvas_updated")

        case .writeTerminal:
            guard let text = request.payload["text"] else {
                return .failure(id: request.id, message: "text required")
            }
            var userInfo: [String: Any] = ["text": text]
            if let tileID = request.payload["tile_id"] ?? canvasStore.firstTile(kind: .terminal)?.id.uuidString {
                userInfo["tile_id"] = tileID
            }
            if let idStr = userInfo["tile_id"] as? String, let id = UUID(uuidString: idStr) {
                let cwd = canvasStore.tile(id: id)?.workspacePath
                NativeVibeTerminalHub.shared.write(tileID: id, text: text, workingDirectory: cwd)
                NativeVibeOrchestrator.shared.record(source: "bridge", action: "terminal_write", tileID: id, payload: ["text": String(text.prefix(80))])
            }
            canvasStore.statusMessage = "Terminal write: \(text.prefix(40))"
            return .success(id: request.id, message: "terminal_write_queued", data: ["tile_id": (userInfo["tile_id"] as? String) ?? ""])

        case .sendAgentMessage:
            guard let text = request.payload["text"] else {
                return .failure(id: request.id, message: "text required")
            }
            let tileID = request.payload["tile_id"] ?? canvasStore.firstTile(kind: .agent)?.id.uuidString
            guard let tileID, let id = UUID(uuidString: tileID), let tile = canvasStore.tile(id: id) else {
                return .failure(id: request.id, message: "no agent tile")
            }
            NativeVibeOrchestrator.shared.record(source: "bridge", action: "agent_send", tileID: id, payload: ["text": String(text.prefix(80))])
            NativeVibeAgentRunner.send(text: text, tileID: id, tile: tile) { [weak self] in
                self?.canvasStore.statusMessage = $0
            }
            return .success(id: request.id, message: "agent_message_queued", data: ["tile_id": tileID])

        case .memoryRetrieve:
            let query = request.payload["query"] ?? ""
            let hits = NativeVibeMemoryStore.shared.retrieveSync(query: query)
            NotificationCenter.default.post(
                name: .nativeVibeMemoryResults,
                object: nil,
                userInfo: ["query": query, "hits": hits]
            )
            var response = NativeVibeBridgeResponse.success(id: request.id, message: "memory_ok")
            response.data["count"] = String(hits.count)
            if let first = hits.first {
                response.data["top_excerpt"] = first.excerpt
                response.data["top_source"] = first.source
            }
            canvasStore.statusMessage = hits.isEmpty
                ? "Memory retrieved: 0 hits for \"\(query)\""
                : "Memory retrieved: \(hits.count) hit\(hits.count == 1 ? "" : "s")"
            return response

        case .voiceToggle:
            if request.payload["prefer_parakeet"] == "1" {
                voiceCoordinator.startListening(preferParakeet: true)
            } else {
                voiceCoordinator.toggleListening()
            }
            canvasStore.statusMessage = voiceCoordinator.isListening
                ? "\(voiceCoordinator.pathLabel): listening"
                : "Voice stopped"
            return .success(id: request.id, message: voiceCoordinator.isListening ? "voice_on" : "voice_off")

        case .ping:
            return .success(
                id: request.id,
                message: "pong",
                data: [
                    "open": isOpen ? "1" : "0",
                    "tile_count": String(canvasStore.document.tiles.count),
                    "action_count": String(NativeVibeOrchestrator.shared.recentActions(limit: 999).count),
                ]
            )

        case .updateTile:
            guard let idStr = request.payload["tile_id"], let id = UUID(uuidString: idStr) else {
                return .failure(id: request.id, message: "tile_id required")
            }
            canvasStore.updateTile(
                id: id,
                title: request.payload["title"],
                workspacePath: request.payload["workspace"],
                url: request.payload["url"]
            )
            return .success(id: request.id, message: "tile_updated")

        case .listTiles, .getCanvas:
            var response = NativeVibeBridgeResponse.success(id: request.id, message: "tiles_ok")
            response.data["tiles"] = NativeVibeOrchestrator.shared.tilesSummary(from: canvasStore)
            response.data["pan_x"] = String(describing: canvasStore.document.panX)
            response.data["pan_y"] = String(describing: canvasStore.document.panY)
            response.data["zoom"] = String(describing: canvasStore.document.zoom)
            return response

        case .getState:
            var response = NativeVibeBridgeResponse.success(id: request.id, message: "state_ok")
            response.data["tiles"] = NativeVibeOrchestrator.shared.tilesSummary(from: canvasStore)
            response.data["actions"] = NativeVibeOrchestrator.shared.actionsJSON(limit: 40)
            response.data["status"] = canvasStore.statusMessage
            response.data["focused_tile"] = canvasStore.focusedTileID?.uuidString ?? ""
            return response

        case .readTerminal:
            let tileID = request.payload["tile_id"].flatMap(UUID.init(uuidString:))
                ?? canvasStore.firstTile(kind: .terminal)?.id
            guard let tileID else {
                return .failure(id: request.id, message: "no terminal tile")
            }
            let maxChars = Int(request.payload["max_chars"] ?? "8000") ?? 8000
            let output = NativeVibeTerminalHub.shared.snapshot(tileID: tileID, maxChars: maxChars)
            var response = NativeVibeBridgeResponse.success(id: request.id, message: "terminal_ok")
            response.data["tile_id"] = tileID.uuidString
            response.data["output"] = output
            response.data["chars"] = String(output.count)
            return response

        case .readAgent:
            guard let idStr = request.payload["tile_id"], let id = UUID(uuidString: idStr) else {
                return .failure(id: request.id, message: "tile_id required")
            }
            var response = NativeVibeBridgeResponse.success(id: request.id, message: "agent_ok")
            response.data["messages"] = NativeVibeOrchestrator.shared.agentMessagesJSON(tileID: id)
            return response

        case .getActions:
            let limit = Int(request.payload["limit"] ?? "30") ?? 30
            var response = NativeVibeBridgeResponse.success(id: request.id, message: "actions_ok")
            response.data["actions"] = NativeVibeOrchestrator.shared.actionsJSON(limit: limit)
            return response

        case .setTileFrame:
            guard let idStr = request.payload["tile_id"], let id = UUID(uuidString: idStr) else {
                return .failure(id: request.id, message: "tile_id required")
            }
            guard let tile = canvasStore.tile(id: id) else {
                return .failure(id: request.id, message: "tile not found")
            }
            var frame = tile.frame
            if let v = request.payload["x"], let n = Double(v) { frame.x = CGFloat(n) }
            if let v = request.payload["y"], let n = Double(v) { frame.y = CGFloat(n) }
            if let v = request.payload["width"], let n = Double(v) { frame.width = CGFloat(n) }
            if let v = request.payload["height"], let n = Double(v) { frame.height = CGFloat(n) }
            canvasStore.updateTileFrame(id: id, frame: frame)
            NativeVibeOrchestrator.shared.record(source: "bridge", action: "set_tile_frame", tileID: id)
            return .success(id: request.id, message: "frame_updated")

        case .applyLayout:
            let presetName = request.payload["preset"] ?? "studio"
            guard let preset = NativeVibeLayoutPreset(rawValue: presetName) else {
                return .failure(id: request.id, message: "unknown preset: \(presetName)")
            }
            let tiles = NativeVibeLayoutEngine.apply(
                preset: preset,
                to: canvasStore,
                viewport: canvasStore.viewportSize,
                workspacePath: request.payload["workspace"]
            )
            var response = NativeVibeBridgeResponse.success(id: request.id, message: "layout_applied")
            response.data["preset"] = preset.rawValue
            response.data["tile_count"] = String(tiles.count)
            response.data["tiles"] = NativeVibeOrchestrator.shared.tilesSummary(from: canvasStore)
            return response

        case .navigateBrowser:
            guard let idStr = request.payload["tile_id"], let id = UUID(uuidString: idStr) else {
                return .failure(id: request.id, message: "tile_id required")
            }
            guard let url = request.payload["url"] else {
                return .failure(id: request.id, message: "url required")
            }
            canvasStore.updateTile(id: id, url: url)
            NativeVibeOrchestrator.shared.record(source: "bridge", action: "navigate_browser", tileID: id, payload: ["url": url])
            return .success(id: request.id, message: "browser_navigated")
        }
    }

    private func rebuildContent() {
        let root = NativeVibeRootView(store: canvasStore, voice: voiceCoordinator)
        let host = NSHostingView(rootView: root)
        host.frame = window?.contentView?.bounds ?? .zero
        host.autoresizingMask = [.width, .height]
        window?.contentView = host
        hostingView = host
        attachResizeObserver()
    }

    private func attachResizeObserver() {
        if let resizeObserver {
            NotificationCenter.default.removeObserver(resizeObserver)
        }
        for observer in fullScreenObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        fullScreenObservers.removeAll()

        guard let window else { return }
        resizeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResizeNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.syncViewportFromWindow() }
        }

        for notification in [
            NSWindow.didEnterFullScreenNotification,
            NSWindow.didExitFullScreenNotification,
            NSWindow.didChangeScreenNotification,
        ] {
            let observer = NotificationCenter.default.addObserver(
                forName: notification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.syncViewportFromWindow()
                    try? await Task.sleep(nanoseconds: 150_000_000)
                    self?.syncViewportFromWindow()
                }
            }
            fullScreenObservers.append(observer)
        }
    }

    private func syncViewportFromWindow() {
        guard let size = window?.contentView?.bounds.size, size.width > 0, size.height > 0 else { return }
        canvasStore.updateViewport(size)
    }
}

extension Notification.Name {
    static let nativeVibeTerminalWrite = Notification.Name("nativevibe.terminal.write")
}