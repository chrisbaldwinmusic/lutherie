import PedalCore
import SwiftUI

/// The whole editor: toolbar, part palette, drawing board, inspector, and the rack of knobs and plots.
public struct EditorView<Extra: View>: View {
    @ObservedObject var model: EditorModel
    let extra: Extra
    @State private var bottomTab = 0

    public init(model: EditorModel, @ViewBuilder extra: () -> Extra) {
        self.model = model
        self.extra = extra()
    }

    public var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider().background(Theme.line)
            HStack(spacing: 0) {
                PaletteView(model: model)
                Divider().background(Theme.line)
                SchematicView(model: model)
                Divider().background(Theme.line)
                InspectorView(model: model)
            }
            Divider().background(Theme.line)
            RackView(model: model, tab: $bottomTab)
                .frame(height: 230)
        }
        .background(Theme.bg)
        .preferredColorScheme(.dark)
        .foregroundColor(Theme.text)
    }

    var toolbar: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text("LUTHERIE").font(.system(size: 17, weight: .bold)).tracking(5.5).foregroundColor(Theme.text)
                Text("AMP & PEDAL WORKSHOP").font(.system(size: 7.5, weight: .bold)).tracking(2.6).foregroundColor(Theme.red)
            }
            .padding(.trailing, 6)
            Picker("", selection: $model.board) {
                ForEach(Board.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 140)
            .onChange(of: model.board) { _, _ in model.selection = []; model.selectedWires = []; model.fitView() }
            Menu {
                ForEach(model.board == .pedal ? Presets.pedals : Presets.amps, id: \.name) { p in
                    Button(p.name) { model.load(preset: p) }
                }
            } label: { Label("Starter circuits", systemImage: "square.grid.2x2") }
            .menuStyle(.borderlessButton).fixedSize()
            Divider().frame(height: 18)
            Button { model.undo() } label: { Image(systemName: "arrow.uturn.backward") }.disabled(!model.canUndo).help("Undo")
            Button { model.redo() } label: { Image(systemName: "arrow.uturn.forward") }.disabled(!model.canRedo).help("Redo")
            Button { model.rotateSelection() } label: { Image(systemName: "rotate.right") }.help("Rotate (R)")
            Button { model.flipSelection() } label: { Image(systemName: "arrow.left.and.right.righttriangle.left.righttriangle.right") }.help("Flip (F)")
            Button { model.deleteSelection() } label: { Image(systemName: "trash") }.help("Delete (⌫)")
            Divider().frame(height: 18)
            Button { model.learnMode.toggle() } label: {
                Label("Learn", systemImage: "graduationcap")
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(model.learnMode ? Theme.accent : Theme.panel2, in: Capsule())
                    .foregroundColor(Theme.text)
            }
            .help("Learn mode: explains what each change does to the signal")
            Divider().frame(height: 18)
            Text("Oversampling").font(.system(size: 11)).foregroundColor(Theme.dim)
            Picker("", selection: $model.quality) {
                Text("1×").tag(1); Text("2×").tag(2); Text("4×").tag(4); Text("8×").tag(8)
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 146)
            .help("Oversampling: run the circuits and power stage at a multiple of the sample rate so distortion stays free of aliasing. 4× suits almost everything; 8× is for very high gain; 1× saves CPU.")
            Spacer()
            extra
            Menu {
                Button("Open session…") { model.openDocumentPanel() }
                Button("Save session…") { model.saveDocumentPanel() }
                Divider()
                Button("Export SPICE netlist for LTspice…") { model.exportSpicePanel() }
                Divider()
                Button("Load amp profile (.nam)…") { model.loadProfilePanel() }
                Button("Load cabinet impulse response…") { model.loadImpulsePanel() }
            } label: { Label("File", systemImage: "doc") }
            .menuStyle(.borderlessButton).fixedSize()
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(LinearGradient(colors: [Theme.hex(0x241e20), Theme.hex(0x191516)], startPoint: .top, endPoint: .bottom))
        .overlay(alignment: .bottom) {
            if let m = model.message {
                Text(m).font(.system(size: 11)).padding(.horizontal, 10).padding(.vertical, 4)
                    .background(Theme.panel2, in: Capsule()).offset(y: 30)
                    .onTapGesture { model.message = nil }
                    .task(id: m) { try? await Task.sleep(for: .seconds(6)); if model.message == m { model.message = nil } }
            }
        }
        .zIndex(1)
    }
}

