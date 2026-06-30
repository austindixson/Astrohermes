import Foundation
import CoreGraphics

/// Tile kinds on the infinite canvas (CNVS parity surface).
enum NativeVibeTileKind: String, Codable, CaseIterable, Identifiable {
    case agent
    case terminal
    case browser
    case markdown
    case diagram
    case note

    var id: String { rawValue }

    var label: String {
        switch self {
        case .agent: return "Agent"
        case .terminal: return "Terminal"
        case .browser: return "Browser"
        case .markdown: return "Markdown"
        case .diagram: return "Diagram"
        case .note: return "Note"
        }
    }

    var defaultSize: CGSize {
        switch self {
        case .agent: return CGSize(width: 420, height: 520)
        case .terminal: return CGSize(width: 640, height: 380)
        case .browser: return CGSize(width: 720, height: 480)
        case .markdown: return CGSize(width: 480, height: 560)
        case .diagram: return CGSize(width: 520, height: 400)
        case .note: return CGSize(width: 320, height: 240)
        }
    }
}

struct NativeVibeTileFrame: Codable, Equatable {
    var x: CGFloat
    var y: CGFloat
    var width: CGFloat
    var height: CGFloat

    var origin: CGPoint { CGPoint(x: x, y: y) }
    var size: CGSize { CGSize(width: width, height: height) }

    init(origin: CGPoint, size: CGSize) {
        x = origin.x
        y = origin.y
        width = size.width
        height = size.height
    }
}

struct NativeVibeTile: Identifiable, Codable, Equatable {
    let id: UUID
    var kind: NativeVibeTileKind
    var title: String
    var frame: NativeVibeTileFrame
    var zIndex: Int
    var workspacePath: String?
    var url: String?
    var agentSessionID: String?
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        kind: NativeVibeTileKind,
        title: String? = nil,
        frame: NativeVibeTileFrame,
        zIndex: Int = 0,
        workspacePath: String? = nil,
        url: String? = nil,
        agentSessionID: String? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.kind = kind
        self.title = title ?? kind.label
        self.frame = frame
        self.zIndex = zIndex
        self.workspacePath = workspacePath
        self.url = url
        self.agentSessionID = agentSessionID ?? UUID().uuidString
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

struct NativeVibeCanvasDocument: Codable, Equatable {
    var tiles: [NativeVibeTile]
    var panX: CGFloat
    var panY: CGFloat
    var zoom: CGFloat
    var backgroundPreset: String
    var lastLayoutPreset: String?

    static let empty = NativeVibeCanvasDocument(
        tiles: [],
        panX: 0,
        panY: 0,
        zoom: 1,
        backgroundPreset: "aurora",
        lastLayoutPreset: nil
    )
}

/// Commands Hermes / CLI can send into the running app.
enum NativeVibeBridgeCommand: String, Codable {
    case spawnWindow = "spawn_window"
    case closeWindow = "close_window"
    case addTile = "add_tile"
    case updateTile = "update_tile"
    case removeTile = "remove_tile"
    case focusTile = "focus_tile"
    case setCanvas = "set_canvas"
    case sendAgentMessage = "send_agent_message"
    case writeTerminal = "write_terminal"
    case memoryRetrieve = "memory_retrieve"
    case voiceToggle = "voice_toggle"
    case ping
    case listTiles = "list_tiles"
    case getCanvas = "get_canvas"
    case getState = "get_state"
    case readTerminal = "read_terminal"
    case readAgent = "read_agent"
    case getActions = "get_actions"
    case setTileFrame = "set_tile_frame"
    case applyLayout = "apply_layout"
    case navigateBrowser = "navigate_browser"
}

struct NativeVibeBridgeRequest: Codable {
    var id: String
    var command: NativeVibeBridgeCommand
    var payload: [String: String]

    init(id: String = UUID().uuidString, command: NativeVibeBridgeCommand, payload: [String: String] = [:]) {
        self.id = id
        self.command = command
        self.payload = payload
    }
}

struct NativeVibeBridgeResponse: Codable {
    var id: String
    var ok: Bool
    var message: String
    var data: [String: String]

    static func success(id: String, message: String = "ok", data: [String: String] = [:]) -> NativeVibeBridgeResponse {
        NativeVibeBridgeResponse(id: id, ok: true, message: message, data: data)
    }

    static func failure(id: String, message: String) -> NativeVibeBridgeResponse {
        NativeVibeBridgeResponse(id: id, ok: false, message: message, data: [:])
    }
}