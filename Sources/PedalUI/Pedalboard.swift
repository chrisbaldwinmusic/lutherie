import PedalCore
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Finishes

/// How a pedal's enclosure looks. Lutherie's own palette: each starter circuit gets a finish that hints at
/// its family (boosts light, fuzzes hammered, distortions dark) without copying any real product.
struct PedalFinish {
    enum Texture { case smooth, hammered, brushed }
    var top: UInt32
    var bottom: UInt32
    var ink: UInt32
    var creamKnobs = false
    var texture: Texture = .smooth
    var led: UInt32 = 0xff3b30

    var inkColor: Color { Theme.hex(ink) }

    static func of(_ c: Circuit) -> PedalFinish {
        switch c.name {
        case "JFET Clean Boost": return PedalFinish(top: 0xece4cf, bottom: 0xcfc5ab, ink: 0x2a2224, led: 0x3d9cff)
        case "Single-Transistor Boost": return PedalFinish(top: 0x9fb8a2, bottom: 0x7e9a82, ink: 0x1b2420)
        case "MOSFET Boost": return PedalFinish(top: 0xd9d4cb, bottom: 0xa9a49a, ink: 0x1c1b1d, texture: .brushed, led: 0x3d9cff)
        case "Germanium Treble Booster": return PedalFinish(top: 0xc7cbd0, bottom: 0x8e9399, ink: 0x161719, texture: .brushed)
        case "Diode Overdrive": return PedalFinish(top: 0xc4473f, bottom: 0x8f2a27, ink: 0xf3ead6, creamKnobs: true)
        case "Cascaded JFET Overdrive": return PedalFinish(top: 0x2f7470, bottom: 0x1e4d4a, ink: 0xf0e8d2, creamKnobs: true)
        case "Selectable-Clip Overdrive": return PedalFinish(top: 0xd8a83c, bottom: 0xa87a1f, ink: 0x1d1709)
        case "Hard-Clip Distortion": return PedalFinish(top: 0x2a2a2d, bottom: 0x121214, ink: 0xf08a3c, texture: .smooth, led: 0xff8a1f)
        case "Slew-Limited Distortion": return PedalFinish(top: 0x47607d, bottom: 0x2c3e55, ink: 0xf0e8d2, creamKnobs: true)
        case "Two-Transistor Fuzz": return PedalFinish(top: 0x6c4c8e, bottom: 0x43305c, ink: 0xf1e9d6, texture: .hammered)
        case "Germanium Fuzz": return PedalFinish(top: 0xb4683b, bottom: 0x7a3f22, ink: 0xf6eedb, texture: .hammered)
        case "Four-Stage Sustain Fuzz": return PedalFinish(top: 0x66724a, bottom: 0x414b2d, ink: 0xf1ead4, creamKnobs: true, texture: .hammered)
        case "Bass Blend Overdrive": return PedalFinish(top: 0x2c406a, bottom: 0x1a2744, ink: 0xe9dfc6, led: 0x3d9cff)
        default:
            // a circuit of the player's own: a steady colour from its name
            let palette: [(UInt32, UInt32, UInt32, Bool)] = [(0x7b2f3b, 0x4f1c26, 0xf1e8d2, true), (0x3b5f4a, 0x24402f, 0xf1e8d2, true),
                                                             (0x5a5560, 0x37333b, 0xf1e8d2, true), (0xc9b48a, 0x9e8a62, 0x221c14, false),
                                                             (0x2f5873, 0x1c384c, 0xf1e8d2, true)]
            var h: UInt32 = 2166136261
            for b in c.name.utf8 { h = (h ^ UInt32(b)) &* 16777619 }
            let p = palette[Int(h % UInt32(palette.count))]
            return PedalFinish(top: p.0, bottom: p.1, ink: p.2, creamKnobs: p.3)
        }
    }
}

