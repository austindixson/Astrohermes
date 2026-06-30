import Foundation

/// Parallel worker slices for a 3-agent Orca-style decomposition.
enum NativeVibeWorkerSlice: String, Codable, CaseIterable, Identifiable {
    case foundation
    case functionality
    case polish

    var id: String { rawValue }

    var workerIndex: Int {
        switch self {
        case .foundation: return 1
        case .functionality: return 2
        case .polish: return 3
        }
    }

    var label: String {
        switch self {
        case .foundation: return "Foundation"
        case .functionality: return "Functionality"
        case .polish: return "Polish"
        }
    }

    static func from(workerIndex: Int) -> NativeVibeWorkerSlice? {
        allCases.first { $0.workerIndex == workerIndex }
    }
}

enum NativeVibeWorkerStatus: String, Codable, CaseIterable {
    case pending
    case running
    case completed
    case failed
    case blocked
}

enum NativeVibeSquadStatus: String, Codable, CaseIterable {
    case planning
    case running
    case synthesizing
    case completed
    case failed
    case cancelled
}

struct NativeVibeSquadWorker: Codable, Identifiable, Equatable {
    let index: Int
    let slice: NativeVibeWorkerSlice
    var status: NativeVibeWorkerStatus
    var tileID: UUID?
    var prompt: String
    var resultSummary: String?
    var startedAt: Date?
    var completedAt: Date?

    var id: Int { index }

    var title: String { "Worker \(index)" }

    var isTerminal: Bool {
        status == .completed || status == .failed
    }
}

struct NativeVibeSquadRun: Codable, Identifiable, Equatable {
    let id: UUID
    var goal: String
    var workspacePath: String
    var status: NativeVibeSquadStatus
    var workers: [NativeVibeSquadWorker]
    var leadTileID: UUID?
    var createdAt: Date
    var updatedAt: Date
    var synthesis: String?

    var activeWorkerCount: Int {
        workers.filter { $0.status == .running }.count
    }

    var completedWorkerCount: Int {
        workers.filter { $0.status == .completed }.count
    }

    var allWorkersTerminal: Bool {
        workers.allSatisfy(\.isTerminal)
    }

    func worker(index: Int) -> NativeVibeSquadWorker? {
        workers.first { $0.index == index }
    }

    func worker(slice: NativeVibeWorkerSlice) -> NativeVibeSquadWorker? {
        workers.first { $0.slice == slice }
    }
}

extension Notification.Name {
    static let nativeVibeSquadUpdated = Notification.Name("nativevibe.squad.updated")
}