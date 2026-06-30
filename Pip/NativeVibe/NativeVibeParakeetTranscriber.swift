import Foundation

/// MLX Parakeet fast path — Swift mic capture + parakeet-transcribe.py (parakeet-mlx).
final class NativeVibeParakeetTranscriber {
    static let shared = NativeVibeParakeetTranscriber()

    private let workQueue = DispatchQueue(label: "nativevibe.parakeet", qos: .userInitiated)
    private var cachedReady: Bool?
    private var cachedStatus: String = "unknown"

    private init() {}

    /// True when script + venv python + parakeet-mlx probe succeed.
    func isAvailable() -> Bool {
        if let cachedReady { return cachedReady }
        let ready = probeSync()
        cachedReady = ready
        return ready
    }

    var statusMessage: String { cachedStatus }

    func refreshAvailability(completion: ((Bool) -> Void)? = nil) {
        workQueue.async {
            let ready = self.probeSync()
            self.cachedReady = ready
            DispatchQueue.main.async { completion?(ready) }
        }
    }

    func transcribe(duration: TimeInterval = 5, completion: @escaping (Result<String, Error>) -> Void) {
        NativeVibeParakeetRecorder.shared.record(seconds: duration) { [weak self] recordResult in
            guard let self else { return }
            switch recordResult {
            case .failure(let error):
                completion(.failure(error))
            case .success(let wavURL):
                self.transcribeFile(wavURL, deleteWhenDone: true, completion: completion)
            }
        }
    }

    func transcribeFile(
        _ url: URL,
        deleteWhenDone: Bool = false,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        guard let script = scriptPath() else {
            completion(.failure(Self.missingScriptError()))
            return
        }
        guard let python = pythonPath() else {
            completion(.failure(NSError(
                domain: "NativeVibeParakeet",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Parakeet venv not found — run scripts/setup-parakeet.sh"]
            )))
            return
        }

        workQueue.async {
            defer {
                if deleteWhenDone { try? FileManager.default.removeItem(at: url) }
            }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: python)
            process.arguments = [script, "--file", url.path]
            process.environment = Self.processEnvironment()

            let outPipe = Pipe()
            let errPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = errPipe

            do {
                try process.run()
                process.waitUntilExit()
                let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
                let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                let stdout = String(data: outData, encoding: .utf8) ?? ""
                let stderr = String(data: errData, encoding: .utf8) ?? ""
                let raw = stdout.isEmpty ? stderr : stdout

                if let json = Self.parseJSON(from: raw), json["ok"] as? Bool == true,
                   let text = json["text"] as? String, !text.isEmpty {
                    DispatchQueue.main.async { completion(.success(text)) }
                    return
                }
                let message = (Self.parseJSON(from: raw)?["error"] as? String)
                    ?? raw.trimmingCharacters(in: .whitespacesAndNewlines)
                throw NSError(domain: "NativeVibeParakeet", code: 2, userInfo: [
                    NSLocalizedDescriptionKey: message.isEmpty ? "Parakeet transcription failed" : message,
                ])
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }

    @discardableResult
    private func probeSync() -> Bool {
        guard let script = scriptPath(), let python = pythonPath() else {
            cachedStatus = "Parakeet script/venv missing"
            return false
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: python)
        process.arguments = [script, "--probe"]
        process.environment = Self.processEnvironment()
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let raw = String(data: data, encoding: .utf8) ?? ""
            if let json = Self.parseJSON(from: raw), json["ok"] as? Bool == true {
                cachedStatus = "MLX Parakeet ready"
                return true
            }
            let err = (Self.parseJSON(from: raw)?["issues"] as? [String])?.joined(separator: "; ")
                ?? raw.trimmingCharacters(in: .whitespacesAndNewlines)
            cachedStatus = err.isEmpty ? "Parakeet probe failed" : err
            return false
        } catch {
            cachedStatus = error.localizedDescription
            return false
        }
    }

    private func scriptPath() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var candidates = [
            home.appendingPathComponent(".hermes/parakeet-transcribe.py").path,
            home.appendingPathComponent("Desktop/pip-mascot/scripts/parakeet-transcribe.py").path,
        ]
        if let resource = Bundle.main.resourcePath {
            candidates.append("\(resource)/parakeet-transcribe.py")
        }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private func pythonPath() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [
            home.appendingPathComponent(".nativevibe/parakeet-venv/bin/python").path,
            home.appendingPathComponent("Desktop/pip-mascot/scripts/parakeet-venv/bin/python").path,
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private static func processEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        if env["FFMPEG"] == nil, FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/ffmpeg") {
            env["FFMPEG"] = "/opt/homebrew/bin/ffmpeg"
        }
        return env
    }

    private static func missingScriptError() -> NSError {
        NSError(domain: "NativeVibeParakeet", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "parakeet-transcribe.py not found",
        ])
    }

    private static func parseJSON(from raw: String) -> [String: Any]? {
        for line in raw.split(separator: "\n").reversed() {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            return obj
        }
        guard let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj
    }
}