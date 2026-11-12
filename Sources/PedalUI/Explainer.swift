import Foundation
import PedalCore
import SwiftUI

/// What the person just did, so learn mode can explain it.
public enum Change {
    case added(Part)
    case removed(Part)
    case altered(before: Part, after: Part)
    case knob(Part, from: Double, to: Double)
    case wiring(added: Int, removed: Int)
    case moved(Int)
}

/// One explanation card.
public struct Lesson: Identifiable {
    public let id = UUID()
    public var title: String
    public var role: String
    public var effects: [String] = []
    public var verdict: String = ""
    public var tip: String = ""
    public var meters: [(String, Double, Double)] = []  // name, before, after (dB or %)
}

/// Signal measurements taken from an analysis run.
struct Measure {
    var bass: Double, mid: Double, treble: Double
    var peak: Double
    var thd: Double
    var even: Double, odd: Double

    init?(_ a: Analysis?) {
        guard let a, a.error == nil, a.response.count == a.freqs.count, !a.freqs.isEmpty, a.harmonics.count >= 3 else { return nil }
        func at(_ f: Double) -> Double {
            guard let i = a.freqs.firstIndex(where: { $0 >= f }), i > 0 else { return a.response.first ?? 0 }
            let t = log(f / a.freqs[i - 1]) / log(a.freqs[i] / a.freqs[i - 1])
            return a.response[i - 1] + t * (a.response[i] - a.response[i - 1])
        }
        bass = at(100); mid = at(800); treble = at(4000)
        peak = a.outPeak
        let h = a.harmonics
        let fund = max(h[0], 1e-12)
        let rest = h.dropFirst().reduce(0) { $0 + $1 * $1 }
        thd = sqrt(rest) / fund * 100
        even = sqrt(stride(from: 1, to: h.count, by: 2).reduce(0) { $0 + h[$1] * h[$1] })
        odd = sqrt(stride(from: 2, to: h.count, by: 2).reduce(0) { $0 + h[$1] * h[$1] })
    }
}

/// Works out what a part is doing in its circuit and what a change did to the signal.
enum Explainer {
    // MARK: Topology helpers

    struct Topo {
        let net: Netlist
        let circuit: Circuit
        var acGround: Set<Int> = [0]
        var users: [Int: [(Part, Int)]] = [:]
        var opOut: Set<Int> = [], opInN: Set<Int> = [], opInP: Set<Int> = []
        var collectors: Set<Int> = [], bases: Set<Int> = [], emitters: Set<Int> = []
        var inputNode = -1, outputNode = -1

        init(_ c: Circuit) {
            circuit = c
            net = Netlist.build(c)
            for p in c.parts {
                let n = net.pinNodes[p.id] ?? []
                for (i, node) in n.enumerated() { users[node, default: []].append((p, i)) }
                switch p.kind {
                case .supply: if let a = n.first { acGround.insert(a) }
                case .opamp: opInP.insert(n[0]); opInN.insert(n[1]); opOut.insert(n[2])
                case .npn, .pnp, .njfet, .pjfet, .nmos, .pmos, .triode, .pentode: collectors.insert(n[0]); bases.insert(n[1]); emitters.insert(n[2])
                case .input: inputNode = n[0]
                case .output: outputNode = n[0]
                default: break
                }
            }
        }

        func nodes(_ p: Part) -> [Int] { net.pinNodes[p.id] ?? [] }

        /// Nodes reachable from `start` through simple in-series links (nodes with exactly two users), not via `except`.
        func chainEnds(from start: Int, except: UUID) -> Set<Int> {
            var ends: Set<Int> = [start]
            var node = start, prev = except
            for _ in 0..<3 {
                let others = (users[node] ?? []).filter { $0.0.id != prev }
                guard others.count == 1, [.resistor, .pot, .capacitor].contains(others[0].0.kind) else { break }
                let part = others[0].0
                guard let next = nodes(part).first(where: { $0 != node }) else { break }
                ends.insert(next)
                node = next; prev = part.id
            }
            return ends
        }

