import Foundation
import Observation
import CoreGraphics

@MainActor
@Observable
final class NativeVibeCanvasStore {
    private(set) var document: NativeVibeCanvasDocument
    var focusedTileID: UUID?
    var selectedTileID: UUID?
    var isVoiceListening = false
    var lastVoiceTranscript = ""
    var statusMessage = "Ready"
    var viewportSize = CGSize(width: 1200, height: 800)
    var scrollContentHeight: CGFloat = 800

    private let persistenceURL: URL
    private var nextZIndex = 1
    private var refitTask: Task<Void, Never>?
    private var viewportInitialized = false

    var lastLayoutPreset: NativeVibeLayoutPreset? {
        get { document.lastLayoutPreset.flatMap(NativeVibeLayoutPreset.init(rawValue:)) }
        set { document.lastLayoutPreset = newValue?.rawValue }
    }

    init(persistenceURL: URL? = nil) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        self.persistenceURL = persistenceURL ?? home.appendingPathComponent(".nativevibe/canvas.json")
        self.document = Self.load(from: self.persistenceURL) ?? Self.bootstrapDocument()
        self.nextZIndex = (document.tiles.map(\.zIndex).max() ?? 0) + 1
        scrollContentHeight = computedContentHeight()
    }

    var pan: CGPoint {
        get { CGPoint(x: document.panX, y: document.panY) }
        set {
            document.panX = newValue.x
            document.panY = newValue.y
            persistSoon()
        }
    }

    var zoom: CGFloat {
        get { document.zoom }
        set {
            document.zoom = min(2.5, max(0.35, newValue))
            persistSoon()
        }
    }

    var sortedTiles: [NativeVibeTile] {
        document.tiles.sorted { $0.zIndex < $1.zIndex }
    }

    func tile(id: UUID) -> NativeVibeTile? {
        document.tiles.first { $0.id == id }
    }

    func firstTile(kind: NativeVibeTileKind) -> NativeVibeTile? {
        document.tiles.first { $0.kind == kind }
    }

    func updateTile(id: UUID, title: String? = nil, workspacePath: String? = nil, url: String? = nil) {
        guard let index = document.tiles.firstIndex(where: { $0.id == id }) else { return }
        if let title { document.tiles[index].title = title }
        if let workspacePath { document.tiles[index].workspacePath = workspacePath }
        if let url { document.tiles[index].url = url }
        document.tiles[index].updatedAt = Date()
        if let title {
            statusMessage = title
        } else {
            statusMessage = "Updated tile"
        }
        NativeVibeOrchestrator.shared.record(source: "ui", action: "update_tile", tileID: id)
        persistSoon()
    }

    func updateViewport(_ size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        let previous = viewportSize
        viewportSize = size

        if viewportInitialized {
            refitToViewport(previous: previous, persist: false)
        } else {
            viewportInitialized = true
            if let preset = lastLayoutPreset {
                NativeVibeLayoutEngine.refit(preset: preset, to: self, viewport: viewportSize)
            }
            scrollContentHeight = computedContentHeight()
        }

        refitTask?.cancel()
        refitTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard !Task.isCancelled else { return }
            persistSoon()
        }
    }

    func refitToViewport(previous: CGSize? = nil, persist: Bool = false) {
        let prior = previous ?? viewportSize
        if let preset = lastLayoutPreset {
            let applied = NativeVibeLayoutEngine.refit(preset: preset, to: self, viewport: viewportSize)
            if !applied {
                refitFreeformHorizontally(from: prior)
            }
        } else if abs(prior.width - viewportSize.width) > 1 || abs(prior.height - viewportSize.height) > 1 {
            refitFreeformHorizontally(from: prior)
        }
        scrollContentHeight = computedContentHeight()
        if persist { persistSoon() }
    }

    private func refitFreeformHorizontally(from previous: CGSize) {
        guard previous.width > 1, !document.tiles.isEmpty else { return }

        let padding = NativeVibeLayoutEngine.horizontalPadding
        let oldContentWidth = max(1, previous.width - padding * 2)
        let newContentWidth = max(1, viewportSize.width - padding * 2)
        let scaleX = newContentWidth / oldContentWidth
        guard abs(scaleX - 1) > 0.001 else { return }

        let heightScale = max(1, previous.height - NativeVibeLayoutEngine.topChrome - NativeVibeLayoutEngine.bottomChrome)
        let newHeightSpan = max(1, viewportSize.height - NativeVibeLayoutEngine.topChrome - NativeVibeLayoutEngine.bottomChrome)
        let scaleY = newHeightSpan / heightScale

        for index in document.tiles.indices {
            var frame = document.tiles[index].frame
            frame.x = padding + (frame.x - padding) * scaleX
            frame.width = max(200, frame.width * scaleX)
            frame.y = NativeVibeLayoutEngine.topChrome
                + (frame.y - NativeVibeLayoutEngine.topChrome) * scaleY
            frame.height = max(120, frame.height * scaleY)
            document.tiles[index].frame = frame
            document.tiles[index].updatedAt = Date()
        }
    }

    func finishLayoutApply(preset: NativeVibeLayoutPreset, contentHeight: CGFloat) {
        lastLayoutPreset = preset
        scrollContentHeight = max(contentHeight, computedContentHeight())
        persistSoon()
    }

    func clearLayoutPreset() {
        lastLayoutPreset = nil
        scrollContentHeight = computedContentHeight()
    }

    func scrollContentHeight(for viewport: CGSize? = nil) -> CGFloat {
        let viewportHeight = viewport?.height ?? viewportSize.height
        let tileBottom = document.tiles.map { $0.frame.y + $0.frame.height }.max() ?? 0
        let extent = tileBottom + NativeVibeLayoutEngine.bottomChrome
        return max(viewportHeight, extent)
    }

    func needsVerticalScroll(in viewport: CGSize) -> Bool {
        let tileBottom = document.tiles.map { $0.frame.y + $0.frame.height }.max() ?? 0
        return tileBottom + NativeVibeLayoutEngine.bottomChrome > viewport.height + 1
    }

    private func computedContentHeight() -> CGFloat {
        scrollContentHeight(for: viewportSize)
    }

    @discardableResult
    func addTile(
        kind: NativeVibeTileKind,
        at origin: CGPoint? = nil,
        title: String? = nil,
        workspacePath: String? = nil,
        url: String? = nil,
        clearsLayoutPreset: Bool = true
    ) -> NativeVibeTile {
        if clearsLayoutPreset { clearLayoutPreset() }
        let size = kind.defaultSize
        let tileOrigin = origin ?? CGPoint(
            x: NativeVibeLayoutEngine.horizontalPadding,
            y: NativeVibeLayoutEngine.topChrome
        )
        var tile = NativeVibeTile(
            kind: kind,
            title: title,
            frame: NativeVibeTileFrame(origin: tileOrigin, size: size),
            zIndex: nextZIndex,
            workspacePath: workspacePath,
            url: url
        )
        nextZIndex += 1
        document.tiles.append(tile)
        focusedTileID = tile.id
        selectedTileID = tile.id
        scrollContentHeight = computedContentHeight()
        statusMessage = "Added \(tile.title)"
        NativeVibeOrchestrator.shared.record(
            source: "ui",
            action: "add_tile",
            tileID: tile.id,
            payload: ["kind": kind.rawValue, "title": tile.title]
        )
        persistSoon()
        return tile
    }

    func replaceTiles(with tiles: [NativeVibeTile]) {
        document.tiles = tiles
        nextZIndex = (tiles.map(\.zIndex).max() ?? 0) + 1
        focusedTileID = tiles.last?.id
        selectedTileID = tiles.last?.id
        persistSoon()
    }

    func clearAllTiles() {
        for tile in document.tiles {
            NativeVibeOrchestrator.shared.clearTile(tileID: tile.id)
        }
        document.tiles = []
        focusedTileID = nil
        selectedTileID = nil
        nextZIndex = 1
        persistSoon()
    }

    func updateTileFrame(
        id: UUID,
        frame: NativeVibeTileFrame,
        clearsLayoutPreset: Bool = true,
        persist: Bool = true,
        recordAction: Bool = true
    ) {
        guard let index = document.tiles.firstIndex(where: { $0.id == id }) else { return }
        if clearsLayoutPreset { clearLayoutPreset() }
        document.tiles[index].frame = frame
        document.tiles[index].updatedAt = Date()
        scrollContentHeight = computedContentHeight()
        if recordAction {
            NativeVibeOrchestrator.shared.record(source: "ui", action: "resize_tile", tileID: id)
        }
        if persist { persistSoon() }
    }

    func setTileFrames(_ frames: [UUID: NativeVibeTileFrame]) {
        for (id, frame) in frames {
            guard let index = document.tiles.firstIndex(where: { $0.id == id }) else { continue }
            document.tiles[index].frame = frame
            document.tiles[index].updatedAt = Date()
        }
        scrollContentHeight = computedContentHeight()
    }

    func bringToFront(id: UUID) {
        guard let index = document.tiles.firstIndex(where: { $0.id == id }) else { return }
        document.tiles[index].zIndex = nextZIndex
        nextZIndex += 1
        focusedTileID = id
        selectedTileID = id
        NativeVibeOrchestrator.shared.record(source: "ui", action: "focus_tile", tileID: id)
        persistSoon()
    }

    func removeTile(id: UUID) {
        document.tiles.removeAll { $0.id == id }
        if focusedTileID == id { focusedTileID = nil }
        if selectedTileID == id { selectedTileID = nil }
        statusMessage = "Removed tile"
        NativeVibeOrchestrator.shared.clearTile(tileID: id)
        NativeVibeOrchestrator.shared.record(source: "ui", action: "remove_tile", tileID: id)
        persistSoon()
    }

    func setCanvas(pan: CGPoint? = nil, zoom: CGFloat? = nil, background: String? = nil) {
        if let pan {
            document.panX = pan.x
            document.panY = pan.y
        }
        if let zoom { document.zoom = min(2.5, max(0.35, zoom)) }
        if let background { document.backgroundPreset = background }
        persistSoon()
    }

    func apply(document incoming: NativeVibeCanvasDocument) {
        document = incoming
        nextZIndex = (document.tiles.map(\.zIndex).max() ?? 0) + 1
        persistSoon()
    }

    func persistNow() {
        Self.save(document, to: persistenceURL)
    }

    private var persistWorkItem: DispatchWorkItem?

    private func persistSoon() {
        persistWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in self?.persistNow() }
        }
        persistWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    private static func bootstrapDocument() -> NativeVibeCanvasDocument {
        var doc = NativeVibeCanvasDocument.empty
        doc.tiles = [
            NativeVibeTile(
                kind: .agent,
                title: "Hermes",
                frame: NativeVibeTileFrame(origin: CGPoint(x: 80, y: 80), size: NativeVibeTileKind.agent.defaultSize),
                zIndex: 1,
                workspacePath: HermesChatClient.shared.activeWorkingDirectory
            ),
            NativeVibeTile(
                kind: .terminal,
                title: "Shell",
                frame: NativeVibeTileFrame(origin: CGPoint(x: 540, y: 120), size: NativeVibeTileKind.terminal.defaultSize),
                zIndex: 2
            ),
        ]
        return doc
    }

    private static func load(from url: URL) -> NativeVibeCanvasDocument? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(NativeVibeCanvasDocument.self, from: data)
    }

    private static func save(_ document: NativeVibeCanvasDocument, to url: URL) {
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(document) else { return }
        try? data.write(to: url, options: .atomic)
    }
}