/// The painted, stamped box of a pedal: finish, texture, corner screws and a lit edge.
struct Enclosure: View {
    let finish: PedalFinish
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
        ZStack {
            shape.fill(LinearGradient(colors: [Theme.hex(finish.top), Theme.hex(finish.bottom)], startPoint: .top, endPoint: .bottom))
            Canvas { ctx, size in
                switch finish.texture {
                case .smooth: break
                case .brushed:
                    var y: CGFloat = 0, k: UInt32 = 7
                    while y < size.height {
                        k = k &* 1664525 &+ 1013904223
                        var l = Path(); l.move(to: CGPoint(x: 0, y: y)); l.addLine(to: CGPoint(x: size.width, y: y))
                        ctx.stroke(l, with: .color((k & 1 == 0 ? Color.white : .black).opacity(0.05 + Double(k >> 28) * 0.004)), lineWidth: 0.6)
                        y += 1.3
                    }
                case .hammered:
                    var k: UInt32 = 12345
                    for _ in 0..<Int(size.width * size.height / 38) {
                        k = k &* 1664525 &+ 1013904223; let x = CGFloat(k >> 16) / 65536 * size.width
                        k = k &* 1664525 &+ 1013904223; let y = CGFloat(k >> 16) / 65536 * size.height
                        k = k &* 1664525 &+ 1013904223; let r = 1.5 + CGFloat(k >> 29)
                        let rect = CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)
                        ctx.fill(Path(ellipseIn: rect), with: .radialGradient(Gradient(colors: [.white.opacity(0.13), .black.opacity(0.10)]),
                                                                              center: CGPoint(x: x - r * 0.3, y: y - r * 0.3), startRadius: 0, endRadius: r))
                    }
                }
                // corner screws
                for (x, y) in [(7.0, 7.0), (size.width - 7, 7.0), (7.0, size.height - 7), (size.width - 7, size.height - 7)] {
                    let r = CGRect(x: x - 2.6, y: y - 2.6, width: 5.2, height: 5.2)
                    ctx.fill(Path(ellipseIn: r), with: .linearGradient(Gradient(colors: [Theme.hex(0xd8d8d8), Theme.hex(0x6c6c6c)]),
                                                                       startPoint: CGPoint(x: x, y: r.minY), endPoint: CGPoint(x: x, y: r.maxY)))
                    var slot = Path(); slot.move(to: CGPoint(x: x - 1.8, y: y + 1)); slot.addLine(to: CGPoint(x: x + 1.8, y: y - 1))
                    ctx.stroke(slot, with: .color(.black.opacity(0.55)), lineWidth: 0.8)
                }
            }
            .clipShape(shape)
            shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.35), .white.opacity(0.03), .black.opacity(0.3)], startPoint: .top, endPoint: .bottom), lineWidth: 1.2)
        }
        .shadow(color: .black.opacity(0.55), radius: 5, y: 4)
    }
}

/// A status lamp: lit with a soft glow, or dark.
struct LED: View {
    let on: Bool
    var color: Color = Theme.hex(0xff3b30)
    var size: CGFloat = 7
    var body: some View {
        Circle()
            .fill(on ? RadialGradient(colors: [.white.opacity(0.95), color, color.opacity(0.75)], center: UnitPoint(x: 0.35, y: 0.35), startRadius: 0, endRadius: size * 0.7)
                     : RadialGradient(colors: [Theme.hex(0x5a4a4c), Theme.hex(0x1c1617)], center: UnitPoint(x: 0.35, y: 0.35), startRadius: 0, endRadius: size * 0.7))
            .overlay(Circle().stroke(.black.opacity(0.6), lineWidth: 0.8))
            .frame(width: size, height: size)
            .shadow(color: on ? color.opacity(0.9) : .clear, radius: on ? 5 : 0)
    }
}

/// A metal stomp switch.
struct StompSwitch: View {
    let on: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            ZStack {
                // hex nut
                Path { p in
                    for i in 0..<6 {
                        let a = Double(i) / 6 * 2 * .pi + .pi / 6
                        let pt = CGPoint(x: 18 + 17 * cos(a), y: 18 + 17 * sin(a))
                        if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
                    }
                    p.closeSubpath()
                }
                .fill(LinearGradient(colors: [Theme.hex(0xe6e6e6), Theme.hex(0x6f6f73)], startPoint: .top, endPoint: .bottom))
                .overlay(Path { p in
                    for i in 0..<6 {
                        let a = Double(i) / 6 * 2 * .pi + .pi / 6
                        let pt = CGPoint(x: 18 + 17 * cos(a), y: 18 + 17 * sin(a))
                        if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
                    }
                    p.closeSubpath()
                }.stroke(.black.opacity(0.45), lineWidth: 0.8))
                Circle()
                    .fill(RadialGradient(colors: [Theme.hex(0xffffff), Theme.hex(0xb9babd), Theme.hex(0x6a6b70)], center: UnitPoint(x: 0.38, y: 0.3), startRadius: 1, endRadius: 14))
                    .frame(width: 22, height: 22)
                    .overlay(Circle().stroke(.black.opacity(0.5), lineWidth: 0.8))
                    .offset(y: on ? 0.6 : 0)
            }
            .frame(width: 36, height: 36)
            .shadow(color: .black.opacity(0.5), radius: 2, y: 2)
        }
        .buttonStyle(.plain)
        .help(on ? "On: click to bypass" : "Bypassed: click to switch on")
    }
}

/// A small bat-handle toggle for a switch in the circuit: up is A (or on), down is B (or off).
struct MiniToggle: View {
    @ObservedObject var model: EditorModel
    let board: Board
    let part: Part
    let ink: Color