        /// True when the part sits (alone or in a short chain) between an op-amp output and its − input.
        func inFeedback(_ p: Part) -> Bool {
            let n = nodes(p)
            guard n.count >= 2 else { return false }
            let a = chainEnds(from: n[0], except: p.id), b = chainEnds(from: n[1], except: p.id)
            return (!a.isDisjoint(with: opOut) && !b.isDisjoint(with: opInN)) || (!b.isDisjoint(with: opOut) && !a.isDisjoint(with: opInN))
        }

        /// True when one end reaches the op-amp − input and the other reaches AC ground (the gain-setting leg).
        func inGainLeg(_ p: Part) -> Bool {
            let n = nodes(p)
            guard n.count >= 2 else { return false }
            let a = chainEnds(from: n[0], except: p.id), b = chainEnds(from: n[1], except: p.id)
            return (!a.isDisjoint(with: opInN) && !b.isDisjoint(with: acGround)) || (!b.isDisjoint(with: opInN) && !a.isDisjoint(with: acGround))
        }
    }

    static func vf(_ p: Part) -> String {
        let m = DeviceLibrary.diode(p.model, led: p.kind == .led)
        let v = m.n * 0.02585 * log(1e-3 / m.Is)
        return String(format: "%.2f V", v)
    }

    // MARK: Roles

