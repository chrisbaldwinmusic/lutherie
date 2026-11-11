import PedalCore
import SwiftUI

/// The drawing board: grid, wires, parts, and mouse editing.
struct SchematicView: View {
    @ObservedObject var model: EditorModel
    @State private var hover: CGPoint?
    @State private var dragStart: CGPoint?
    @State private var dragMode: DragMode = .none
    @State private var dragNow: CGPoint = .zero
    @State private var panStart: CGSize = .zero
    @State private var zoomStart: CGFloat?
    @FocusState private var focused: Bool

    enum DragMode { case none, move(Set<UUID>, GridPoint), pan, wire(GridPoint), place, marquee }

    var unit: CGFloat { 20 * model.zoom }
    var origin: CGPoint { CGPoint(x: model.pan.width, y: model.pan.height) }

    func toGrid(_ p: CGPoint) -> GridPoint {
        GridPoint(Int(((p.x - origin.x) / unit).rounded()), Int(((p.y - origin.y) / unit).rounded()))
    }
    func toView(_ g: GridPoint) -> CGPoint { CGPoint(x: origin.x + CGFloat(g.x) * unit, y: origin.y + CGFloat(g.y) * unit) }

    func hitPart(_ p: CGPoint) -> Part? {
        let gx = (p.x - origin.x) / unit, gy = (p.y - origin.y) / unit
        for part in model.circuit.parts.reversed() {
            var x = gx - CGFloat(part.position.x), y = gy - CGFloat(part.position.y)
            switch part.rotation {  // inverse rotation
            case 1: (x, y) = (y, -x)
            case 2: (x, y) = (-x, -y)
            case 3: (x, y) = (-y, x)
            default: break
            }
            if part.flipped { x = -x }
            if Symbol.bounds(part.kind).insetBy(dx: -0.15, dy: -0.15).contains(CGPoint(x: x, y: y)) { return part }
        }
        return nil
    }

    func hitWire(_ p: CGPoint) -> Wire? {
        let gx = (p.x - origin.x) / unit, gy = (p.y - origin.y) / unit
        for w in model.circuit.wires {
            let ax = CGFloat(w.a.x), ay = CGFloat(w.a.y), bx = CGFloat(w.b.x), by = CGFloat(w.b.y)
            let dx = bx - ax, dy = by - ay
            let len2 = dx * dx + dy * dy
            guard len2 > 0 else { continue }
            let t = max(0, min(1, ((gx - ax) * dx + (gy - ay) * dy) / len2))
            let qx = ax + t * dx - gx, qy = ay + t * dy - gy
            if qx * qx + qy * qy < 0.09 { return w }
        }
        return nil
    }