    var body: some View {
        let state = part.switchState
        let up = part.kind == .spst ? state == 1 : state == 0
        let centre = part.kind == .spdt && state == 2
        Button {
            let next = part.kind == .spst ? (state == 1 ? 0 : 1) : (state == 0 ? 1 : 0)
            model.setSwitch(board, part.id, next)
        } label: {
            HStack(spacing: 4) {
                Canvas { ctx, size in
                    let c = CGPoint(x: size.width / 2, y: size.height / 2)
                    let nut = CGRect(x: c.x - 5, y: c.y - 5, width: 10, height: 10)
                    ctx.fill(Path(ellipseIn: nut), with: .linearGradient(Gradient(colors: [Theme.hex(0xe0e0e0), Theme.hex(0x6a6a6e)]),
                                                                        startPoint: CGPoint(x: c.x, y: nut.minY), endPoint: CGPoint(x: c.x, y: nut.maxY)))
                    ctx.stroke(Path(ellipseIn: nut), with: .color(.black.opacity(0.5)), lineWidth: 0.6)
                    let tip = CGPoint(x: c.x, y: centre ? c.y - 1 : (up ? c.y - 9 : c.y + 9))
                    var bat = Path(); bat.move(to: c); bat.addLine(to: tip)
                    ctx.stroke(bat, with: .color(Theme.hex(0xf2f2f2)), style: StrokeStyle(lineWidth: 2.6, lineCap: .round))
                    ctx.stroke(bat, with: .color(.black.opacity(0.35)), style: StrokeStyle(lineWidth: 0.6, lineCap: .round))
                    ctx.fill(Path(ellipseIn: CGRect(x: tip.x - 2, y: tip.y - 2, width: 4, height: 4)), with: .color(Theme.hex(0xfafafa)))
                }
                .frame(width: 14, height: 24)
                VStack(alignment: .leading, spacing: 0) {
                    Text((part.text.isEmpty ? part.name : part.text).uppercased()).font(Theme.label(7)).tracking(0.5)
                    Text(part.kind == .spst ? (up ? "ON" : "OFF") : (centre ? "OFF" : up ? "A" : "B")).font(Theme.label(7)).opacity(0.75)
                }
                .foregroundColor(ink).lineLimit(1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(part.text.isEmpty ? part.name : part.text): click to flip (the circuit is re-simulated)")
    }
}

// MARK: - Pedals

/// Knob layout for a faceplate: rows, columns and knob size from how many knobs there are.
struct KnobLayout {
    let rows: [[Int]]
    let size: CGFloat
    init(count: Int) {
        let cols: Int
        switch count {
        case 0...3: cols = max(count, 1); size = 30
        case 4: cols = 2; size = 28
        case 5, 6: cols = 3; size = 25
        default: cols = 4; size = 22
        }
        var r: [[Int]] = []
        var i = 0
        while i < count { r.append(Array(i..<min(i + cols, count))); i += cols }
        rows = r
    }
    var columns: Int { rows.map(\.count).max() ?? 1 }
    var width: CGFloat { max(124, CGFloat(columns) * (size + 18) + 20) }
}

struct PedalFace: View {
    @ObservedObject var model: EditorModel
    let pedal: BoardPedal
    let index: Int
    @Binding var dragging: UUID?
    @Binding var dropIndex: Int?

    static let height: CGFloat = 190

    var body: some View { Ticking(clock: model.clock) { face } }

    @ViewBuilder var face: some View {
        let b = Board.pedal(pedal.id)
        let f = PedalFinish.of(pedal.circuit)
        let knobs = model.knobs(b)
        let layout = KnobLayout(count: knobs.count)
        let on = model.isOn(b)
        let isOpen = model.board == b
        VStack(spacing: 5) {
            VStack(spacing: 4) {
                VStack(spacing: 2) {
                    if knobs.isEmpty {
                        Text("NO KNOBS").font(Theme.label(8)).tracking(1).foregroundColor(f.inkColor.opacity(0.6)).frame(height: 40)
                    }
                    ForEach(layout.rows, id: \.self) { row in
                        HStack(spacing: 2) {
                            ForEach(row, id: \.self) { i in
                                let k = knobs[i]
                                Knob(label: k.1, value: model.param(k.0), range: 0...1, size: layout.size,
                                     style: .pedal(cream: f.creamKnobs), ink: f.inkColor, compact: true) { model.setParam(k.0, $0) }
                            }
                        }
                    }
                }
                .padding(.top, 10)
                switches(b, ink: f.inkColor)
                Spacer(minLength: 0)
                // the name plate doubles as the handle for moving the pedal along the board
                VStack(spacing: 4) {
                    LED(on: on, color: Theme.hex(f.led))
                    Text(pedal.circuit.name.uppercased())
                        .font(.system(size: 10, weight: .heavy)).tracking(1.2)
                        .multilineTextAlignment(.center).lineLimit(2).minimumScaleFactor(0.75)
                        .foregroundColor(f.inkColor)
                        .padding(.horizontal, 10)
                }
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
                .onDrag {
                    dragging = pedal.id
                    return NSItemProvider(object: pedal.id.uuidString as NSString)
                }
                .help("Click to open its circuit; drag to move it along the board")
                StompSwitch(on: on) { model.toggle(pedal.id) }
                    .padding(.bottom, 8)
            }
            .frame(width: layout.width, height: PedalFace.height)
            .background(Enclosure(finish: f))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(isOpen ? Theme.gold : .clear, lineWidth: 2).padding(-3))
            .opacity(dragging == pedal.id ? 0.45 : 1)
            .contentShape(Rectangle())
            .onTapGesture { model.open(b) }
            .onDrop(of: [UTType.text], delegate: PedalDrop(index: index, width: layout.width, model: model, dragging: $dragging, dropIndex: $dropIndex))
            .contextMenu { menu }
            caption
        }
    }

    @ViewBuilder func switches(_ b: Board, ink: Color) -> some View {
        let parts = pedal.circuit.parts.filter { $0.kind == .spst || $0.kind == .spdt }.prefix(3)
        if !parts.isEmpty {
            HStack(spacing: 10) {
                ForEach(Array(parts), id: \.id) { part in MiniToggle(model: model, board: b, part: part, ink: ink) }
            }
            .padding(.top, 2)
        }
    }

    var caption: some View {
        HStack(spacing: 5) {
            Text("\(index + 1)").font(.system(size: 9, weight: .bold).monospacedDigit())
                .frame(width: 14, height: 14).background(Theme.panel2, in: Circle()).foregroundColor(Theme.dim)
            if let cpu = model.analysis[.pedal(pedal.id)]?.cpu {
                Text(String(format: "%.0f%% CPU", cpu * 100)).font(.system(size: 9).monospacedDigit())
                    .foregroundColor(cpu > 0.5 ? Theme.orange : Theme.dim)
                    .help("Share of one processor core this pedal needs at the current oversampling")
            }
            if model.analysis[.pedal(pedal.id)]?.error != nil {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 9)).foregroundColor(Theme.orange)
                    .help(model.analysis[.pedal(pedal.id)]?.error ?? "")
            }
        }
        .frame(height: 14)
    }