struct RackView: View {
    @ObservedObject var model: EditorModel
    @Binding var tab: Int

    var body: some View {
        let _ = model.paramTick
        HStack(alignment: .top, spacing: 6) {
            levels.frame(maxHeight: .infinity, alignment: .top).background(PanelBackground())
            pedalSection.frame(maxHeight: .infinity, alignment: .top).background(PanelBackground())
            ampSection.frame(maxHeight: .infinity, alignment: .top).background(PanelBackground())
            analysis.background(PanelBackground())
        }
        .padding(6)
        .background(LinearGradient(colors: [Theme.hex(0x1d1819), Theme.hex(0x120f10)], startPoint: .top, endPoint: .bottom))
    }

    func dbFormat(_ v: Float) -> String { String(format: "%+.1f dB", v) }

    var levels: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle("LEVELS", Theme.ivory)
            HStack(alignment: .top, spacing: 6) {
                Knob(label: "Input", value: model.param(.inputLevel), range: RigParam.inputLevel.range, format: dbFormat, size: 38, accent: Theme.ivory) { model.setParam(.inputLevel, $0) }
                Meter(level: model.bridge?.rig.inputPeak ?? 0).frame(height: 70)
                Knob(label: "Output", value: model.param(.outputLevel), range: RigParam.outputLevel.range, format: dbFormat, size: 38, accent: Theme.ivory) { model.setParam(.outputLevel, $0) }
                Meter(level: model.bridge?.rig.outputPeak ?? 0).frame(height: 70)
            }
            HStack(spacing: 6) {
                Knob(label: "Gate", value: model.param(.gate), range: RigParam.gate.range,
                     format: { $0 <= -99 ? "off" : String(format: "%.0f dB", $0) }, size: 30, accent: Theme.green) { model.setParam(.gate, $0) }
                Knob(label: "Mix", value: model.param(.mix), range: 0...1, format: { String(format: "%.0f%%", $0 * 100) }, size: 30, accent: Theme.ivory) { model.setParam(.mix, $0) }
            }
            Text(String(format: "CPU %.0f%%", (model.bridge?.rig.load ?? 0) * 100)).font(.system(size: 10).monospacedDigit()).foregroundColor(Theme.dim)
        }
        .padding(10)
        .frame(width: 170)
    }

    var pedalSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                sectionTitle("PEDAL · " + model.pedal.name.uppercased(), Theme.red)
                Spacer()
                Footswitch(on: model.param(.pedalOn) > 0.5) { model.setParam(.pedalOn, model.param(.pedalOn) > 0.5 ? 0 : 1) }
            }
            knobGrid(.pedal)
            if let e = model.analysis[.pedal]?.error { Text(e).font(.system(size: 10)).foregroundColor(.orange) }
        }
        .padding(10)
        .frame(minWidth: 230, maxWidth: 330)
    }

    var ampSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                sectionTitle("AMP", Theme.crimson)
                Spacer()
                Picker("", selection: Binding(get: { Int(model.param(.ampMode).rounded()) }, set: { model.setParam(.ampMode, Float($0)) })) {
                    Text("Off").tag(0); Text("Tube circuit").tag(1); Text("Profile").tag(2)
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 210)
            }
            let mode = Int(model.param(.ampMode).rounded())
            if mode == 1 {
                knobGrid(.amp, extra: !model.amp.hasPowerStage)
            } else if mode == 2 {
                HStack {
                    Image(systemName: "waveform.path.ecg").foregroundColor(Theme.accent)
                    Text(model.profileName ?? "No profile loaded").lineLimit(1)
                    Button("Load .nam…") { model.loadProfilePanel() }.controlSize(.small)
                    if Tone3000Config.isConfigured {
                        Button(model.tone3000Busy ? "Loading…" : "Browse TONE3000…") { model.browseTone3000() }
                            .controlSize(.small).disabled(model.tone3000Busy)
                            .help("Sign in to your TONE3000 account and pick an amp capture")
                    }
                }
                .font(.system(size: 12))
                if let t = model.tone3000 {
                    Text(t.credit).font(.system(size: 10)).foregroundColor(Theme.text).lineLimit(2)
                    if model.tone3000NeedsReload && Tone3000Config.isConfigured {
                        Button("Reload from TONE3000") { model.reloadTone3000() }.controlSize(.small).disabled(model.tone3000Busy)
                    }
                    if model.tone3000Models.count > 1 {
                        Picker("Capture", selection: Binding(get: { t.modelID }, set: { id in
                            if let m = model.tone3000Models.first(where: { $0.id == id }) { model.chooseTone3000(model: m) }
                        })) {
                            ForEach(model.tone3000Models) { Text($0.size.isEmpty ? $0.name : "\($0.name) (\($0.size))").tag($0.id) }
                        }
                        .font(.system(size: 11)).frame(maxWidth: 300)
                    }
                    Link("Powered by TONE3000", destination: URL(string: t.url ?? "https://www.tone3000.com")!)
                        .font(.system(size: 10, weight: .semibold))
                } else {
                    Text("Neural Amp Modeler captures of real amps. Free ones are shared at tone3000.com.")
                        .font(.system(size: 10)).foregroundColor(Theme.dim)
                }
                Knob(label: "Presence", value: model.param(.presence), range: RigParam.presence.range, format: dbFormat, size: 30, accent: Theme.crimson) { model.setParam(.presence, $0) }
            } else {
                Text("Amp off: the pedal goes straight to the cabinet.").font(.system(size: 11)).foregroundColor(Theme.dim)
            }
            HStack {
                Text("Cabinet").font(.system(size: 11)).foregroundColor(Theme.dim)
                Picker("", selection: Binding(get: { Int(model.param(.cabMode).rounded()) }, set: { model.setParam(.cabMode, Float($0)) })) {
                    Text("Off").tag(0); Text("Simple 1×12").tag(1); Text(model.irName ?? "Impulse").tag(2)
                }
                .labelsHidden().frame(width: 150)
                Menu("Cabinets") {
                    ForEach(CabinetLibrary.cabinets, id: \.self) { name in
                        Button(name) {
                            model.choose(cabinet: CabinetChoice(cabinet: name, mic: model.cabinet?.mic ?? CabinetLibrary.mics[0],
                                                                position: model.cabinet?.position ?? CabinetLibrary.positions[1]))
                        }
                    }
                    Divider()
                    Button("Load impulse response file…") { model.loadImpulsePanel() }
                }
                .controlSize(.small).frame(width: 96)
                .help("Built-in speaker cabinets, or load your own impulse response")
            }
            if let cab = model.cabinet, Int(model.param(.cabMode).rounded()) == 2 {
                HStack {
                    Text("Mic").font(.system(size: 11)).foregroundColor(Theme.dim)
                    Picker("", selection: Binding(get: { cab.mic }, set: { v in var c = cab; c.mic = v; model.choose(cabinet: c) })) {
                        ForEach(CabinetLibrary.mics, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden().frame(width: 104)
                    Text("at").font(.system(size: 11)).foregroundColor(Theme.dim)
                    Picker("", selection: Binding(get: { cab.position }, set: { v in var c = cab; c.position = v; model.choose(cabinet: c) })) {
                        ForEach(CabinetLibrary.positions, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden().frame(width: 96)
                }
                Text(CabinetLibrary.notes(cab.cabinet)).font(.system(size: 10)).foregroundColor(Theme.dim)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .frame(minWidth: 330, maxWidth: 460)
    }

    var analysis: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Picker("", selection: $tab) {
                    Text("Frequency response").tag(0); Text("Oscilloscope").tag(1)
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 260)
                Spacer()
                if tab == 1 {
                    Text("Test tone").font(.system(size: 10)).foregroundColor(Theme.dim)
                    Picker("", selection: $model.scopeFrequency) {
                        ForEach([82.0, 110, 220, 440, 880], id: \.self) { Text("\(Int($0)) Hz").tag($0) }
                    }
                    .labelsHidden().frame(width: 80)
                    Picker("", selection: $model.scopeLevel) {
                        ForEach([0.05, 0.1, 0.3, 1.0], id: \.self) { Text(String(format: "%.2g V", $0)).tag($0) }
                    }
                    .labelsHidden().frame(width: 74)
                    .onChange(of: model.scopeLevel) { _, _ in model.rerunScope() }
                    .onChange(of: model.scopeFrequency) { _, _ in model.rerunScope() }
                }
            }
            let a = model.analysis[model.board]
            if tab == 0 {
                ResponsePlot(freqs: model.analysis[.pedal]?.freqs ?? [],
                             curves: [(model.analysis[.pedal]?.response ?? [], Theme.red, "Pedal (small signal)"),
                                      (model.analysis[.amp]?.response ?? [], Theme.gold, "Amp circuit")])
            } else {
                ScopePlot(input: a?.scopeIn ?? [], output: a?.scopeOut ?? [])
                Text("\(model.board.title) circuit, simulated in volts at the output jack.").font(.system(size: 10)).foregroundColor(Theme.dim)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    func knobGrid(_ b: Board, extra: Bool = false) -> some View {
        let knobs = model.knobs(b)
        let total = knobs.count + (extra ? 2 : 0)
        let size: CGFloat = total > 5 ? 30 : 40
        return Group {
            if knobs.isEmpty && !extra {
                Text("Add a potentiometer to the \(b.title.lowercased()) circuit to get a knob here.")
                    .font(.system(size: 11)).foregroundColor(Theme.dim)
            } else {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(size + 22), spacing: 2), count: min(7, max(total, 1))), spacing: 4) {
                    ForEach(knobs, id: \.0) { k in
                        Knob(label: k.1, value: model.param(k.0), range: 0...1, size: size, accent: b == .pedal ? Theme.red : Theme.crimson) { model.setParam(k.0, $0) }
                    }
                    if extra {
                        Knob(label: "Power", value: model.param(.powerDrive), range: 0...1, size: size, accent: Theme.gold) { model.setParam(.powerDrive, $0) }
                        Knob(label: "Presence", value: model.param(.presence), range: RigParam.presence.range, format: dbFormat, size: size, accent: Theme.gold) { model.setParam(.presence, $0) }
                    }
                }
            }
        }
    }

    func sectionTitle(_ s: String, _ accent: Color = Theme.gold) -> some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 1).fill(accent).frame(width: 3, height: 11)
            Text(s).font(Theme.label(11)).tracking(1.8).foregroundColor(Theme.text).lineLimit(1)
        }
    }
}

struct Footswitch: View {
    let on: Bool
    let toggle: () -> Void
    var body: some View {
        Button(action: toggle) {
            Text(on ? "ON" : "BYPASS").font(Theme.label(10)).tracking(0.7)
                .foregroundColor(on ? Theme.text : Theme.dim)
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(on ? Theme.red : Theme.panel2, in: RoundedRectangle(cornerRadius: 3))
                .overlay(RoundedRectangle(cornerRadius: 3).stroke(on ? Theme.red.opacity(0.6) : Theme.wellEdge, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help("Footswitch: true bypass")
    }
}
