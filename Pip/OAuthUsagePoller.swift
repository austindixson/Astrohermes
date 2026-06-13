import Foundation

/// Always-on primary source: polls the UNDOCUMENTED endpoint
///   GET https://api.anthropic.com/api/oauth/usage
/// every 30 seconds with the Claude Code session token. Treats everything
/// defensively — schema drift, 4xx/5xx, malformed JSON, and no network all
/// degrade gracefully (last-good snapshot is kept; mascot goes sleepy when
/// data ages out).
///
/// On the first successful response the raw JSON is dumped to
/// ~/Library/Logs/Pip/usage-raw.json so the real schema can be inspected.
final class OAuthUsagePoller {

    var pollInterval: TimeInterval = 30

    private let store: UsageStore
    private let workQueue = DispatchQueue(label: "pip.oauth-poller", qos: .utility)
    private var timer: Timer?
    private let session: URLSession
    private let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    private var rawDumpPath: String {
        (NSHomeDirectory() as NSString).appendingPathComponent("Library/Logs/\(mascotName)/usage-raw.json")
    }

    init(store: UsageStore) {
        self.store = store
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 20
        config.waitsForConnectivity = false
        session = URLSession(configuration: config)
    }

    func start() {
        pollNow()
        let t = Timer(timeInterval: pollInterval, repeats: true) { [weak self] _ in
            self?.pollNow()
        }
        t.tolerance = 5
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func pollNow() {
        workQueue.async { [weak self] in self?.poll() }
    }

    private func poll() {
        guard let token = CredentialsProvider.loadAccessToken() else {
            onMain { store in
                store.markTokenAvailable(false)
                store.noteError("no claude code token found")
            }
            return
        }
        onMain { store in store.markTokenAvailable(true) }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let task = session.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }
            if let error {
                self.onMain { store in store.noteError("network: \(error.localizedDescription)") }
                return
            }
            guard let http = response as? HTTPURLResponse else { return }
            guard (200...299).contains(http.statusCode) else {
                self.onMain { store in store.noteError("http \(http.statusCode) from usage endpoint") }
                return
            }
            guard let data, !data.isEmpty, let object = JSONProbe.parse(data) else {
                self.onMain { store in store.noteError("malformed usage response") }
                return
            }
            self.dumpRawOnce(data)
            guard var snap = JSONProbe.extractUsage(from: object) else {
                self.onMain { store in store.noteError("usage schema not recognized — see usage-raw.json") }
                return
            }
            snap.lastUpdated = Date()
            self.onMain { store in store.ingest(snap, source: "oauth") }
        }
        task.resume()
    }

    private func dumpRawOnce(_ data: Data) {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: rawDumpPath) else { return }
        let dir = (rawDumpPath as NSString).deletingLastPathComponent
        try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? data.write(to: URL(fileURLWithPath: rawDumpPath))
    }

    private func onMain(_ body: @escaping (UsageStore) -> Void) {
        let store = self.store
        DispatchQueue.main.async { body(store) }
    }
}
