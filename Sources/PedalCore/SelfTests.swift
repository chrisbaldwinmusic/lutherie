import Foundation

/// Checks that don't need audio hardware; run by the PedalCheck tool.
public enum SelfTests {
    public static func run() -> [String] {
        var out: [String] = []
        func check(_ ok: Bool, _ what: String) { out.append((ok ? "ok   " : "FAIL ") + what) }
        check(Eng.parse("4.7k") == 4700, "parse 4.7k")
        check(abs((Eng.parse("2M2") ?? 0) - 2.2e6) < 1, "parse 2M2")
        check(abs((Eng.parse("100n") ?? 0) - 1e-7) < 1e-12, "parse 100n")
        check(Eng.format(4700, unit: "Ω") == "4.7kΩ", "format 4.7kΩ (got \(Eng.format(4700, unit: "Ω")))")
        // A plain RC low-pass must be -3 dB at 1/(2πRC).
        var rc = Circuit(name: "RC")
        rc.parts = [Part(.input, name: "IN", at: GridPoint(0, 0), props: ["rs": 1]),
                    Part(.resistor, name: "R1", at: GridPoint(2, 0), props: ["r": 10_000]),
                    Part(.capacitor, name: "C1", at: GridPoint(4, 2), rotation: 1, props: ["c": 10e-9]),
                    Part(.ground, name: "G", at: GridPoint(4, 4)),
                    Part(.output, name: "OUT", at: GridPoint(4, 0), props: ["rl": 1e12])]
        rc.addWire(GridPoint(0, 0), GridPoint(0, 0))
        if let e = try? CircuitEngine(circuit: rc, sampleRate: 96_000) {
            let fc = 1 / (2 * Double.pi * 10_000 * 10e-9)
            let r = e.frequencyResponse([10, fc])
            check(abs(r[0]) < 0.05 && abs(r[1] + 3.01) < 0.1, String(format: "RC low-pass: %.2f dB at 10 Hz, %.2f dB at fc", r[0], r[1]))
            // time domain: a 1 kHz sine should be attenuated like the AC answer
            var inp = [Float](repeating: 0, count: 9600), o = inp
            for i in 0..<inp.count { inp[i] = Float(sin(2 * Double.pi * fc * Double(i) / 96_000)) }
            e.process(inp, &o, inp.count)
            let pk = o[4800...].map { abs($0) }.max() ?? 0
            check(abs(20 * log10(Double(pk)) + 3.01) < 0.2, String(format: "RC transient at fc: %.2f dB", 20 * log10(Double(pk))))
        } else { check(false, "RC circuit builds") }
        signalChain(check)
        mosfetsAndSwitches(check)
        zenersJfetsGangs(check)
        powerParts(check)
        powerAmp(check)
        cabinets(check)
        let wiring = Presets.auditLibrary()
        check(wiring.isEmpty, "library schematics match their intended connections" + (wiring.isEmpty ? "" : ":\n       " + wiring.joined(separator: "\n       ")))
        if let dir = ProcessInfo.processInfo.environment["NAM_TEST_DIR"] {
            for f in ["wavenet.nam", "lstm.nam", "wavenet_a1_standard.nam"] {
                let url = URL(fileURLWithPath: dir).appendingPathComponent(f)
                do {
                    let m = try NAMModel(data: Data(contentsOf: url), name: f)
                    var buf = [Float](repeating: 0, count: 2048)
                    for i in 0..<buf.count { buf[i] = 0.5 * Float(sin(Double(i) * 0.05)) }
                    m.reset()
                    buf.withUnsafeMutableBufferPointer { m.process($0.baseAddress!, $0.count) }
                    let pk = buf.map { abs($0) }.max() ?? 0
                    check(pk.isFinite && pk > 0, "NAM \(f): \(m.detail), peak \(pk)")
                } catch { check(false, "NAM \(f): \(error)") }
            }
        }
        // Sample-by-sample comparison with renders from the reference implementation, when provided.
        if let dir = ProcessInfo.processInfo.environment["NAM_TEST_DIR"],
           let refDir = ProcessInfo.processInfo.environment["NAM_REF_DIR"],
           let inData = try? Data(contentsOf: URL(fileURLWithPath: refDir + "/input.f32")) {
            let input: [Float] = inData.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
            for f in ["wavenet", "lstm", "wavenet_a1_standard"] {
                guard let refData = try? Data(contentsOf: URL(fileURLWithPath: refDir + "/\(f).ref.f32")),
                      let m = try? NAMModel(data: Data(contentsOf: URL(fileURLWithPath: dir + "/\(f).nam")), name: f) else { continue }
                let ref: [Float] = refData.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
                var buf = input
                buf.withUnsafeMutableBufferPointer { b in
                    var i = 0
                    while i < b.count { m.process(b.baseAddress! + i, min(64, b.count - i)); i += 64 }
                }
                var maxErr: Float = 0, refPeak: Float = 0
                for i in 4800..<min(buf.count, ref.count) { maxErr = max(maxErr, abs(buf[i] - ref[i])); refPeak = max(refPeak, abs(ref[i])) }
                check(maxErr <= max(1e-4, refPeak * 1e-3), "NAM \(f) matches the reference: max error \(maxErr) (reference peak \(refPeak))")
            }
        }
        return out
    }

