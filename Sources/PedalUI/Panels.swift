import PedalCore
import SwiftUI

// MARK: - Part palette

enum Palette {
    static let groups: [(String, [PartKind])] = [
        ("Passive", [.resistor, .capacitor, .inductor, .pot, .transformer]),
        ("Semiconductors", [.diode, .led, .zener, .npn, .pnp, .njfet, .pjfet, .nmos, .pmos, .opamp]),
        ("Switches", [.spst, .spdt]),
        ("Tubes", [.triode, .pentode]),
        ("Connections", [.ground, .supply, .input, .output, .label]),
    ]
    static let shortcuts: [String: PartKind] = ["1": .resistor, "2": .capacitor, "3": .pot, "4": .diode, "5": .npn,
                                                "6": .opamp, "7": .triode, "g": .ground, "p": .supply, "l": .label]
}

struct PaletteView: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    toolButton("cursorarrow", "Select (S)", model.tool == .select) { model.tool = .select }
                    toolButton("line.diagonal", "Wire (W)", model.tool == .wire) { model.tool = .wire }
                }
                ForEach(Palette.groups, id: \.0) { group in
                    Text(group.0.uppercased()).font(.system(size: 10, weight: .semibold)).foregroundColor(Theme.dim)
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], spacing: 6) {
                        ForEach(group.1, id: \.self) { kind in partButton(kind) }
                    }
                }
            }
            .padding(10)
        }
        .frame(width: 168)
        .background(Theme.panel)
    }

    func toolButton(_ icon: String, _ help: String, _ on: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).frame(maxWidth: .infinity, minHeight: 26)
                .background(on ? Theme.accent.opacity(0.85) : Theme.panel2, in: RoundedRectangle(cornerRadius: 6))
                .foregroundColor(Theme.text)
        }
        .buttonStyle(.plain).help(help)
    }

    func partButton(_ kind: PartKind) -> some View {
        let on = model.tool == .place(kind)
        return Button { model.tool = on ? .select : .place(kind) } label: {
            VStack(spacing: 2) {
                Canvas { ctx, size in
                    let part = Part(kind, name: "", at: GridPoint(0, 0))
                    let s: CGFloat = 7
                    var c = ctx
                    let b = Symbol.bounds(kind)
                    let origin = CGPoint(x: size.width / 2 - b.midX * s, y: size.height / 2 - b.midY * s)
                    drawPartShapeOnly(part, in: &c, origin: origin, scale: s, color: Theme.part)
                }
                .frame(height: 30)
                Text(kind.displayName).font(.system(size: 9)).lineLimit(1).minimumScaleFactor(0.7)
                    .foregroundColor(on ? Theme.text : Theme.dim)
            }
            .padding(4)
            .frame(maxWidth: .infinity)
            .background(on ? Theme.accent : Theme.panel2, in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .help("Place \(kind.displayName.lowercased())")
    }
}

/// Symbol without captions, for the palette.
func drawPartShapeOnly(_ part: Part, in ctx: inout GraphicsContext, origin: CGPoint, scale: CGFloat, color: Color) {
    let shape = Symbol.shape(for: part)
    func tx(_ q: CGPoint) -> CGPoint { CGPoint(x: origin.x + q.x * scale, y: origin.y + q.y * scale) }
    for line in shape.strokes + shape.dashed {
        var p = Path(); p.addLines(line.map(tx))
        ctx.stroke(p, with: .color(color), style: StrokeStyle(lineWidth: 1.3, lineCap: .round, lineJoin: .round))
    }
    for poly in shape.filled { var p = Path(); p.addLines(poly.map(tx)); p.closeSubpath(); ctx.fill(p, with: .color(color)) }
    for (c, r) in shape.circles {
        let cc = tx(c)
        ctx.stroke(Path(ellipseIn: CGRect(x: cc.x - r * scale, y: cc.y - r * scale, width: 2 * r * scale, height: 2 * r * scale)), with: .color(color), lineWidth: 1.3)
    }
}

// MARK: - Inspector

struct ValueField: View {
    let label: String
    let unit: String
    let value: Double
    let commit: (Double) -> Void
    @State private var text = ""
    @State private var bad = false

    var body: some View {
        HStack {
            Text(label).foregroundColor(Theme.dim).frame(width: 92, alignment: .leading)
            TextField("", text: $text)
                .textFieldStyle(.roundedBorder)
                .onSubmit {
                    if let v = Eng.parse(text) { bad = false; commit(v) } else { bad = true }
                }
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(bad ? Color.red : .clear))
            Text(unit).foregroundColor(Theme.dim).frame(width: 18, alignment: .leading)
        }
        .onAppear { text = Eng.format(value) }
        .onChange(of: value) { _, v in text = Eng.format(v) }
    }
}