    @ViewBuilder var menu: some View {
        Button("Open circuit") { model.open(.pedal(pedal.id)) }
        Button(model.isOn(.pedal(pedal.id)) ? "Bypass" : "Switch on") { model.toggle(pedal.id) }
        Divider()
        Button("Move left") { model.movePedal(pedal.id, to: index - 1) }.disabled(index == 0)
        Button("Move right") { model.movePedal(pedal.id, to: index + 2) }.disabled(index == model.pedals.count - 1)
        Menu("Replace with") {
            ForEach(Presets.pedals, id: \.name) { p in
                Button(p.name) { model.open(.pedal(pedal.id)); model.load(preset: p) }
            }
        }
        Button("Duplicate") { model.addPedal(pedal.circuit, at: index + 1) }.disabled(!model.canAddPedal)
        Divider()
        Button("Remove from board") { model.removePedal(pedal.id) }
    }
}

/// Dropping a dragged pedal on another: in front of it on the left half, after it on the right.
struct PedalDrop: DropDelegate {
    let index: Int
    let width: CGFloat
    let model: EditorModel
    @Binding var dragging: UUID?
    @Binding var dropIndex: Int?

    func validateDrop(info: DropInfo) -> Bool { dragging != nil }
    func dropUpdated(info: DropInfo) -> DropProposal? {
        dropIndex = info.location.x < width / 2 ? index : index + 1
        return DropProposal(operation: .move)
    }
    func dropExited(info: DropInfo) { if dropIndex == index || dropIndex == index + 1 { dropIndex = nil } }
    func performDrop(info: DropInfo) -> Bool {
        defer { dragging = nil; dropIndex = nil }
        guard let d = dragging, let i = dropIndex else { return false }
        Task { @MainActor in model.movePedal(d, to: i) }
        return true
    }
}

/// A patch cable between two modules, with a marker where a dragged pedal would land.
struct PatchCable: View {
    var insert = false
    var live = true
    var body: some View {
        Canvas { ctx, size in
            let y = size.height * 0.42
            var p = Path()
            p.move(to: CGPoint(x: 0, y: y))
            p.addCurve(to: CGPoint(x: size.width, y: y), control1: CGPoint(x: size.width * 0.3, y: y + 16), control2: CGPoint(x: size.width * 0.7, y: y + 16))
            ctx.stroke(p.offsetBy(dx: 0, dy: 2), with: .color(.black.opacity(0.4)), lineWidth: 5)
            ctx.stroke(p, with: .color(Theme.hex(0x141112)), lineWidth: 4.5)
            ctx.stroke(p, with: .color(live ? Theme.wire.opacity(0.55) : Theme.wellEdge), lineWidth: 1.2)
            for x in [CGFloat(0), size.width - 6] {
                ctx.fill(Path(roundedRect: CGRect(x: x, y: y - 3.5, width: 6, height: 7), cornerRadius: 1.5),
                         with: .linearGradient(Gradient(colors: [Theme.hex(0xd9d9d9), Theme.hex(0x707074)]),
                                               startPoint: CGPoint(x: x, y: y - 3.5), endPoint: CGPoint(x: x, y: y + 3.5)))
            }
            if insert {
                let r = CGRect(x: size.width / 2 - 2, y: 6, width: 4, height: size.height - 12)
                ctx.fill(Path(roundedRect: r, cornerRadius: 2), with: .color(Theme.gold))
            }
        }
        .frame(width: 26, height: PedalFace.height)
    }
}

/// The empty space at the end of the board: opens a catalogue of starter pedals.
struct AddPedalCard: View {
    @ObservedObject var model: EditorModel
    @Binding var dragging: UUID?
    @Binding var dropIndex: Int?
    @State private var showing = false

