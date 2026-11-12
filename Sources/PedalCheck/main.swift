import Foundation
import PedalCore

// Self-test: bias points, frequency response and real-time speed of every starter circuit.
let sr = Double(ProcessInfo.processInfo.environment["SR"] ?? "") ?? 48_000.0
var testAmp: Float = 0.3
var failures = 0

// Cross-check against ngspice: `SPICE_DIR=folder PedalCheck` writes, for every starter circuit, an ngspice
// deck and Lutherie's own output for the same input, then quits. compare.py in that folder runs ngspice
// on each deck and reports how far apart the two are.
if let dir = ProcessInfo.processInfo.environment["SPICE_DIR"] {
    let fm = FileManager.default
    try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let rate = Double(ProcessInfo.processInfo.environment["RATE"] ?? "") ?? 192_000.0, seconds = 0.3, freq = 220.0, amp = 0.3
    let only = ProcessInfo.processInfo.environment["ONLY"]
    var index: [String] = []
    for circuit in Presets.pedals + Presets.amps where !circuit.name.hasPrefix("Empty") && (only == nil || circuit.name == only) {
        let slug = circuit.name.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "_" }.reduce("") { $0 + String($1) }
        guard let out = SpiceExport.outputNode(circuit), let e = try? CircuitEngine(circuit: circuit, sampleRate: rate) else { continue }
        let input = circuit.parts.first { $0.kind == .input }, output = circuit.parts.first { $0.kind == .output }
        // Circuits with a transformer are stiff: ngspice's trapezoidal rule rings on them (its answer changes with
        // the step size), so those are checked with its damped Gear method at a finer step.
        let stiff = circuit.hasPowerStage
        let step = 1 / 192_000.0 / (stiff ? 16 : 4)
        let deck = SpiceExport.netlist(circuit, testFrequency: freq, testAmplitude: amp * (input?["scale"] ?? 1), analysis: [
            ".options reltol=1e-5 abstol=1e-13 vntol=1e-8 " + (stiff ? "method=gear maxord=2" : "method=trap"),
            ".tran \(step) \(seconds) 0 \(step)",
            ".control", "set wr_singlescale", "set numdgt=12", "run", "wrdata \(slug).ngspice.txt v(\(out))", ".endc",
        ])
        try? deck.write(toFile: "\(dir)/\(slug).cir", atomically: true, encoding: .utf8)
        e.tolerance = 1e-7
        var text = "", probeText = ""
        let probe = ProcessInfo.processInfo.environment["PROBE"]?.split(separator: ",").map(String.init)
        let n = Int(rate * seconds), scale = output?["scale"] ?? 1
        for i in 0..<n {
            // the first sample is taken one step after the start, like the simulator's first time point
            let t = Double(i + 1) / rate
            let y = e.tick(amp * sin(2 * Double.pi * freq * t))
            if let probe, t < 0.012 { probeText += String(format: "%.9e", t) + e.operatingPoint().filter { probe.contains($0.0) }.map { String(format: " %@=%.6f", $0.0, $0.1) }.joined() + "\n" }
            text += String(format: "%.9e %.9e\n", t, y / (scale == 0 ? 1 : scale))
        }
        try? text.write(toFile: "\(dir)/\(slug).lutherie.txt", atomically: true, encoding: .utf8)
        if probe != nil { try? probeText.write(toFile: "\(dir)/\(slug).probe.txt", atomically: true, encoding: .utf8) }
        index.append("\(slug)\t\(circuit.name)")
        print("wrote \(slug)  (non-converged \(e.nonConverged))")
    }
    try? index.joined(separator: "\n").write(toFile: "\(dir)/index.txt", atomically: true, encoding: .utf8)
    exit(0)
}

