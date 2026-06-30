import SwiftUI
import AppKit
import SwiftTerm

/// Routes terminal writes/readback even when SwiftUI has not mounted the NSView yet.
@MainActor
final class NativeVibeTerminalHub {
    static let shared = NativeVibeTerminalHub()

    private struct WeakView {
        weak var view: OrchestratedTerminalView?
    }

    private var views: [UUID: WeakView] = [:]
    private var headlessSessions: [UUID: NativeVibePTYSession] = [:]
    private var pendingInput: [UUID: [String]] = [:]
    private var workingDirectories: [UUID: String] = [:]

    func register(_ view: OrchestratedTerminalView) {
        views[view.tileID] = WeakView(view: view)
        headlessSessions.removeValue(forKey: view.tileID)
        flushPending(tileID: view.tileID, into: view)
    }

    func unregister(tileID: UUID) {
        views.removeValue(forKey: tileID)
    }

    func write(tileID: UUID, text: String, workingDirectory: String? = nil) {
        if let workingDirectory {
            workingDirectories[tileID] = workingDirectory
        }
        let payload = text.hasSuffix("\n") ? text : text + "\n"
        if let view = views[tileID]?.view {
            deliver(payload, to: view)
            return
        }
        let session = headlessSession(for: tileID)
        session.sendInput(payload)
        syncHeadlessOutput(tileID: tileID, session: session)
    }

    func snapshot(tileID: UUID, maxChars: Int = 8_000) -> String {
        if let view = views[tileID]?.view {
            return view.snapshot(maxChars: maxChars)
        }
        if let session = headlessSessions[tileID] {
            syncHeadlessOutput(tileID: tileID, session: session)
        }
        return NativeVibeOrchestrator.shared.terminalSnapshot(tileID: tileID, maxChars: maxChars)
    }

    func stopHeadless(tileID: UUID) {
        headlessSessions.removeValue(forKey: tileID)?.stop()
    }

    private func flushPending(tileID: UUID, into view: OrchestratedTerminalView) {
        guard let queued = pendingInput.removeValue(forKey: tileID) else { return }
        for payload in queued {
            deliver(payload, to: view)
        }
    }

    private func deliver(_ payload: String, to view: OrchestratedTerminalView) {
        guard let data = payload.data(using: .utf8) else { return }
        view.send(source: view, data: ArraySlice(Array(data)))
    }

    private func headlessSession(for tileID: UUID) -> NativeVibePTYSession {
        if let session = headlessSessions[tileID] {
            return session
        }
        let session = NativeVibePTYSession()
        session.start(workingDirectory: workingDirectories[tileID])
        headlessSessions[tileID] = session
        NativeVibeOrchestrator.shared.record(source: "terminal", action: "start_headless", tileID: tileID)
        return session
    }

    private func syncHeadlessOutput(tileID: UUID, session: NativeVibePTYSession) {
        NativeVibeOrchestrator.shared.setTerminalSnapshot(tileID: tileID, text: session.output)
    }
}

/// Terminal tile with orchestrator-backed output capture + buffer readback.
struct NativeVibeSwiftTermView: NSViewRepresentable {
    let tileID: UUID
    let workingDirectory: String?

    func makeCoordinator() -> Coordinator {
        Coordinator(tileID: tileID)
    }

    func makeNSView(context: Context) -> OrchestratedTerminalView {
        let view = OrchestratedTerminalView(tileID: tileID)
        view.configureNativeVibeAppearance()
        context.coordinator.attach(view)
        let cwd = workingDirectory.flatMap { path in
            FileManager.default.fileExists(atPath: path) ? path : nil
        }
        view.startProcess(executable: "/bin/zsh", args: ["-l"], currentDirectory: cwd)
        NativeVibeTerminalHub.shared.register(view)
        NativeVibeOrchestrator.shared.record(source: "terminal", action: "start", tileID: tileID)
        return view
    }

    func updateNSView(_ nsView: OrchestratedTerminalView, context: Context) {}

    static func dismantleNSView(_ nsView: OrchestratedTerminalView, coordinator: Coordinator) {
        NativeVibeTerminalHub.shared.unregister(tileID: nsView.tileID)
    }

    final class Coordinator {
        let tileID: UUID
        private var writeObserver: NSObjectProtocol?

        init(tileID: UUID) {
            self.tileID = tileID
        }

        func attach(_ view: OrchestratedTerminalView) {
            writeObserver = NotificationCenter.default.addObserver(
                forName: .nativeVibeTerminalWrite,
                object: nil,
                queue: .main
            ) { [weak self, weak view] note in
                guard let self, let view else { return }
                if let target = note.userInfo?["tile_id"] as? String,
                   target != self.tileID.uuidString {
                    return
                }
                guard let text = note.userInfo?["text"] as? String else { return }
                NativeVibeTerminalHub.shared.write(tileID: self.tileID, text: text)
                NativeVibeOrchestrator.shared.record(
                    source: "bridge",
                    action: "terminal_write",
                    tileID: self.tileID,
                    payload: ["text": String(text.prefix(80))]
                )
            }
        }

        deinit {
            if let writeObserver { NotificationCenter.default.removeObserver(writeObserver) }
        }
    }
}

final class OrchestratedTerminalView: LocalProcessTerminalView {
    let tileID: UUID

    init(tileID: UUID) {
        self.tileID = tileID
        super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func dataReceived(slice: ArraySlice<UInt8>) {
        super.dataReceived(slice: slice)
        let chunk = String(decoding: slice, as: UTF8.self)
        NativeVibeOrchestrator.shared.appendTerminalOutput(tileID: tileID, chunk: chunk)
    }

    func snapshot(maxChars: Int = 8_000) -> String {
        let buffer = String(data: getTerminal().getBufferAsData(), encoding: .utf8) ?? ""
        NativeVibeOrchestrator.shared.setTerminalSnapshot(tileID: tileID, text: buffer)
        return String(buffer.suffix(maxChars))
    }
}

private extension LocalProcessTerminalView {
    func configureNativeVibeAppearance() {
        nativeForegroundColor = NSColor(red: 0.78, green: 0.92, blue: 0.78, alpha: 1)
        nativeBackgroundColor = NSColor(red: 0.04, green: 0.05, blue: 0.07, alpha: 1)
    }
}