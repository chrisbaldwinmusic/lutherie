import AppKit
import Foundation
import PedalCore
import SwiftUI
import UniformTypeIdentifiers

public enum Board: String, CaseIterable, Identifiable, Codable {
    case pedal, amp
    public var id: String { rawValue }
    public var title: String { self == .pedal ? "Pedal" : "Amp" }
    var knobBase: RigParam { self == .pedal ? .pedalKnob1 : .ampKnob1 }
}

public enum Tool: Equatable {
    case select, wire
    case place(PartKind)
}

/// Lets the editor read and write parameters through the plugin, so the host sees every change.
public protocol ParamBridge: AnyObject {
    func value(_ p: RigParam) -> Float
    func set(_ p: RigParam, _ v: Float)
    var rig: Rig { get }
    /// The delay through the rig changed (oversampling or amp mode): tell the host so it can realign tracks.
    func latencyChanged()
}

/// Everything saved with a session or a plugin preset.
public struct PedalDocument: Codable {
    public var version = 1
    public var pedal: Circuit
    public var amp: Circuit
    public var params: [Int: Float]
    public var quality: Int
    public var profileName: String?
    public var profileData: Data?
    public var irName: String?
    public var irSamples: [Float]?
    /// Set when the impulse response is one of the built-in cabinets (so it can be rebuilt at any sample rate).
    public var cabinet: CabinetChoice?
    /// Set when the amp profile came from TONE3000: the session keeps this reference, not the model file.
    public var tone3000: Tone3000Ref?
}

public struct Analysis {
    public var freqs: [Double] = []
    public var response: [Double] = []
    public var scopeIn: [Double] = []
    public var scopeOut: [Double] = []
    public var bias: [(String, Double)] = []
    public var error: String?
    public var warnings: [String] = []
    public var knobLabels: [String] = []
    public var nodeCount = 0
    public var harmonics: [Double] = []  // amplitudes of harmonics 1…9 at the test tone
    public var outPeak: Double = 0
}

@MainActor
public final class EditorModel: ObservableObject {
    @Published public var pedal: Circuit
    @Published public var amp: Circuit
    @Published public var board: Board = .pedal
    @Published public var tool: Tool = .select
    @Published public var selection: Set<UUID> = []
    @Published public var selectedWires: Set<UUID> = []
    @Published public var zoom: CGFloat = 1
    @Published public var pan: CGSize = CGSize(width: 120, height: 320)
    @Published public var analysis: [Board: Analysis] = [:]
    @Published public var quality: Int = 4 { didSet { if quality != oldValue { rebuild(.pedal); rebuild(.amp) } } }
    @Published public var profileName: String?
    @Published public var irName: String?
    @Published public var cabinet: CabinetChoice?
    @Published public var tone3000: Tone3000Ref?
    @Published public var tone3000Models: [Tone3000Model] = []
    @Published public var tone3000Busy = false
    /// True when a session names a TONE3000 tone that hasn't been fetched yet.
    @Published public var tone3000NeedsReload = false
    @Published public var message: String?
    @Published public var paramTick = 0
    @Published public var scopeFrequency: Double = 220
    @Published public var scopeLevel: Double = 0.3
    @Published public var learnMode = false { didSet { if !learnMode { lesson = nil } } }
    @Published public var lesson: Lesson?
    var pendingChange: [Board: Change] = [:]

    public weak var bridge: ParamBridge?
    var profileData: Data?
    var irSamples: [Float]?
    var undoStack: [(Circuit, Circuit)] = []
    var redoStack: [(Circuit, Circuit)] = []
    var pending: [Board: DispatchWorkItem] = [:]
    var generation: [Board: Int] = [.pedal: 0, .amp: 0]
    var meterTimer: Timer?
    var reportedLatency = 0
    let workQueue = DispatchQueue(label: "lutherie.compile", qos: .userInitiated)

    public init() {
        pedal = Presets.overdrive
        amp = Presets.tubePreamp
    }