    /// A plain explanation of what this part does where it is.
    static func role(of p: Part, in c: Circuit) -> (String, String) {
        let t = Topo(c)
        let n = t.nodes(p)
        let shuntNode: Int? = n.count == 2 ? (t.acGround.contains(n[0]) ? n[1] : (t.acGround.contains(n[1]) ? n[0] : nil)) : nil
        let label = p.text.isEmpty ? p.name : "\(p.name) (\(p.text))"
        switch p.kind {
        case .capacitor:
            let v = Eng.format(p["c"], unit: "F")
            if t.inFeedback(p) {
                return ("\(label): feedback capacitor, \(v)",
                        "It sits across the op-amp's feedback path. At high frequencies it bypasses the feedback resistance, so the gain falls off above about 1/(2πRC). It tames fizz in the clipping: bigger value = darker, smoother drive.")
            }
            if t.inGainLeg(p) {
                return ("\(label): gain-leg capacitor, \(v)",
                        "In series with the resistor from the op-amp's − input to the reference, it decides which frequencies get the full gain. Below 1/(2πRC) the gain falls back towards 1, so bass is distorted less (a tighter low end). Bigger value = more bass gets driven.")
            }
            if let s = shuntNode {
                if t.emitters.contains(s) {
                    return ("\(label): bypass capacitor, \(v)",
                            "It lets audio skip the emitter/cathode/source resistor, so the stage has much more gain above about 1/(2πRC). Large values boost everything; small values boost only the mids and treble.")
                }
                return ("\(label): treble bleed to ground, \(v)",
                        "With the resistance feeding it, it forms a low-pass filter: high frequencies leak to ground. The corner is about 1/(2πRC); a bigger capacitor = darker sound.")
            }
            return ("\(label): coupling capacitor, \(v)",
                    "It blocks DC between stages so their bias voltages don't upset each other. With the resistance after it, it is also a high-pass filter: a smaller value lets less bass through (tighter, thinner); a bigger one keeps the lows.")
        case .resistor:
            let v = Eng.format(p["r"], unit: "Ω")
            if t.inFeedback(p) {
                return ("\(label): feedback resistor, \(v)",
                        "With the resistor from the − input to the reference it sets the op-amp gain: G = 1 + Rf/Rg. A bigger value means more gain, which drives the clipping harder.")
            }
            if t.inGainLeg(p) {
                return ("\(label): gain-setting resistor, \(v)",
                        "This is Rg in G = 1 + Rf/Rg. A smaller value means more gain (and more clipping); a bigger value means a cleaner stage.")
            }
            if let s = shuntNode {
                if t.collectors.contains(s) {
                    return ("\(label): load resistor, \(v)",
                            "It turns the device's current into a voltage. A bigger load gives more gain but less headroom, and it moves the bias point, which changes how symmetric the clipping is.")
                }
                if t.emitters.contains(s) {
                    return ("\(label): bias / degeneration resistor, \(v)",
                            "It sets the device's operating current. Without a bypass capacitor it lowers the gain and cleans the stage up; a bigger value biases it colder, so it clips earlier and more unevenly.")
                }
                if t.bases.contains(s) || t.opInP.contains(s) {
                    return ("\(label): bias resistor, \(v)",
                            "It holds the input at its working voltage and sets the input impedance: how heavily this stage loads whatever drives it (a guitar pickup loses treble into a low impedance).")
                }
                return ("\(label): resistor to ground/supply, \(v)",
                        "It loads this point of the circuit, forming a voltage divider or filter with what comes before it.")
            }
            if n.contains(where: { t.bases.contains($0) }) && c.parts.contains(where: { $0.kind == .triode }) {
                return ("\(label): grid stopper, \(v)",
                        "With the tube's Miller capacitance it rolls off the extreme highs and stops the stage oscillating. Bigger = smoother, slightly darker.")
            }
            return ("\(label): series resistor, \(v)",
                    "It limits current and, together with capacitors, sets filter corners. Any series resistance also loses a little level into the load after it.")
        case .pot:
            let wiperTied = n.count == 3 && (n[2] == n[0] || n[2] == n[1])
            let endGrounded = n.count == 3 && (t.acGround.contains(n[0]) || t.acGround.contains(n[1]))
            if t.inFeedback(p) || (wiperTied && (n.contains { t.opOut.contains($0) } || n.contains { t.opInN.contains($0) })) {
                return ("\(label): gain control", "It is a variable resistor in the op-amp's feedback loop. Turning it up raises the gain, so the clipping starts sooner: more sustain, more compression, more harmonics.")
            }
            if n.contains(where: { t.emitters.contains($0) }) {
                return ("\(label): gain control", "It changes how much of the emitter/cathode resistance is bypassed, and so how much gain the stage has. More gain = more fuzz and sustain.")
            }
            if endGrounded && !wiperTied {
                return ("\(label): volume / level", "It is a voltage divider: the wiper picks off part of the signal. It changes how much signal goes on to the next stage, not the tone of this one; into an amp or a later stage, more level also means more drive there.")
            }
            if wiperTied && c.parts.contains(where: { $0.kind == .capacitor && Set(t.nodes($0)).contains(where: { Set(n).contains($0) }) }) {
                return ("\(label): tone control", "It is a variable resistance next to a capacitor, so it moves a filter's corner frequency: it changes how much treble (or bass) is bled away.")
            }
            return ("\(label): potentiometer", "A variable resistor or divider: the wiper's position changes the resistance on each side of it.")
        case .diode, .led:
            if t.inFeedback(p) {
                return ("\(label): soft-clipping diode (\(p.model))",
                        "Once the output swings about \(vf(p)) past the input, the diode starts conducting and pulls the gain down. The clipping comes in gradually: smooth overdrive that keeps the dynamics.")
            }
            if shuntNode != nil {
                return ("\(label): hard-clipping diode (\(p.model))",
                        "It clamps the signal at its forward voltage (about \(vf(p))). The wave gets flattened tops: squarer, more odd harmonics, more compression. LEDs clip higher (louder, more open); germanium clips lower and softer.")
            }
            return ("\(label): series diode (\(p.model))", "It only conducts one way and needs about \(vf(p)) to turn on, so in the signal path it rectifies: strong uneven (even-harmonic) distortion, and small signals get gated out.")
        case .opamp:
            let m = DeviceLibrary.opamp(p.model)
            return ("\(label): op-amp (\(p.model))",
                    "An amplifier that makes its − input follow its + input, so the feedback network sets the gain. This model has \(Eng.format(m.gbw, unit: "Hz")) gain-bandwidth and slews at \(m.slew) V/µs; slow parts like the LM308 add grit when pushed. Its output can't go past its supply rails, so it clips there too.")
        case .npn, .pnp:
            return ("\(label): transistor gain stage (\(p.model))",
                    "A small base current controls a much larger collector current. The gain depends on the collector load and how much emitter resistance is bypassed; when pushed into saturation or cutoff it clips unevenly: the classic fuzz sound. Germanium parts are softer and more temperature-dependent.")
        case .zener:
            let bv = DeviceLibrary.zener(p.model).bv
            return ("\(label): zener diode (\(p.model))",
                    "Connected backwards on purpose: it does nothing until the voltage across it reaches \(bv) V, then conducts and holds it there. Used to protect a gate, to set a steady voltage, or as a clipper that clips at \(bv) V one way and about 0.7 V the other.")
        case .njfet, .pjfet:
            return ("\(label): JFET gain stage (\(p.model))",
                    "Its square-law behaviour is a lot like a tube's, so when pushed it adds mostly even harmonics: warm, touch-sensitive boost and drive.")
        case .nmos, .pmos:
            if n.count == 3, n[0] == n[1] {
                return ("\(label): MOSFET used as a clipper (\(p.model))",
                        "With its gate tied to its drain it behaves like a diode that turns on at about \(DeviceLibrary.mosfet(p.model, pmos: p.kind == .pmos).vto) V, and gradually rather than suddenly. The other way round its built-in body diode conducts at about 0.6 V. A pair back to back clips later and more softly than ordinary diodes: louder, more open drive.")
            }
            return ("\(label): MOSFET gain stage (\(p.model))",
                    "The gate draws no current, so it doesn't load the guitar at all. Above its threshold the current follows a square law, like a JFET or a tube, so it distorts softly with mostly even harmonics.")
        case .spst:
            return ("\(label): switch (\(p.switchStateName))",
                    p.switchState == 0 ? "Open: the two sides are disconnected, so whatever hangs on it is out of the circuit."
                                       : "Closed: the two sides are joined, as if by a wire.")
        case .spdt:
            return ("\(label): selector (\(p.switchStateName))",
                    p.switchState == 2 ? "Centre position: Common is connected to neither side, so both branches are out of the circuit."
                                       : "Common is joined to side \(p.switchStateName); whatever is on the other side is out of the circuit. Selectors like this choose between clipping parts, capacitor values or voicings.")
        case .pentode:
            return ("\(label): power tube (\(p.model))",
                    "A pentode or beam tetrode: the control grid steers a large current to the plate, and the screen grid sets how much is available. In pairs working in push-pull through the output transformer they drive the speaker. Pushed hard they clip against the plate's knee and the grid's own conduction, and pull the supply down: the compression and bloom of a cranked amp.")
        case .transformer:
            return ("\(label): output transformer",
                    "Matches the tubes, which want a few thousand ohms, to a speaker of a few ohms, and adds the two halves of the push-pull pair into one signal. Its primary inductance sets how low the bass goes and its leakage how high the treble; the tubes' supply comes in at the centre tap.")
        case .triode:
            return ("\(label): tube gain stage (\(p.model))",
                    "A triode with a bypassed cathode gives about 30–35 dB of gain (12AX7). It clips softly and unevenly: grid current flattens the positive peaks and cutoff flattens the negative ones, which makes rich even harmonics.")
        case .inductor:
            return ("\(label): inductor", "It passes bass and resists treble: the opposite of a capacitor. With a capacitor it makes a resonant peak, as in a wah or a mid-boost.")
        case .lfo:
            return ("\(label): low-frequency oscillator",
                    "A slow wave, a few times a second, that moves something else: a JFET's resistance in a phaser, an LED's brightness in a tremolo, a delay chip's clock in a chorus. Its rate is set by the voltage on its Rate CV pin.")
        case .vactrol:
            return ("\(label): vactrol (\(p.model))",
                    "An LED shining on a light-dependent resistor, sealed together. Current through the LED lowers the cell's resistance; the cell is quick to follow the light and slow to let go, which rounds off the wave that drives it. That softness is the sound of optical tremolos and compressors.")
        case .ota:
            return ("\(label): transconductance amplifier (\(p.model))",
                    "Its gain is set by the current into its bias pin, so a voltage can turn it up and down: in tremolos, filters that sweep, and phasers. Above a few tens of millivolts of input it saturates smoothly (tanh).")
        case .bbd:
            return ("\(label): bucket-brigade delay (\(p.model))",
                    "A line of capacitors passes each sample along, one step per clock tick, so the clock rate sets the delay. Slow the clock and the delay grows, the sound darkens and grains; wobble it and the pitch wobbles: chorus, flanging and analog echo all come from this one chip.")
        case .supply:
            return ("\(label): power", "A DC voltage. Op-amps and transistors need it to work, and it decides the headroom: more volts = louder before the stage clips.")
        case .ground:
            return ("Ground", "The 0 V reference. Every signal is measured against it.")
        case .input:
            return ("Guitar in", "Where the guitar signal enters, a few hundred millivolts from a pickup with some source resistance.")
        case .output:
            return ("Output", "Where the signal leaves for the next pedal or the amp. Its load resistance is the input of whatever comes next.")
        case .label:
            return ("Net label \(p.text)", "Every label with the same name is connected, a tidy way to wire without drawing long lines.")
        }
    }

