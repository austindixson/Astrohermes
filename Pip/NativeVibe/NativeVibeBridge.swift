import Foundation

/// File-based bidirectional control for Hermes CLI / MCP companions.
/// Commands: ~/.nativevibe/bridge/inbox/<id>.json
/// Responses: ~/.nativevibe/bridge/outbox/<id>.json
@MainActor
final class NativeVibeBridge {
    static let shared = NativeVibeBridge()

    private let inbox: URL
    private let outbox: URL
    private var pollTimer: Timer?
    private var seen = Set<String>()

    private init() {
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".nativevibe/bridge")
        inbox = base.appendingPathComponent("inbox")
        outbox = base.appendingPathComponent("outbox")
        try? FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: outbox, withIntermediateDirectories: true)
    }

    func start() {
        pollTimer?.invalidate()
        let timer = Timer(timeInterval: 0.15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.pollInbox() }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func pollInbox() {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: inbox,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let name = file.lastPathComponent
            guard name.hasSuffix(".json"), !seen.contains(name) else { continue }
            seen.insert(name)
            handle(file: file)
        }
    }

    private func handle(file: URL) {
        defer { try? FileManager.default.removeItem(at: file) }

        let requestID = file.deletingPathExtension().lastPathComponent
        guard let data = try? Data(contentsOf: file) else {
            writeResponse(.failure(id: requestID, message: "unreadable_request"), id: requestID)
            return
        }
        guard let request = try? JSONDecoder().decode(NativeVibeBridgeRequest.self, from: data) else {
            writeResponse(.failure(id: requestID, message: "invalid_request_json"), id: requestID)
            return
        }

        let response = NativeVibeWindowController.shared.handleBridge(request)
        writeResponse(response, id: request.id)
    }

    private func writeResponse(_ response: NativeVibeBridgeResponse, id: String) {
        let outURL = outbox.appendingPathComponent("\(id).json")
        if let encoded = try? JSONEncoder().encode(response) {
            try? encoded.write(to: outURL, options: .atomic)
        }
    }
}