    var body: some View {
        GeometryReader { geo in
            Canvas { ctx, size in
                drawGrid(&ctx, size)
                drawWires(&ctx)
                drawParts(&ctx)
                drawOverlay(&ctx)
            }
            .background(Theme.bg)
            .contentShape(Rectangle())
            .gesture(drag)
            .simultaneousGesture(MagnifyGesture()
                .onChanged { v in
                    if zoomStart == nil { zoomStart = model.zoom }
                    model.zoom = min(3, max(0.35, (zoomStart ?? 1) * v.magnification))
                }
                .onEnded { _ in zoomStart = nil })
            .onContinuousHover { phase in
                if case .active(let p) = phase { hover = p } else { hover = nil }
            }
            .focusable()
            .focusEffectDisabled()
            .focused($focused)
            .onAppear { focused = true }
            .onKeyPress(phases: .down) { press in handleKey(press) }
            .overlay(alignment: .bottomLeading) { hint.padding(10) }
            .overlay(alignment: .bottomTrailing) { zoomControls.padding(10) }
            .overlay(alignment: .topTrailing) { if model.learnMode { LessonCard(model: model).padding(10) } }
            .clipped()
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    // MARK: Drawing

    func drawGrid(_ ctx: inout GraphicsContext, _ size: CGSize) {
        let step = unit
        guard step >= 6 else { return }
        var dots = Path()
        let x0 = origin.x.truncatingRemainder(dividingBy: step), y0 = origin.y.truncatingRemainder(dividingBy: step)
        var x = x0
        while x < size.width {
            var y = y0
            while y < size.height { dots.addRect(CGRect(x: x - 0.75, y: y - 0.75, width: 1.5, height: 1.5)); y += step }
            x += step
        }
        ctx.fill(dots, with: .color(Color(white: 1, opacity: 0.13)))
    }

    func drawWires(_ ctx: inout GraphicsContext) {
        let c = model.circuit
        var counts: [GridPoint: Int] = [:]
        for w in c.wires { counts[w.a, default: 0] += 1; counts[w.b, default: 0] += 1 }
        for p in c.parts { for pin in p.pins { counts[pin, default: 0] += 1 } }
        for w in c.wires {
            var path = Path()
            path.move(to: toView(w.a)); path.addLine(to: toView(w.b))
            let sel = model.selectedWires.contains(w.id)
            ctx.stroke(path, with: .color(sel ? Theme.selected : Theme.wire), style: StrokeStyle(lineWidth: sel ? 2.6 : 1.8, lineCap: .round))
        }
        // junction dots where three or more things meet
        for (pt, n) in counts where n >= 3 {
            let v = toView(pt)
            ctx.fill(Path(ellipseIn: CGRect(x: v.x - 3.5, y: v.y - 3.5, width: 7, height: 7)), with: .color(Theme.wire))
        }
    }

    func drawParts(_ ctx: inout GraphicsContext) {
        var moving: Set<UUID> = []
        var offset = GridPoint(0, 0)
        if case .move(let ids, let start) = dragMode { moving = ids; offset = toGrid(dragNow) - start }
        for var part in model.circuit.parts {
            if moving.contains(part.id) { part.position = part.position + offset }
            let sel = model.selection.contains(part.id)
            drawPart(part, in: &ctx, origin: origin, scale: unit, color: sel ? Theme.selected : Theme.part, lineWidth: sel ? 2.2 : 1.6)
        }
        // open pins
        let net = Netlist.build(model.circuit)
        var uses: [Int: Int] = [:]
        for p in model.circuit.parts { for n in net.pinNodes[p.id] ?? [] { uses[n, default: 0] += 1 } }
        for p in model.circuit.parts where ![.ground, .supply, .label].contains(p.kind) {
            for (i, pin) in p.pins.enumerated() {
                let n = net.pinNodes[p.id]?[i] ?? 0
                if n != 0 && (uses[n] ?? 0) < 2 {
                    let v = toView(pin)
                    ctx.stroke(Path(ellipseIn: CGRect(x: v.x - 3, y: v.y - 3, width: 6, height: 6)), with: .color(Theme.pin), lineWidth: 1.4)
                }
            }
        }
    }

    func drawOverlay(_ ctx: inout GraphicsContext) {
        if case .wire(let start) = dragMode {
            let end = toGrid(dragNow)
            let vfirst = verticalFirst(start, end)
            let corner = vfirst ? GridPoint(start.x, end.y) : GridPoint(end.x, start.y)
            var path = Path()
            path.move(to: toView(start)); path.addLine(to: toView(corner)); path.addLine(to: toView(end))
            ctx.stroke(path, with: .color(Theme.accent), style: StrokeStyle(lineWidth: 2, dash: [5, 4]))
        }
        if case .marquee = dragMode, let s = dragStart {
            let r = CGRect(x: min(s.x, dragNow.x), y: min(s.y, dragNow.y), width: abs(dragNow.x - s.x), height: abs(dragNow.y - s.y))
            ctx.fill(Path(r), with: .color(Theme.accent.opacity(0.08)))
            ctx.stroke(Path(r), with: .color(Theme.accent.opacity(0.6)), lineWidth: 1)
        }
        if let h = hover {
            switch model.tool {
            case .place(let kind):
                let ghost = Part(kind, name: model.circuit.nextName(for: kind), at: toGrid(h))
                drawPart(ghost, in: &ctx, origin: origin, scale: unit, color: Theme.accent.opacity(0.7), lineWidth: 1.6)
            case .wire:
                let v = toView(toGrid(h))
                ctx.stroke(Path(ellipseIn: CGRect(x: v.x - 5, y: v.y - 5, width: 10, height: 10)), with: .color(Theme.accent), lineWidth: 1.5)
            default: break
            }
        }
    }

    func verticalFirst(_ a: GridPoint, _ b: GridPoint) -> Bool {
        // start along the direction the pointer moved most
        abs(b.y - a.y) > abs(b.x - a.x) && NSEvent.modifierFlags.contains(.shift) == false
    }

    // MARK: Mouse

    var drag: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { v in
                focused = true
                dragNow = v.location
                if dragStart == nil {
                    dragStart = v.startLocation
                    begin(at: v.startLocation)
                }
                if case .pan = dragMode {
                    model.pan = CGSize(width: panStart.width + v.translation.width, height: panStart.height + v.translation.height)
                }
            }
            .onEnded { v in
                finish(at: v.location, moved: hypot(v.translation.width, v.translation.height) > 3)
                dragStart = nil
                dragMode = .none
            }
    }

    func begin(at p: CGPoint) {
        let shift = NSEvent.modifierFlags.contains(.shift)
        let option = NSEvent.modifierFlags.contains(.option)
        switch model.tool {
        case .place: dragMode = .place
        case .wire: dragMode = .wire(toGrid(p))
        case .select:
            if let part = hitPart(p) {
                if shift { model.selection.formSymmetricDifference([part.id]) }
                else if !model.selection.contains(part.id) { model.selection = [part.id]; model.selectedWires = [] }
                dragMode = .move(model.selection, toGrid(p))
            } else if let w = hitWire(p) {
                if shift { model.selectedWires.formSymmetricDifference([w.id]) } else { model.selectedWires = [w.id]; model.selection = [] }
                dragMode = .none
            } else if option || shift {
                dragMode = .marquee
            } else {
                panStart = model.pan
                dragMode = .pan
            }
        }
    }

    func finish(at p: CGPoint, moved: Bool) {
        switch dragMode {
        case .place:
            if case .place(let kind) = model.tool { model.place(kind, at: toGrid(p)) }
            if !NSEvent.modifierFlags.contains(.shift) { model.tool = .select }
        case .wire(let start):
            let end = toGrid(p)
            if start != end { model.addWire(start, end, verticalFirst: verticalFirst(start, end)) }
        case .move(let ids, let start):
            let d = toGrid(p) - start
            if moved && d != GridPoint(0, 0) { model.move(ids, by: d, wiresToo: !NSEvent.modifierFlags.contains(.option)) }
        case .pan:
            if !moved { model.selection = []; model.selectedWires = [] }
        case .marquee:
            if let s = dragStart {
                let a = toGrid(CGPoint(x: min(s.x, p.x), y: min(s.y, p.y))), b = toGrid(CGPoint(x: max(s.x, p.x), y: max(s.y, p.y)))
                let inside = { (g: GridPoint) in g.x >= a.x && g.x <= b.x && g.y >= a.y && g.y <= b.y }
                model.selection = Set(model.circuit.parts.filter { inside($0.position) }.map(\.id))
                model.selectedWires = Set(model.circuit.wires.filter { inside($0.a) && inside($0.b) }.map(\.id))
            }
        case .none: break
        }
    }

    func handleKey(_ press: KeyPress) -> KeyPress.Result {
        if press.modifiers.contains(.command) { return .ignored }
        switch press.key {
        case .delete, .deleteForward: model.deleteSelection(); return .handled
        case .escape: model.tool = .select; model.selection = []; model.selectedWires = []; return .handled
        default: break
        }
        switch press.characters.lowercased() {
        case "r": model.rotateSelection()
        case "f": model.flipSelection()
        case "w": model.tool = .wire
        case "s", "v": model.tool = .select
        case "d": model.duplicateSelection()
        case "=", "+": model.zoom = min(3, model.zoom * 1.2)
        case "-": model.zoom = max(0.35, model.zoom / 1.2)
        default:
            if let k = Palette.shortcuts[press.characters.lowercased()] { model.tool = .place(k); return .handled }
            return .ignored
        }
        return .handled
    }

    var hint: some View {
        let text: String
        switch model.tool {
        case .select: text = "Drag parts to move • drag empty space to pan • Shift-drag to box-select • R rotate • F flip • ⌫ delete"
        case .wire: text = "Drag from pin to pin to wire (Shift for the other corner) • Esc to stop"
        case .place(let k): text = "Click to place \(k.displayName.lowercased()) • Shift-click to place several • Esc to stop"
        }
        return Text(text).font(.system(size: 11)).foregroundColor(Theme.dim)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Theme.panel.opacity(0.85), in: RoundedRectangle(cornerRadius: 6))
    }

    var zoomControls: some View {
        HStack(spacing: 4) {
            Button { model.zoom = max(0.35, model.zoom / 1.2) } label: { Image(systemName: "minus.magnifyingglass") }
            Text("\(Int(model.zoom * 100))%").font(.system(size: 11).monospacedDigit()).foregroundColor(Theme.dim).frame(width: 40)
            Button { model.zoom = min(3, model.zoom * 1.2) } label: { Image(systemName: "plus.magnifyingglass") }
            Button { model.fitView() } label: { Image(systemName: "arrow.up.left.and.down.right.magnifyingglass") }.help("Show the whole circuit")
        }
        .buttonStyle(.borderless)
        .padding(6)
        .background(Theme.panel.opacity(0.85), in: RoundedRectangle(cornerRadius: 6))
    }
}