    // MARK: Lessons

    static func lesson(for change: Change, before: Analysis?, after: Analysis?, circuit: Circuit) -> Lesson {
        var l: Lesson
        switch change {
        case .added(let p):
            let r = role(of: p, in: circuit)
            l = Lesson(title: "Added \(p.kind.displayName.lowercased()) \(p.name)", role: r.1)
            if (Netlist.build(circuit).pinNodes[p.id] ?? []).contains(where: { n in
                circuit.parts.filter { (Netlist.build(circuit).pinNodes[$0.id] ?? []).contains(n) }.count < 2 && n != 0 }) {
                l.tip = "It isn't connected yet: wire both ends (the red circles) and I'll explain what it does here."
            }
        case .removed(let p):
            l = Lesson(title: "Removed \(p.name)", role: "Without this \(p.kind.displayName.lowercased()) the signal takes a different path. " + role(of: p, in: circuit).1.components(separatedBy: ". ").first! + ".")
        case .altered(let a, let b):
            let r = role(of: b, in: circuit)
            var what = "Changed \(b.name)"
            if a.model != b.model { what = "\(b.name): \(a.model) → \(b.model)" }
            for (k, unit) in [("r", "Ω"), ("c", "F"), ("l", "H"), ("v", "V")] where a[k] != b[k] {
                what = "\(b.name): \(Eng.format(a[k], unit: unit)) → \(Eng.format(b[k], unit: unit))"
            }
            if a.switchState != b.switchState { what = "\(b.text.isEmpty ? b.name : b.text): \(a.switchStateName) → \(b.switchStateName)" }
            if a.rotation != b.rotation || a.flipped != b.flipped { what = "Turned \(b.name) around" }
            l = Lesson(title: what, role: r.1)
        case .knob(let p, let from, let to):
            let r = role(of: p, in: circuit)
            l = Lesson(title: "\(p.text.isEmpty ? p.name : p.text) \(to > from ? "up" : "down"): \(Int(from * 10))/10 → \(Int(to * 10))/10", role: r.1)
        case .wiring(let added, let removed):
            l = Lesson(title: added > 0 ? "New connection" : "Removed \(removed) wire\(removed == 1 ? "" : "s")",
                       role: "Wires join pins into nets. Every pin on a net shares one voltage, so connecting or breaking a path changes where the signal (and the bias current) can flow.")
        case .moved(let count):
            l = Lesson(title: "Moved \(count) part\(count == 1 ? "" : "s")", role: "Moving parts doesn't change the sound unless their connections change.")
        }
        if let err = after?.error {
            l.effects = ["The circuit can't be simulated right now: \(err)"]
            l.verdict = "No signal gets through until that's fixed."
            return l
        }
        guard let m0 = Measure(before), let m1 = Measure(after) else { return l }
        var fx: [String] = []
        func band(_ name: String, _ a: Double, _ b: Double) {
            let d = b - a
            if abs(d) >= 0.5 { fx.append(String(format: "%@ %@ by %.1f dB", name, d > 0 ? "up" : "down", abs(d))) }
        }
        band("Small-signal gain at 100 Hz (bass)", m0.bass, m1.bass)
        band("Small-signal gain at 800 Hz (mids)", m0.mid, m1.mid)
        band("Small-signal gain at 4 kHz (treble)", m0.treble, m1.treble)
        let lv = 20 * log10(max(m1.peak, 1e-6) / max(m0.peak, 1e-6))
        if abs(lv) >= 0.5 { fx.append(String(format: "Output level %@ by %.1f dB (%.2f V → %.2f V peak)", lv > 0 ? "up" : "down", abs(lv), m0.peak, m1.peak)) }
        let dThd = m1.thd - m0.thd
        if abs(dThd) >= 0.5 { fx.append(String(format: "Distortion %.1f%% → %.1f%%", m0.thd, m1.thd)) }
        let gainRise = (m1.mid - m0.mid)
        if gainRise > 3 && abs(lv) < 2 && m1.thd > 3 {
            fx.append("The output level hardly moved: the clipping holds it steady, so the extra gain became distortion instead of volume.")
        } else if gainRise < -3 && abs(lv) < 2 && m0.thd > 3 {
            fx.append("The output level hardly moved: the stage still reaches its clipping point, just with less drive behind it.")
        }
        l.effects = fx.isEmpty ? ["No measurable change at the test tone. Try a louder test level or a different frequency in the oscilloscope."] : fx
        l.meters = [("Bass", m0.bass, m1.bass), ("Mids", m0.mid, m1.mid), ("Treble", m0.treble, m1.treble),
                    ("Level", 20 * log10(max(m0.peak, 1e-6)), 20 * log10(max(m1.peak, 1e-6))), ("Drive %", m0.thd, m1.thd)]
        var v: [String] = []
        if dThd > 2 { v.append("more clipping: thicker, more compressed, more sustain") }
        else if dThd < -2 { v.append("cleaner: more dynamics and clarity") }
        let tilt = (m1.treble - m1.bass) - (m0.treble - m0.bass)
        if tilt > 1.5 { v.append("brighter") } else if tilt < -1.5 { v.append("darker") }
        if m1.mid - (m1.bass + m1.treble) / 2 > (m0.mid - (m0.bass + m0.treble) / 2) + 1.5 { v.append("more mid-forward (cuts through a band)") }
        if lv > 3 { v.append("louder") } else if lv < -3 { v.append("quieter") }
        if m1.thd > 3 {
            v.append(m1.even > m1.odd * 1.2 ? "the harmonics lean even (warm, tube-like)" : (m1.odd > m1.even * 1.2 ? "the harmonics lean odd (edgier, squarer)" : "a mix of even and odd harmonics"))
        }
        l.verdict = v.isEmpty ? "A subtle change." : "Sounds " + v.joined(separator: ", ") + "."
        if l.tip.isEmpty {
            l.tip = m1.thd > 20 ? "Watch the oscilloscope: the flattened peaks are the clipping you hear."
                : "Switch the bottom panel to the oscilloscope to see the waveform change as you go."
        }
        return l
    }
}