struct InspectorView: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if model.selectedParts.count == 1, let part = model.selectedParts.first {
                    partEditor(part)
                } else if model.selectedParts.count > 1 {
                    Text("\(model.selectedParts.count) parts selected").font(.headline)
                    actions
                } else {
                    circuitInfo
                }
            }
            .padding(12)
            .foregroundColor(Theme.text)
            .font(.system(size: 12))
        }
        .frame(width: 270)
        .background(Theme.panel)
    }

    var actions: some View {
        HStack {
            Button("Rotate") { model.rotateSelection() }
            Button("Flip") { model.flipSelection() }
            Button("Copy") { model.duplicateSelection() }
            Button("Delete", role: .destructive) { model.deleteSelection() }
        }
        .controlSize(.small)
    }

    @ViewBuilder
    func partEditor(_ part: Part) -> some View {
        Text(part.kind.displayName.uppercased()).font(.system(size: 10, weight: .semibold)).foregroundColor(Theme.accent)
        HStack {
            Text("Name").foregroundColor(Theme.dim).frame(width: 92, alignment: .leading)
            TextField("", text: Binding(get: { part.name }, set: { v in model.updatePart(part.id) { $0.name = v } }))
                .textFieldStyle(.roundedBorder)
        }
        switch part.kind {
        case .resistor:
            ValueField(label: "Resistance", unit: "Ω", value: part["r"]) { v in model.updatePart(part.id) { $0["r"] = max(v, 0.001) } }
        case .capacitor:
            ValueField(label: "Capacitance", unit: "F", value: part["c"]) { v in model.updatePart(part.id) { $0["c"] = max(v, 0) } }
        case .inductor:
            ValueField(label: "Inductance", unit: "H", value: part["l"]) { v in model.updatePart(part.id) { $0["l"] = max(v, 1e-9) } }
            ValueField(label: "Winding R", unit: "Ω", value: part["rs"]) { v in model.updatePart(part.id) { $0["rs"] = max(v, 0.001) } }
        case .pot:
            HStack {
                Text("Knob label").foregroundColor(Theme.dim).frame(width: 92, alignment: .leading)
                TextField("", text: Binding(get: { part.text }, set: { v in model.updatePart(part.id) { $0.text = v } }))
                    .textFieldStyle(.roundedBorder)
            }
            ValueField(label: "Track", unit: "Ω", value: part["r"]) { v in model.updatePart(part.id) { $0["r"] = max(v, 2) } }
            modelPicker(part, label: "Taper")
            HStack {
                Text("Gang").foregroundColor(Theme.dim).frame(width: 92, alignment: .leading)
                Picker("", selection: Binding(get: { part.gang }, set: { v in model.updatePart(part.id) { $0["gang"] = Double(v) } })) {
                    Text("None").tag(0)
                    ForEach(1...4, id: \.self) { Text("\($0)").tag($0) }
                }
                .labelsHidden()
            }
            Text("Pots in the same gang turn together from one knob, like the sections of a dual pot. The knob takes the label of the first one by name.")
                .font(.system(size: 10)).foregroundColor(Theme.dim).fixedSize(horizontal: false, vertical: true)
            Text("A = audio (log), B = linear, C = reverse log. Wiper is the pin on the arrow; turning up moves it toward End 3.")
                .font(.system(size: 10)).foregroundColor(Theme.dim)
        case .diode, .led, .zener, .npn, .pnp, .njfet, .pjfet, .nmos, .pmos, .triode, .pentode:
            modelPicker(part, label: "Model")
            deviceNotes(part)
        case .spst, .spdt:
            HStack {
                Text("Label").foregroundColor(Theme.dim).frame(width: 92, alignment: .leading)
                TextField("", text: Binding(get: { part.text }, set: { v in model.updatePart(part.id) { $0.text = v } }))
                    .textFieldStyle(.roundedBorder)
            }
            HStack {
                Text("Position").foregroundColor(Theme.dim).frame(width: 92, alignment: .leading)
                Picker("", selection: Binding(get: { part.switchState }, set: { v in model.updatePart(part.id) { $0["state"] = Double(v) } })) {
                    if part.kind == .spst {
                        Text("Off").tag(0); Text("On").tag(1)
                    } else {
                        Text("A").tag(0); Text("Off").tag(2); Text("B").tag(1)
                    }
                }
                .labelsHidden().pickerStyle(.segmented)
            }
            Text(part.kind == .spst ? "On joins the two pins; off leaves them apart."
                                    : "Joins Common to A or to B. Off is the centre position, joined to neither.")
                .font(.system(size: 10)).foregroundColor(Theme.dim)
        case .transformer:
            ValueField(label: "Primary load", unit: "Ω", value: part["zpp"]) { v in model.updatePart(part.id) { $0["zpp"] = max(v, 1) } }
            ValueField(label: "Speaker", unit: "Ω", value: part["zs"]) { v in model.updatePart(part.id) { $0["zs"] = max(v, 0.1) } }
            ValueField(label: "Primary L", unit: "H", value: part["lp"]) { v in model.updatePart(part.id) { $0["lp"] = max(v, 0.01) } }
            ValueField(label: "Primary R", unit: "Ω", value: part["rp"]) { v in model.updatePart(part.id) { $0["rp"] = max(v, 0.001) } }
            ValueField(label: "Secondary R", unit: "Ω", value: part["rsec"]) { v in model.updatePart(part.id) { $0["rsec"] = max(v, 0.001) } }
            ValueField(label: "Coupling", unit: "", value: part["k"]) { v in model.updatePart(part.id) { $0["k"] = min(max(v, 0), 0.99999) } }
            Text("Primary load is plate to plate, for the speaker impedance given. Less primary inductance loses bass; looser coupling loses treble. The centre tap goes to the supply.")
                .font(.system(size: 10)).foregroundColor(Theme.dim).fixedSize(horizontal: false, vertical: true)
        case .opamp:
            modelPicker(part, label: "Model")
            ValueField(label: "Negative rail", unit: "V", value: part.props["vneg"] ?? 0) { v in model.updatePart(part.id) { $0.props["vneg"] = v } }
            ValueField(label: "Positive rail", unit: "V", value: part.props["vpos"] ?? 9) { v in model.updatePart(part.id) { $0.props["vpos"] = v } }
            deviceNotes(part)
        case .supply:
            ValueField(label: "Voltage", unit: "V", value: part["v"]) { v in
                model.updatePart(part.id) { $0["v"] = v; $0.text = Eng.format(v) + "V" }
            }
            ValueField(label: "Source R", unit: "Ω", value: part["rs"]) { v in model.updatePart(part.id) { $0["rs"] = max(v, 0.001) } }
            Text("Source R is the supply's own resistance. Tens of ohms with a reservoir capacitor makes a rail that sags when the amp is pushed.").font(.system(size: 10)).foregroundColor(Theme.dim).fixedSize(horizontal: false, vertical: true)
            Text("Supplies with the same voltage are the same net.").font(.system(size: 10)).foregroundColor(Theme.dim)
        case .input:
            ValueField(label: "Source R", unit: "Ω", value: part["rs"]) { v in model.updatePart(part.id) { $0["rs"] = max(v, 1) } }
            ValueField(label: "Volts per unit", unit: "V", value: part["scale"]) { v in model.updatePart(part.id) { $0["scale"] = v } }
            Text("A full-scale digital signal becomes this many volts at the jack.").font(.system(size: 10)).foregroundColor(Theme.dim)
        case .output:
            ValueField(label: "Load", unit: "Ω", value: part["rl"]) { v in model.updatePart(part.id) { $0["rl"] = max(v, 1) } }
            ValueField(label: "Units per volt", unit: "", value: part["scale"]) { v in model.updatePart(part.id) { $0["scale"] = v } }
        case .label:
            HStack {
                Text("Net name").foregroundColor(Theme.dim).frame(width: 92, alignment: .leading)
                TextField("", text: Binding(get: { part.text }, set: { v in model.updatePart(part.id) { $0.text = v } }))
                    .textFieldStyle(.roundedBorder)
            }
            Text("Every label with the same name is connected.").font(.system(size: 10)).foregroundColor(Theme.dim)
        case .ground:
            Text("All grounds are connected (0 V).").foregroundColor(Theme.dim)
        }
        Text("Pins: " + part.kind.pinNames.joined(separator: ", ")).font(.system(size: 10)).foregroundColor(Theme.dim)
        actions
    }

    func modelPicker(_ part: Part, label: String) -> some View {
        HStack {
            Text(label).foregroundColor(Theme.dim).frame(width: 92, alignment: .leading)
            Picker("", selection: Binding(get: { part.model }, set: { v in model.updatePart(part.id) { $0.model = v } })) {
                ForEach(part.kind.models, id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden()
        }
    }

    @ViewBuilder
    func deviceNotes(_ part: Part) -> some View {
        let t: String = {
            switch part.kind {
            case .diode, .led:
                let m = DeviceLibrary.diode(part.model, led: part.kind == .led)
                return "Shockley model: Is \(Eng.format(m.Is, unit: "A")), n \(m.n), series R \(Eng.format(m.rs, unit: "Ω")), junction C \(Eng.format(m.cj, unit: "F"))."
            case .npn, .pnp:
                let m = DeviceLibrary.bjt(part.model, pnp: part.kind == .pnp)
                return "Ebers–Moll with Early effect: Is \(Eng.format(m.Is, unit: "A")), β \(Int(m.bf)), Early \(Int(m.va)) V, junction capacitances included."
            case .zener:
                let m = DeviceLibrary.zener(part.model)
                return "An ordinary diode forwards (about 0.7 V); backwards it breaks down and holds about \(m.bv) V (its rating at \(Int(m.ibv * 1000)) mA; a little less at pedal currents). The knee is \(m.bv < 5 ? "soft" : "sharp") at this voltage."
            case .njfet, .pjfet:
                let m = DeviceLibrary.jfet(part.model, pch: part.kind == .pjfet)
                return "Square-law JFET: Vp \(m.vto) V, β \(Eng.format(m.beta, unit: "A/V²")), gate junctions conduct when forward biased."
            case .nmos, .pmos:
                let m = DeviceLibrary.mosfet(part.model, pmos: part.kind == .pmos)
                return "Square-law MOSFET with a smooth turn-on: threshold \(m.vto) V, Kp \(Eng.format(m.kp, unit: "A/V²")), body diode between source and drain, gate capacitances included."
            case .pentode:
                let m = DeviceLibrary.pentode(part.model)
                return "Koren power-tube model: µ \(m.mu), the screen sets the current and the plate has a knee at low voltage; grid current above 0 V."
            case .triode:
                let m = DeviceLibrary.triode(part.model)
                return "Koren triode: µ \(Int(m.mu)), grid current above 0 V, Miller capacitance (Cgp \(Eng.format(m.cgp, unit: "F")))."
            case .opamp:
                let m = DeviceLibrary.opamp(part.model)
                return "Gain \(Eng.format(m.gain)), GBW \(Eng.format(m.gbw, unit: "Hz")), slew \(m.slew) V/µs, swings to \(m.headroom) V from each rail."
            default: return ""
            }
        }()
        Text(t).font(.system(size: 10)).foregroundColor(Theme.dim).fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    var circuitInfo: some View {
        Text(model.board == .pedal ? "PEDAL CIRCUIT" : "AMP CIRCUIT").font(.system(size: 10, weight: .semibold)).foregroundColor(Theme.accent)
        TextField("Name", text: Binding(get: { model.circuit.name }, set: { v in model.edit { $0.name = v } }))
            .textFieldStyle(.roundedBorder)
        Text(model.circuit.notes).foregroundColor(Theme.dim).fixedSize(horizontal: false, vertical: true)
        let a = model.analysis[model.board]
        if let err = a?.error {
            Label(err, systemImage: "exclamationmark.triangle.fill").foregroundColor(.orange)
        } else if let a {
            Label("Simulating \(a.nodeCount) unknowns", systemImage: "checkmark.circle.fill").foregroundColor(Theme.good)
        }
        ForEach(a?.warnings ?? [], id: \.self) { Label($0, systemImage: "exclamationmark.circle").foregroundColor(.yellow) }
        if let bias = a?.bias, !bias.isEmpty {
            Text("BIAS VOLTAGES").font(.system(size: 10, weight: .semibold)).foregroundColor(Theme.dim).padding(.top, 6)
            ForEach(Array(bias.enumerated()), id: \.offset) { _, row in
                HStack {
                    Text(row.0).foregroundColor(Theme.dim)
                    Spacer()
                    Text(String(format: "%.3f V", row.1)).monospacedDigit()
                }
                .font(.system(size: 11))
            }
            Text("Node numbers (N…) appear in the exported SPICE netlist.").font(.system(size: 10)).foregroundColor(Theme.dim)
        }
    }
}

// MARK: - Knob

struct Knob: View {
    let label: String
    let value: Float
    let range: ClosedRange<Float>
    var format: (Float) -> String = { String(format: "%.0f", $0 * 10) }
    var size: CGFloat = 46
    var accent: Color = Theme.gold
    let set: (Float) -> Void
    @State private var startValue: Float?

    var fraction: Double { Double((value - range.lowerBound) / (range.upperBound - range.lowerBound)) }

    var body: some View {
        VStack(spacing: 2) {
            Canvas { ctx, sz in
                // Atelier's knob: a ring of eleven dots that light up to the setting, a dark skirt,
                // a cap in the section's colour and a cream pointer.
                let c = CGPoint(x: sz.width / 2, y: sz.height / 2)
                let radius = min(sz.width, sz.height) / 2 - 7
                func angle(_ t: Double) -> Double { (-225 + 270 * t) * .pi / 180 }
                for i in 0...10 {
                    let t = Double(i) / 10, a = angle(t)
                    let p = CGPoint(x: c.x + (radius + 4.5) * cos(a), y: c.y + (radius + 4.5) * sin(a))
                    ctx.fill(Path(ellipseIn: CGRect(x: p.x - 1.3, y: p.y - 1.3, width: 2.6, height: 2.6)),
                             with: .color(t <= fraction + 0.001 ? accent : Theme.hex(0x3a3c42)))
                }
                let skirt = CGRect(x: c.x - radius, y: c.y - radius, width: radius * 2, height: radius * 2)
                ctx.fill(Path(ellipseIn: skirt.offsetBy(dx: 0, dy: 2.5)), with: .color(.black.opacity(0.45)))
                ctx.fill(Path(ellipseIn: skirt), with: .linearGradient(Gradient(colors: [Theme.hex(0x4a4d54), Theme.hex(0x101113)]),
                                                                       startPoint: CGPoint(x: c.x, y: skirt.minY), endPoint: CGPoint(x: c.x, y: skirt.maxY)))
                ctx.stroke(Path(ellipseIn: skirt), with: .color(.black.opacity(0.8)), lineWidth: 1)
                let cap = skirt.insetBy(dx: radius * 0.24, dy: radius * 0.24)
                ctx.fill(Path(ellipseIn: cap), with: .linearGradient(Gradient(colors: [accent.opacity(1), accent.opacity(0.45)]),
                                                                     startPoint: CGPoint(x: c.x, y: cap.minY), endPoint: CGPoint(x: c.x, y: cap.maxY)))
                ctx.stroke(Path(ellipseIn: cap.insetBy(dx: 0.5, dy: 0.5)), with: .color(.white.opacity(0.18)), lineWidth: 1)
                let a = angle(fraction)
                var pointer = Path()
                pointer.move(to: CGPoint(x: c.x + radius * 0.36 * cos(a), y: c.y + radius * 0.36 * sin(a)))
                pointer.addLine(to: CGPoint(x: c.x + radius * 0.96 * cos(a), y: c.y + radius * 0.96 * sin(a)))
                ctx.stroke(pointer, with: .color(Theme.hex(0xf6f0de)), style: StrokeStyle(lineWidth: 2.6, lineCap: .round))
            }
            .frame(width: size + 14, height: size + 14)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                if startValue == nil { startValue = value }
                let span = range.upperBound - range.lowerBound
                let fine: Float = NSEvent.modifierFlags.contains(.option) ? 0.2 : 1
                let v = (startValue ?? value) + Float(-g.translation.height / 180) * span * fine
                set(min(max(v, range.lowerBound), range.upperBound))
            }.onEnded { _ in startValue = nil })
            .onTapGesture(count: 2) { set((range.lowerBound + range.upperBound) / 2) }
            Text(label.uppercased()).font(Theme.label(9.5)).tracking(0.8).foregroundColor(Theme.dim).lineLimit(1).minimumScaleFactor(0.7)
            Text(format(value)).font(.system(size: 9, weight: .semibold).monospacedDigit()).foregroundColor(startValue == nil ? Theme.dim.opacity(0.8) : Theme.text)
        }
        .frame(minWidth: size + 18)
        .help("Drag up or down (Option for fine control). Double-click to centre.")
    }
}