    var body: some View {
        VStack(spacing: 5) {
            Button { showing = true } label: {
                VStack(spacing: 8) {
                    Image(systemName: "plus").font(.system(size: 20, weight: .semibold))
                    Text("ADD\nPEDAL").font(Theme.label(9)).tracking(1.4).multilineTextAlignment(.center)
                    Text("\(model.pedals.count) of \(Rig.maxPedals)").font(.system(size: 9).monospacedDigit()).foregroundColor(Theme.dim)
                }
                .foregroundColor(model.canAddPedal ? Theme.text : Theme.dim)
                .frame(width: 84, height: PedalFace.height)
                .background(RoundedRectangle(cornerRadius: 9).fill(Theme.well.opacity(0.5)))
                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Theme.wellEdge, style: StrokeStyle(lineWidth: 1.2, dash: [4, 3])))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!model.canAddPedal)
            .help(model.canAddPedal ? "Add a pedal to the end of the board" : "The board holds \(Rig.maxPedals) pedals")
            .popover(isPresented: $showing, arrowEdge: .bottom) { catalogue }
            .onDrop(of: [UTType.text], delegate: PedalDrop(index: model.pedals.count, width: 1e9, model: model, dragging: $dragging, dropIndex: $dropIndex))
            Color.clear.frame(height: 14)
        }
    }

    var catalogue: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("STARTER PEDALS").font(Theme.label(10)).tracking(1.6).foregroundColor(Theme.dim).padding(.bottom, 4)
            ForEach(Presets.pedals, id: \.name) { p in
                let f = PedalFinish.of(p)
                Button {
                    showing = false
                    model.addPedal(p, at: model.pedals.count)
                } label: {
                    HStack(alignment: .top, spacing: 10) {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(LinearGradient(colors: [Theme.hex(f.top), Theme.hex(f.bottom)], startPoint: .top, endPoint: .bottom))
                            .frame(width: 16, height: 22)
                            .overlay(RoundedRectangle(cornerRadius: 3).stroke(.black.opacity(0.4)))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(p.name).font(.system(size: 12, weight: .semibold)).foregroundColor(Theme.text)
                            Text(p.notes).font(.system(size: 10)).foregroundColor(Theme.dim).lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 4).padding(.horizontal, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(CatalogueRowStyle())
            }
        }
        .padding(12)
        .frame(width: 360)
        .background(Theme.panel)
    }
}

struct CatalogueRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.background(RoundedRectangle(cornerRadius: 5).fill(configuration.isPressed ? Theme.panelHi : .clear))
    }
}

// MARK: - Amp head

struct AmpFace: View {
    @ObservedObject var model: EditorModel

    static let tolex = Theme.hex(0x1a1617)
    static let plate = [Theme.hex(0xe2d3a8), Theme.hex(0xbfa874)]
    static let ink = Theme.hex(0x2a1e14)

    var body: some View { Ticking(clock: model.clock) { face } }