/// The learn-mode card shown over the drawing board.
struct LessonCard: View {
    @ObservedObject var model: EditorModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "graduationcap.fill").foregroundColor(Theme.accent)
                Text("LEARN").font(.system(size: 10, weight: .bold)).foregroundColor(Theme.accent)
                Spacer()
                Button { model.learnMode = false } label: { Image(systemName: "xmark") }.buttonStyle(.borderless)
            }
            if let l = model.lesson {
                Text(l.title).font(.system(size: 13, weight: .semibold))
                Text(l.role).font(.system(size: 12)).foregroundColor(Theme.text.opacity(0.9)).fixedSize(horizontal: false, vertical: true)
                if !l.effects.isEmpty {
                    Text("WHAT CHANGED IN THE SIGNAL").font(.system(size: 9, weight: .bold)).foregroundColor(Theme.dim).padding(.top, 2)
                    ForEach(l.effects, id: \.self) { e in
                        Label(e, systemImage: "waveform").font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
                    }
                }
                if !l.meters.isEmpty { meters(l.meters) }
                if !l.verdict.isEmpty { Text(l.verdict).font(.system(size: 12, weight: .medium)).foregroundColor(Theme.good).fixedSize(horizontal: false, vertical: true) }
                if !l.tip.isEmpty { Text(l.tip).font(.system(size: 11)).foregroundColor(Theme.dim).fixedSize(horizontal: false, vertical: true) }
            } else if model.selectedParts.count == 1, let p = model.selectedParts.first {
                let r = Explainer.role(of: p, in: model.circuit)
                Text(r.0).font(.system(size: 13, weight: .semibold))
                Text(r.1).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                Text("Change its value or model and I'll measure what it does to the sound.").font(.system(size: 11)).foregroundColor(Theme.dim)
            } else {
                Text("Learn mode is on").font(.system(size: 13, weight: .semibold))
                Text("Click a part to see what it does here. Add, remove or change parts, or turn a knob, and I'll explain what happened to the signal, with before-and-after measurements.")
                    .font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(width: 330, alignment: .leading)
        .background(Theme.panel.opacity(0.96), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.accent.opacity(0.5)))
        .shadow(radius: 8)
    }

    func meters(_ rows: [(String, Double, Double)]) -> some View {
        VStack(spacing: 3) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 6) {
                    Text(row.0).font(.system(size: 10)).foregroundColor(Theme.dim).frame(width: 46, alignment: .leading)
                    GeometryReader { g in
                        let isPct = row.0.hasSuffix("%")
                        let lo = isPct ? 0.0 : -30.0, hi = isPct ? 60.0 : 30.0
                        let f = { (v: Double) in CGFloat((min(max(v, lo), hi) - lo) / (hi - lo)) * g.size.width }
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 2).fill(Color.black.opacity(0.35))
                            RoundedRectangle(cornerRadius: 2).fill(Color(white: 0.5)).frame(width: f(row.1), height: 3).offset(y: -2)
                            RoundedRectangle(cornerRadius: 2).fill(Theme.accent).frame(width: f(row.2), height: 3).offset(y: 2)
                        }
                    }
                    .frame(height: 9)
                    Text(row.0.hasSuffix("%") ? String(format: "%.0f→%.0f", row.1, row.2) : String(format: "%+.1f", row.2 - row.1))
                        .font(.system(size: 10).monospacedDigit()).foregroundColor(Theme.dim).frame(width: 52, alignment: .trailing)
                }
            }
            HStack(spacing: 10) {
                Label("before", systemImage: "minus").foregroundColor(Color(white: 0.6))
                Label("after", systemImage: "minus").foregroundColor(Theme.accent)
            }
            .font(.system(size: 9))
        }
    }
}
