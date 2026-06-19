import AppKit
import SwiftUI
import QuartzCore
import ServiceManagement
import ApplicationServices

/// Apps that make Pip jealous. Matched by bundle id (preferred) or, as a
/// fallback, a substring of the file / Dock-tile name. Add a rival here and
/// both trigger paths (Finder-drag onto Pip, cursor-over-Dock-icon) pick it up.
enum Rival {
    static let bundleIDs: Set<String> = ["com.openai.chat", "com.openai.codex"]
    static let nameNeedles = ["chatgpt", "codex"]

    static func matches(bundleID: String?) -> Bool {
        guard let id = bundleID else { return false }
        return bundleIDs.contains(id)
    }
    static func matches(name: String) -> Bool {
        let n = name.lowercased()
        return nameNeedles.contains { n.contains($0) }
    }
}

/// Borderless floating panel — can become key when the composer is active.
final class MascotPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if let responder = firstResponder, responder !== self, responder.performKeyEquivalent(with: event) {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// Passes mouse hits through to SwiftUI; transparent areas are click-through.
final class MascotContainerView: NSView {
    weak var controller: MascotController?

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let superview else { return nil }
        let p = convert(point, from: superview)
        guard bounds.contains(p) else { return nil }
        for subview in subviews.reversed() {
            let local = convert(p, to: subview)
            if let hit = subview.hitTest(local) { return hit }
        }
        return nil
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        if Self.draggingIsRival(sender) { controller?.rivalDraggedNear() }
        if controller?.isChatOpen == true, !Self.filePaths(from: sender).isEmpty { return .copy }
        return []
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        if Self.draggingIsRival(sender) { controller?.rivalDraggedNear() }
        if controller?.isChatOpen == true, !Self.filePaths(from: sender).isEmpty { return .copy }
        return []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard controller?.isChatOpen == true else { return false }
        let paths = Self.filePaths(from: sender)
        guard !paths.isEmpty else { return false }
        HermesChatClient.shared.adoptWorkspace(paths: paths)
        NotificationCenter.default.post(name: .pipFileDrop, object: paths)
        controller?.activateComposer()
        return true
    }

    static func filePaths(from sender: NSDraggingInfo) -> [String] {
        let opts: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        guard let urls = sender.draggingPasteboard
            .readObjects(forClasses: [NSURL.self], options: opts) as? [URL] else { return [] }
        return urls.map(\.path)
    }

    static func draggingIsRival(_ sender: NSDraggingInfo) -> Bool {
        let opts: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        guard let urls = sender.draggingPasteboard
            .readObjects(forClasses: [NSURL.self], options: opts) as? [URL] else { return false }
        return urls.contains { url in
            if Rival.matches(bundleID: Bundle(url: url)?.bundleIdentifier) { return true }
            return Rival.matches(name: url.lastPathComponent)
        }
    }
}

/// SwiftUI host that accepts first click without activating the app first.
final class InteractiveHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
}

/// Bridges onscreen-agent UI callbacks to MascotController without a retain cycle.
final class OnscreenAgentBridge: OnscreenAgentHandling {
    weak var controller: MascotController?

    func onscreenSend(_ text: String) { controller?.engine.sendChat(text) }
    func onscreenStopChat() { controller?.engine.stopChat() }
    func onscreenCloseChat() { controller?.toggleChat() }
    func onscreenExpandChat() { controller?.engine.expandChat(); controller?.resizeForChat(open: true) }
    func onscreenCollapseChat() { controller?.engine.collapseChat(); controller?.resizeForChat(open: true) }
    func onscreenComposerActivated() { controller?.activateComposer() }
    func onscreenAvatarHover(_ hovering: Bool) { controller?.engine.setAvatarHovered(hovering) }
    func onscreenAvatarDragBegan() { controller?.avatarDragBegan() }
    func onscreenAvatarDragChanged(translation: CGSize) { controller?.avatarDragChanged() }
    func onscreenAvatarDragEnded() { controller?.avatarDragEnded() }
}