// Reference for the C++ port: `REF_DIR=folder PedalCheck` writes every starter circuit as JSON (the C++ version
// loads its presets from these) and this engine's output for a fixed test signal, as raw 32-bit floats, then quits.
if let dir = ProcessInfo.processInfo.environment["REF_DIR"] {
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    for (kind, list) in [("pedals", Presets.pedals), ("amps", Presets.amps)] {
        if let d = try? enc.encode(list) { try? d.write(to: URL(fileURLWithPath: "\(dir)/\(kind).json")) }
    }
    let rate = 96_000.0, n = Int(rate * 0.25)
    var index = ""
    for circuit in Presets.pedals + Presets.amps where !circuit.name.hasPrefix("Empty") {
        let slug = circuit.name.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "_" }.reduce("") { $0 + String($1) }
        guard let e = try? CircuitEngine(circuit: circuit, sampleRate: rate) else { print("FAIL builds: \(circuit.name)"); continue }
        var out = [Float](repeating: 0, count: n)
        var firstNC = -1
        for i in 0..<n {
            let t = Double(i) / rate
            if i == n / 2 { for k in 0..<e.knobCount { e.setKnob(k, 0.8) } }
            if i % 32 == 0 { e.applyKnobs() }
            out[i] = Float(e.tick(0.3 * sin(2 * Double.pi * 220 * t) + 0.1 * sin(2 * Double.pi * 1250 * t)))
            if firstNC < 0 && e.nonConverged > 0 { firstNC = i }
        }
        out.withUnsafeBufferPointer { try? Data(buffer: $0).write(to: URL(fileURLWithPath: "\(dir)/\(slug).f32")) }
        if e.nonConverged > 0 { print("\(circuit.name): non-converged \(e.nonConverged)") }
        // where Newton first gave up (-1: never): past that point two engines may drift apart without either being wrong
        index += "\(slug)\t\(circuit.name)\t\(firstNC)\n"
    }
    try? index.write(toFile: "\(dir)/index.txt", atomically: true, encoding: .utf8)
    // The whole rig: four pedals (slots 0, 2, 3, 5, run in the order 3, 0, 5, 2) into the two-stage tube preamp
    // with its power stage and the built-in cabinet, at 4× oversampling, 48 kHz.
    let names = ["Diode Overdrive", "Four-Stage Phaser", "Bucket-Brigade Delay", "Germanium Fuzz"]
    let rig = Rig(sampleRate: 48_000)
    for (slot, name) in zip([0, 2, 3, 5], names) {
        rig.install(pedal: try? CircuitStage(circuit: Presets.pedals.first { $0.name == name }!, hostRate: 48_000, factor: 4), slot: slot)
    }
    rig.setOrder([3, 0, 5, 2])
    rig.install(amp: try? CircuitStage(circuit: Presets.tubePreamp, hostRate: 48_000, factor: 4))
    rig[.pedalOn(5)] = 0       // the fuzz is on the board but switched off
    rig[.mix] = 0.8
    let frames = 48_000 / 4
    var buf = (0..<frames).map { Float(0.3 * sin(2 * Double.pi * 220 * Double($0) / 48_000)) }
    buf.withUnsafeMutableBufferPointer { b in
        var s = 0
        while s < frames { let c = min(256, frames - s); rig.process(b.baseAddress! + s, b.baseAddress! + s, c); s += c }
    }
    buf.withUnsafeBufferPointer { try? Data(buffer: $0).write(to: URL(fileURLWithPath: "\(dir)/rig.f32")) }
    print("rig latency \(rig.latencySamples)")
    exit(0)
}