    public func attach(_ bridge: ParamBridge) {
        self.bridge = bridge
        rebuild(.pedal)
        rebuild(.amp)
        meterTimer?.invalidate()
        meterTimer = Timer.scheduledTimer(withTimeInterval: 1 / 20, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.paramTick &+= 1
                if let rig = self.bridge?.rig, rig.expectedLatency != self.reportedLatency {
                    self.reportedLatency = rig.expectedLatency
                    self.bridge?.latencyChanged()
                }
            }
        }
    }

    // MARK: Circuits

    public var circuit: Circuit {
        get { board == .pedal ? pedal : amp }
        set { if board == .pedal { pedal = newValue } else { amp = newValue } }
    }

    public func circuit(_ b: Board) -> Circuit { b == .pedal ? pedal : amp }

    public func checkpoint() {
        undoStack.append((pedal, amp))
        if undoStack.count > 200 { undoStack.removeFirst() }
        redoStack.removeAll()
    }

    /// Applies an edit with undo and re-simulates.
    public func edit(_ body: (inout Circuit) -> Void) {
        checkpoint()
        let old = circuit
        var c = circuit
        body(&c)
        circuit = c
        if learnMode, let ch = describe(old, c) { pendingChange[board] = ch }
        rebuild(board)
    }

    /// What differs between two versions of a circuit, for learn mode.
    func describe(_ a: Circuit, _ b: Circuit) -> Change? {
        let oldParts = Dictionary(uniqueKeysWithValues: a.parts.map { ($0.id, $0) })
        let newParts = Dictionary(uniqueKeysWithValues: b.parts.map { ($0.id, $0) })
        if let added = b.parts.first(where: { oldParts[$0.id] == nil }) { return .added(added) }
        if let gone = a.parts.first(where: { newParts[$0.id] == nil }) { return .removed(gone) }
        var moved = 0
        for p in b.parts {
            guard let o = oldParts[p.id], o != p else { continue }
            if o.props != p.props || o.model != p.model || o.rotation != p.rotation || o.flipped != p.flipped || o.text != p.text {
                return .altered(before: o, after: p)
            }
            if o.position != p.position { moved += 1 }
        }
        let oldW = Set(a.wires.map { "\($0.a)-\($0.b)" }), newW = Set(b.wires.map { "\($0.a)-\($0.b)" })
        if moved > 0 { return .moved(moved) }
        if oldW != newW { return .wiring(added: newW.subtracting(oldW).count, removed: oldW.subtracting(newW).count) }
        return nil
    }

    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }

    public func undo() {
        guard let s = undoStack.popLast() else { return }
        redoStack.append((pedal, amp))
        pedal = s.0; amp = s.1
        rebuild(.pedal); rebuild(.amp)
    }

    public func redo() {
        guard let s = redoStack.popLast() else { return }
        undoStack.append((pedal, amp))
        pedal = s.0; amp = s.1
        rebuild(.pedal); rebuild(.amp)
    }

    public func load(preset: Circuit) {
        checkpoint()
        circuit = preset
        selection = []; selectedWires = []
        fitView()
        rebuild(board)
    }

    public func fitView() {
        let pts = circuit.parts.flatMap(\.pins) + circuit.wires.flatMap { [$0.a, $0.b] }
        guard let minX = pts.map(\.x).min(), let minY = pts.map(\.y).min() else { return }
        zoom = 1
        pan = CGSize(width: CGFloat(-minX + 3) * 20 * zoom, height: CGFloat(-minY + 4) * 20 * zoom)
    }

    // MARK: Selection & editing

    public var selectedParts: [Part] { circuit.parts.filter { selection.contains($0.id) } }

    public func deleteSelection() {
        guard !selection.isEmpty || !selectedWires.isEmpty else { return }
        edit { c in
            c.parts.removeAll { selection.contains($0.id) }
            c.wires.removeAll { selectedWires.contains($0.id) }
        }
        selection = []; selectedWires = []
    }

    public func rotateSelection() {
        guard !selection.isEmpty else { return }
        edit { c in for i in c.parts.indices where selection.contains(c.parts[i].id) { c.parts[i].rotation = (c.parts[i].rotation + 1) % 4 } }
    }

    public func flipSelection() {
        guard !selection.isEmpty else { return }
        edit { c in for i in c.parts.indices where selection.contains(c.parts[i].id) { c.parts[i].flipped.toggle() } }
    }

    public func duplicateSelection() {
        guard !selection.isEmpty else { return }
        var newIDs = Set<UUID>()
        edit { c in
            for p in c.parts where selection.contains(p.id) {
                var q = p
                q.id = UUID()
                q.name = c.nextName(for: p.kind)
                q.position = p.position + GridPoint(2, 2)
                c.parts.append(q)
                newIDs.insert(q.id)
            }
        }
        selection = newIDs
    }

    public func updatePart(_ id: UUID, _ body: (inout Part) -> Void) {
        edit { c in if let i = c.parts.firstIndex(where: { $0.id == id }) { body(&c.parts[i]) } }
    }

    public func place(_ kind: PartKind, at p: GridPoint) {
        var newID = UUID()
        edit { c in
            var part = Part(kind, name: c.nextName(for: kind), at: p)
            if kind == .supply { part.text = "\(Eng.format(part["v"]))V" }
            if kind == .label { part.text = "NET\(c.parts.filter { $0.kind == .label }.count + 1)" }
            if kind == .pot { part.text = "Knob \(c.parts.filter { $0.kind == .pot }.count + 1)" }
            newID = part.id
            c.parts.append(part)
        }
        selection = [newID]
        selectedWires = []
    }

    public func addWire(_ a: GridPoint, _ b: GridPoint, verticalFirst: Bool) {
        guard a != b else { return }
        edit { c in c.connect(a, b, verticalFirst: verticalFirst) }
    }

    public func move(_ ids: Set<UUID>, by d: GridPoint, wiresToo: Bool) {
        guard d != GridPoint(0, 0) else { return }
        edit { c in
            let moving = c.parts.filter { ids.contains($0.id) }
            let oldPins = Set(moving.flatMap(\.pins))
            for i in c.parts.indices where ids.contains(c.parts[i].id) { c.parts[i].position = c.parts[i].position + d }
            // wire ends that were attached to a moved pin follow it
            if wiresToo {
                for i in c.wires.indices {
                    if oldPins.contains(c.wires[i].a) { c.wires[i].a = c.wires[i].a + d }
                    if oldPins.contains(c.wires[i].b) { c.wires[i].b = c.wires[i].b + d }
                }
                c.wires.removeAll { $0.a == $0.b }
            }
        }
    }

    // MARK: Simulation

    /// Re-simulates a board in the background and installs it in the audio engine.
    public func rebuild(_ b: Board, install: Bool = true, delay: Double = 0.12) {
        pending[b]?.cancel()
        generation[b, default: 0] += 1
        let gen = generation[b]!
        let c = circuit(b)
        let q = quality
        let sr = bridge?.rig.sampleRate ?? 48_000
        let freq = scopeFrequency, level = scopeLevel
        let work = DispatchWorkItem { [weak self] in
            var a = Analysis()
            var stage: CircuitStage?
            do {
                let s = try CircuitStage(circuit: c, hostRate: sr, factor: q)
                stage = s
                // Analysis on a separate copy so the audio copy stays untouched.
                let probe = try CircuitEngine(circuit: c, sampleRate: 96_000)
                a.freqs = (0..<120).map { 20 * pow(1000, Double($0) / 119) }
                a.response = probe.frequencyResponse(a.freqs)
                a.bias = probe.operatingPoint()
                a.warnings = probe.warnings
                a.knobLabels = probe.potLabels
                a.nodeCount = probe.n
                let periods = 3.0
                let settle = Int(96_000 * 0.25)
                let count = Int(96_000 * periods / freq)
                for i in 0..<(settle + count) {
                    let u = level * sin(2 * Double.pi * freq * Double(i) / 96_000)
                    let y = probe.tick(u)
                    if i >= settle && (i - settle) % max(1, count / 600) == 0 { a.scopeIn.append(u); a.scopeOut.append(y) }
                    if i >= settle {
                        // harmonic content of the output (DFT at the test tone and its multiples)
                        if a.harmonics.isEmpty { a.harmonics = Array(repeating: 0, count: 18) }
                        let ph = 2 * Double.pi * freq * Double(i - settle) / 96_000
                        for k in 0..<9 {
                            a.harmonics[2 * k] += y * cos(ph * Double(k + 1))
                            a.harmonics[2 * k + 1] += y * sin(ph * Double(k + 1))
                        }
                    }
                }
                if a.harmonics.count == 18 {
                    a.harmonics = (0..<9).map { k in 2 * hypot(a.harmonics[2 * k], a.harmonics[2 * k + 1]) / Double(count) }
                    // peak around the mean (outputs can sit on a DC level)
                    let mean = a.scopeOut.reduce(0, +) / Double(max(a.scopeOut.count, 1))
                    a.outPeak = a.scopeOut.map { abs($0 - mean) }.max() ?? 0
                }
            } catch {
                a.error = "\(error)"
            }
            DispatchQueue.main.async {
                guard let self, self.generation[b] == gen else { return }
                let before = self.analysis[b]
                self.analysis[b] = a
                if self.learnMode, let ch = self.pendingChange[b] {
                    self.pendingChange[b] = nil
                    self.lesson = Explainer.lesson(for: ch, before: before, after: a, circuit: c)
                }
                guard install, let rig = self.bridge?.rig else { return }
                if let s = stage {
                    // knobs keep the positions drawn in the circuit
                    for (i, pot) in c.knobs.prefix(8).enumerated() {
                        self.bridge?.set(RigParam(rawValue: b.knobBase.rawValue + i)!, Float(pot["position"]))
                    }
                    if b == .pedal { rig.install(pedal: s) } else { rig.install(amp: s) }
                } else {
                    if b == .pedal { rig.install(pedal: nil) } else { rig.install(amp: nil) }
                }
            }
        }
        pending[b] = work
        workQueue.asyncAfter(deadline: .now() + delay, execute: work)
    }

    public func rerunScope() { rebuild(.pedal); rebuild(.amp) }

    // MARK: Parameters

    public func param(_ p: RigParam) -> Float { bridge?.value(p) ?? p.defaultValue }

    public func setParam(_ p: RigParam, _ v: Float) {
        bridge?.set(p, v)
        // keep the drawing's knob positions in step (no undo entry, no re-simulation)
        let raw = p.rawValue
        if raw >= 10 && raw < 30 {
            let b: Board = raw >= 20 ? .amp : .pedal
            let idx = raw - b.knobBase.rawValue
            var c = circuit(b)
            let pots = c.knobs
            let members = c.partIndices(forKnob: idx)
            if idx < pots.count, let i = members.first {
                let old = c.parts[i]["position"]
                for m in members { c.parts[m]["position"] = Double(v) }   // ganged pots turn together
                if b == .pedal { pedal = c } else { amp = c }
                if learnMode {
                    // keep the position from the start of the gesture
                    var from = old
                    if case .knob(let p, let f, _)? = pendingChange[b], p.id == pots[idx].id { from = f }
                    pendingChange[b] = .knob(c.parts[i], from: from, to: Double(v))
                    rebuild(b, install: false, delay: 0.45)
                }
            }
        }
        paramTick &+= 1
    }

    public func knobs(_ b: Board) -> [(RigParam, String)] {
        circuit(b).knobs.prefix(8).enumerated().map { (RigParam(rawValue: b.knobBase.rawValue + $0)!, $1.text.isEmpty ? $1.name : $1.text) }
    }

    // MARK: Amp profiles and cabinets

    public func loadProfile(url: URL) {
        do {
            let data = try Data(contentsOf: url)
            try applyProfile(data: data, name: url.deletingPathExtension().lastPathComponent)
            tone3000 = nil; tone3000Models = []; tone3000NeedsReload = false
            setParam(.ampMode, 2)
        } catch { message = "Couldn't load that amp profile: \(error)" }
    }

    func applyProfile(data: Data, name: String) throws {
        let model = try NAMModel(data: data, name: name)
        let sr = bridge?.rig.sampleRate ?? 48_000
        bridge?.rig.install(profile: ProfileStage(model: model, hostRate: sr))
        profileData = data
        profileName = name
        message = "Loaded \(name): \(model.detail)" + (abs(model.modelSampleRate - sr) > 1 ? " (resampled from \(Int(model.modelSampleRate)) Hz)" : "")
    }

    // MARK: TONE3000

    /// Opens TONE3000's own picker (the player signs in with their account) and loads the tone they choose.
    public func browseTone3000() {
        guard !tone3000Busy else { return }
        tone3000Busy = true
        Task { @MainActor in
            defer { self.tone3000Busy = false }
            do {
                guard let id = try await Tone3000Client.shared.pickTone() else { return }
                try await self.loadTone3000(toneID: id, modelID: nil)
            } catch is CancellationError {
            } catch { self.message = "\(error)" }
        }
    }

    /// Fetches the tone a session refers to, through TONE3000's own prompt (it checks the player's access
    /// and may offer a replacement if the tone has gone).
    public func reloadTone3000() {
        guard let ref = tone3000, !tone3000Busy else { return }
        tone3000Busy = true
        Task { @MainActor in
            defer { self.tone3000Busy = false }
            do {
                guard let id = try await Tone3000Client.shared.pickTone(reload: ref.toneID) else { return }
                try await self.loadTone3000(toneID: id, modelID: id == ref.toneID ? ref.modelID : nil)
            } catch is CancellationError {
            } catch { self.message = "\(error)" }
        }
    }

    /// Loads another capture of the tone that is already chosen.
    public func chooseTone3000(model m: Tone3000Model) {
        guard let ref = tone3000, !tone3000Busy else { return }
        tone3000Busy = true
        Task { @MainActor in
            defer { self.tone3000Busy = false }
            do { try await self.loadTone3000(toneID: ref.toneID, modelID: m.id) } catch { self.message = "\(error)" }
        }
    }

    func loadTone3000(toneID: Int, modelID: Int?) async throws {
        let t = try await Tone3000Client.shared.tone(toneID)
        guard let m = t.models.first(where: { $0.id == modelID }) ?? t.models.first else {
            throw Tone3000Error("\(t.title) has no NAM captures this app can load.")
        }
        let data = try await Tone3000Client.shared.download(m)
        do { try applyProfile(data: data, name: t.title) }
        catch { throw Tone3000Error("Couldn't load \(m.name) from \(t.title): \(error)") }
        tone3000 = Tone3000Ref(toneID: toneID, modelID: m.id, title: t.title, creator: t.creator, license: t.license, modelName: m.name, url: t.url)
        tone3000Models = t.models
        tone3000NeedsReload = false
        setParam(.ampMode, 2)
    }

    public func loadImpulse(url: URL) {
        do {
            let (samples, name) = try ImpulseLoader.load(url: url, targetRate: bridge?.rig.sampleRate ?? 48_000)
            irSamples = samples
            irName = name
            cabinet = nil
            bridge?.rig.install(impulse: samples)
            setParam(.cabMode, 2)
            message = "Loaded cabinet \(name) (\(samples.count) samples)"
        } catch { message = "Couldn't load that impulse response: \(error)" }
    }

    /// Switches to one of the built-in cabinets.
    public func choose(cabinet c: CabinetChoice) {
        guard let samples = CabinetLibrary.impulse(c, sampleRate: bridge?.rig.sampleRate ?? 48_000) else { return }
        irSamples = samples
        irName = c.cabinet
        cabinet = c
        bridge?.rig.install(impulse: samples)
        setParam(.cabMode, 2)
    }

    /// Called when the host changes sample rate.
    public func sampleRateChanged() {
        rebuild(.pedal); rebuild(.amp)
        if let d = profileData, let n = profileName { try? applyProfile(data: d, name: n) }
        if let c = cabinet, let s = CabinetLibrary.impulse(c, sampleRate: bridge?.rig.sampleRate ?? 48_000) { irSamples = s }
        if let s = irSamples { bridge?.rig.install(impulse: s) }
    }

    // MARK: Documents

    public var document: PedalDocument {
        var params: [Int: Float] = [:]
        for p in RigParam.allCases { params[p.rawValue] = param(p) }
        return PedalDocument(pedal: pedal, amp: amp, params: params, quality: quality, profileName: profileName,
                             profileData: tone3000 == nil ? profileData : nil, irName: irName, irSamples: irSamples,
                             cabinet: cabinet, tone3000: tone3000)
    }

    public func apply(_ d: PedalDocument) {
        checkpoint()
        pedal = d.pedal
        amp = d.amp
        quality = d.quality
        if let ref = d.tone3000 {
            // TONE3000 models aren't stored in sessions: fetch this one again through the player's account
            tone3000 = ref; profileName = ref.title; tone3000Models = []; tone3000NeedsReload = true
            bridge?.rig.install(profile: nil)
            message = "This session uses \(ref.title) from TONE3000. Choose Reload from TONE3000 to fetch it."
        } else if let data = d.profileData, let n = d.profileName {
            try? applyProfile(data: data, name: n); tone3000 = nil; tone3000Models = []; tone3000NeedsReload = false
        }
        if let c = d.cabinet, CabinetLibrary.contains(c), let s = CabinetLibrary.impulse(c, sampleRate: bridge?.rig.sampleRate ?? 48_000) {
            irSamples = s; irName = c.cabinet; cabinet = c; bridge?.rig.install(impulse: s)
        } else if let s = d.irSamples { irSamples = s; irName = d.irName; cabinet = nil; bridge?.rig.install(impulse: s) }
        rebuild(.pedal); rebuild(.amp)
        for (k, v) in d.params { if let p = RigParam(rawValue: k), !(10..<30).contains(k) { bridge?.set(p, v) } }
        fitView()
    }

    public func encodedDocument() -> Data? { try? JSONEncoder().encode(document) }

    public func decodeDocument(_ data: Data) -> Bool {
        guard let d = try? JSONDecoder().decode(PedalDocument.self, from: data) else { return false }
        apply(d)
        return true
    }

    // MARK: File panels

    public func openDocumentPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "lutherie") ?? .json, UTType(filenameExtension: "pedal") ?? .json, .json]
        guard panel.runModal() == .OK, let url = panel.url, let data = try? Data(contentsOf: url) else { return }
        if !decodeDocument(data) { message = "That file isn't a Lutherie session." }
    }

    public func saveDocumentPanel() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "lutherie") ?? .json]
        panel.nameFieldStringValue = pedal.name + ".lutherie"
        guard panel.runModal() == .OK, let url = panel.url, let data = encodedDocument() else { return }
        do { try data.write(to: url); message = "Saved \(url.lastPathComponent)" } catch { message = "Couldn't save: \(error)" }
    }

    public func exportSpicePanel() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "cir") ?? .plainText]
        panel.nameFieldStringValue = circuit.name + ".cir"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let text = SpiceExport.netlist(circuit, testFrequency: scopeFrequency, testAmplitude: scopeLevel)
        do { try text.write(to: url, atomically: true, encoding: .utf8); message = "Exported \(url.lastPathComponent) for LTspice" }
        catch { message = "Couldn't export: \(error)" }
    }

    public func loadProfilePanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "nam") ?? .json, .json]
        panel.message = "Choose a Neural Amp Modeler profile (.nam)"
        if panel.runModal() == .OK, let url = panel.url { loadProfile(url: url) }
    }

    public func loadImpulsePanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.wav, .aiff, .audio]
        panel.message = "Choose a speaker cabinet impulse response (WAV or AIFF)"
        if panel.runModal() == .OK, let url = panel.url { loadImpulse(url: url) }
    }
}