    @ViewBuilder var face: some View {
        let mode = Int(model.param(.ampMode).rounded())
        let isOpen = model.board == .amp
        VStack(spacing: 5) {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Text(mode == 2 ? "AMP PROFILE" : model.amp.name.uppercased())
                        .font(.system(size: 11, weight: .heavy)).tracking(2).foregroundColor(Theme.gold).lineLimit(1)
                    Spacer(minLength: 6)
                    modeSwitch(mode)
                    LED(on: mode != 0, color: Theme.hex(0xff4a2a), size: 11)
                }
                .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 8)
                plate(mode)
                    .padding(.horizontal, 10)
                Spacer(minLength: 0)
                HStack(spacing: 10) {
                    jack("INPUT")
                    Spacer()
                    Text("LUTHERIE").font(.system(size: 13, weight: .black)).tracking(4.5)
                        .foregroundStyle(LinearGradient(colors: [Theme.hex(0xf0dfae), Theme.hex(0xa9894e)], startPoint: .top, endPoint: .bottom))
                        .shadow(color: .black.opacity(0.6), radius: 0, y: 1)
                    Spacer()
                    jack("SPEAKER")
                }
                .padding(.horizontal, 16).padding(.bottom, 8)
                // piping along the bottom of the head
                Rectangle().fill(Theme.hex(0xcbb98d).opacity(0.7)).frame(height: 1.5).padding(.horizontal, 10).padding(.bottom, 10)
            }
            .frame(width: width(mode), height: PedalFace.height)
            .background(tolexBackground)
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(isOpen ? Theme.gold : .clear, lineWidth: 2).padding(-3))
            .contentShape(Rectangle())
            .onTapGesture { if mode == 1 { model.open(.amp) } }
            .help(mode == 1 ? "Click to open the amp's circuit" : "")
            HStack(spacing: 5) {
                if mode == 1, let cpu = model.analysis[.amp]?.cpu {
                    Text(String(format: "%.0f%% CPU", cpu * 100)).font(.system(size: 9).monospacedDigit())
                        .foregroundColor(cpu > 0.5 ? Theme.orange : Theme.dim)
                }
            }
            .frame(height: 14)
        }
    }

    func jack(_ name: String) -> some View {
        VStack(spacing: 2) {
            Circle().fill(RadialGradient(colors: [Theme.hex(0x050405), Theme.hex(0x2a2a2c), Theme.hex(0xb8b8bb)], center: .center, startRadius: 2, endRadius: 7))
                .frame(width: 13, height: 13).overlay(Circle().stroke(.black.opacity(0.6), lineWidth: 0.6))
            Text(name).font(Theme.label(6.5)).tracking(0.8).foregroundColor(Theme.dim)
        }
    }

    func width(_ mode: Int) -> CGFloat {
        guard mode == 1 else { return 330 }
        let n = model.knobs(.amp).count + (model.amp.hasPowerStage ? 0 : 2)
        let sw = min(2, model.amp.parts.filter { $0.kind == .spst || $0.kind == .spdt }.count)
        return max(300, CGFloat(n) * 56 + CGFloat(sw) * 56 + 40)
    }

    var tolexBackground: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        return ZStack {
            shape.fill(LinearGradient(colors: [Theme.hex(0x2a2426), AmpFace.tolex], startPoint: .top, endPoint: .bottom))
            Canvas { ctx, size in
                // tolex grain
                var k: UInt32 = 99
                for _ in 0..<Int(size.width * size.height / 14) {
                    k = k &* 1664525 &+ 1013904223; let x = CGFloat(k >> 16) / 65536 * size.width
                    k = k &* 1664525 &+ 1013904223; let y = CGFloat(k >> 16) / 65536 * size.height
                    ctx.fill(Path(CGRect(x: x, y: y, width: 1.2, height: 1.2)), with: .color((k & 4 == 0 ? Color.white : .black).opacity(0.06)))
                }
            }
            .clipShape(shape)
            shape.strokeBorder(LinearGradient(colors: [.white.opacity(0.18), .black.opacity(0.4)], startPoint: .top, endPoint: .bottom), lineWidth: 1.5)
        }
        .shadow(color: .black.opacity(0.55), radius: 5, y: 4)
    }

    func modeSwitch(_ mode: Int) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(["OFF", "TUBES", "PROFILE"].enumerated()), id: \.offset) { i, name in
                Button { model.setParam(.ampMode, Float(i)); if i == 1 { model.open(.amp) } } label: {
                    Text(name).font(Theme.label(8)).tracking(0.8)
                        .foregroundColor(mode == i ? Theme.hex(0x1a1410) : Theme.dim)
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(mode == i ? Theme.gold : .clear, in: RoundedRectangle(cornerRadius: 3))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(Theme.well, in: RoundedRectangle(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Theme.wellEdge, lineWidth: 1))
    }

    @ViewBuilder func plate(_ mode: Int) -> some View {
        let shape = RoundedRectangle(cornerRadius: 4)
        Group {
            if mode == 1 {
                HStack(spacing: 6) {
                    ForEach(model.knobs(.amp), id: \.0) { k in
                        Knob(label: k.1, value: model.param(k.0), range: 0...1, size: 26, style: .chicken, ink: AmpFace.ink, compact: true) { model.setParam(k.0, $0) }
                    }
                    let sw = model.amp.parts.filter { $0.kind == .spst || $0.kind == .spdt }.prefix(2)
                    ForEach(Array(sw), id: \.id) { part in MiniToggle(model: model, board: .amp, part: part, ink: AmpFace.ink) }
                    if !model.amp.hasPowerStage {
                        Rectangle().fill(AmpFace.ink.opacity(0.25)).frame(width: 1, height: 50).padding(.horizontal, 3)
                        Knob(label: "Power", value: model.param(.powerDrive), range: 0...1, size: 26, style: .chicken, ink: AmpFace.ink, compact: true) { model.setParam(.powerDrive, $0) }
                        Knob(label: "Presence", value: model.param(.presence), range: RigParam.presence.range,
                             format: { String(format: "%+.1f dB", $0) }, size: 26, style: .chicken, ink: AmpFace.ink, compact: true) { model.setParam(.presence, $0) }
                    }
                }
                .padding(.vertical, 8).padding(.horizontal, 6)
            } else if mode == 2 {
                profilePanel
            } else {
                VStack(spacing: 4) {
                    Text("STANDBY").font(Theme.label(11)).tracking(3).foregroundColor(AmpFace.ink.opacity(0.7))
                    Text("The pedals go straight to the cabinet.").font(.system(size: 10)).foregroundColor(AmpFace.ink.opacity(0.7))
                }
                .frame(maxWidth: .infinity).padding(.vertical, 26)
            }
        }
        .frame(maxWidth: .infinity)
        .background(shape.fill(LinearGradient(colors: AmpFace.plate, startPoint: .top, endPoint: .bottom)))
        .overlay(shape.stroke(.black.opacity(0.5), lineWidth: 1))
        .overlay(shape.inset(by: 1.5).stroke(.white.opacity(0.35), lineWidth: 0.6))
    }

    var profilePanel: some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                Text(model.profileName ?? "No profile loaded").font(.system(size: 12, weight: .bold)).foregroundColor(AmpFace.ink).lineLimit(1)
                if let t = model.tone3000 {
                    Text(t.credit).font(.system(size: 9)).foregroundColor(AmpFace.ink.opacity(0.75)).lineLimit(2)
                    Link("Powered by TONE3000", destination: URL(string: t.url ?? "https://www.tone3000.com")!)
                        .font(.system(size: 9, weight: .semibold))
                } else {
                    Text("A Neural Amp Modeler capture of a real amp.").font(.system(size: 9)).foregroundColor(AmpFace.ink.opacity(0.75))
                }
                HStack(spacing: 6) {
                    Button("Load .nam…") { model.loadProfilePanel() }.controlSize(.mini)
                    if Tone3000Config.isConfigured {
                        Button(model.tone3000Busy ? "Loading…" : "TONE3000…") { model.browseTone3000() }
                            .controlSize(.mini).disabled(model.tone3000Busy)
                    }
                    if model.tone3000NeedsReload && Tone3000Config.isConfigured {
                        Button("Reload") { model.reloadTone3000() }.controlSize(.mini).disabled(model.tone3000Busy)
                    }
                }
            }
            Spacer(minLength: 0)
            Knob(label: "Presence", value: model.param(.presence), range: RigParam.presence.range,
                 format: { String(format: "%+.1f dB", $0) }, size: 26, style: .chicken, ink: AmpFace.ink, compact: true) { model.setParam(.presence, $0) }
        }
        .padding(8)
    }
}