    /// A wire with a load: passes the signal through unchanged, so only the rig's own behaviour shows.
    static var passThrough: Circuit {
        var c = Circuit(name: "Pass-through")
        c.parts = [Part(.input, name: "IN", at: GridPoint(0, 0), props: ["rs": 1]),
                   Part(.resistor, name: "R1", at: GridPoint(2, 0), props: ["r": 1_000]),
                   Part(.resistor, name: "R2", at: GridPoint(4, 2), rotation: 1, props: ["r": 1e6]),
                   Part(.ground, name: "G", at: GridPoint(4, 4)),
                   Part(.output, name: "OUT", at: GridPoint(4, 0), props: ["rl": 1e9])]
        return c
    }

    /// Magnitude of one frequency in a signal (single-bin DFT).
    static func level(_ x: [Float], _ f: Double, _ sr: Double) -> Double {
        var re = 0.0, im = 0.0
        for (i, v) in x.enumerated() {
            let ph = 2 * Double.pi * f * Double(i) / sr
            re += Double(v) * cos(ph); im += Double(v) * sin(ph)
        }
        return 2 * (re * re + im * im).squareRoot() / Double(x.count)
    }

    /// Latency reporting, the delay-matched Mix, oversampled power stage and gate timing.
    static func signalChain(_ check: (Bool, String) -> Void) {
        let sr = 48_000.0
        func makeRig(factor: Int, ampMode: Float) -> Rig? {
            let rig = Rig(sampleRate: sr)
            guard let pedal = try? CircuitStage(circuit: passThrough, hostRate: sr, factor: factor),
                  let amp = try? CircuitStage(circuit: passThrough, hostRate: sr, factor: factor) else { return nil }
            rig.install(pedal: pedal); rig.install(amp: amp)
            rig[.ampMode] = ampMode; rig[.cabMode] = 0; rig[.outputLevel] = 0; rig[.powerDrive] = 0
            return rig
        }
        func run(_ rig: Rig, _ input: [Float]) -> [Float] {
            var out = [Float](repeating: 0, count: input.count)
            input.withUnsafeBufferPointer { ip in
                out.withUnsafeMutableBufferPointer { op in
                    var s = 0
                    while s < input.count { let c = min(256, input.count - s); rig.process(ip.baseAddress! + s, op.baseAddress! + s, c); s += c }
                }
            }
            return out
        }
        // 1. An impulse comes out exactly as late as the rig says it will.
        for (factor, mode, expect) in [(1, Float(0), 0), (4, Float(0), 48), (2, Float(1), 48), (8, Float(1), 48)] {
            guard let rig = makeRig(factor: factor, ampMode: mode) else { check(false, "rig builds"); continue }
            var imp = [Float](repeating: 0, count: 2048); imp[100] = 0.5
            let out = run(rig, imp)
            let peakAt = out.indices.max { abs(out[$0]) < abs(out[$1]) }! - 100
            check(rig.latencySamples == expect && peakAt == expect && rig.expectedLatency == expect,
                  "latency at \(factor)× oversampling, amp \(mode == 0 ? "off" : "on"): reported \(rig.latencySamples), measured \(peakAt) samples")
        }
        // 2. Bypassing the pedal keeps the same timing.
        if let rig = makeRig(factor: 4, ampMode: 0) {
            rig[.pedalOn] = 0
            var imp = [Float](repeating: 0, count: 1024); imp[100] = 0.5
            let out = run(rig, imp)
            let peakAt = out.indices.max { abs(out[$0]) < abs(out[$1]) }! - 100
            check(peakAt == rig.latencySamples, "bypassed pedal keeps its timing: \(peakAt) samples")
        }
        // 3. Mix at 50 %: at 500 Hz a 48-sample mismatch would cancel completely; delay-matched it stays at full level.
        if let rig = makeRig(factor: 4, ampMode: 0) {
            rig[.mix] = 0.5
            let tone = (0..<9600).map { Float(0.5 * sin(2 * Double.pi * 500 * Double($0) / sr)) }
            let out = run(rig, tone)
            let pk = out[4800...].map { abs($0) }.max() ?? 0
            check(abs(pk - 0.5) < 0.01, String(format: "Mix 50%% stays in phase: peak %.3f for 0.500 in", pk))
        }
        // 4. Power-stage aliasing: a 5 kHz tone driven hard. Harmonics above 24 kHz fold back to 3, 8, 13, 18, 23 kHz at 1×.
        var alias: [Int: Double] = [:]
        for factor in [1, 4, 8] {
            guard let rig = makeRig(factor: factor, ampMode: 1) else { continue }
            rig[.powerDrive] = 1; rig[.pedalOn] = 0
            let tone = (0..<96_000).map { Float(0.6 * sin(2 * Double.pi * 5000 * Double($0) / sr)) }
            let out = Array(run(rig, tone)[48_000...])
            let fund = level(out, 5000, sr)
            let worst = [3000.0, 8000, 13000, 18000, 23000].map { level(out, $0, sr) }.max() ?? 0
            alias[factor] = 20 * log10(max(worst, 1e-12) / fund)
        }
        check((alias[4] ?? 0) < -80,
              String(format: "power-stage aliasing below the fundamental: %.0f dB at 1×, %.0f dB at 4×, %.0f dB at 8×",
                     alias[1] ?? 0, alias[4] ?? 0, alias[8] ?? 0))
        // 5. The gate closes in the same real time at any sample rate.
        var closeTimes: [Double] = []
        for rate in [44_100.0, 96_000.0] {
            let rig = Rig(sampleRate: rate)
            rig[.ampMode] = 0; rig[.cabMode] = 0; rig[.outputLevel] = 0; rig[.gate] = -40
            let n = Int(rate)
            // half a second of tone, then a faint hiss below the threshold
            let sig = (0..<n).map { i -> Float in
                i < n / 2 ? Float(0.3 * sin(2 * Double.pi * 440 * Double(i) / rate)) : Float(0.001 * sin(2 * Double.pi * 3000 * Double(i) / rate))
            }
            let out = run(rig, sig)
            let closed = (n / 2..<n).first { i in out[i...min(i + 200, n - 1)].allSatisfy { abs($0) < 0.0001 } } ?? n
            closeTimes.append(Double(closed - n / 2) / rate * 1000)
        }
        check(abs(closeTimes[0] - closeTimes[1]) < 5 && closeTimes[0] < 400,
              String(format: "gate closes in %.0f ms at 44.1 kHz and %.0f ms at 96 kHz", closeTimes[0], closeTimes[1]))
        // 6. Profile resampling delay matches what ProfileStage reports (44.1 kHz host, 48 kHz profile).
        do {
            let host = 44_100.0, model = 48_000.0
            let up = StreamResampler(from: host, to: model), down = StreamResampler(from: model, to: host)
            for _ in 0..<24 { up.push(0); down.push(0) }
            var work = [Float](repeating: 0, count: 8192), out = [Float](repeating: 0, count: 4096)
            var pos = 0
            while pos < 4096 {
                for i in 0..<256 { up.push(pos + i == 500 ? 1 : 0) }
                let m = work.withUnsafeMutableBufferPointer { up.pull(into: $0.baseAddress!, max: 8192) }
                for i in 0..<m { down.push(work[i]) }
                _ = out.withUnsafeMutableBufferPointer { down.pull(into: $0.baseAddress! + pos, max: 256) }
                pos += 256
            }
            let peakAt = out.indices.max { abs(out[$0]) < abs(out[$1]) }! - 500
            let expect = Int((32 + 32 * host / model).rounded())
            check(abs(peakAt - expect) <= 1, "profile resampling delay: expected \(expect), measured \(peakAt) samples")
        }
    }