final class MascotController: NSObject {

    static var windowSize: NSSize {
        SpaceAgentLayout.windowSize(chatOpen: false, mode: .compact)
    }

    private func currentWindowSize() -> NSSize {
        let pose = model.pose
        let compactLoading = pose.chatOpen
            && pose.chatDisplayMode == .compact
            && pose.chatLoading
            && (pose.compactAssistantText?.isEmpty ?? true)
        return SpaceAgentLayout.windowSize(
            chatOpen: pose.chatOpen,
            mode: pose.chatDisplayMode,
            compactAssistantText: pose.compactAssistantText,
            compactLoading: compactLoading,
            chatTraceActive: pose.chatTraceActive,
            composerTextHeight: composerTextHeight,
            uiBubblePhase: pose.uiBubblePhase
        )
    }

    fileprivate let engine: WalkEngine
    private let agentBridge = OnscreenAgentBridge()
    private let store: UsageStore
    private let poller: HermesStatsPoller
    private let panel: MascotPanel
    private let model = PoseModel()
    private var statusItem: NSStatusItem?
    private var displayLink: CADisplayLink?
    private var containerView: MascotContainerView!
    private var hostingView: InteractiveHostingView<MascotRootView>!
    private var tooltipTimer: Timer?
    private var rivalTimer: Timer?

    private var avatarDragActive = false
    private var composerTextHeight: CGFloat = SpaceAgentChatTokens.composerRowHeightCompact
    private var keyEventMonitor: Any?

    // Auto-hide Dock "platform": no API exposes its geometry, so estimate the
    // top edge above the bottom (≈ tilesize 57 + padding) and detect the reveal
    // from the cursor pressing the bottom edge. Tunable if his feet float/sink.
    static let dockTopFromBottom: CGFloat = 80
    private var dockRevealed = false

    init(store: UsageStore, poller: HermesStatsPoller) {
        self.store = store
        self.poller = poller

        panel = MascotPanel(
            contentRect: NSRect(origin: .zero, size: Self.windowSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        panel.ignoresMouseEvents = false  // interactive by default so Pip can be picked up; toggle click-through in the menu
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.isMovable = false           // dragging is handled manually
        panel.isReleasedWhenClosed = false
        // Set the level LAST — isFloatingPanel resets it to .floating, which is
        // below the Dock. Sit just above the Dock so Pip walks ON it, but below
        // the menu bar (24).
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)) + 1)

        engine = WalkEngine(store: store, model: model)
        engine.windowSize = Self.windowSize

        super.init()
        agentBridge.controller = self

        let container = MascotContainerView(frame: NSRect(origin: .zero, size: currentWindowSize()))
        container.controller = self
        container.registerForDraggedTypes([.fileURL])
        let hosting = InteractiveHostingView(rootView: MascotRootView(model: model, handler: agentBridge))
        hosting.frame = container.bounds
        hosting.autoresizingMask = [.width, .height]
        hosting.wantsLayer = true
        hosting.layer?.masksToBounds = false
        container.addSubview(hosting)
        container.wantsLayer = true
        container.layer?.masksToBounds = false
        panel.contentView = container
        containerView = container
        hostingView = hosting

        engine.visibleFrameProvider = { [weak self] in
            guard let self else { return .zero }
            let screen = self.panel.screen ?? NSScreen.main ?? NSScreen.screens.first
            return screen?.visibleFrame ?? .zero
        }
        engine.dockGroundProvider = { [weak self] in self?.revealedDockTopY() }
        engine.moveWindow = { [weak self] origin in
            self?.panel.setFrameOrigin(origin)
        }
        engine.physics.moveWindow = engine.moveWindow
        engine.physics.visibleFrameProvider = { [weak engine] in engine?.visibleFrameProvider?() ?? .zero }

        setUpStatusItem()