// MARK: - Cabinet

struct CabinetFace: View {
    @ObservedObject var model: EditorModel

    var body: some View { Ticking(clock: model.clock) { face } }

    @ViewBuilder var face: some View {
        let mode = Int(model.param(.cabMode).rounded())
        VStack(spacing: 5) {
            VStack(spacing: 6) {
                ZStack {
                    grille.opacity(mode == 0 ? 0.35 : 1)
                    VStack(spacing: 2) {
                        Text(mode == 2 ? (model.irName ?? "Impulse") : mode == 1 ? "Simple 1×12" : "No cabinet")
                            .font(.system(size: 9, weight: .heavy)).tracking(0.8).foregroundColor(Theme.hex(0x241a10))
                            .lineLimit(1).minimumScaleFactor(0.7)
                        if mode == 2, let c = model.cabinet {
                            Text("\(c.mic) · \(c.position)").font(.system(size: 8)).foregroundColor(Theme.hex(0x3a2c1c)).lineLimit(1).minimumScaleFactor(0.7)
                        }
                    }
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(LinearGradient(colors: AmpFace.plate, startPoint: .top, endPoint: .bottom), in: RoundedRectangle(cornerRadius: 3))
                    .overlay(RoundedRectangle(cornerRadius: 3).stroke(.black.opacity(0.4), lineWidth: 0.8))
                    .padding(.horizontal, 12)
                    .frame(maxHeight: .infinity, alignment: .top).padding(.top, 10)
                }
                .padding([.horizontal, .top], 9)
                controls.padding(.horizontal, 8).padding(.bottom, 10)
            }
            .frame(width: 176, height: PedalFace.height)
            .background(AmpFace(model: model).tolexBackground)
            Color.clear.frame(height: 14)
        }
    }

    var grille: some View {
        Canvas { ctx, size in
            let r = CGRect(origin: .zero, size: size)
            ctx.clip(to: Path(roundedRect: r, cornerRadius: 5))
            ctx.fill(Path(roundedRect: r, cornerRadius: 5), with: .color(Theme.hex(0x3a332c)))
            var x: CGFloat = -size.height
            while x < size.width {
                var a = Path(); a.move(to: CGPoint(x: x, y: size.height)); a.addLine(to: CGPoint(x: x + size.height, y: 0))
                var b = Path(); b.move(to: CGPoint(x: x, y: 0)); b.addLine(to: CGPoint(x: x + size.height, y: size.height))
                ctx.stroke(a, with: .color(Theme.hex(0x8a7a5e).opacity(0.55)), lineWidth: 1)
                ctx.stroke(b, with: .color(Theme.hex(0x1d1915).opacity(0.7)), lineWidth: 1)
                x += 3
            }
            ctx.fill(Path(ellipseIn: r.insetBy(dx: size.width * 0.16, dy: size.height * 0.12).offsetBy(dx: 0, dy: 6)),
                     with: .radialGradient(Gradient(colors: [.black.opacity(0.22), .clear]), center: CGPoint(x: r.midX, y: r.midY + 6), startRadius: 0, endRadius: size.width * 0.4))
            ctx.stroke(Path(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), cornerRadius: 5), with: .color(.black.opacity(0.6)), lineWidth: 1)
        }
        .frame(height: 104)
    }

    var controls: some View {
        VStack(spacing: 4) {
            HStack(spacing: 4) {
                Menu {
                    Button("No cabinet") { model.setParam(.cabMode, 0) }
                    Button("Simple 1×12") { model.setParam(.cabMode, 1) }
                    Divider()
                    ForEach(CabinetLibrary.cabinets, id: \.self) { name in
                        Button(name) {
                            model.choose(cabinet: CabinetChoice(cabinet: name, mic: model.cabinet?.mic ?? CabinetLibrary.mics[0],
                                                                position: model.cabinet?.position ?? CabinetLibrary.positions[1]))
                        }
                    }
                    Divider()
                    Button("Load impulse response file…") { model.loadImpulsePanel() }
                } label: { Text("Cabinet") }
                .controlSize(.small)
            }
            if let cab = model.cabinet, Int(model.param(.cabMode).rounded()) == 2 {
                HStack(spacing: 4) {
                    Menu {
                        ForEach(CabinetLibrary.mics, id: \.self) { m in Button(m) { var c = cab; c.mic = m; model.choose(cabinet: c) } }
                    } label: { Text("Mic") }.controlSize(.small)
                    Menu {
                        ForEach(CabinetLibrary.positions, id: \.self) { p in Button(p) { var c = cab; c.position = p; model.choose(cabinet: c) } }
                    } label: { Text("Position") }.controlSize(.small)
                }
            }
        }
        .help(model.cabinet.map { CabinetLibrary.notes($0.cabinet) } ?? "Built-in speaker cabinets, or load your own impulse response")
    }
}

