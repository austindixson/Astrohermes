import Foundation

extension Notification.Name {
    static let nativeVibeAgentUpdated = Notification.Name("nativevibe.agent.updated")
}

/// Bridge/voice-safe Hermes dispatch — does not depend on SwiftUI tile views being mounted.
@MainActor
enum NativeVibeAgentRunner {
    private static var inFlight: Set<UUID> = []

    static func isInFlight(tileID: UUID) -> Bool {
        inFlight.contains(tileID)
    }

    static func send(text: String, tileID: UUID, tile: NativeVibeTile, status: @escaping (String) -> Void) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard !inFlight.contains(tileID) else { return }

        inFlight.insert(tileID)
        NativeVibeOrchestrator.shared.recordAgentMessage(tileID: tileID, text: trimmed, isUser: true)
        notify(tileID: tileID)
        status("Agent thinking…")

        if let path = tile.workspacePath {
            HermesChatClient.shared.setWorkingDirectory(path)
        }

        HermesChatClient.shared.send(trimmed, verbose: true) { result in
            inFlight.remove(tileID)
            switch result {
            case .success(let reply):
                let body = HermesTranscriptParser.replyText(from: reply)
                NativeVibeOrchestrator.shared.recordAgentMessage(tileID: tileID, text: body, isUser: false)
                status(body.contains("qa_iteration_ok") ? "Agent: qa_iteration_ok" : "Agent replied")
            case .failure(let error):
                let message = error.localizedDescription
                NativeVibeOrchestrator.shared.recordAgentMessage(tileID: tileID, text: message, isUser: false)
                status("Agent error")
            }
            notify(tileID: tileID)
        }
    }

    private static func notify(tileID: UUID) {
        NotificationCenter.default.post(
            name: .nativeVibeAgentUpdated,
            object: nil,
            userInfo: ["tile_id": tileID.uuidString]
        )
    }
}