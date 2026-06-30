import Foundation

/// File-backed persistence for parallel 3-agent squad runs.
@MainActor
final class NativeVibeSquadStore {
    static let shared = NativeVibeSquadStore()

    private let squadsDir: URL
    private var activeSquadID: UUID?
    private var cache: [UUID: NativeVibeSquadRun] = [:]

    private init() {
        squadsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".nativevibe/squads")
        try? FileManager.default.createDirectory(at: squadsDir, withIntermediateDirectories: true)
        loadActivePointer()
    }

    var activeSquad: NativeVibeSquadRun? {
        guard let activeSquadID else { return nil }
        return squad(id: activeSquadID)
    }

    func squad(id: UUID) -> NativeVibeSquadRun? {
        if let cached = cache[id] { return cached }
        let url = fileURL(for: id)
        guard let data = try? Data(contentsOf: url),
              let run = try? JSONDecoder().decode(NativeVibeSquadRun.self, from: data) else { return nil }
        cache[id] = run
        return run
    }

    func recentSquads(limit: Int = 10) -> [NativeVibeSquadRun] {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: squadsDir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        let runs: [NativeVibeSquadRun] = files
            .filter { $0.pathExtension == "json" && $0.lastPathComponent != "active.json" }
            .compactMap { url -> NativeVibeSquadRun? in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? JSONDecoder().decode(NativeVibeSquadRun.self, from: data)
            }
            .sorted { $0.updatedAt > $1.updatedAt }

        return Array(runs.prefix(limit))
    }

    @discardableResult
    func save(_ run: NativeVibeSquadRun, setActive: Bool = false) -> NativeVibeSquadRun {
        var updated = run
        updated.updatedAt = Date()
        cache[updated.id] = updated
        if let data = try? JSONEncoder().encode(updated) {
            try? data.write(to: fileURL(for: updated.id), options: .atomic)
        }
        if setActive {
            setActiveSquad(id: updated.id)
        }
        notify(runID: updated.id)
        return updated
    }

    func setActiveSquad(id: UUID?) {
        activeSquadID = id
        let pointer = squadsDir.appendingPathComponent("active.json")
        if let id {
            let payload = ["squad_id": id.uuidString]
            if let data = try? JSONEncoder().encode(payload) {
                try? data.write(to: pointer, options: .atomic)
            }
        } else {
            try? FileManager.default.removeItem(at: pointer)
        }
    }

    func squadJSON(id: UUID) -> String {
        guard let run = squad(id: id),
              let data = try? JSONEncoder().encode(run),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }

    func activeSquadJSON() -> String {
        guard let run = activeSquad else { return "{}" }
        return squadJSON(id: run.id)
    }

    private func fileURL(for id: UUID) -> URL {
        squadsDir.appendingPathComponent("\(id.uuidString).json")
    }

    private func loadActivePointer() {
        let pointer = squadsDir.appendingPathComponent("active.json")
        guard let data = try? Data(contentsOf: pointer),
              let payload = try? JSONDecoder().decode([String: String].self, from: data),
              let idStr = payload["squad_id"],
              let id = UUID(uuidString: idStr) else { return }
        activeSquadID = id
    }

    private func notify(runID: UUID) {
        NotificationCenter.default.post(
            name: .nativeVibeSquadUpdated,
            object: nil,
            userInfo: ["squad_id": runID.uuidString]
        )
    }
}