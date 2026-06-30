import SwiftUI
import WebKit

struct NativeVibeBrowserTileView: View {
    let tile: NativeVibeTile

    var body: some View {
        NativeVibeWebView(urlString: tile.url ?? "https://www.google.com", tileID: tile.id)
            .background(Color.black.opacity(0.2))
    }
}

struct NativeVibeWebView: NSViewRepresentable {
    let urlString: String
    let tileID: UUID

    func makeCoordinator() -> Coordinator {
        Coordinator(tileID: tileID)
    }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        let view = WKWebView(frame: .zero, configuration: config)
        view.setValue(false, forKey: "drawsBackground")
        context.coordinator.load(urlString, in: view)
        return view
    }

    func updateNSView(_ view: WKWebView, context: Context) {
        if context.coordinator.lastURL != urlString {
            context.coordinator.load(urlString, in: view)
        }
    }

    final class Coordinator {
        let tileID: UUID
        var lastURL = ""

        init(tileID: UUID) {
            self.tileID = tileID
        }

        func load(_ urlString: String, in view: WKWebView) {
            lastURL = urlString
            let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let url = URL(string: trimmed.hasPrefix("http") ? trimmed : "https://\(trimmed)") else { return }
            view.load(URLRequest(url: url))
            Task { @MainActor in
                NativeVibeOrchestrator.shared.record(
                    source: "browser",
                    action: "navigate",
                    tileID: tileID,
                    payload: ["url": url.absoluteString]
                )
            }
        }
    }
}