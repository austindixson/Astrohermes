import Foundation

/// Central observer for NativeVibe — records every action, terminal I/O, and agent messages.
/// Pushes events to `~/.nativevibe/bridge/events/` for Hermes/MCP subscribers.
@MainActor
final class NativeVibeOrchestrator {
    static let shared = NativeVibeOrchestrator()

    struct ActionEvent: Codable, Identifiable, Equatable {
        let id: String
        let timestamp: Date
        let source: String
        let action: String
        let tileID: String?
        let payload: [String: String]
    }

    struct AgentMessageRecord: Codable, Equatable {
        let text: String
        let isUser: Bool
        let timestamp: Date
    }

    private var actions: [ActionEvent] = []
    private var terminalOutput: [UUID: String] = [:]
    private var agentMessages: [UUID: [AgentMessageRecord]] = [:]
    private let eventsDir: URL
    private var eventSeq = 0
    private let maxActions = 500
    private let maxTerminalChars = 120_000
    private let maxAgentMessages = 200

    private init() {
        eventsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".nativevibe/bridge/events")
        try? FileManager.default.createDirectory(at: eventsDir, withIntermediateDirectories: true)
        eventSeq = (try? String(contentsOf: eventsDir.appendingPathComponent("seq.txt"), encoding: .utf8))
            .flatMap(Int.init) ?? 0
    }

    func record(
        source: String,
        action: String,
        tileID: UUID? = nil,
        payload: [String: String] = [:]
    ) {
        let event = ActionEvent(
            id: UUID().uuidString,
            timestamp: Date(),
            source: source,
            action: action,
            tileID: tileID?.uuidString,
            payload: payload
        )
        actions.append(event)
        if actions.count > maxActions {
            actions.removeFirst(actions.count - maxActions)
        }
        publish(event)
    }

    func appendTerminalOutput(tileID: UUID, chunk: String) {
        guard !chunk.isEmpty else { return }
        var buffer = terminalOutput[tileID] ?? ""
        buffer.append(chunk)
        if buffer.count > maxTerminalChars {
            buffer = String(buffer.suffix(maxTerminalChars / 2))
        }
        terminalOutput[tileID] = buffer
        record(
            source: "terminal",
            action: "output",
            tileID: tileID,
            payload: ["bytes": String(chunk.utf8.count)]
        )
    }

    func terminalSnapshot(tileID: UUID, maxChars: Int = 8_000) -> String {
        if let live = terminalOutput[tileID], !live.isEmpty {
            return String(live.suffix(maxChars))
        }
        return ""
    }

    func setTerminalSnapshot(tileID: UUID, text: String) {
        terminalOutput[tileID] = String(text.suffix(maxTerminalChars))
    }

    func recordAgentMessage(tileID: UUID, text: String, isUser: Bool) {
        var list = agentMessages[tileID] ?? []
        list.append(AgentMessageRecord(text: text, isUser: isUser, timestamp: Date()))
        if list.count > maxAgentMessages {
            list.removeFirst(list.count - maxAgentMessages)
        }
        agentMessages[tileID] = list
        record(
            source: "agent",
            action: isUser ? "user_message" : "agent_reply",
            tileID: tileID,
            payload: ["preview": String(text.prefix(120))]
        )
    }

    func agentSnapshot(tileID: UUID) -> [AgentMessageRecord] {
        agentMessages[tileID] ?? []
    }

    func recentActions(limit: Int = 40) -> [ActionEvent] {
        Array(actions.suffix(limit))
    }

    func clearTile(tileID: UUID) {
        terminalOutput.removeValue(forKey: tileID)
        agentMessages.removeValue(forKey: tileID)
    }

    func tilesSummary(from store: NativeVibeCanvasStore) -> String {
        let tiles = store.sortedTiles.map { tile -> String in
            let focused = store.focusedTileID == tile.id ? "1" : "0"
            return """
            {"id":"\(tile.id.uuidString)","kind":"\(tile.kind.rawValue)","title":"\(escapeJSON(tile.title))","x":"\(tile.frame.x)","y":"\(tile.frame.y)","width":"\(tile.frame.width)","height":"\(tile.frame.height)","focused":\(focused),"url":"\(escapeJSON(tile.url ?? ""))"}
            """
        }
        return "[\(tiles.joined(separator: ","))]"
    }

    func actionsJSON(limit: Int = 30) -> String {
        let slice = recentActions(limit: limit)
        guard let data = try? JSONEncoder().encode(slice),
              let text = String(data: data, encoding: .utf8) else { return "[]" }
        return text
    }

    func agentMessagesJSON(tileID: UUID) -> String {
        let msgs = agentSnapshot(tileID: tileID)
        guard let data = try? JSONEncoder().encode(msgs),
              let text = String(data: data, encoding: .utf8) else { return "[]" }
        return text
    }

    private func publish(_ event: ActionEvent) {
        eventSeq += 1
        let filename = String(format: "%06d_%@.json", eventSeq, event.action)
        let url = eventsDir.appendingPathComponent(filename)
        if let data = try? JSONEncoder().encode(event) {
            try? data.write(to: url, options: .atomic)
        }
        try? "\(eventSeq)".write(to: eventsDir.appendingPathComponent("seq.txt"), atomically: true, encoding: .utf8)
    }

    private func escapeJSON(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}