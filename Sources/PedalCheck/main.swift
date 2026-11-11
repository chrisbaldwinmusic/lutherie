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
    let rate = 192_000.0, seconds = 0.3, freq = 220.0, amp = 0.3
    var index: [String] = []
    for circuit in Presets.pedals + Presets.amps where !circuit.name.hasPrefix("Empty") {
        let slug = circuit.name.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "_" }.reduce("") { $0 + String($1) }
        guard let out = SpiceExport.outputNode(circuit), let e = try? CircuitEngine(circuit: circuit, sampleRate: rate) else { continue }
        let input = circuit.parts.first { $0.kind == .input }, output = circuit.parts.first { $0.kind == .output }
        let step = 1 / rate / 4
        let deck = SpiceExport.netlist(circuit, testFrequency: freq, testAmplitude: amp * (input?["scale"] ?? 1), analysis: [
            ".options reltol=1e-5 abstol=1e-13 vntol=1e-8 method=trap",
            ".tran \(step) \(seconds) 0 \(step)",
            ".control", "set wr_singlescale", "set numdgt=12", "run", "wrdata \(slug).ngspice.txt v(\(out))", ".endc",
        ])
        try? deck.write(toFile: "\(dir)/\(slug).cir", atomically: true, encoding: .utf8)
        e.tolerance = 1e-7
        var text = ""
        let n = Int(rate * seconds), scale = output?["scale"] ?? 1
        for i in 0..<n {
            // the first sample is taken one step after the start, like the simulator's first time point
            let t = Double(i + 1) / rate
            let y = e.tick(amp * sin(2 * Double.pi * freq * t))
            text += String(format: "%.9e %.9e\n", t, y / (scale == 0 ? 1 : scale))
        }
        try? text.write(toFile: "\(dir)/\(slug).lutherie.txt", atomically: true, encoding: .utf8)
        index.append("\(slug)\t\(circuit.name)")
        print("wrote \(slug)  (non-converged \(e.nonConverged))")
    }
    try? index.joined(separator: "\n").write(toFile: "\(dir)/index.txt", atomically: true, encoding: .utf8)
    exit(0)
}

for circuit in Presets.pedals + Presets.amps where !circuit.name.hasPrefix("Empty") {
    print("== \(circuit.name)")
    let net = Netlist.build(circuit)
    if !net.problems.isEmpty { print("  problems: \(net.problems)") }
    do {
        let e = try CircuitEngine(circuit: circuit, sampleRate: sr)
        if let it = ProcessInfo.processInfo.environment["ITER"], let v = Int(it) { e.maxIterations = v }
        if let t = ProcessInfo.processInfo.environment["TOL"], let v = Double(t) { e.tolerance = v }
        if let t = ProcessInfo.processInfo.environment["PRED"] { e.predictor = t == "1" }
        if let t = ProcessInfo.processInfo.environment["AMP"], let v = Float(t) { testAmp = v }
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
        let frames = Int(sr) * 2
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
        print(String(format: "  220 Hz 0.3 V in: output peak %.3f (DC %.3f)  speed %.1fx real time  non-converged %d",
                     peak, mean, 2 / secs, e.nonConverged))
        if !(peak.isFinite) || peak == 0 { failures += 1; print("  FAIL: no output") }
        // The reduced solver must give the same samples as solving the whole matrix every iteration.
        let ref = try CircuitEngine(circuit: circuit, sampleRate: sr)
        ref.useFullSolver = true
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
                     e.ns, e.n, Double(e.iterationCount) / Double(frames), maxDiff, 2 / refSecs))
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

// Extra checks provided by other modules
for line in SelfTests.run() { print(line); if line.contains("FAIL") { failures += 1 } }
print(failures == 0 ? "ALL OK" : "\(failures) FAILURE(S)")
exit(failures == 0 ? 0 : 1)
