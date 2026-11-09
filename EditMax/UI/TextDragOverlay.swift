import SwiftUI
import AppKit

/// Titles on the program monitor can be grabbed and moved, as in other editors: hover one to see its box, click it to
/// select it (the inspector shows it), drag it to move it. The title follows the pointer in the picture itself
/// (`LiveTextPositions`), snaps to the frame's centre lines, and the move becomes one undoable edit when the mouse goes
/// up. A caption moves with the rest of its set, so captions stay in one place. Shown while paused, on the current
/// version only (an older version's titles are not the project's).
struct TextDragOverlay: View {
    @ObservedObject var document: EditMaxDocument
    @ObservedObject var player: PlayerController
    @ObservedObject var state: EditorState
    /// The project's width / height: the picture is aspect-fit in the view, as the player layer draws it.
    let aspect: Double

    struct Drag: Equatable {
        var id: UUID
        /// Where each moving title started (the dragged one and the rest of its caption set).
        var starts: [UUID: CGPoint]
        var moves: [UUID: CGPoint]
        var snapX = false, snapY = false
    }
    @State private var drag: Drag?
    @State private var hovered: UUID?

    /// Within this many points of the frame's centre line, a dragged title's centre sits on it.
    static let snapPoints: CGFloat = 6
    private static let space = "textDrag"

    private var canvas: CGSize { CGSize(width: document.project.settings.width, height: document.project.settings.height) }

    /// The titles on screen at the playhead; none while playing, unless one is being dragged.
    private var visible: [TextOverlay] {
        guard player.viewingProject == nil, !player.isPlaying || drag != nil else { return [] }
        let t = player.currentTime
        return document.project.texts.filter { ($0.start <= t && t < $0.end) || $0.id == drag?.id }
    }