    /// MOSFET currents against the square law they should follow, and switches doing what their position says.
    static func mosfetsAndSwitches(_ check: (Bool, String) -> Void) {
        func drainVolts(pmos: Bool) -> Double? {
            var s = Sheet("MOS test", notes: "")
            s.add(.input, "IN", 2, 0)
            s.add(.resistor, "R0", 5, 0, ["r": 1e6])
            s.add(pmos ? .pmos : .nmos, "M1", 10, 0)
            s.add(.resistor, "R1", 11, -4, rot: 1, ["r": 47])
            s.add(.output, "OUT", 14, -2)
            s.net("IN", "R0.1"); s.net("R0.2", "M1.g")
            s.rail("M1.g", pmos ? 5.3 : 3, dy: -3)
            s.net("R1.2", "M1.d", "OUT")
            if pmos { s.gnd("R1.1"); s.rail("M1.s", 9, dy: 2) } else { s.rail("R1.1", 9); s.gnd("M1.s") }
            guard s.audit().isEmpty, let e = try? CircuitEngine(circuit: s.c, sampleRate: 48_000) else { return nil }
            return e.operatingPoint().first { $0.0 == "OUT" }?.1
        }
        // expected drain voltage from id = kp/2 · (Vgs − Vto)² · (1 + λ·Vds) with a 47 Ω load
        func expected(_ m: MOSFETModel, vgs: Double) -> Double {
            var id = 0.0
            for _ in 0..<50 { id = m.kp / 2 * (vgs - m.vto) * (vgs - m.vto) * (1 + m.lambda * (9 - 47 * id)) }
            return m.pmos ? 47 * id : 9 - 47 * id
        }
        let wantN = expected(DeviceLibrary.mosfet("2N7000", pmos: false), vgs: 3)
        let wantP = expected(DeviceLibrary.mosfet("BS250", pmos: true), vgs: 3.7)
        if let vn = drainVolts(pmos: false), let vp = drainVolts(pmos: true) {
            check(abs(vn - wantN) < 0.01, String(format: "N-MOSFET saturation current: drain at %.3f V, square law gives %.3f V", vn, wantN))
            // the 9 V supply's 10 mΩ sits in this one's source lead, which costs about 20 mV at the drain
            check(abs(vp - wantP) < 0.03, String(format: "P-MOSFET saturation current: drain at %.3f V, square law gives %.3f V", vp, wantP))
        } else { check(false, "MOSFET test circuits build") }

        // The selector in the overdrive: MOSFETs clip later than diodes, and the centre position doesn't clip at all.
        var peaks: [Double] = []
        for state in [0, 1, 2] {
            var c = Presets.selectableClipSheet.c
            for i in c.parts.indices {
                if c.parts[i].name == "SW1" { c.parts[i]["state"] = Double(state) }
                if c.parts[i].name == "VR1" || c.parts[i].name == "VR2" { c.parts[i]["position"] = 1 }
            }
            guard let e = try? CircuitEngine(circuit: c, sampleRate: 48_000) else { continue }
            var inp = [Float](repeating: 0, count: 24_000), o = inp
            for i in 0..<inp.count { inp[i] = 0.3 * Float(sin(2 * Double.pi * 220 * Double(i) / 48_000)) }
            e.process(inp, &o, inp.count)
            peaks.append(Double(o[12_000...].map { abs($0) }.max() ?? 0))
        }
        if peaks.count == 3 {
            check(peaks[1] > 0.4 && peaks[1] < 0.8 && peaks[0] > 2 && peaks[0] < 2.9 && peaks[2] > peaks[0] + 0.2,
                  String(format: "clip selector: diodes ±%.2f V, MOSFETs ±%.2f V, off ±%.2f V", peaks[1], peaks[0], peaks[2]))
        } else { check(false, "selector circuits build") }
    }

