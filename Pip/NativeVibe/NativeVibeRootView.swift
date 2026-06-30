import SwiftUI

struct NativeVibeRootView: View {
    @Bindable var store: NativeVibeCanvasStore
    @ObservedObject var voice: NativeVibeVoiceCoordinator
    @State private var memoryHits: [NativeVibeMemoryHit] = []
    @State private var memoryQuery = ""
    @State private var memoryPanelVisible = false

    var body: some View {
        ZStack(alignment: .top) {
            NativeVibeCanvasView(store: store)

            VStack(spacing: 0) {
                header
                memoryPanel
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .nativeVibeMemoryResults)) { note in
            if let hits = note.userInfo?["hits"] as? [NativeVibeMemoryHit] {
                memoryHits = hits
                memoryPanelVisible = true
            }
            if let query = note.userInfo?["query"] as? String {
                memoryQuery = query
            }
        }
        .onAppear {
            voice.onFinalUtterance = { utterance in
                store.lastVoiceTranscript = utterance
                store.isVoiceListening = false
                routeVoiceCommand(utterance)
            }
        }
        .onChange(of: voice.isListening) { _, listening in
            store.isVoiceListening = listening
        }
        .onChange(of: voice.transcript) { _, text in
            store.lastVoiceTranscript = text
        }
        .onChange(of: voice.status) { _, status in
            guard voice.isListening || status != "Voice idle" else { return }
            store.statusMessage = "\(voice.pathLabel): \(status)"
        }
        .onChange(of: voice.isListening) { wasListening, listening in
            if wasListening && !listening && voice.status == "Voice idle" {
                store.statusMessage = "Voice stopped"
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text("NativeVibe")
                .font(.system(size: 15, weight: .bold, design: .rounded))
            Text("voice-controlled native IDE")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(NativeVibeTheme.tileMuted)
            Spacer()
            NativeVibeAccessibleTextField(
                placeholder: "Memory query…",
                text: $memoryQuery,
                axIdentifier: "nativevibe.memory.query",
                onSubmit: retrieveMemory
            )
            .frame(width: 220)
            Button("Retrieve", action: retrieveMemory)
                .accessibilityLabel("Retrieve")
                .accessibilityIdentifier("nativevibe.memory.retrieve")
            Button(action: { voice.toggleListening() }) {
                Label(voice.isListening ? "Stop" : "Voice", systemImage: voice.isListening ? "mic.fill" : "mic")
                    .foregroundStyle(voice.isListening ? NativeVibeTheme.voiceActive : .primary)
            }
            .accessibilityLabel(voice.isListening ? "Stop" : "Voice")
            .accessibilityIdentifier("nativevibe.voice.toggle")
            .help(voice.parakeetReady
                ? "MLX Parakeet — \(voice.status)"
                : "Apple Speech fallback — \(NativeVibeParakeetTranscriber.shared.statusMessage)")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
    }

    private var memoryPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("On-demand memory")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(NativeVibeTheme.tileMuted)
                .accessibilityIdentifier("nativevibe.memory.panel")
            if memoryHits.isEmpty {
                Text("No hits — try hermes, orca, or project names")
                    .font(.system(size: 11))
                    .foregroundStyle(NativeVibeTheme.tileMuted)
                    .accessibilityIdentifier("nativevibe.memory.empty")
            } else {
                ForEach(memoryHits) { hit in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(hit.source)
                            .accessibilityIdentifier("nativevibe.memory.hit.\(hit.source)")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(NativeVibeTheme.accent)
                        Text(hit.excerpt)
                            .font(.system(size: 11))
                            .foregroundStyle(NativeVibeTheme.tileTitle)
                            .lineLimit(2)
                    }
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.05)))
                }
            }
        }
        .opacity(memoryPanelVisible ? 1 : 0)
        .frame(height: memoryPanelVisible ? nil : 0)
        .clipped()
        .padding(12)
        .frame(maxWidth: 420, alignment: .leading)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .padding(.leading, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func retrieveMemory() {
        let query = memoryQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            store.statusMessage = "Enter a memory query"
            return
        }
        let hits = NativeVibeMemoryStore.shared.retrieveSync(query: query)
        memoryHits = hits
        memoryPanelVisible = true
        store.statusMessage = hits.isEmpty
            ? "Memory retrieved: 0 hits for \"\(query)\""
            : "Memory retrieved: \(hits.count) hit\(hits.count == 1 ? "" : "s")"
    }

    private func routeVoiceCommand(_ utterance: String) {
        let lower = utterance.lowercased()
        if lower.contains("terminal") || lower.contains("shell") {
            store.addTile(kind: .terminal)
        } else if lower.contains("agent") || lower.contains("hermes") {
            store.addTile(kind: .agent)
        } else if lower.contains("memory") {
            memoryQuery = utterance
            retrieveMemory()
        } else if let focused = store.focusedTileID,
                  let tile = store.tile(id: focused),
                  tile.kind == .agent {
            // Voice-to-agent: inject into focused Hermes tile via notification
            NotificationCenter.default.post(
                name: .nativeVibeAgentInject,
                object: nil,
                userInfo: ["tile_id": focused.uuidString, "text": utterance]
            )
            store.statusMessage = "Sent voice to agent tile"
        } else {
            store.addTile(kind: .agent)
            store.statusMessage = "Voice: \(utterance)"
        }
    }
}

extension Notification.Name {
    static let nativeVibeAgentInject = Notification.Name("nativevibe.agent.inject")
    static let nativeVibeMemoryResults = Notification.Name("nativevibe.memory.results")
}