        NotificationCenter.default.addObserver(
            forName: .pipChatResize, object: nil, queue: .main) { [weak self] note in
            if let open = note.object as? Bool { self?.resizeForChat(open: open) }
        }
        NotificationCenter.default.addObserver(
            forName: .pipChatMode, object: nil, queue: .main) { [weak self] _ in
            self?.resizeForChat(open: true)
        }
        NotificationCenter.default.addObserver(
            forName: .pipComposerHeight, object: nil, queue: .main) { [weak self] note in
            guard let height = note.object as? CGFloat else { return }
            self?.composerTextHeight = height
            if self?.model.pose.chatOpen == true {
                self?.resizeForChat(open: false)
            }
        }

        keyEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.model.pose.chatOpen else { return event }
            guard event.modifierFlags.contains(.command),
                  let key = event.charactersIgnoringModifiers?.lowercased() else { return event }
            guard self.panel.isKeyWindow || self.panel.isMainWindow else { return event }

            switch key {
            case "v":
                if SpaceAgentComposerTextContainer.pasteIntoActiveComposer() { return nil }
            case "c":
                if SpaceAgentComposerTextContainer.copyFromActiveComposer() { return nil }
            case "x":
                if SpaceAgentComposerTextContainer.cutFromActiveComposer() { return nil }
            case "a":
                if SpaceAgentComposerTextContainer.selectAllInActiveComposer() { return nil }
            default:
                break
            }
            return event
        }
    }

    func activateComposer() {
        NSApp.activate(ignoringOtherApps: true)
        updateComposerEditingMode()
        panel.makeKeyAndOrderFront(nil)
        guard let composer = SpaceAgentComposerTextContainer.activeComposer else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.panel.makeFirstResponder(composer.textView)
            composer.isEditing = true
            composer.updatePlaceholderVisibility()
            composer.refreshInsertionPoint()
        }
    }

    private func updateComposerEditingMode() {
        if model.pose.chatOpen {
            panel.styleMask.remove(.nonactivatingPanel)
            panel.becomesKeyOnlyIfNeeded = false
        } else {
            if !panel.styleMask.contains(.nonactivatingPanel) {
                panel.styleMask.insert(.nonactivatingPanel)
            }
            panel.becomesKeyOnlyIfNeeded = true
        }
    }

    private func updateChatBubblePlacement() {
        guard let screen = panel.screen ?? NSScreen.main else { return }
        let vf = screen.visibleFrame
        let midY = panel.frame.midY
        let belowHead = midY > vf.minY + vf.height * 0.55
        var pose = model.pose
        if pose.chatBubbleBelowHead != belowHead {
            pose.chatBubbleBelowHead = belowHead
            model.pose = pose
        }
    }

    func show() {
        let screen = NSScreen.main ?? NSScreen.screens.first
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        panel.setFrameOrigin(engine.startPosition(in: visible))
        panel.orderFrontRegardless()
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)) + 1)  // above the Dock
        syncContentLayout()
        engine.physics.windowSize = currentWindowSize()

        if !model.pose.chatOpen {
            engine.toggleChat()
        }

        let link = panel.displayLink(target: engine, selector: #selector(WalkEngine.tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
        link.add(to: .main, forMode: .common)
        displayLink = link

        let t = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            self?.refreshTooltip()
        }
        RunLoop.main.add(t, forMode: .common)
        tooltipTimer = t
        refreshTooltip()

        // Fume whenever the cursor hovers the ChatGPT icon in the Dock. Requires
        // Accessibility — check silently; never auto-prompt on launch (rebuilt or
        // DerivedData binaries often differ from the app entry in System Settings).
        let trusted = AXIsProcessTrusted()
        let rt = Timer(timeInterval: 0.08, repeats: true) { [weak self] _ in
            self?.pollRivalHover()
        }
        RunLoop.main.add(rt, forMode: .common)
        rivalTimer = rt
        Self.dlog("=== Pip launched; rival hover poll started; accessibilityTrusted=\(trusted) ===")
    }

    private func refreshTooltip() {
        containerView.toolTip = store.hasFreshData
            ? nil
            : "start hermes gateway to wake me up"
    }

    // MARK: - Status bar item (always reachable, even with click-through on)

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "🧑‍🚀"
        item.button?.toolTip = mascotName
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
    }

    func showContextMenu(with event: NSEvent, in view: NSView) {
        let menu = NSMenu()
        populateMenu(menu)
        NSMenu.popUpContextMenu(menu, with: event, for: view)
    }

    private func populateMenu(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.autoenablesItems = false

        menu.addItem(headerItem())
        menu.addItem(.separator())

        // Primary action: Chat
        let chatItem = actionItem("💬 Chat with Hermes", action: #selector(openChat),
                                  symbol: "bubble.left.and.bubble.right.fill")
        chatItem.keyEquivalent = "k"
        chatItem.keyEquivalentModifierMask = .command
        menu.addItem(chatItem)
        menu.addItem(.separator())

        let goHome = actionItem("Go Home", action: #selector(goHome), symbol: "house.fill")
        goHome.isEnabled = !engine.isHomeOrHeading
        menu.addItem(goHome)

        menu.addItem(actionItem(
            engine.paused ? "Resume Roaming" : "Pause Roaming",
            action: #selector(togglePause),
            symbol: engine.paused ? "figure.walk" : "pause.fill"))

        let clickThrough = actionItem("Click-Through", action: #selector(toggleClickThrough),
                                      symbol: "cursorarrow.rays")
        clickThrough.state = panel.ignoresMouseEvents ? .on : .off
        menu.addItem(clickThrough)

        let pinMenu = NSMenu()
        pinMenu.autoenablesItems = false
        for (title, pin) in [("Bottom Left", WalkEngine.Pin.left),
                             ("Bottom Right", WalkEngine.Pin.right),
                             ("Unpinned (roam)", WalkEngine.Pin.none)] {
            let item = actionItem(title, action: #selector(setPin(_:)))
            item.tag = pin.rawValue
            item.state = engine.pin == pin ? .on : .off
            pinMenu.addItem(item)
        }
        let pinItem = actionItem("Pin to a Corner", action: nil, symbol: "pin.fill")
        pinItem.submenu = pinMenu
        menu.addItem(pinItem)

        let badge = actionItem("Show Usage Details", action: #selector(toggleBadge),
                               symbol: "chart.bar.fill")
        badge.state = engine.showBadgePersistent ? .on : .off
        menu.addItem(badge)

        if !AXIsProcessTrusted() {
            menu.addItem(actionItem(
                "Enable Dock Rival Detection…",
                action: #selector(requestAccessibilityAccess),
                symbol: "accessibility"
            ))
        }

        menu.addItem(.separator())
        menu.addItem(actionItem("Refresh Usage Now", action: #selector(refreshNow),
                                symbol: "arrow.clockwise"))

        menu.addItem(.separator())
        let login = actionItem("Launch at Login", action: #selector(toggleLaunchAtLogin),
                               symbol: "power")
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)

        menu.addItem(.separator())
        menu.addItem(actionItem("Quit \(mascotName)", action: #selector(quit), symbol: "xmark"))
    }

    /// Claude-themed status banner pinned to the top of the menu.
    private func headerItem() -> NSMenuItem {
        let updated = store.stats.lastUpdated > .distantPast
            ? "updated \(UsageStore.ago(store.stats.lastUpdated, from: Date())) · \(store.lastSource)"
            : ""
        let header = MenuHeaderView(mood: store.mood().rawValue,
                                    stats: store.usageStats(),
                                    note: store.badgeNote,
                                    updated: updated)
        let host = NSHostingView(rootView: header)
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        let item = NSMenuItem()
        item.view = host
        return item
    }

    private func actionItem(_ title: String, action: Selector?, symbol: String? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        if let symbol {
            let cfg = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(cfg)
        }
        return item
    }

    // MARK: - Menu actions

    func toggleChat() {
        engine.toggleChat()
    }

    var isChatOpen: Bool { model.pose.chatOpen }

    func toggleChatMode() {
        if model.pose.chatDisplayMode == .compact {
            engine.expandChat()
        } else {
            engine.collapseChat()
        }
        resizeForChat(open: true)
    }

    private func syncContentLayout() {
        guard let content = panel.contentView else { return }
        containerView.frame = content.bounds
        hostingView.frame = containerView.bounds
        engine.windowSize = NSSize(width: content.bounds.width, height: content.bounds.height)
        engine.physics.windowSize = engine.windowSize
    }

    fileprivate func resizeForChat(open: Bool) {
        updateChatBubblePlacement()
        updateComposerEditingMode()

        let target = currentWindowSize()
        var frame = panel.frame
        let sizeChanged = abs(frame.size.width - target.width) > 0.5
            || abs(frame.size.height - target.height) > 0.5
        frame.size = target
        // AppKit origin is bottom-left: keep origin.y fixed so the window grows
        // upward and the astronaut stays planted on screen.
        panel.setFrame(frame, display: true, animate: open && sizeChanged)
        syncContentLayout()
        engine.physics.windowSize = currentWindowSize()
        if let visible = (panel.screen ?? NSScreen.main)?.visibleFrame {
            engine.physics.syncFromWindow(in: visible)
        }
    }

    @objc private func togglePause() {
        engine.paused.toggle()
    }

    @objc private func goHome() {
        engine.goHome()
    }

    /// User-initiated only — avoids the system prompt on every launch.
    @objc private func requestAccessibilityAccess() {
        let axOpts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(axOpts)
    }

    // MARK: - Rival detection (cursor over the ChatGPT Dock icon → Pip gets mad)
    //
    // We locate the ChatGPT tile in the Dock via the Accessibility API, cache
    // its on-screen frame, and fume whenever the cursor is over it. Needs
    // Accessibility permission (prompted at launch); without it AX queries fail
    // and Pip simply never finds the icon.

    private var rivalIconFrame: CGRect?                       // ChatGPT Dock tile, AppKit (bottom-left) coords
    private var rivalFrameRefreshedAt: TimeInterval = 0
    private var rivalIconLogged = false

    /// Easter egg entry point: a rival app icon was dragged over Pip's window.
    /// Provoke him. Throttled-logged so the drag stream stays quiet.
    private var rivalDragLogged = false
    func rivalDraggedNear() {
        if !rivalDragLogged { rivalDragLogged = true; Self.dlog("rival icon dragged near Pip → fuming") }
        engine.provokeByRival()
    }

    private func pollRivalHover() {
        let now = CACurrentMediaTime()
        // The tile only moves when the Dock changes (app opens/closes, resize),
        // so relocating once every ~1.5s is plenty; the hover test is cheap.
        if rivalIconFrame == nil || now - rivalFrameRefreshedAt > 1.5 {
            rivalFrameRefreshedAt = now
            rivalIconFrame = locateRivalDockIcon()
            if let f = rivalIconFrame, !rivalIconLogged {
                rivalIconLogged = true
                Self.dlog("ChatGPT Dock icon located at \(f)")
            }
        }
        guard let frame = rivalIconFrame else { return }
        if frame.contains(NSEvent.mouseLocation) { engine.provokeByRival() }
    }

    /// Walks the Dock's Accessibility tree for a rival tile (ChatGPT, Codex) and
    /// returns its frame in AppKit (bottom-left origin) screen coordinates, or nil.
    private func locateRivalDockIcon() -> CGRect? {
        guard AXIsProcessTrusted() else { return nil }
        guard let dock = NSRunningApplication
                .runningApplications(withBundleIdentifier: "com.apple.dock").first else { return nil }
        let app = AXUIElementCreateApplication(dock.processIdentifier)
        guard let el = findRivalElement(in: app, depth: 0), let cg = axFrame(of: el) else { return nil }
        // AX positions are top-left origin (Quartz global); flip to AppKit's
        // bottom-left using the primary screen's height.
        let primaryH = (NSScreen.screens.first { $0.frame.origin == .zero } ?? NSScreen.main)?
            .frame.height ?? cg.maxY
        return CGRect(x: cg.minX, y: primaryH - cg.maxY, width: cg.width, height: cg.height)
    }

    private func findRivalElement(in el: AXUIElement, depth: Int) -> AXUIElement? {
        if depth > 4 { return nil }
        var titleRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(el, kAXTitleAttribute as CFString, &titleRef) == .success,
           let title = titleRef as? String, Rival.matches(name: title) {
            return el
        }
        var childrenRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &childrenRef) == .success,
              let children = childrenRef as? [AXUIElement] else { return nil }
        for child in children {
            if let found = findRivalElement(in: child, depth: depth + 1) { return found }
        }
        return nil
    }

    private func axFrame(of el: AXUIElement) -> CGRect? {
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &sizeRef) == .success
        else { return nil }
        var pos = CGPoint.zero, size = CGSize.zero
        AXValueGetValue(posRef as! AXValue, .cgPoint, &pos)
        AXValueGetValue(sizeRef as! AXValue, .cgSize, &size)
        return CGRect(origin: pos, size: size)
    }

    static func dlog(_ s: String) {
        let line = "\(Date()) \(s)\n"
        let url = URL(fileURLWithPath: "/tmp/pip_drag.log")
        if let fh = try? FileHandle(forWritingTo: url) { fh.seekToEndOfFile(); fh.write(Data(line.utf8)); try? fh.close() }
        else { try? line.write(to: url, atomically: true, encoding: .utf8) }
    }

    /// Top edge (AppKit y) of the revealed bottom Dock to stand on, or nil.
    private func revealedDockTopY() -> CGFloat? {
        guard let screen = panel.screen ?? NSScreen.main ?? NSScreen.screens.first else { return nil }
        let f = screen.frame, vf = screen.visibleFrame
        // A persistent bottom Dock already reserves space (visibleFrame excludes
        // it), so he stands on it for free — nothing to add here.
        guard vf.minY <= f.minY + 1 else { return nil }
        // Auto-hide: reveal when the cursor presses the very bottom edge; hide
        // once it climbs back above the Dock band. (Hysteresis so it's stable.)
        let m = NSEvent.mouseLocation
        let inX = m.x >= f.minX && m.x <= f.maxX
        if inX, m.y <= f.minY + 2 {
            dockRevealed = true
        } else if !inX || m.y > f.minY + Self.dockTopFromBottom + 16 {
            dockRevealed = false
        }
        return dockRevealed ? f.minY + Self.dockTopFromBottom : nil
    }

    @objc private func toggleClickThrough() {
        panel.ignoresMouseEvents.toggle()
    }

    @objc private func openChat() {
        engine.toggleChat()
    }

    @objc private func setPin(_ sender: NSMenuItem) {
        engine.pin = WalkEngine.Pin(rawValue: sender.tag) ?? .none
    }

    @objc private func toggleBadge() {
        engine.showBadgePersistent.toggle()
    }

    @objc private func cycleAppearance() {
        engine.cycleAppearance()
    }

    @objc private func refreshNow() {
        poller.pollNow()
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = "Couldn't change Launch at Login"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            alert.runModal()
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: - Avatar dragging (Space Agent shell)

    func avatarDragBegan() {
        if model.pose.bubbleText != nil { engine.dismissBubble() }
        if let visible = engine.physics.visibleFrameProvider?() {
            engine.physics.syncFromWindow(in: visible)
        }
        engine.physics.beginDrag(mouse: NSEvent.mouseLocation)
    }

    func avatarDragChanged() {
        engine.physics.updateDrag(mouse: NSEvent.mouseLocation)
    }

    func avatarDragEnded() {
        let result = engine.physics.endDrag()
        if result.tappedHiddenEdge, let visible = engine.physics.visibleFrameProvider?() {
            engine.physics.revealHiddenEdge(in: visible)
            activateComposer()
        } else if result.tappedAvatar {
            if model.pose.chatOpen {
                toggleChatMode()
            } else {
                engine.toggleChat()
            }
        }
    }
}

extension MascotController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        populateMenu(menu)
    }
}