import AVFoundation

enum ImpulseLoader {
    static func load(url: URL, targetRate: Double) throws -> ([Float], String) {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        let frames = AVAudioFrameCount(min(file.length, Int64(format.sampleRate * 2)))
        guard let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) else { throw CircuitError("Couldn't read the file.") }
        try file.read(into: buf, frameCount: frames)
        guard let ch = buf.floatChannelData else { throw CircuitError("Unsupported audio format.") }
        var mono = [Float](repeating: 0, count: Int(buf.frameLength))
        for c in 0..<Int(format.channelCount) { for i in 0..<mono.count { mono[i] += ch[c][i] / Float(format.channelCount) } }
        // resample (windowed sinc) to the host rate
        if abs(format.sampleRate - targetRate) > 1 {
            let rs = StreamResampler(from: format.sampleRate, to: targetRate)
            for s in mono { rs.push(s) }
            for _ in 0..<32 { rs.push(0) }
            var out = [Float](repeating: 0, count: Int(Double(mono.count) * targetRate / format.sampleRate) + 64)
            let n = out.withUnsafeMutableBufferPointer { rs.pull(into: $0.baseAddress!, max: $0.count) }
            mono = Array(out.prefix(n))
        }
        // trim to 8192 samples with a short fade, normalise to unity gain at its loudest frequency region
        if mono.count > 8192 {
            mono = Array(mono.prefix(8192))
            for i in 0..<256 { mono[8191 - i] *= Float(i) / 256 }
        }
        let energy = sqrt(mono.reduce(0) { $0 + $1 * $1 })
        if energy > 0 { mono = mono.map { $0 / energy * 0.5 } }
        return (mono, url.deletingPathExtension().lastPathComponent)
    }
}
