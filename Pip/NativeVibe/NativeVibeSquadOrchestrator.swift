import Foundation

/// Decomposes goals into 3 parallel worker slices and tracks squad lifecycle.
@MainActor
enum NativeVibeSquadOrchestrator {
    static let workerCount = 3

    @discardableResult
    static func start(
        goal: String,
        workspacePath: String,
        canvasStore: NativeVibeCanvasStore
    ) -> NativeVibeSquadRun {
        let trimmedGoal = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        let workspace = workspacePath.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedWorkspace = workspace.isEmpty
            ? (HermesChatClient.shared.activeWorkingDirectory ?? FileManager.default.currentDirectoryPath)
            : workspace

        var run = NativeVibeSquadRun(
            id: UUID(),
            goal: trimmedGoal,
            workspacePath: resolvedWorkspace,
            status: .planning,
            workers: makeWorkers(goal: trimmedGoal),
            leadTileID: nil,
            createdAt: Date(),
            updatedAt: Date(),
            synthesis: nil
        )

        NativeVibeOrchestrator.shared.record(
            source: "squad",
            action: "start",
            payload: ["goal": String(trimmedGoal.prefix(120)), "workspace": resolvedWorkspace]
        )

        let tiles = NativeVibeLayoutEngine.apply(
            preset: .threeAgents,
            to: canvasStore,
            viewport: canvasStore.viewportSize,
            workspacePath: resolvedWorkspace,
            squadID: run.id
        )

        run.leadTileID = tiles.first(where: { $0.kind == .terminal })?.id
        for worker in run.workers {
            guard let tile = tiles.first(where: { $0.workerIndex == worker.index && $0.kind == .agent }) else { continue }
            if let idx = run.workers.firstIndex(where: { $0.index == worker.index }) {
                run.workers[idx].tileID = tile.id
            }
        }

        run.status = .running
        run = NativeVibeSquadStore.shared.save(run, setActive: true)
        canvasStore.statusMessage = "Squad started — 3 agents on \(trimmedGoal.prefix(48))"
        return run
    }

    @discardableResult
    static func updateWorker(
        squadID: UUID,
        workerIndex: Int,
        status: NativeVibeWorkerStatus,
        resultSummary: String? = nil
    ) -> NativeVibeSquadRun? {
        guard var run = NativeVibeSquadStore.shared.squad(id: squadID),
              let idx = run.workers.firstIndex(where: { $0.index == workerIndex }) else { return nil }

        run.workers[idx].status = status
        if status == .running, run.workers[idx].startedAt == nil {
            run.workers[idx].startedAt = Date()
        }
        if status == .completed || status == .failed {
            run.workers[idx].completedAt = Date()
        }
        if let resultSummary {
            run.workers[idx].resultSummary = resultSummary
        }

        if run.allWorkersTerminal {
            let anyFailed = run.workers.contains { $0.status == .failed }
            run.status = anyFailed ? .failed : .synthesizing
        }

        NativeVibeOrchestrator.shared.record(
            source: "squad",
            action: "worker_update",
            tileID: run.workers[idx].tileID,
            payload: [
                "squad_id": squadID.uuidString,
                "worker": String(workerIndex),
                "status": status.rawValue,
            ]
        )

        return NativeVibeSquadStore.shared.save(run)
    }

    static func workerPrompt(goal: String, slice: NativeVibeWorkerSlice, workerIndex: Int) -> String {
        let others = NativeVibeWorkerSlice.allCases
            .filter { $0 != slice }
            .map { "Worker \($0.workerIndex): \($0.defaultResponsibility(for: goal))" }
            .joined(separator: " | ")

        return """
        [Orca Worker \(workerIndex)/\(workerCount)] \
        Workspace: \(HermesChatClient.shared.activeWorkingDirectory ?? FileManager.default.currentDirectoryPath) \
        Shared goal: \(goal) \
        Your slice ONLY: \(slice.defaultResponsibility(for: goal)) \
        Other workers (do not duplicate): \(others) \
        Rules: Do NOT ask clarifying questions. Use sensible defaults and ship your slice as real files in the workspace. \
        If the workspace is empty, scaffold from scratch. Stay in your slice.
        """
    }

    static func dispatchPrompts(
        squadID: UUID,
        canvasStore: NativeVibeCanvasStore,
        status: @escaping (String) -> Void
    ) {
        guard let run = NativeVibeSquadStore.shared.squad(id: squadID) else { return }

        for worker in run.workers {
            guard let tileID = worker.tileID,
                  let tile = canvasStore.tile(id: tileID) else { continue }
            _ = updateWorker(squadID: squadID, workerIndex: worker.index, status: .running)
            NativeVibeAgentRunner.send(text: worker.prompt, tileID: tileID, tile: tile, status: status)
        }
    }

    static func markReadyForSynthesis(squadID: UUID) -> NativeVibeSquadRun? {
        guard var run = NativeVibeSquadStore.shared.squad(id: squadID) else { return nil }
        guard run.completedWorkerCount == workerCount else { return run }
        run.status = .synthesizing
        return NativeVibeSquadStore.shared.save(run)
    }

    @discardableResult
    static func completeSynthesis(squadID: UUID, synthesis: String) -> NativeVibeSquadRun? {
        guard var run = NativeVibeSquadStore.shared.squad(id: squadID) else { return nil }
        run.synthesis = synthesis
        run.status = .completed
        NativeVibeOrchestrator.shared.record(
            source: "squad",
            action: "synthesize_complete",
            payload: ["squad_id": squadID.uuidString]
        )
        return NativeVibeSquadStore.shared.save(run)
    }

    static func cancel(squadID: UUID) -> NativeVibeSquadRun? {
        guard var run = NativeVibeSquadStore.shared.squad(id: squadID) else { return nil }
        run.status = .cancelled
        for idx in run.workers.indices where run.workers[idx].status == .pending || run.workers[idx].status == .running {
            run.workers[idx].status = .blocked
        }
        return NativeVibeSquadStore.shared.save(run)
    }

    private static func makeWorkers(goal: String) -> [NativeVibeSquadWorker] {
        NativeVibeWorkerSlice.allCases.map { slice in
            NativeVibeSquadWorker(
                index: slice.workerIndex,
                slice: slice,
                status: .pending,
                tileID: nil,
                prompt: workerPrompt(goal: goal, slice: slice, workerIndex: slice.workerIndex),
                resultSummary: nil,
                startedAt: nil,
                completedAt: nil
            )
        }
    }
}

private extension NativeVibeWorkerSlice {
    func defaultResponsibility(for goal: String) -> String {
        switch self {
        case .foundation:
            return "Scaffold project files and implement the foundation for: \(goal)"
        case .functionality:
            return "Build the main user-facing functionality for: \(goal)"
        case .polish:
            return "Polish UI/UX, responsive layout, and add a brief README for: \(goal)"
        }
    }
}