    /// Every built-in cabinet makes a sane impulse response, and they differ from each other.
    static func cabinets(_ check: (Bool, String) -> Void) {
        let freqs = [60.0, 120, 250, 500, 1000, 2000, 3500, 5000, 8000, 12000]
        var bad: [String] = [], curves: [[Double]] = []
        for sr in [44_100.0, 48_000, 96_000] {
            for cab in CabinetLibrary.cabinets { for mic in CabinetLibrary.mics { for pos in CabinetLibrary.positions {
                let c = CabinetChoice(cabinet: cab, mic: mic, position: pos)
                guard let ir = CabinetLibrary.impulse(c, sampleRate: sr), ir.allSatisfy(\.isFinite) else { bad.append(c.title); continue }
                let r = freqs.map { CabinetLibrary.responseDB(ir, $0, sampleRate: sr) }
                let mid = (r[3] + r[4] + r[5]) / 3
                // a guitar speaker: little above 10 kHz, some but not all of the bass, tail faded to nothing
                if r[9] > mid - 15 || r[1] < mid - 18 || abs(ir[ir.count - 1]) > 1e-4 { bad.append("\(c.title) at \(Int(sr))") }
                if sr == 48_000 && mic == "Dynamic" && pos == "Cap edge" {
                    curves.append(r.map { $0 - mid })
                    print("  " + cab.padding(toLength: 22, withPad: " ", startingAt: 0)
                          + zip(freqs, r).map { String(format: "%5.0f:%+5.1f", $0, $1 - mid) }.joined(separator: " "))
                }
            } } }
        }
        check(bad.isEmpty, "built-in cabinets: \(CabinetLibrary.cabinets.count * CabinetLibrary.mics.count * CabinetLibrary.positions.count) impulse responses at three sample rates" + (bad.isEmpty ? "" : " — bad: \(bad.prefix(5))"))
        var closest = 99.0
        for i in curves.indices { for j in curves.indices where j > i {
            closest = min(closest, zip(curves[i], curves[j]).map { abs($0 - $1) }.max() ?? 0)
        } }
        check(closest > 1.5, String(format: "built-in cabinets differ from each other (closest pair differs by %.1f dB somewhere)", closest))
        // the same cabinet at two sample rates should sound the same
        let c = CabinetChoice(cabinet: CabinetLibrary.cabinets[3])
        if let a = CabinetLibrary.impulse(c, sampleRate: 44_100), let b = CabinetLibrary.impulse(c, sampleRate: 96_000) {
            let d = freqs.prefix(8).map { abs((CabinetLibrary.responseDB(a, $0, sampleRate: 44_100) - CabinetLibrary.responseDB(a, 1000, sampleRate: 44_100))
                                             - (CabinetLibrary.responseDB(b, $0, sampleRate: 96_000) - CabinetLibrary.responseDB(b, 1000, sampleRate: 96_000))) }.max() ?? 99
            check(d < 1.5, String(format: "cabinet response is the same at 44.1 and 96 kHz (within %.1f dB up to 5 kHz)", d))
        }
    }

