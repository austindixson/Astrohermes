import CoreGraphics
import Foundation

/// Dynamic grid layout — variable tile spans (Hermes ×2, code, browser/music).
enum NativeVibeLayoutPreset: String, CaseIterable {
    case studio
    case devDesk = "dev_desk"
    case threeAgents = "three_agents"

    var label: String {
        switch self {
        case .studio: return "Studio"
        case .devDesk: return "Dev Desk"
        case .threeAgents: return "3 Agents"
        }
    }
}

struct NativeVibeLayoutCell {
    let kind: NativeVibeTileKind
    let title: String
    let url: String?
    let col: Int
    let row: Int
    let colSpan: Int
    let rowSpan: Int
}

struct NativeVibeGridMetrics {
    let cellWidth: CGFloat
    let cellHeight: CGFloat
    let gutter: CGFloat
    let origin: CGPoint
    let contentWidth: CGFloat
    let contentHeight: CGFloat
}

@MainActor
enum NativeVibeLayoutEngine {
    static let referenceCellWidth: CGFloat = 360
    static let referenceCellHeight: CGFloat = 280
    static let gutter: CGFloat = 12
    static let horizontalPadding: CGFloat = 16
    static let topChrome: CGFloat = 108
    static let bottomChrome: CGFloat = 44
    static let minCellHeight: CGFloat = 140

    static func cells(for preset: NativeVibeLayoutPreset, viewport: CGSize? = nil) -> [NativeVibeLayoutCell] {
        switch preset {
        case .threeAgents:
            let narrow = (viewport?.width ?? 1200) < NativeVibeTheme.compactBreakpoint
            if narrow {
                return [
                    NativeVibeLayoutCell(kind: .agent, title: "Lead", url: nil, col: 0, row: 0, colSpan: 1, rowSpan: 1),
                    NativeVibeLayoutCell(kind: .agent, title: "Worker 1", url: nil, col: 0, row: 1, colSpan: 1, rowSpan: 1),
                    NativeVibeLayoutCell(kind: .agent, title: "Worker 2", url: nil, col: 0, row: 2, colSpan: 1, rowSpan: 1),
                ]
            }
            return [
                NativeVibeLayoutCell(kind: .agent, title: "Lead", url: nil, col: 0, row: 0, colSpan: 1, rowSpan: 1),
                NativeVibeLayoutCell(kind: .agent, title: "Worker 1", url: nil, col: 1, row: 0, colSpan: 1, rowSpan: 1),
                NativeVibeLayoutCell(kind: .agent, title: "Worker 2", url: nil, col: 2, row: 0, colSpan: 1, rowSpan: 1),
            ]
        case .studio:
            return [
                NativeVibeLayoutCell(kind: .agent, title: "Hermes", url: nil, col: 0, row: 0, colSpan: 2, rowSpan: 2),
                NativeVibeLayoutCell(kind: .terminal, title: "Code", url: nil, col: 2, row: 0, colSpan: 1, rowSpan: 2),
                NativeVibeLayoutCell(kind: .agent, title: "Hermes 2", url: nil, col: 0, row: 2, colSpan: 2, rowSpan: 1),
                NativeVibeLayoutCell(
                    kind: .browser,
                    title: "Music",
                    url: "https://open.spotify.com",
                    col: 2,
                    row: 2,
                    colSpan: 1,
                    rowSpan: 1
                ),
            ]
        case .devDesk:
            return [
                NativeVibeLayoutCell(kind: .agent, title: "Hermes", url: nil, col: 0, row: 0, colSpan: 1, rowSpan: 2),
                NativeVibeLayoutCell(kind: .terminal, title: "Shell", url: nil, col: 1, row: 0, colSpan: 1, rowSpan: 1),
                NativeVibeLayoutCell(kind: .browser, title: "Browser", url: "https://www.google.com", col: 2, row: 0, colSpan: 1, rowSpan: 2),
                NativeVibeLayoutCell(kind: .note, title: "Notes", url: nil, col: 1, row: 1, colSpan: 1, rowSpan: 1),
            ]
        }
    }

    static func gridDimensions(for cells: [NativeVibeLayoutCell]) -> (cols: Int, rows: Int) {
        var maxCol = 0
        var maxRow = 0
        for cell in cells {
            maxCol = max(maxCol, cell.col + cell.colSpan)
            maxRow = max(maxRow, cell.row + cell.rowSpan)
        }
        return (maxCol, maxRow)
    }