// MARK: - Plots

struct ResponsePlot: View {
    let freqs: [Double]
    let curves: [([Double], Color, String)]

    var body: some View {
        Canvas { ctx, size in
            let lo = -40.0, hi = 50.0
            func x(_ f: Double) -> CGFloat { CGFloat(log10(f / 20) / 3) * size.width }
            func y(_ db: Double) -> CGFloat { CGFloat(1 - (min(max(db, lo), hi) - lo) / (hi - lo)) * size.height }
            for f in [50.0, 100, 200, 500, 1000, 2000, 5000, 10000] {
                var p = Path(); p.move(to: CGPoint(x: x(f), y: 0)); p.addLine(to: CGPoint(x: x(f), y: size.height))
                ctx.stroke(p, with: .color(Theme.line), lineWidth: 1)
                ctx.draw(Text(f >= 1000 ? "\(Int(f / 1000))k" : "\(Int(f))").font(.system(size: 9)).foregroundColor(Theme.dim),
                         at: CGPoint(x: x(f) + 2, y: size.height - 2), anchor: .bottomLeading)
            }
            for db in stride(from: -40.0, through: 40, by: 20) {
                var p = Path(); p.move(to: CGPoint(x: 0, y: y(db))); p.addLine(to: CGPoint(x: size.width, y: y(db)))
                ctx.stroke(p, with: .color(db == 0 ? Color(white: 1, opacity: 0.25) : Theme.line), lineWidth: 1)
                ctx.draw(Text("\(Int(db)) dB").font(.system(size: 9)).foregroundColor(Theme.dim), at: CGPoint(x: 3, y: y(db) - 1), anchor: .bottomLeading)
            }
            for (i, c) in curves.enumerated() where c.0.count == freqs.count && !freqs.isEmpty {
                var p = Path()
                for (k, f) in freqs.enumerated() {
                    let pt = CGPoint(x: x(f), y: y(c.0[k]))
                    if k == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
                }
                ctx.stroke(p, with: .color(c.1), lineWidth: 2)
                ctx.draw(Text(c.2).font(.system(size: 10, weight: .semibold)).foregroundColor(c.1),
                         at: CGPoint(x: size.width - 6, y: 6 + CGFloat(i) * 14), anchor: .topTrailing)
            }
        }
    }
}