    var body: some View {
        GeometryReader { geo in
            let pic = MonitorLayout.picture(in: geo.size, aspect: aspect)
            ZStack(alignment: .topLeading) {
                ForEach(visible) { t in box(t, pic: pic) }
                if let d = drag { guides(d, pic: pic) }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            .coordinateSpace(name: Self.space)
        }
    }

    // MARK: Geometry (static, so tests can check it)

    /// A title's box (normalized, y down, as `TextLayout.box`) in the view's points, for a picture drawn in `pic`.
    static func rect(_ box: CGRect, in pic: CGRect) -> CGRect {
        CGRect(x: pic.minX + box.minX * pic.width, y: pic.minY + box.minY * pic.height, width: box.width * pic.width, height: box.height * pic.height)
    }

    /// Where a drag of `translation` points puts a title centred on `start`, in a picture `pic` points large: snapped to
    /// the frame's centre lines within `snapPoints`, and never off the frame.
    static func dragged(from start: CGPoint, by translation: CGSize, pic: CGSize) -> (point: CGPoint, snapX: Bool, snapY: Bool) {
        guard pic.width > 0, pic.height > 0 else { return (start, false, false) }
        var x = start.x + translation.width / pic.width, y = start.y + translation.height / pic.height
        let snapX = abs(x - 0.5) * pic.width < snapPoints, snapY = abs(y - 0.5) * pic.height < snapPoints
        if snapX { x = 0.5 }
        if snapY { y = 0.5 }
        return (CGPoint(x: min(1, max(0, x)), y: min(1, max(0, y))), snapX, snapY)
    }

    /// The titles that move together with `t`: its caption set, or only itself.
    static func moving(with t: TextOverlay, in texts: [TextOverlay]) -> [TextOverlay] {
        guard let g = t.group else { return [t] }
        return texts.filter { $0.group == g }
    }

    // MARK: Views

    private func box(_ t: TextOverlay, pic: CGRect) -> some View {
        let at = drag?.moves[t.id] ?? CGPoint(x: t.x, y: t.y)
        var placed = t; placed.x = at.x; placed.y = at.y
        let r = Self.rect(TextLayout.box(placed, canvas: canvas), in: pic).insetBy(dx: -4, dy: -3)
        let selected = state.selectedTextID == t.id, dragging = drag?.id == t.id
        return RoundedRectangle(cornerRadius: 3)
            .strokeBorder(dragging || selected ? Color.accentColor : Color.white.opacity(0.85),
                          style: StrokeStyle(lineWidth: dragging || selected ? 1.5 : 1, dash: dragging || selected ? [] : [4, 3]))
            .opacity(dragging || selected || hovered == t.id ? 1 : 0)
            .contentShape(Rectangle())
            .frame(width: max(12, r.width), height: max(12, r.height))
            .onHover { inside in if inside { hovered = t.id } else if hovered == t.id { hovered = nil } }
            .pointerStyle(dragging ? .grabActive : .grabIdle)
            .help(t.isCaption ? "Drag to move the captions" : "Drag to move this text")
            .onTapGesture { select(t) }
            .gesture(DragGesture(minimumDistance: 2, coordinateSpace: .named(Self.space))
                .onChanged { v in move(t, by: v.translation, pic: pic.size) }
                .onEnded { v in move(t, by: v.translation, pic: pic.size); finish() })
            .uiFrame("preview.text.\(t.id.short)")
            .uiTap("preview.text.\(t.id.short)") { select(t) }
            .position(x: r.midX, y: r.midY)   // last: modifiers after it would cover the whole viewer
    }

    private func guides(_ d: Drag, pic: CGRect) -> some View {
        ZStack(alignment: .topLeading) {
            if d.snapX { Rectangle().fill(Color.pink).frame(width: 1, height: pic.height).position(x: pic.midX, y: pic.midY) }
            if d.snapY { Rectangle().fill(Color.pink).frame(width: pic.width, height: 1).position(x: pic.midX, y: pic.midY) }
        }
        .allowsHitTesting(false)
    }

    // MARK: Actions

    private func select(_ t: TextOverlay) {
        state.selectedTextID = t.id
        state.selectedClipIDs = []
    }

    private func move(_ t: TextOverlay, by translation: CGSize, pic: CGSize) {
        if drag?.id != t.id { select(t); drag = Self.begin(t, in: document.project.texts) }
        guard var d = drag else { return }
        Self.update(&d, by: translation, pic: pic)
        drag = d
        LiveTextPositions.shared.set(d.moves)
        player.redrawMovedText()
    }

    private func finish() {
        guard let d = drag else { return }
        drag = nil
        // The live positions stay until the rebuilt player has these (PlayerController.rebuild settles them).
        if !Self.commit(d, to: document) { LiveTextPositions.shared.clear(); player.redrawMovedText() }
    }

    // MARK: The drag itself (static: the gesture above and the tests run the same code)

    /// A drag that starts on `t`: it and the rest of its caption set, where they are now.
    static func begin(_ t: TextOverlay, in texts: [TextOverlay]) -> Drag {
        let starts = Dictionary(uniqueKeysWithValues: moving(with: t, in: texts).map { ($0.id, CGPoint(x: $0.x, y: $0.y)) })
        return Drag(id: t.id, starts: starts, moves: starts)
    }

    /// Moves every title of the drag by the pointer's `translation` (points) in a picture `pic` points large.
    static func update(_ d: inout Drag, by translation: CGSize, pic: CGSize) {
        guard let start = d.starts[d.id] else { return }
        let (p, sx, sy) = dragged(from: start, by: translation, pic: pic)
        let dx = p.x - start.x, dy = p.y - start.y
        d.moves = d.starts.mapValues { CGPoint(x: min(1, max(0, $0.x + dx)), y: min(1, max(0, $0.y + dy))) }
        d.snapX = sx; d.snapY = sy
    }

    /// Makes the drag one undoable edit; false when nothing moved (a click).
    @discardableResult static func commit(_ d: Drag, to document: EditMaxDocument) -> Bool {
        guard d.moves != d.starts else { return false }
        document.apply(d.moves.count > 1 ? "Move captions" : "Move text", origin: .user) { p in
            for i in p.texts.indices { if let q = d.moves[p.texts[i].id] { p.texts[i].x = q.x; p.texts[i].y = q.y } }
        }
        DebugLog.event("text-drag", ["texts": d.moves.count])
        return true
    }
}