    static func zenersJfetsGangs(_ check: (Bool, String) -> Void) {
        // A zener fed from ±9 V through 1 kΩ: holds its rated voltage backwards, about 0.7 V forwards.
        func zenerVolts(_ supply: Double, _ model: String) -> Double? {
            var s = Sheet("Zener test", notes: "")
            s.add(.input, "IN", 0, 0)
            s.add(.resistor, "R0", 3, 0, ["r": 1e6])
            s.add(.resistor, "R1", 8, -2, rot: 1, ["r": 1e3])
            s.add(.zener, "D1", 8, 2, rot: 3, model: model)       // cathode up
            s.add(.output, "OUT", 11, 0)
            s.net("IN", "R0.1"); s.net("R0.2", "R1.2", "D1.k", "OUT")
            s.rail("R1.1", supply); s.gnd("D1.a")
            guard s.audit().isEmpty, let e = try? CircuitEngine(circuit: s.c, sampleRate: 48_000) else { return nil }
            return e.operatingPoint().first { $0.0 == "OUT" }?.1
        }
        var zenerOK = true, report: [String] = []
        for (name, m) in DeviceLibrary.zeners.sorted(by: { $0.value.bv < $1.value.bv }) where m.bv < 8.5 {
            guard let back = zenerVolts(9, name), let fwd = zenerVolts(-9, name) else { zenerOK = false; continue }
            // what the breakdown law gives through 1 kΩ from 9 V: V = rating + knee·ln(I / test current) + series R·I
            var want = m.bv
            for _ in 0..<60 { let i = (9 - want) / 1000; want = 0.5 * want + 0.5 * (m.bv + m.nbv * 0.025852 * log(i / m.ibv) + m.rs * i) }
            report.append(String(format: "%.1f V part holds %.2f V at %.1f mA (law gives %.2f), %.2f V forwards", m.bv, back, 9 - back, want, fwd))
            if abs(back - want) > 0.02 || back > m.bv || fwd > -0.5 || fwd < -0.85 { zenerOK = false }
        }
        check(zenerOK && report.count == 3, "zeners: " + report.joined(separator: "; "))

        // P-JFET with its gate tied to its source passes Idss = β·Vp²·(1 + λ·Vsd).
        var s = Sheet("P-JFET test", notes: "")
        s.add(.input, "IN", 2, -6)
        s.add(.resistor, "R0", 5, -6, ["r": 1e6])
        s.add(.pjfet, "J1", 10, 0)
        s.add(.resistor, "R1", 11, -4, rot: 1, ["r": 1e3])
        s.add(.output, "OUT", 14, -2)
        s.net("IN", "R0.1"); s.net("R0.2", "R1.1"); s.gnd("R1.1", dx: 2)
        s.net("R1.2", "J1.d", "OUT")
        s.net("J1.g", "@8,2", "J1.s"); s.rail("J1.s", 9, dy: 2)
        let m = DeviceLibrary.jfet("2N5460", pch: true)
        var id = 0.0
        for _ in 0..<50 { id = m.beta * m.vto * m.vto * (1 + m.lambda * (9 - 1000 * id)) }
        let problems = s.audit()
        if problems.isEmpty, let e = try? CircuitEngine(circuit: s.c, sampleRate: 48_000),
           let vd = e.operatingPoint().first(where: { $0.0 == "OUT" })?.1 {
            check(abs(vd - 1000 * id) < 0.02, String(format: "P-JFET saturation current: drain at %.3f V, square law gives %.3f V", vd, 1000 * id))
        } else { check(false, "P-JFET test circuit builds \(problems)") }

        // Two ganged pots as cascaded dividers: one knob, and a quarter turn gives a quarter of a quarter.
        var g = Sheet("Gang test", notes: "")
        g.add(.input, "IN", 0, 0, ["rs": 1])
        g.add(.pot, "VR1", 4, 0, flip: true, ["r": 1e3, "position": 1, "gang": 1], model: "B", text: "Both")
        g.add(.pot, "VR2", 10, -2, flip: true, ["r": 1e6, "position": 1, "gang": 1], model: "B")
        g.add(.output, "OUT", 14, -4, ["rl": 1e9])
        g.net("IN", "VR1.3"); g.gnd("VR1.1", dy: 2)
        g.net("VR1.w", "VR2.3"); g.gnd("VR2.1", dy: 2)
        g.net("VR2.w", "OUT")
        let gp = g.audit()
        if gp.isEmpty, let e = try? CircuitEngine(circuit: g.c, sampleRate: 48_000) {
            e.setKnob(0, 0.25)
            var inp = [Float](repeating: 0, count: 9600), o = inp
            for i in 0..<inp.count { inp[i] = Float(sin(2 * Double.pi * 440 * Double(i) / 48_000)) }
            e.process(inp, &o, inp.count)
            let pk = Double(o[4800...].map { abs($0) }.max() ?? 0)
            check(e.knobCount == 1 && e.potLabels == ["Both"] && abs(pk - 0.0625) < 0.004,
                  String(format: "ganged pots: %d knob for 2 pots, quarter turn passes %.4f (expect 0.0625)", e.knobCount, pk))
        } else { check(false, "gang test circuit builds \(gp)") }
    }

