import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct NativeVibeTileChrome<Content: View>: View {
    let title: String
    let kind: NativeVibeTileKind
    let isFocused: Bool
    let onClose: () -> Void
    var headerDragGesture: AnyGesture<Void>?
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: iconName)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(NativeVibeTheme.accent)
                NativeVibeAccessibleLabel(
                    text: title,
                    axIdentifier: "nativevibe.tile.title.\(kind.rawValue)",
                    fontSize: 12,
                    weight: .semibold,
                    textColor: NSColor(NativeVibeTheme.tileTitle)
                )
                Spacer(minLength: 0)
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(NativeVibeTheme.tileMuted)
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(NativeVibeTheme.tileChrome)
            .contentShape(Rectangle())
            .gesture(headerDragGesture)

            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(
            RoundedRectangle(cornerRadius: NativeVibeTheme.tileRadius, style: .continuous)
                .fill(Color.black.opacity(0.35))
        )
        .overlay(
            RoundedRectangle(cornerRadius: NativeVibeTheme.tileRadius, style: .continuous)
                .strokeBorder(isFocused ? NativeVibeTheme.accent.opacity(0.75) : NativeVibeTheme.tileBorder, lineWidth: isFocused ? 1.5 : 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: NativeVibeTheme.tileRadius, style: .continuous))
        .shadow(color: .black.opacity(0.25), radius: isFocused ? 16 : 8, y: 8)
    }

    private var iconName: String {
        switch kind {
        case .agent: return "sparkles"
        case .terminal: return "terminal"
        case .browser: return "globe"
        case .markdown: return "doc.richtext"
        case .diagram: return "point.3.connected.trianglepath.dotted"
        case .note: return "note.text"
        }
    }
}

struct NativeVibeAgentTileView: View {
    let tile: NativeVibeTile
    @State private var draft = ""
    @State private var messages: [ChatBubbleMessage] = []
    @State private var isLoading = false
    @State private var liveTranscript = ""

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(messages) { message in
                        NativeVibeAgentBubble(message: message)
                    }
                    if isLoading {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text(liveTranscript.isEmpty ? "Hermes thinking…" : liveTranscript)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(NativeVibeTheme.tileMuted)
                                .lineLimit(4)
                        }
                    }
                }
                .padding(12)
            }

            Divider().opacity(0.2)

            HStack(spacing: 8) {
                NativeVibeAccessibleTextField(
                    placeholder: "Ask Hermes…",
                    text: $draft,
                    axIdentifier: "nativevibe.agent.composer.\(tile.id.uuidString)",
                    bordered: false,
                    onSubmit: send
                )
                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            ? NativeVibeTheme.tileMuted
                            : NativeVibeTheme.accent)
                }
                .buttonStyle(.plain)
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isLoading)
            }
            .padding(10)
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            handleDrop(providers)
        }
        .onAppear { syncMessagesFromOrchestrator() }
        .onReceive(NotificationCenter.default.publisher(for: .nativeVibeAgentUpdated)) { note in
            guard let target = note.userInfo?["tile_id"] as? String, target == tile.id.uuidString else { return }
            syncMessagesFromOrchestrator()
        }
        .onReceive(NotificationCenter.default.publisher(for: .nativeVibeAgentInject)) { note in
            if let target = note.userInfo?["tile_id"] as? String, target != tile.id.uuidString { return }
            guard let text = note.userInfo?["text"] as? String else { return }
            sendMessage(text)
        }
    }

    private func syncMessagesFromOrchestrator() {
        let records = NativeVibeOrchestrator.shared.agentSnapshot(tileID: tile.id)
        messages = records.map { ChatBubbleMessage(text: $0.text, isUser: $0.isUser) }
        isLoading = NativeVibeAgentRunner.isInFlight(tileID: tile.id)
        liveTranscript = ""
    }

    private func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        draft = ""
        sendMessage(text)
    }

    private func sendMessage(_ text: String) {
        guard !isLoading else { return }
        isLoading = true
        NativeVibeAgentRunner.send(text: text, tileID: tile.id, tile: tile) { _ in }
        syncMessagesFromOrchestrator()
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        let group = DispatchGroup()
        var paths: [String] = []
        for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                defer { group.leave() }
                if let url = item as? URL {
                    paths.append(url.path)
                } else if let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) {
                    paths.append(url.path)
                }
            }
        }
        group.notify(queue: .main) {
            guard !paths.isEmpty else { return }
            HermesChatClient.shared.adoptWorkspace(paths: paths)
        }
        return true
    }
}

private struct NativeVibeAgentBubble: View {
    let message: ChatBubbleMessage

    var body: some View {
        HStack {
            if message.isUser { Spacer(minLength: 24) }
            NativeVibeAccessibleLabel(
                text: message.text,
                axIdentifier: message.isUser ? "nativevibe.agent.user" : "nativevibe.agent.reply",
                fontSize: 12,
                weight: message.isUser ? .medium : .regular,
                textColor: message.isUser ? .white : NSColor(NativeVibeTheme.tileTitle),
                multiline: true
            )
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(message.isUser ? NativeVibeTheme.accent.opacity(0.85) : Color.white.opacity(0.08))
            )
            if !message.isUser { Spacer(minLength: 24) }
        }
    }
}

struct NativeVibeTerminalTileView: View {
    let tile: NativeVibeTile

    var body: some View {
        NativeVibeSwiftTermView(tileID: tile.id, workingDirectory: tile.workspacePath)
            .background(Color.black.opacity(0.55))
    }
}

struct NativeVibePlaceholderTileView: View {
    let kind: NativeVibeTileKind

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "hammer")
                .font(.system(size: 28))
                .foregroundStyle(NativeVibeTheme.tileMuted)
            Text("\(kind.label) tile")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
            Text("Coming in v1 — scaffolded for canvas parity")
                .font(.system(size: 11))
                .foregroundStyle(NativeVibeTheme.tileMuted)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}