let only = ProcessInfo.processInfo.environment["ONLY"]   // run one starter circuit by name
let seconds = Int(ProcessInfo.processInfo.environment["SECONDS"] ?? "") ?? 2
for circuit in Presets.pedals + Presets.amps where !circuit.name.hasPrefix("Empty") && (only == nil || circuit.name == only) {
    print("== \(circuit.name)")
    let net = Netlist.build(circuit)
    if !net.problems.isEmpty { print("  problems: \(net.problems)") }
    do {
        let e = try CircuitEngine(circuit: circuit, sampleRate: sr)
        if let it = ProcessInfo.processInfo.environment["ITER"], let v = Int(it) { e.maxIterations = v }
        if let t = ProcessInfo.processInfo.environment["TOL"], let v = Double(t) { e.tolerance = v }
        if let t = ProcessInfo.processInfo.environment["PRED"] { e.predictor = t == "1" }
        if let t = ProcessInfo.processInfo.environment["EARLY"] { e.earlyExit = t == "1" }
        if let t = ProcessInfo.processInfo.environment["AMP"], let v = Float(t) { testAmp = v }
        if ProcessInfo.processInfo.environment["PROFILE"] != nil { for (k, v) in e.profile() { print(String(format: "  profile %@: %.0f ns", k, v)) } }
        print("  nodes: \(e.n)  knobs: \(e.potLabels)  warnings: \(e.warnings)")
        for (name, v) in e.operatingPoint() where !name.hasPrefix("N") || CommandLine.arguments.contains("-v") {
            print(String(format: "  %@ = %.3f V", name, v))
        }
        if CommandLine.arguments.contains("-v") {
            for (name, v) in e.operatingPoint() { print(String(format: "  %@ = %.3f V", name, v)) }
        }
        let f = [100.0, 500, 1000, 3000, 8000]
        let r = e.frequencyResponse(f)
        print("  small-signal gain: " + zip(f, r).map { String(format: "%.0fHz %.1fdB", $0, $1) }.joined(separator: ", "))
        // 0.3 V, 220 Hz sine for 2 s
        let frames = Int(sr) * seconds
        var input = [Float](repeating: 0, count: frames)
        for i in 0..<frames { input[i] = testAmp * Float(sin(2 * Double.pi * 220 * Double(i) / sr)) }
        var output = [Float](repeating: 0, count: frames)
        let t0 = Date()
        input.withUnsafeBufferPointer { ip in
            output.withUnsafeMutableBufferPointer { op in
                var s = 0
                while s < frames { let c = min(256, frames - s); e.process(ip.baseAddress! + s, op.baseAddress! + s, c); s += c }
            }
        }
        let secs = Date().timeIntervalSince(t0)
        let tail = output[(frames / 2)...]
        let mean = tail.reduce(0, +) / Float(tail.count)
        let peak = tail.map { abs($0 - mean) }.max() ?? 0
        print(String(format: "  220 Hz 0.3 V in: output peak %.3f (DC %.3f)  speed %.1fx real time  non-converged %d  cut back %d",
                     peak, mean, Double(seconds) / secs, e.nonConverged, e.cutbacks))
        if !(peak.isFinite) || peak == 0 { failures += 1; print("  FAIL: no output") }
        // The reduced solver must give the same samples as solving the whole matrix every iteration.
        let ref = try CircuitEngine(circuit: circuit, sampleRate: sr)
        ref.useFullSolver = true
        ref.cutBackEnabled = false
        ref.earlyExit = false
        ref.tolerance = 1e-9
        var refOut = [Float](repeating: 0, count: frames)
        let t1 = Date()
        input.withUnsafeBufferPointer { ip in
            refOut.withUnsafeMutableBufferPointer { op in
                var s = 0
                while s < frames { let c = min(256, frames - s); ref.process(ip.baseAddress! + s, op.baseAddress! + s, c); s += c }
            }
        }
        let refSecs = Date().timeIntervalSince(t1)
        var maxDiff: Float = 0
        for i in 0..<frames { maxDiff = max(maxDiff, abs(output[i] - refOut[i])) }
        print(String(format: "  reduced solver: %d of %d unknowns iterated, %.2f iterations/sample, max difference from full solve %.2e (full solve %.1fx real time)",
                     e.ns, e.n, Double(e.iterationCount) / Double(frames), maxDiff, Double(seconds) / refSecs))
        if ref.nonConverged > 0 { print("  full solve non-converged \(ref.nonConverged)") }
        if maxDiff > 1e-5 { failures += 1; print("  FAIL: reduced solver differs from the full solve") }
    } catch {
        failures += 1
        print("  FAIL: \(error)")
    }
}

