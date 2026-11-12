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
            PedalboardView(model: model)
                .frame(height: PedalFace.height + 46)
            Divider().background(Theme.line)
            if model.workshopOpen {
                workshopHeader
                HStack(spacing: 0) {
                    PaletteView(model: model)
                    Divider().background(Theme.line)
                    SchematicView(model: model)
                    Divider().background(Theme.line)
                    InspectorView(model: model)
                }
                Divider().background(Theme.line)
            }
            AnalysisPanel(model: model, tab: $bottomTab)
                .frame(height: 170)
                .frame(maxHeight: model.workshopOpen ? 170 : .infinity)
        }
        .background(Theme.bg)
        .preferredColorScheme(.dark)
        .foregroundColor(Theme.text)
    }

    /// The strip over the drawing board: which module is open, and a way to fold the workshop away.
    var workshopHeader: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 1).fill(model.board.isAmp ? Theme.gold : Theme.red).frame(width: 3, height: 12)
            Text("WORKSHOP").font(Theme.label(10)).tracking(1.8).foregroundColor(Theme.dim)
            Text(model.title(model.board).uppercased() + " · " + model.circuit.name.uppercased())
                .font(Theme.label(10)).tracking(1.4).foregroundColor(Theme.text).lineLimit(1)
            if let n = model.analysis[model.board]?.nodeCount, n > 0 {
                Text("\(n) nodes").font(.system(size: 10)).foregroundColor(Theme.dim)
            }
            Spacer()
            Button { model.workshopOpen = false } label: {
                Label("Hide circuit", systemImage: "chevron.down").font(.system(size: 10))
            }
            .buttonStyle(.borderless)
            .help("Fold the schematic away and keep just the board")
        }
        .padding(.horizontal, 12).padding(.vertical, 5)
        .background(Theme.panel2)
    }

    var toolbar: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text("LUTHERIE").font(.system(size: 17, weight: .bold)).tracking(5.5).foregroundColor(Theme.text)
                Text("AMP & PEDAL WORKSHOP").font(.system(size: 7.5, weight: .bold)).tracking(2.6).foregroundColor(Theme.red)
            }
            .padding(.trailing, 6)
            Menu {
                ForEach(model.board.isAmp ? Presets.amps : Presets.pedals, id: \.name) { p in
                    Button(p.name) { model.load(preset: p) }
                }
            } label: { Label("Load into \(model.title(model.board).lowercased())", systemImage: "square.grid.2x2") }
            .menuStyle(.borderlessButton).fixedSize()
            .help("Replace the circuit open in the workshop with a starter circuit")
            if !model.workshopOpen {
                Button { model.workshopOpen = true } label: { Label("Show circuit", systemImage: "chevron.up") }
                    .help("Open the schematic workshop")
            }
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

/// Frequency response and oscilloscope for the module open in the workshop.
struct AnalysisPanel: View {
    @ObservedObject var model: EditorModel
    @Binding var tab: Int

    /// The open module in its own colour, with the amp circuit behind it for reference.
    var curves: [([Double], Color, String)] {
        var c: [([Double], Color, String)] = []
        if !model.board.isAmp { c.append((model.analysis[model.board]?.response ?? [], Theme.red, "\(model.title(model.board)) (small signal)")) }
        if Int(model.param(.ampMode).rounded()) == 1 || model.board.isAmp {
            c.append((model.analysis[.amp]?.response ?? [], Theme.gold, "Amp circuit"))
        }
        return c
    }

    var body: some View {
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
                ResponsePlot(freqs: a?.freqs ?? model.analysis[.amp]?.freqs ?? [], curves: curves)
            } else {
                ScopePlot(input: a?.scopeIn ?? [], output: a?.scopeOut ?? [])
                Text("\(model.title(model.board)) · \(model.circuit.name), simulated in volts at the output jack.").font(.system(size: 10)).foregroundColor(Theme.dim)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

}