    /// Fits grid width to the viewport; height scales to fill when possible, otherwise scrolls vertically.
    static func metrics(for preset: NativeVibeLayoutPreset, viewport: CGSize) -> NativeVibeGridMetrics {
        let layoutCells = cells(for: preset, viewport: viewport)
        let (cols, rows) = gridDimensions(for: layoutCells)
        let availableWidth = max(320, viewport.width - horizontalPadding * 2)
        let cellWidth = (availableWidth - CGFloat(cols - 1) * gutter) / CGFloat(cols)

        let availableHeight = max(240, viewport.height - topChrome - bottomChrome)
        let fitHeight = (availableHeight - CGFloat(rows - 1) * gutter) / CGFloat(rows)
        let cellHeight = max(minCellHeight, fitHeight)

        let gridWidth = CGFloat(cols) * cellWidth + CGFloat(cols - 1) * gutter
        let originX = horizontalPadding + max(0, (viewport.width - horizontalPadding * 2 - gridWidth) / 2)
        let originY = topChrome
        let gridHeight = CGFloat(rows) * cellHeight + CGFloat(rows - 1) * gutter
        let gridExtent = originY + gridHeight + bottomChrome
        let contentHeight = max(viewport.height, gridExtent)

        return NativeVibeGridMetrics(
            cellWidth: cellWidth,
            cellHeight: cellHeight,
            gutter: gutter,
            origin: CGPoint(x: originX, y: originY),
            contentWidth: viewport.width,
            contentHeight: contentHeight
        )
    }

    @discardableResult
    static func apply(
        preset: NativeVibeLayoutPreset,
        to store: NativeVibeCanvasStore,
        viewport: CGSize? = nil,
        workspacePath: String? = nil
    ) -> [NativeVibeTile] {
        let viewportSize = viewport ?? store.viewportSize
        let grid = metrics(for: preset, viewport: viewportSize)
        store.clearAllTiles()
        let layoutCells = cells(for: preset, viewport: viewportSize)
        var created: [NativeVibeTile] = []

        for cell in layoutCells {
            let frame = frameFor(cell: cell, metrics: grid)
            let tile = store.addTile(
                kind: cell.kind,
                at: CGPoint(x: frame.x, y: frame.y),
                title: cell.title,
                workspacePath: cell.kind == .agent || cell.kind == .terminal ? workspacePath : nil,
                url: cell.url,
                clearsLayoutPreset: false
            )
            store.updateTileFrame(id: tile.id, frame: frame, clearsLayoutPreset: false)
            created.append(tile)
        }

        store.finishLayoutApply(preset: preset, contentHeight: grid.contentHeight)
        store.setCanvas(pan: .zero, zoom: 1)
        store.statusMessage = "Applied \(preset.label) layout"
        NativeVibeOrchestrator.shared.record(
            source: "orchestrator",
            action: "apply_layout",
            payload: ["preset": preset.rawValue, "tile_count": String(created.count)]
        )
        return created
    }

    @discardableResult
    static func refit(
        preset: NativeVibeLayoutPreset,
        to store: NativeVibeCanvasStore,
        viewport: CGSize
    ) -> Bool {
        let layoutCells = cells(for: preset, viewport: viewport)
        let grid = metrics(for: preset, viewport: viewport)
        var frames: [UUID: NativeVibeTileFrame] = [:]
        var usedTileIDs = Set<UUID>()

        for cell in layoutCells {
            let tile =
                store.document.tiles.first(where: { $0.kind == cell.kind && $0.title == cell.title && !usedTileIDs.contains($0.id) })
                ?? store.document.tiles.first(where: { $0.kind == cell.kind && !usedTileIDs.contains($0.id) })
            guard let tile else { return false }
            usedTileIDs.insert(tile.id)
            frames[tile.id] = frameFor(cell: cell, metrics: grid)
        }

        guard frames.count == layoutCells.count else { return false }
        store.setTileFrames(frames)
        return true
    }

    static func frameFor(cell: NativeVibeLayoutCell, metrics: NativeVibeGridMetrics) -> NativeVibeTileFrame {
        let x = metrics.origin.x + CGFloat(cell.col) * (metrics.cellWidth + metrics.gutter)
        let y = metrics.origin.y + CGFloat(cell.row) * (metrics.cellHeight + metrics.gutter)
        let width = CGFloat(cell.colSpan) * metrics.cellWidth + CGFloat(cell.colSpan - 1) * metrics.gutter
        let height = CGFloat(cell.rowSpan) * metrics.cellHeight + CGFloat(cell.rowSpan - 1) * metrics.gutter
        return NativeVibeTileFrame(origin: CGPoint(x: x, y: y), size: CGSize(width: width, height: height))
    }
}