// MARK: - Input and output

struct LevelPlate: View {
    @ObservedObject var model: EditorModel
    let output: Bool

    var body: some View { Ticking(clock: model.clock) { face } }

    @ViewBuilder var face: some View {
        VStack(spacing: 6) {
            Text(output ? "OUTPUT" : "INPUT").font(Theme.label(9)).tracking(1.6).foregroundColor(Theme.dim)
            HStack(alignment: .top, spacing: 4) {
                let p: RigParam = output ? .outputLevel : .inputLevel
                Knob(label: output ? "Level" : "Gain", value: model.param(p), range: p.range,
                     format: { String(format: "%+.1f dB", $0) }, size: 28, accent: Theme.ivory, compact: true) { model.setParam(p, $0) }
                Meter(level: (output ? model.bridge?.rig.outputPeak : model.bridge?.rig.inputPeak) ?? 0).frame(height: 62)
            }
            if output {
                Knob(label: "Mix", value: model.param(.mix), range: 0...1, format: { String(format: "%.0f%%", $0 * 100) },
                     size: 24, accent: Theme.ivory, compact: true) { model.setParam(.mix, $0) }
                Text(String(format: "CPU %.0f%%", (model.bridge?.rig.load ?? 0) * 100)).font(.system(size: 9).monospacedDigit()).foregroundColor(Theme.dim)
                    .help("What the whole rig is using of one core right now")
            } else {
                Knob(label: "Gate", value: model.param(.gate), range: RigParam.gate.range,
                     format: { $0 <= -99 ? "off" : String(format: "%.0f dB", $0) }, size: 24, accent: Theme.green, compact: true) { model.setParam(.gate, $0) }
                Text(" ").font(.system(size: 9))
            }
        }
        .padding(.vertical, 10).padding(.horizontal, 8)
        .frame(width: 96, height: PedalFace.height)
        .background(PanelBackground())
        .padding(.bottom, 19)
    }
}

// MARK: - The board

/// The whole rig left to right, as it would sit on the floor: input, the pedals, the amp, the cabinet, output.
struct PedalboardView: View {
    @ObservedObject var model: EditorModel
    @State private var dragging: UUID?
    @State private var dropIndex: Int?

    var body: some View {
        HStack(spacing: 0) {
            LevelPlate(model: model, output: false).padding(.leading, 10)
            scroller {
                HStack(alignment: .top, spacing: 0) {
                    PatchCable(insert: dropIndex == 0 && dragging != nil)
                    ForEach(Array(model.pedals.enumerated()), id: \.element.id) { i, p in
                        PedalFace(model: model, pedal: p, index: i, dragging: $dragging, dropIndex: $dropIndex)
                        PatchCable(insert: dropIndex == i + 1 && dragging != nil)
                    }
                    if model.canAddPedal || dragging != nil {
                        AddPedalCard(model: model, dragging: $dragging, dropIndex: $dropIndex)
                        PatchCable()
                    }
                    AmpFace(model: model)
                    PatchCable()
                    CabinetFace(model: model)
                    PatchCable()
                }
                .padding(.vertical, 12)
                .padding(.horizontal, 4)
            }
            LevelPlate(model: model, output: true).padding(.trailing, 10)
        }
        .background(boardSurface)
    }

    /// Off-screen pictures can't draw scroll views, so they get the board laid out flat.
    @ViewBuilder func scroller<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        if SchematicSnapshot.rendering { content().fixedSize().frame(maxWidth: .infinity, alignment: .leading).clipped() }
        else { ScrollView(.horizontal, showsIndicators: true) { content() } }
    }

    /// The board itself: a dark carpeted deck.
    var boardSurface: some View {
        ZStack {
            LinearGradient(colors: [Theme.hex(0x1c1819), Theme.hex(0x110e0f)], startPoint: .top, endPoint: .bottom)
            Canvas { ctx, size in
                var k: UInt32 = 4242
                for _ in 0..<Int(size.width * size.height / 30) {
                    k = k &* 1664525 &+ 1013904223; let x = CGFloat(k >> 16) / 65536 * size.width
                    k = k &* 1664525 &+ 1013904223; let y = CGFloat(k >> 16) / 65536 * size.height
                    ctx.fill(Path(CGRect(x: x, y: y, width: 1, height: 1)), with: .color(.white.opacity(0.025)))
                }
            }
        }
    }
}
