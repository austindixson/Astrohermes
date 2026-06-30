import Foundation

/// Shared chat bubble model (Pip mascot + NativeVibe agent tiles).
struct ChatBubbleMessage: Equatable, Identifiable {
    let id = UUID()
    let text: String
    let isUser: Bool
    /// Full Hermes TUI transcript (tool traces, diffs, boxed replies).
    var isHermesTranscript = false
}