    /// Pentode current against Koren's formula; transformer ratio, reflected load and time-domain behaviour.
    static func powerParts(_ check: (Bool, String) -> Void) {
        // 6L6GC: screen at 300 V, plate fed from 300 V through 100 Ω, grid at -20 V.
        var s = Sheet("Pentode test", notes: "")
        s.add(.input, "IN", -6, 0)
        s.add(.resistor, "R0", -3, 0, ["r": 1e6])
        s.add(.pentode, "V1", 2, 0, model: "6L6GC")
        s.add(.resistor, "R1", 3, -4, rot: 1, ["r": 100])
        s.add(.output, "OUT", 8, -2)
        s.net("IN", "R0.1"); s.net("R0.2", "V1.g"); s.rail("V1.g", -20, dy: 3)
        s.net("R1.2", "V1.p", "OUT"); s.rail("R1.1", 300)
        s.rail("V1.s", 300, dy: -3); s.gnd("V1.k")
        let m = DeviceLibrary.pentode("6L6GC")
        let e1 = 300 / m.kp * log(1 + exp(m.kp * (1 / m.mu - 20.0 / 300)))
        var vp = 300.0
        for _ in 0..<40 { vp = 300 - 100 * 2 * pow(e1, m.ex) / m.kg1 * atan(vp / m.kvb) }
        let problems = s.audit()
        if problems.isEmpty, let e = try? CircuitEngine(circuit: s.c, sampleRate: 48_000),
           let got = e.operatingPoint().first(where: { $0.0 == "OUT" })?.1 {
            check(abs(got - vp) < 0.05, String(format: "power tube plate current: %.1f mA, Koren's formula gives %.1f mA", (300 - got) * 10, (300 - vp) * 10))
        } else { check(false, "pentode test circuit builds \(problems)") }

        // Transformer: 6.6 kΩ plate to plate into 8 Ω, driven from 6.6 kΩ: the speaker sees the source voltage
        // divided by twice the turns ratio (less the winding resistances).
        var t = Sheet("Transformer test", notes: "")
        t.add(.input, "IN", -6, -2, ["rs": 6600])
        t.add(.transformer, "T1", 0, 0)
        t.add(.resistor, "R1", 5, 0, rot: 1, ["r": 8])
        t.add(.output, "OUT", 8, -2, ["rl": 1e9])
        t.net("IN", "T1.p1"); t.gnd("T1.p2"); t.net("T1.ct", "@-4,0")
        t.net("T1.s1", "R1.1", "OUT"); t.net("T1.s2", "R1.2"); t.gnd("T1.s2")
        let tp = t.audit().filter { !$0.contains("Not connected") }
        if tp.isEmpty, let e = try? CircuitEngine(circuit: t.c, sampleRate: 96_000) {
            let n = sqrt(6600.0 / 8)
            let want = 20 * log10(8 * n * n / (6600 + 150 + n * n * 8.5) / n)
            let r = e.frequencyResponse([1000, 20, 20_000])
            var inp = [Float](repeating: 0, count: 19_200), o = inp
            for i in 0..<inp.count { inp[i] = Float(sin(2 * Double.pi * 1000 * Double(i) / 96_000)) }
            e.process(inp, &o, inp.count)
            let pk = 20 * log10(Double(o[9600...].map { abs($0) }.max() ?? 0))
            check(abs(r[0] - want) < 0.1 && abs(pk - want) < 0.15 && r[1] > r[0] - 3 && r[2] > r[0] - 3,
                  String(format: "output transformer: %.2f dB at 1 kHz (ideal %.2f), %.2f dB when run sample by sample, %.1f dB at 20 Hz, %.1f dB at 20 kHz",
                         r[0], want, pk, r[1] - r[0], r[2] - r[0]))
        } else { check(false, "transformer test circuit builds \(tp)") }
    }