// Knob sweep on the overdrive: output should change with Drive.
if let e = try? CircuitEngine(circuit: Presets.overdrive, sampleRate: sr) {
    for d in [0.0, 0.5, 1.0] {
        e.setKnob(0, d)
        var inp = [Float](repeating: 0, count: 9600), out = inp
        for i in 0..<inp.count { inp[i] = 0.1 * Float(sin(2 * Double.pi * 440 * Double(i) / sr)) }
        e.process(inp, &out, inp.count)
        print(String(format: "Overdrive drive %.1f: peak %.3f", d, out[4800...].map { abs($0) }.max()!))
    }
}

// The whole rig (overdrive into the tube amp, power stage, cabinet) at each oversampling setting.
for factor in [1, 2, 4, 8] {
    let rig = Rig(sampleRate: sr)
    guard let pedal = try? CircuitStage(circuit: Presets.overdrive, hostRate: sr, factor: factor),
          let amp = try? CircuitStage(circuit: Presets.tubePreamp, hostRate: sr, factor: factor) else { continue }
    rig.install(pedal: pedal); rig.install(amp: amp)
    let frames = Int(sr) * 2
    var buf = (0..<frames).map { 0.3 * Float(sin(2 * Double.pi * 220 * Double($0) / sr)) }
    let t0 = Date()
    buf.withUnsafeMutableBufferPointer { b in
        var s = 0
        while s < frames { let c = min(256, frames - s); rig.process(b.baseAddress! + s, b.baseAddress! + s, c); s += c }
    }
    let secs = Date().timeIntervalSince(t0)
    let peak = buf[(frames / 2)...].map { abs($0) }.max() ?? 0
    print(String(format: "Rig at %d× oversampling: %.0f%% of one core, latency %d samples, output peak %.3f, non-converged %d",
                 factor, secs / 2 * 100, rig.latencySamples, peak,
                 (rig.pedalEngine?.nonConverged ?? 0) + (rig.ampEngine?.nonConverged ?? 0)))
    if !peak.isFinite || peak == 0 { failures += 1; print("  FAIL: no output") }
}

// A full board: boost, overdrive and fuzz into the tube amp, all in one oversampled pass.
for factor in [1, 4] {
    let rig = Rig(sampleRate: sr)
    var ok = true
    for (slot, c) in [Presets.boost, Presets.overdrive, Presets.fuzz].enumerated() {
        guard let st = try? CircuitStage(circuit: c, hostRate: sr, factor: factor) else { ok = false; continue }
        rig.install(pedal: st, slot: slot)
    }
    guard ok, let amp = try? CircuitStage(circuit: Presets.tubePreamp, hostRate: sr, factor: factor) else { failures += 1; print("  FAIL: board builds"); continue }
    rig.install(amp: amp)
    let frames = Int(sr) * 2
    var buf = (0..<frames).map { 0.3 * Float(sin(2 * Double.pi * 220 * Double($0) / sr)) }
    let t0 = Date()
    buf.withUnsafeMutableBufferPointer { b in
        var s = 0
        while s < frames { let c = min(256, frames - s); rig.process(b.baseAddress! + s, b.baseAddress! + s, c); s += c }
    }
    let secs = Date().timeIntervalSince(t0)
    let peak = buf[(frames / 2)...].map { abs($0) }.max() ?? 0
    print(String(format: "Board of 3 pedals + amp at %d×: %.0f%% of one core, latency %d samples, output peak %.3f",
                 factor, secs / 2 * 100, rig.latencySamples, peak))
    if !peak.isFinite || peak == 0 { failures += 1; print("  FAIL: no output") }
}

// Extra checks provided by other modules
for line in SelfTests.run() { print(line); if line.contains("FAIL") { failures += 1 } }
print(failures == 0 ? "ALL OK" : "\(failures) FAILURE(S)")
exit(failures == 0 ? 0 : 1)