struct ScopePlot: View {
    let input: [Double]
    let output: [Double]

    var body: some View {
        Canvas { ctx, size in
            let peak = max(0.05, (input + output).map(abs).max() ?? 1)
            func draw(_ s: [Double], _ color: Color) {
                guard s.count > 1 else { return }
                var p = Path()
                let mean = s.reduce(0, +) / Double(s.count)
                for (i, v) in s.enumerated() {
                    let pt = CGPoint(x: CGFloat(i) / CGFloat(s.count - 1) * size.width,
                                     y: size.height / 2 - CGFloat((v - (color == Theme.accent ? mean : 0)) / peak) * size.height * 0.45)
                    if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
                }
                ctx.stroke(p, with: .color(color), lineWidth: 1.6)
            }
            var mid = Path(); mid.move(to: CGPoint(x: 0, y: size.height / 2)); mid.addLine(to: CGPoint(x: size.width, y: size.height / 2))
            ctx.stroke(mid, with: .color(Theme.line), lineWidth: 1)
            draw(input, Color(white: 0.55))
            draw(output, Theme.accent)
            ctx.draw(Text(String(format: "±%.2f V", peak)).font(.system(size: 9)).foregroundColor(Theme.dim), at: CGPoint(x: 4, y: 4), anchor: .topLeading)
            ctx.draw(Text("in").font(.system(size: 10, weight: .semibold)).foregroundColor(Color(white: 0.6)), at: CGPoint(x: size.width - 30, y: 6), anchor: .topTrailing)
            ctx.draw(Text("out").font(.system(size: 10, weight: .semibold)).foregroundColor(Theme.accent), at: CGPoint(x: size.width - 6, y: 6), anchor: .topTrailing)
        }
    }
}

struct Meter: View {
    let level: Float
    var body: some View {
        GeometryReader { g in
            let db = 20 * log10(max(Double(level), 1e-5))
            let f = CGFloat(min(1, max(0, (db + 60) / 66)))
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 2).fill(Theme.well)
                RoundedRectangle(cornerRadius: 2)
                    .fill(LinearGradient(colors: [Theme.good, .yellow, .red], startPoint: .bottom, endPoint: .top))
                    .frame(height: g.size.height * f)
            }
        }
        .frame(width: 6)
    }
}