    /// The complete amp: feedback has the right sign, the supply sags under load, and it makes sensible power.
    static func powerAmp(_ check: (Bool, String) -> Void) {
        func gain(feedback: Double) -> Double? {
            var c = Presets.britishHeadSheet.c
            for i in c.parts.indices where c.parts[i].name == "R37" { c.parts[i]["r"] = feedback }
            return (try? CircuitEngine(circuit: c, sampleRate: 48_000))?.frequencyResponse([1000]).first
        }
        if let with = gain(feedback: 100e3), let without = gain(feedback: 1e12) {
            check(with < without - 2, String(format: "power amp feedback is negative: %.1f dB with it, %.1f dB without", with, without))
        } else { check(false, "head builds") }
        guard let e = try? CircuitEngine(circuit: Presets.britishHeadSheet.c, sampleRate: 96_000) else { return }
        func volts(_ name: String) -> Double { e.operatingPoint().first { $0.0 == name }?.1 ?? 0 }
        let idle = volts("VCC_440V")
        for i in 0..<e.knobCount where e.potLabels[i] == "Master" || e.potLabels[i] == "Gain" { e.setKnob(i, 1) }
        var inp = [Float](repeating: 0, count: 48_000), o = inp
        for i in 0..<inp.count { inp[i] = 0.3 * Float(sin(2 * Double.pi * 220 * Double(i) / 96_000)) }
        e.process(inp, &o, inp.count)
        let loaded = volts("VCC_440V")
        let scale = Presets.britishHeadSheet.c.parts.first { $0.kind == .output }?["scale"] ?? 1
        let tail = o[24_000...].map { Double($0) / scale }
        let rms = sqrt(tail.reduce(0) { $0 + $1 * $1 } / Double(tail.count))
        check(idle - loaded > 5 && idle - loaded < 80 && rms > 12 && rms < 40 && e.nonConverged < 48,   // under one sample in a thousand
              String(format: "power amp flat out: %.0f V rms at the speaker, supply sags from %.0f V to %.0f V, %d samples unsettled", rms, idle, loaded, e.nonConverged))
    }
}
