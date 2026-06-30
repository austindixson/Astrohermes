import Foundation

/// On-demand memory retrieval — never dumps full history into agent context.
/// Indexes project-scoped snippets from Hermes memory files + NativeVibe notes.
final class NativeVibeMemoryStore {
    static let shared = NativeVibeMemoryStore()

    private let queue = DispatchQueue(label: "nativevibe.memory", qos: .utility)

    private init() {}

    /// Synchronous path for bridge handlers — avoids main-thread deadlock with the poll timer.
    func retrieveSync(query: String, limit: Int = 8) -> [NativeVibeMemoryHit] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        return Self.search(query: trimmed, limit: limit)
    }

    func retrieve(query: String, limit: Int = 8, completion: @escaping ([NativeVibeMemoryHit]) -> Void) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            DispatchQueue.main.async { completion([]) }
            return
        }

        queue.async {
            let hits = Self.search(query: trimmed, limit: limit)
            DispatchQueue.main.async { completion(hits) }
        }
    }

    private static func search(query: String, limit: Int) -> [NativeVibeMemoryHit] {
        let tokens = query.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        guard !tokens.isEmpty else { return [] }

        var scored: [(NativeVibeMemoryHit, Int)] = []
        for source in memorySources() {
            let body = (try? String(contentsOf: source.url, encoding: .utf8)) ?? ""
            let lines = body.components(separatedBy: .newlines)
            for (index, line) in lines.enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.count > 12 else { continue }
                let lower = trimmed.lowercased()
                let score = tokens.reduce(0) { partial, token in
                    partial + (lower.contains(token) ? token.count + 2 : 0)
                }
                guard score > 0 else { continue }
                let hit = NativeVibeMemoryHit(
                    id: "\(source.label)-\(index)",
                    source: source.label,
                    path: source.url.path,
                    excerpt: String(trimmed.prefix(240)),
                    score: score
                )
                scored.append((hit, score))
            }
        }

        return scored
            .sorted { $0.1 > $1.1 }
            .prefix(limit)
            .map(\.0)
    }

    private static func memorySources() -> [(label: String, url: URL)] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates: [(String, URL)] = [
            ("hermes-memory", home.appendingPathComponent(".hermes/memories/MEMORY.md")),
            ("hermes-user", home.appendingPathComponent(".hermes/memories/USER.md")),
            ("nativevibe-notes", home.appendingPathComponent(".nativevibe/notes.md")),
        ]
        return candidates.filter { FileManager.default.fileExists(atPath: $0.1.path) }
    }
}

struct NativeVibeMemoryHit: Identifiable, Equatable, Codable {
    let id: String
    let source: String
    let path: String
    let excerpt: String
    let score: Int
}