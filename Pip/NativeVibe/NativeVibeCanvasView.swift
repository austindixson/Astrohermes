import SwiftUI

struct NativeVibeCanvasView: View {
    @Bindable var store: NativeVibeCanvasStore
    @State private var draggingTileID: UUID?
    @State private var dragStartFrame: NativeVibeTileFrame?
    @State private var resizingTileID: UUID?
    @State private var resizeStartFrame: NativeVibeTileFrame?
    @State private var resizeStartPoint: CGPoint = .zero

    var body: some View {
        GeometryReader { geo in
            let contentHeight = store.scrollContentHeight(for: geo.size)
            let needsScroll = store.needsVerticalScroll(in: geo.size)

            ScrollView(.vertical, showsIndicators: needsScroll) {
                ZStack(alignment: .topLeading) {
                    NativeVibeCanvasBackground(preset: store.document.backgroundPreset)

                    CanvasGrid(size: CGSize(width: geo.size.width, height: contentHeight))

                    ForEach(store.sortedTiles) { tile in
                        tileView(tile)
                            .frame(width: tile.frame.width, height: tile.frame.height)
                            .position(
                                x: tile.frame.x + tile.frame.width / 2,
                                y: tile.frame.y + tile.frame.height / 2
                            )
                            .overlay(alignment: .bottomTrailing) {
                                resizeHandle(tile)
                            }
                    }
                }
                .frame(width: geo.size.width, height: contentHeight, alignment: .topLeading)
                .contentShape(Rectangle())
                .onTapGesture {
                    store.selectedTileID = nil
                    store.focusedTileID = nil
                }
            }
            .scrollBounceBehavior(needsScroll ? .automatic : .basedOnSize)
            .overlay(alignment: .topLeading) { toolbar }
            .overlay(alignment: .bottomLeading) { statusBar }
            .onAppear { store.updateViewport(geo.size) }
            .onChange(of: geo.size) { _, newSize in
                store.updateViewport(newSize)
            }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Button {
                NativeVibeLayoutEngine.apply(preset: .studio, to: store, viewport: store.viewportSize)
            } label: {
                Label("Studio", systemImage: "square.grid.2x2")
                    .font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
            }
            .buttonStyle(.plain)
            .background(Capsule().fill(NativeVibeTheme.accent.opacity(0.25)))
            .accessibilityLabel("Studio")
            .accessibilityIdentifier("nativevibe.toolbar.studio")

            ForEach([NativeVibeTileKind.agent, .terminal, .browser, .note, .diagram], id: \.self) { kind in
                Button {
                    store.addTile(kind: kind)
                } label: {
                    Label(kind.label, systemImage: icon(for: kind))
                        .font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.plain)
                .background(Capsule().fill(NativeVibeTheme.tileChrome))
                .accessibilityLabel(kind.label)
                .accessibilityIdentifier("nativevibe.toolbar.\(kind.rawValue)")
            }
        }
        .padding(14)
    }

    private var statusBar: some View {
        Text(store.statusMessage)
            .font(.system(size: 11, weight: .medium, design: .rounded))
            .foregroundStyle(NativeVibeTheme.tileMuted)
            .accessibilityLabel(store.statusMessage)
            .accessibilityIdentifier("nativevibe.status")
            .padding(.horizontal, 14)
            .padding(.bottom, 12)
    }

    private func tileView(_ tile: NativeVibeTile) -> some View {
        let focused = store.focusedTileID == tile.id
        return NativeVibeTileChrome(
            title: tile.title,
            kind: tile.kind,
            isFocused: focused,
            onClose: { store.removeTile(id: tile.id) },
            headerDragGesture: AnyGesture(tileDragGesture(tile).map { _ in () })
        ) {
            switch tile.kind {
            case .agent:
                NativeVibeAgentTileView(tile: tile)
            case .terminal:
                NativeVibeTerminalTileView(tile: tile)
            case .browser:
                NativeVibeBrowserTileView(tile: tile)
            default:
                NativeVibePlaceholderTileView(kind: tile.kind)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(tile.title)
        .accessibilityIdentifier("nativevibe.tile.\(tile.id.uuidString)")
        .accessibilityAddTraits(.isButton)
        .onTapGesture { store.bringToFront(id: tile.id) }
    }

    private func tileDragGesture(_ tile: NativeVibeTile) -> some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                if draggingTileID != tile.id {
                    draggingTileID = tile.id
                    dragStartFrame = store.tile(id: tile.id)?.frame ?? tile.frame
                    store.bringToFront(id: tile.id)
                }
                guard var frame = dragStartFrame else { return }
                frame.x += value.translation.width
                frame.y += value.translation.height
                store.updateTileFrame(
                    id: tile.id,
                    frame: frame,
                    persist: false,
                    recordAction: false
                )
            }
            .onEnded { _ in
                draggingTileID = nil
                dragStartFrame = nil
                store.persistNow()
            }
    }

    private func resizeHandle(_ tile: NativeVibeTile) -> some View {
        Image(systemName: "arrow.up.left.and.arrow.down.right")
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(NativeVibeTheme.tileMuted)
            .padding(6)
            .background(Circle().fill(Color.black.opacity(0.35)))
            .padding(6)
            .gesture(
                DragGesture(minimumDistance: 2)
                    .onChanged { value in
                        if resizingTileID != tile.id {
                            resizingTileID = tile.id
                            resizeStartFrame = store.tile(id: tile.id)?.frame ?? tile.frame
                            resizeStartPoint = value.startLocation
                        }
                        guard var frame = resizeStartFrame else { return }
                        let dx = value.location.x - resizeStartPoint.x
                        let dy = value.location.y - resizeStartPoint.y
                        frame.width = max(240, frame.width + dx)
                        frame.height = max(160, frame.height + dy)
                        store.updateTileFrame(
                            id: tile.id,
                            frame: frame,
                            persist: false,
                            recordAction: false
                        )
                    }
                    .onEnded { _ in
                        resizingTileID = nil
                        resizeStartFrame = nil
                        store.persistNow()
                    }
            )
    }

    private func icon(for kind: NativeVibeTileKind) -> String {
        switch kind {
        case .agent: return "sparkles"
        case .terminal: return "terminal"
        case .browser: return "globe"
        case .markdown: return "doc.richtext"
        case .diagram: return "point.3.connected.trianglepath.dotted"
        case .note: return "note.text"
        }
    }
}

private struct CanvasGrid: View {
    let size: CGSize

    var body: some View {
        Canvas { context, canvasSize in
            let spacing: CGFloat = 48
            var path = Path()
            stride(from: 0, through: canvasSize.width, by: spacing).forEach { x in
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: canvasSize.height))
            }
            stride(from: 0, through: canvasSize.height, by: spacing).forEach { y in
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: canvasSize.width, y: y))
            }
            context.stroke(path, with: .color(NativeVibeTheme.gridLine), lineWidth: 1)
        }
        .frame(width: size.width, height: size.height)
    }
}