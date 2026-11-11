import Foundation

/// A schematic drawn from a list of intended connections, so the drawing can be checked against the intent.
///
/// Pins are written "Part.pin": two-lead parts ".1" ".2"; diodes ".a" ".k"; pots ".1" ".3" ".w" (wiper);
/// transistors ".c" ".b" ".e"; JFETs ".d" ".g" ".s"; triodes ".p" ".g" ".k"; op-amps ".+" ".-" ".o";
/// single-pin parts by name alone. In `net`:
///   "@x,y"   a corner the wire passes through
///   "|ref"   reach this pin going vertically first (default is horizontally first)
///   "~ref"   this pin is already on the net (no wire drawn); listed so the audit knows
struct Sheet {
    var c: Circuit
    var groups: [[String]] = []
    private var symbols = 0

    init(_ name: String, notes: String) { c = Circuit(name: name, notes: notes) }

    @discardableResult
    mutating func add(_ k: PartKind, _ name: String, _ x: Int, _ y: Int, rot: Int = 0, flip: Bool = false,
                      _ props: [String: Double] = [:], model: String? = nil, text: String = "") -> Part {
        let p = Part(k, name: name, at: GridPoint(x, y), rotation: rot, flipped: flip, props: props, model: model, text: text)
        c.parts.append(p)
        return p
    }

    static func pinIndex(_ kind: PartKind, _ pin: String) -> Int? {
        switch kind {
        case .resistor, .capacitor, .inductor: return ["1": 0, "2": 1][pin]
        case .diode, .led, .zener: return ["a": 0, "k": 1][pin]
        case .pot: return ["1": 0, "3": 1, "w": 2][pin]
        case .npn, .pnp: return ["c": 0, "b": 1, "e": 2][pin]
        case .njfet, .pjfet, .nmos, .pmos: return ["d": 0, "g": 1, "s": 2][pin]
        case .spst: return ["1": 0, "2": 1][pin]
        case .spdt: return ["c": 0, "a": 1, "b": 2][pin]
        case .triode: return ["p": 0, "g": 1, "k": 2][pin]
        case .opamp: return ["+": 0, "-": 1, "o": 2][pin]
        default: return pin.isEmpty ? 0 : nil
        }
    }

    /// (part, pin index) for "Part.pin".
    func resolve(_ ref: String) -> (Part, Int) {
        let name: String, pin: String
        if let dot = ref.lastIndex(of: ".") { name = String(ref[..<dot]); pin = String(ref[ref.index(after: dot)...]) }
        else { name = ref; pin = "" }
        guard let part = c.parts.first(where: { $0.name == name }), let i = Sheet.pinIndex(part.kind, pin) else {
            fatalError("\(c.name): no pin \(ref)")
        }
        return (part, i)
    }

    func key(_ ref: String) -> String { let (p, i) = resolve(ref); return "\(p.name)#\(i)" }
    func point(_ ref: String) -> GridPoint { let (p, i) = resolve(ref); return p.pin(i) }

    /// Joins the listed pins with wires, in order.
    mutating func net(_ refs: String...) {
        var prev: GridPoint?
        var group: [String] = []
        for raw in refs {
            if raw.hasPrefix("@") {
                let xy = raw.dropFirst().split(separator: ",").compactMap { Int($0) }
                let pt = GridPoint(xy[0], xy[1])
                if let a = prev { c.connect(a, pt) }
                prev = pt
                continue
            }
            if raw.hasPrefix("~") { group.append(key(String(raw.dropFirst()))); continue }
            let vertical = raw.hasPrefix("|")
            let ref = vertical ? String(raw.dropFirst()) : raw
            let pt = point(ref)
            if let a = prev { c.connect(a, pt, verticalFirst: vertical) }
            prev = pt
            group.append(key(ref))
        }
        groups.append(group)
    }

    /// Puts a ground symbol on a pin (or offset from it, with a wire).
    mutating func gnd(_ ref: String, dx: Int = 0, dy: Int = 0) {
        symbols += 1
        let at = point(ref) + GridPoint(dx, dy)
        add(.ground, "GND\(symbols)", at.x, at.y)
        c.connect(point(ref), at, verticalFirst: true)
        groups.append([key(ref), "⏚"])
    }

    /// Puts a supply symbol on a pin (or offset from it, with a wire).
    mutating func rail(_ ref: String, _ v: Double, dx: Int = 0, dy: Int = 0, text: String? = nil) {
        symbols += 1
        let at = point(ref) + GridPoint(dx, dy)
        add(.supply, "VS\(symbols)", at.x, at.y, rot: dy > 0 ? 2 : 0, ["v": v], text: text ?? "\(Eng.format(v))V")
        c.connect(point(ref), at, verticalFirst: true)
        groups.append([key(ref), String(format: "V:%.6g", v)])
    }

    /// Compares the drawing's actual connectivity with the connections it was drawn from.
    func audit() -> [String] {
        let netlist = Netlist.build(c)
        var out = netlist.problems.map { "\(c.name): \($0)" }
        var parent: [String: String] = [:]
        func find(_ s: String) -> String {
            var r = s
            while let q = parent[r], q != r { r = q }
            return r
        }
        for g in groups {
            for k in g where parent[k] == nil { parent[k] = k }
            for k in g.dropFirst() { let a = find(g[0]), b = find(k); if a != b { parent[a] = b } }
        }
        let byName = Dictionary(uniqueKeysWithValues: c.parts.map { ($0.name, $0) })
        func node(_ k: String) -> Int? {
            if k == "⏚" { return 0 }
            let bits = k.split(separator: "#")
            guard bits.count == 2, let part = byName[String(bits[0])], let i = Int(bits[1]) else { return nil }
            return netlist.pinNodes[part.id]?[i]
        }
        var groupNodes: [String: Set<Int>] = [:], nodeGroups: [Int: Set<String>] = [:], members: [String: [String]] = [:]
        for k in parent.keys {
            let root = find(k)
            members[root, default: []].append(k)
            if let n = node(k) { groupNodes[root, default: []].insert(n); nodeGroups[n, default: []].insert(root) }
        }
        for (root, nodes) in groupNodes where nodes.count > 1 {
            out.append("\(c.name): these should be joined but are not: \(members[root]!.sorted().joined(separator: " "))")
        }
        for (_, roots) in nodeGroups where roots.count > 1 {
            let sets = roots.sorted().map { members[$0]!.sorted().prefix(4).joined(separator: " ") }
            out.append("\(c.name): separate connections are shorted together: " + sets.joined(separator: "  /  "))
        }
        for p in c.parts where ![.ground, .supply, .label].contains(p.kind) {
            for i in p.pins.indices where parent["\(p.name)#\(i)"] == nil { out.append("\(c.name): \(p.name) pin \(i) isn't in any connection") }
        }
        return out
    }
}

extension Presets {
    // MARK: Pedals

    /// Op-amp gain stage into a pair of germanium diodes to ground.
    static var hardClipSheet: Sheet {
        var s = Sheet("Hard-Clip Distortion",
                      notes: "An op-amp gain stage (up to about 200×) followed by two germanium diodes to ground, which chop the signal off at ±0.3 V: the bright, raw hard clipping of the first op-amp distortion pedals of the 1970s.")
        s.add(.input, "IN", 0, 0)
        s.add(.capacitor, "C1", 3, 0, ["c": 10e-9])
        s.add(.resistor, "R1", 8, 0, ["r": 10e3])
        s.add(.resistor, "R2", 12, 2, rot: 1, ["r": 1e6])
        s.add(.opamp, "U1", 16, -1, ["vneg": 0, "vpos": 9], model: "LM741")
        s.add(.resistor, "R3", 16, -6, ["r": 1e6])
        s.add(.resistor, "R4", 12, -4, rot: 1, ["r": 4.7e3])
        s.add(.capacitor, "C2", 9, -6, ["c": 47e-9])
        s.add(.pot, "VR1", 4, -6, ["r": 500e3, "position": 0.75], model: "B", text: "Gain")
        s.add(.capacitor, "C3", 21, -1, ["c": 1e-6])
        s.add(.resistor, "R5", 26, -1, ["r": 10e3])
        s.add(.diode, "D1", 30, 1, rot: 1, model: "1N34A (germanium)")
        s.add(.diode, "D2", 33, 1, rot: 3, model: "1N34A (germanium)")
        s.add(.capacitor, "C4", 36, 1, rot: 1, ["c": 1e-9])
        s.add(.pot, "VR2", 38, 1, rot: 1, flip: true, ["r": 100e3, "position": 0.9], model: "A", text: "Level")
        s.add(.output, "OUT", 42, 1)
        s.net("IN", "C1.1"); s.net("C1.2", "R1.1")
        s.net("R1.2", "R2.1", "U1.+")
        s.rail("R2.2", 4.5)
        s.net("U1.-", "R3.1"); s.net("U1.o", "R3.2")
        s.net("U1.-", "R4.2"); s.net("R4.1", "C2.2"); s.net("C2.1", "VR1.3")
        s.net("VR1.w", "VR1.1"); s.gnd("VR1.1", dy: 2)
        s.net("U1.o", "C3.1"); s.net("C3.2", "R5.1")
        s.net("R5.2", "D1.a", "D2.k", "C4.1", "VR2.3")
        s.gnd("D1.k"); s.gnd("D2.a"); s.gnd("C4.2"); s.gnd("VR2.1")
        s.net("VR2.w", "OUT")
        return s
    }

    /// Slow op-amp driven to very high gain, silicon diodes to ground, treble-cut filter.
    static var slewDistortionSheet: Sheet {
        var s = Sheet("Slew-Limited Distortion",
                      notes: "A slow op-amp (0.3 V/µs) asked for up to 2000× gain: it can't keep up with the treble, which rounds the signal before two silicon diodes clip it. Filter turns the treble down as you turn it up. The sound of the late-1970s rodent-named distortion.")
        s.add(.input, "IN", 0, 0)
        s.add(.capacitor, "C1", 3, 0, ["c": 22e-9])
        s.add(.resistor, "R1", 8, 0, ["r": 1e3])
        s.add(.resistor, "R2", 12, 2, rot: 1, ["r": 1e6])
        s.add(.opamp, "U1", 16, -1, ["vneg": 0, "vpos": 9], model: "LM308")
        s.add(.pot, "VR1", 16, -6, ["r": 100e3, "position": 0.6], model: "A", text: "Distortion")
        s.add(.capacitor, "C2", 16, -10, ["c": 100e-12])
        s.add(.resistor, "R3", 10, -10, ["r": 47])
        s.add(.capacitor, "C3", 8, -8, rot: 1, ["c": 2.2e-6])
        s.add(.resistor, "R4", 12, -12, rot: 1, ["r": 560])
        s.add(.capacitor, "C4", 9, -14, ["c": 4.7e-6])
        s.add(.capacitor, "C5", 21, -1, ["c": 4.7e-6])
        s.add(.resistor, "R5", 26, -1, ["r": 1e3])
        s.add(.diode, "D1", 30, 1, rot: 1, model: "1N914")
        s.add(.diode, "D2", 33, 1, rot: 3, model: "1N914")
        s.add(.pot, "VR2", 37, -1, ["r": 100e3, "position": 0.3], model: "A", text: "Filter")
        s.add(.capacitor, "C6", 41, 1, rot: 1, ["c": 3.3e-9])
        s.add(.pot, "VR3", 44, 1, rot: 1, flip: true, ["r": 100e3, "position": 0.6], model: "A", text: "Volume")
        s.add(.output, "OUT", 48, 1)
        s.net("IN", "C1.1"); s.net("C1.2", "R1.1")
        s.net("R1.2", "R2.1", "U1.+")
        s.rail("R2.2", 4.5)
        s.net("U1.-", "VR1.1"); s.net("U1.o", "VR1.3"); s.net("VR1.w", "@18,-8", "VR1.3")
        s.net("VR1.1", "C2.1"); s.net("VR1.3", "C2.2")
        s.net("C2.1", "R3.2"); s.net("R3.1", "C3.1"); s.gnd("C3.2")
        s.net("R3.2", "R4.2"); s.net("R4.1", "C4.2"); s.gnd("C4.1", dy: 2)
        s.net("U1.o", "C5.1"); s.net("C5.2", "R5.1")
        s.net("R5.2", "D1.a", "D2.k", "VR2.1")
        s.gnd("D1.k"); s.gnd("D2.a")
        s.net("VR2.w", "@39,-3", "VR2.3")
        s.net("VR2.3", "C6.1", "VR3.3")
        s.gnd("C6.2"); s.gnd("VR3.1")
        s.net("VR3.w", "OUT")
        return s
    }

    /// The 1960s two-transistor fuzz with germanium PNP transistors and a positive ground.
    static var germaniumFuzzSheet: Sheet {
        var s = Sheet("Germanium Fuzz",
                      notes: "The 1960s round fuzz: two leaky germanium PNP transistors, directly coupled, on a −9 V supply (positive ground). It cleans up when you turn the guitar down, because its input impedance is low enough to load the pickups.")
        s.add(.input, "IN", 0, 0, ["rs": 6000])
        s.add(.capacitor, "C1", 3, 0, ["c": 2.2e-6])
        s.add(.pnp, "Q1", 8, 0, model: "Germanium PNP (AC128 type)")
        s.add(.resistor, "R1", 9, -4, rot: 1, ["r": 33e3])
        s.add(.pnp, "Q2", 15, -2, model: "Germanium PNP (AC128 type)")
        s.add(.resistor, "R2", 16, -6, rot: 1, ["r": 470])
        s.add(.resistor, "R3", 16, -10, rot: 1, ["r": 8.2e3])
        s.add(.pot, "VR1", 16, 2, rot: 3, ["r": 1e3, "position": 0.9], model: "B", text: "Fuzz")
        s.add(.capacitor, "C2", 12, 2, ["c": 22e-6])
        s.add(.resistor, "R4", 11, 7, ["r": 100e3])
        s.add(.capacitor, "C3", 20, -8, ["c": 10e-9])
        s.add(.pot, "VR2", 24, -6, rot: 1, flip: true, ["r": 500e3, "position": 0.6], model: "A", text: "Volume")
        s.add(.output, "OUT", 28, -6)
        s.net("IN", "C1.1"); s.net("C1.2", "Q1.b")
        s.gnd("Q1.e")
        s.rail("R1.1", -9)
        s.net("R1.2", "Q1.c", "Q2.b")
        s.net("Q2.c", "R2.2"); s.net("R2.1", "R3.2", "C3.1")
        s.rail("R3.1", -9)
        s.net("Q2.e", "VR1.3"); s.gnd("VR1.1")
        s.net("VR1.w", "C2.2"); s.net("C2.1", "Q1.e")
        s.net("Q1.b", "@6,7", "R4.1"); s.net("R4.2", "@18,7", "@18,0", "Q2.e")
        s.net("C3.2", "VR2.3"); s.gnd("VR2.1")
        s.net("VR2.w", "OUT")
        return s
    }

    /// One transistor, one knob.
    static var transistorBoostSheet: Sheet {
        var s = Sheet("Single-Transistor Boost",
                      notes: "One silicon transistor in common emitter with a small emitter resistor: about 25 dB of gain, enough to push the next pedal or the amp into overdrive. The simplest pedal there is.")
        s.add(.input, "IN", 0, 0)
        s.add(.capacitor, "C1", 3, 0, ["c": 100e-9])
        s.add(.resistor, "R1", 6, -2, rot: 1, ["r": 430e3])
        s.add(.resistor, "R2", 6, 2, rot: 1, ["r": 43e3])
        s.add(.npn, "Q1", 10, 0, model: "2N5088")
        s.add(.resistor, "R3", 11, -4, rot: 1, ["r": 10e3])
        s.add(.resistor, "R4", 11, 4, rot: 1, ["r": 390])
        s.add(.capacitor, "C2", 15, -2, ["c": 100e-9])
        s.add(.pot, "VR1", 19, 0, rot: 1, flip: true, ["r": 100e3, "position": 0.6], model: "A", text: "Boost")
        s.add(.output, "OUT", 23, 0)
        s.net("IN", "C1.1")
        s.net("C1.2", "R1.2", "R2.1", "Q1.b")
        s.rail("R1.1", 9); s.gnd("R2.2")
        s.net("R3.2", "Q1.c"); s.rail("R3.1", 9)
        s.net("Q1.e", "R4.1"); s.gnd("R4.2")
        s.net("Q1.c", "C2.1"); s.net("C2.2", "VR1.3"); s.gnd("VR1.1")
        s.net("VR1.w", "OUT")
        return s
    }

    /// One MOSFET in common source with a variable source bypass.
    static var mosfetBoostSheet: Sheet {
        var s = Sheet("MOSFET Boost",
                      notes: "One small MOSFET in common source. Gain sets how much of the source resistor is bypassed, from about 4 dB to over 30 dB. The very high input impedance keeps the guitar's treble, and when pushed it clips softly and unevenly, a little like a tube.")
        s.add(.input, "IN", 0, 0)
        s.add(.capacitor, "C1", 3, 0, ["c": 47e-9])
        s.add(.resistor, "R1", 6, -2, rot: 1, ["r": 1e6])
        s.add(.resistor, "R2", 6, 2, rot: 1, ["r": 1e6])
        s.add(.nmos, "M1", 10, 0, model: "2N7000")
        s.add(.resistor, "R3", 11, -4, rot: 1, ["r": 2.7e3])
        s.add(.resistor, "R4", 11, 4, rot: 1, ["r": 2.2e3])
        s.add(.capacitor, "C3", 15, 2, ["c": 47e-6])
        s.add(.pot, "VR1", 21, 4, rot: 1, flip: true, ["r": 5e3, "position": 0.5], model: "B", text: "Gain")
        s.add(.capacitor, "C2", 16, -2, ["c": 4.7e-6])
        s.add(.resistor, "R5", 26, 0, rot: 1, ["r": 100e3])
        s.add(.output, "OUT", 29, -2)
        s.net("IN", "C1.1")
        s.net("C1.2", "R1.2", "R2.1", "M1.g")
        s.rail("R1.1", 9); s.gnd("R2.2")
        s.net("R3.2", "M1.d"); s.rail("R3.1", 9)
        s.net("M1.s", "R4.1", "C3.1"); s.gnd("R4.2")
        s.net("C3.2", "VR1.3")
        s.net("VR1.w", "|VR1.1"); s.gnd("VR1.1")
        s.net("M1.d", "C2.1"); s.net("C2.2", "R5.1", "OUT"); s.gnd("R5.2")
        return s
    }

    /// Op-amp overdrive whose feedback clipping is chosen with a selector: MOSFETs, silicon diodes, or none.
    static var selectableClipSheet: Sheet {
        var s = Sheet("Selectable-Clip Overdrive",
                      notes: "An op-amp overdrive with a three-way Clip selector in its feedback loop. A: two back-to-back MOSFETs, which clip late and softly (open, amp-like). B: two silicon diodes, which clip early (compressed, more driven). Centre: no clipping parts, a clean boost until the op-amp itself runs out of swing.")
        s.add(.input, "IN", 0, 0)
        s.add(.capacitor, "C1", 3, 0, ["c": 47e-9])
        s.add(.resistor, "R1", 8, 0, ["r": 10e3])
        s.add(.resistor, "R2", 12, 2, rot: 1, ["r": 1e6])
        s.add(.opamp, "U1", 16, -1, ["vneg": 0, "vpos": 9], model: "TL072")
        s.add(.resistor, "R3", 16, -6, ["r": 220e3])
        s.add(.resistor, "R4", 12, -4, rot: 1, ["r": 4.7e3])
        s.add(.capacitor, "C2", 9, -6, ["c": 100e-9])
        s.add(.pot, "VR1", 4, -6, ["r": 100e3, "position": 0.7], model: "B", text: "Drive")
        s.add(.nmos, "M1", 17, -10, rot: 3, model: "BS170")
        s.add(.nmos, "M2", 22, -10, rot: 1, flip: true, model: "BS170")
        s.add(.diode, "D1", 19, -15, model: "1N4148")
        s.add(.diode, "D2", 19, -18, rot: 2, model: "1N4148")
        s.add(.spdt, "SW1", 27, -9, rot: 3, ["state": 0], text: "Clip")
        s.add(.capacitor, "C3", 21, -1, ["c": 1e-6])
        s.add(.resistor, "R5", 26, -1, ["r": 1e3])
        s.add(.capacitor, "C4", 30, 1, rot: 1, ["c": 22e-9])
        s.add(.pot, "VR2", 39, 1, rot: 1, flip: true, ["r": 100e3, "position": 0.7], model: "A", text: "Level")
        s.add(.output, "OUT", 43, 1)
        s.net("IN", "C1.1"); s.net("C1.2", "R1.1")
        s.net("R1.2", "R2.1", "U1.+")
        s.rail("R2.2", 4.5, dy: 2)
        s.net("U1.-", "R3.1", "|M1.d", "|D1.a", "D2.k")
        s.net("U1.-", "R4.2"); s.net("R4.1", "C2.2"); s.net("C2.1", "VR1.3")
        s.net("VR1.w", "VR1.1"); s.gnd("VR1.1", dy: 2)
        s.net("M1.g", "M1.d"); s.net("M1.s", "M2.s"); s.net("M2.g", "M2.d")
        s.net("M2.d", "SW1.a")
        s.net("SW1.b", "|D1.k", "D2.a")
        s.net("U1.o", "R3.2"); s.net("SW1.c", "R3.2")
        s.net("U1.o", "C3.1"); s.net("C3.2", "R5.1")
        s.net("R5.2", "C4.1", "VR2.3")
        s.gnd("C4.2"); s.gnd("VR2.1")
        s.net("VR2.w", "OUT")
        return s
    }

    /// Bass overdrive: a buffered clean path and a drive path that leaves the low notes alone, mixed with a Blend knob.
    static var bassBlendDriveSheet: Sheet {
        var s = Sheet("Bass Blend Overdrive",
                      notes: "Made for bass. A buffer splits the signal in two: the drive path only adds gain above about 150 Hz, so the low notes stay solid while the mids and top break up, and Blend mixes it with the untouched clean signal. Fully clean at Blend 0, all drive at 10.")
        s.add(.input, "IN", 0, 0)
        s.add(.capacitor, "C1", 3, 0, ["c": 100e-9])
        s.add(.resistor, "R2", 7, 2, rot: 1, ["r": 1e6])
        s.add(.opamp, "U1", 11, -1, ["vneg": 0, "vpos": 9], model: "TL072")
        s.add(.capacitor, "C2", 17, 0, ["c": 100e-9])
        s.add(.resistor, "R3", 26, 2, rot: 1, ["r": 1e6])
        s.add(.opamp, "U2", 30, -1, ["vneg": 0, "vpos": 9], model: "TL072")
        s.add(.resistor, "R5", 30, -6, ["r": 100e3])
        s.add(.resistor, "R4", 26, -4, rot: 1, ["r": 4.7e3])
        s.add(.capacitor, "C3", 23, -6, ["c": 220e-9])
        s.add(.pot, "VR1", 18, -6, ["r": 100e3, "position": 0.7], model: "B", text: "Drive")
        s.add(.diode, "D1", 30, -9, model: "1N4148")
        s.add(.diode, "D2", 30, -12, rot: 2, model: "1N4148")
        s.add(.capacitor, "C4", 35, -1, ["c": 1e-6])
        s.add(.resistor, "R6", 40, -1, ["r": 4.7e3])
        s.add(.capacitor, "C5", 44, 1, rot: 1, ["c": 10e-9])
        s.add(.capacitor, "C6", 30, 10, ["c": 1e-6])
        s.add(.pot, "VR2", 52, 1, rot: 1, flip: true, ["r": 50e3, "position": 0.5], model: "B", text: "Blend")
        s.add(.pot, "VR3", 58, 3, rot: 1, flip: true, ["r": 100e3, "position": 0.8], model: "A", text: "Level")
        s.add(.output, "OUT", 63, 3)
        s.net("IN", "C1.1")
        s.net("C1.2", "R2.1", "U1.+"); s.rail("R2.2", 4.5, dy: 2)
        s.net("U1.-", "@9,-4", "@13,-4", "U1.o")
        s.net("U1.o", "C2.1")
        s.net("C2.2", "R3.1", "U2.+"); s.rail("R3.2", 4.5, dy: 2)
        s.net("U2.-", "R5.1", "D1.a", "D2.k")
        s.net("U2.-", "R4.2"); s.net("R4.1", "C3.2"); s.net("C3.1", "VR1.3")
        s.net("VR1.w", "VR1.1"); s.gnd("VR1.1", dy: 2)
        s.net("U2.o", "R5.2", "D1.k", "D2.a")
        s.net("U2.o", "C4.1"); s.net("C4.2", "R6.1")
        s.net("R6.2", "C5.1", "VR2.3"); s.gnd("C5.2")
        s.net("U1.o", "@13,10", "C6.1")
        s.net("C6.2", "@52,10", "VR2.1")
        s.net("VR2.w", "VR3.3"); s.gnd("VR3.1")
        s.net("VR3.w", "OUT")
        return s
    }

    /// Germanium treble booster of the 1960s.
    static var trebleBoosterSheet: Sheet {
        var s = Sheet("Germanium Treble Booster",
                      notes: "One germanium PNP transistor with a tiny input capacitor, so it boosts treble far more than bass. Made to push a dark British valve amp into singing overdrive. Positive ground, −9 V supply.")
        s.add(.input, "IN", 0, 0)
        s.add(.capacitor, "C1", 3, 0, ["c": 4.7e-9])
        s.add(.resistor, "R1", 6, -2, rot: 1, ["r": 470e3])
        s.add(.resistor, "R2", 6, 2, rot: 1, ["r": 68e3])
        s.add(.pnp, "Q1", 10, 0, model: "Germanium PNP (AC128 type)")
        s.add(.resistor, "R3", 11, 4, rot: 1, ["r": 3.9e3])
        s.add(.capacitor, "C2", 13, 4, rot: 1, ["c": 47e-6])
        s.add(.pot, "VR1", 11, -4, rot: 1, ["r": 10e3, "position": 0.8], model: "A", text: "Boost")
        s.add(.capacitor, "C3", 17, -4, ["c": 10e-9])
        s.add(.output, "OUT", 21, -4)
        s.net("IN", "C1.1")
        s.net("C1.2", "R1.2", "R2.1", "Q1.b")
        s.rail("R1.1", -9); s.gnd("R2.2")
        s.net("Q1.e", "R3.1", "C2.1"); s.gnd("R3.2"); s.gnd("C2.2")
        s.net("Q1.c", "VR1.3"); s.rail("VR1.1", -9)
        s.net("VR1.w", "C3.1"); s.net("C3.2", "OUT")
        return s
    }

    /// Three JFET stages in a row: an amp-in-a-box overdrive.
    static var jfetOverdriveSheet: Sheet {
        var s = Sheet("Cascaded JFET Overdrive",
                      notes: "Three JFET gain stages in a row, laid out like the preamp of a valve amp. JFETs clip softly and unevenly much as triodes do, so this gives amp-like overdrive at 9 V.")
        s.add(.input, "IN", 0, 0)
        s.add(.capacitor, "C1", 3, 0, ["c": 22e-9])
        s.add(.resistor, "R1", 6, 2, rot: 1, ["r": 1e6])
        s.add(.njfet, "J1", 10, 0, model: "J201")
        s.add(.resistor, "R2", 11, -4, rot: 1, ["r": 33e3])
        s.add(.resistor, "R3", 11, 4, rot: 1, ["r": 1e3])
        s.add(.capacitor, "C2", 13, 4, rot: 1, ["c": 10e-6])
        s.add(.capacitor, "C3", 15, -2, ["c": 22e-9])
        s.add(.pot, "VR1", 19, 0, rot: 1, flip: true, ["r": 500e3, "position": 0.6], model: "A", text: "Gain")
        s.add(.njfet, "J2", 25, 0, model: "J201")
        s.add(.resistor, "R4", 26, -4, rot: 1, ["r": 33e3])
        s.add(.resistor, "R5", 26, 4, rot: 1, ["r": 1e3])
        s.add(.capacitor, "C4", 30, -2, ["c": 22e-9])
        s.add(.resistor, "R6", 35, -2, ["r": 470e3])
        s.add(.resistor, "R7", 38, 0, rot: 1, ["r": 470e3])
        s.add(.njfet, "J3", 42, -2, model: "J201")
        s.add(.resistor, "R8", 43, -6, rot: 1, ["r": 33e3])
        s.add(.resistor, "R9", 43, 2, rot: 1, ["r": 1e3])
        s.add(.capacitor, "C5", 45, 2, rot: 1, ["c": 1e-6])
        s.add(.capacitor, "C6", 47, -4, ["c": 100e-9])
        s.add(.capacitor, "C7", 50, -2, rot: 1, ["c": 10e-9])
        s.add(.pot, "VR2", 50, 2, rot: 1, ["r": 50e3, "position": 0.5], model: "B", text: "Tone")
        s.add(.pot, "VR3", 55, -2, rot: 1, flip: true, ["r": 100e3, "position": 0.6], model: "A", text: "Level")
        s.add(.output, "OUT", 59, -2)
        s.net("IN", "C1.1")
        s.net("C1.2", "R1.1", "J1.g"); s.gnd("R1.2")
        s.net("R2.2", "J1.d"); s.rail("R2.1", 9)
        s.net("J1.s", "R3.1", "C2.1"); s.gnd("R3.2"); s.gnd("C2.2")
        s.net("J1.d", "C3.1"); s.net("C3.2", "VR1.3"); s.gnd("VR1.1")
        s.net("VR1.w", "J2.g")
        s.net("R4.2", "J2.d"); s.rail("R4.1", 9)
        s.net("J2.s", "R5.1"); s.gnd("R5.2")
        s.net("J2.d", "C4.1"); s.net("C4.2", "R6.1")
        s.net("R6.2", "R7.1", "J3.g"); s.gnd("R7.2")
        s.net("R8.2", "J3.d"); s.rail("R8.1", 9)
        s.net("J3.s", "R9.1", "C5.1"); s.gnd("R9.2"); s.gnd("C5.2")
        s.net("J3.d", "C6.1")
        s.net("C6.2", "C7.1", "VR3.3")
        s.net("C7.2", "VR2.1"); s.net("VR2.w", "|VR2.3"); s.gnd("VR2.3")
        s.gnd("VR3.1")
        s.net("VR3.w", "OUT")
        return s
    }

    /// Four transistors: booster, two diode-clipping stages, tone control, recovery.
    static var sustainFuzzSheet: Sheet {
        var s = Sheet("Four-Stage Sustain Fuzz",
                      notes: "The big, endless-sustain fuzz of the 1970s: a booster, then two stages that each clip with a pair of diodes in their feedback path, then a tone control that fades between a bass-only and a treble-only path (which scoops the middle), then a recovery stage.")
        s.add(.input, "IN", 0, 0)
        s.add(.resistor, "R1", 3, 0, ["r": 39e3])
        s.add(.capacitor, "C1", 8, 0, ["c": 100e-9])

        /// One collector-feedback stage with its transistor at (x, 0). Returns nothing; pins are reached by name.
        func stage(_ s: inout Sheet, _ n: Int, x: Int, feed: String, clip: Bool, r: Int, cap: Int, d: Int) {
            let q = "Q\(n)", rb = "R\(r)", rc = "R\(r + 1)", re = "R\(r + 2)", rf = "R\(r + 3)", cf = "C\(cap)"
            s.add(.npn, q, x, 0, model: "2N5088")
            s.add(.resistor, rb, x - 3, 2, rot: 1, ["r": 100e3])
            s.add(.resistor, rc, x + 1, -4, rot: 1, ["r": 12e3])
            s.add(.resistor, re, x + 1, 4, rot: 1, ["r": 100])
            s.add(.resistor, rf, x - 2, -10, ["r": 470e3])
            s.add(.capacitor, cf, x - 2, -12, ["c": 470e-12])
            let xl = x - 5, xr = x + 3
            s.net(feed, "@\(xl),0", "\(rb).1", "\(q).b")
            s.gnd("\(rb).2")
            s.net("\(rc).2", "\(q).c"); s.rail("\(rc).1", 9)
            s.net("\(q).e", "\(re).1"); s.gnd("\(re).2")
            s.net("~\(q).b", "@\(xl),0", "@\(xl),-10", "\(rf).1")
            s.net("~\(q).b", "@\(xl),-10", "@\(xl),-12", "\(cf).1")
            s.net("\(q).c", "@\(xr),-2", "@\(xr),-10", "\(rf).2")
            s.net("~\(q).c", "@\(xr),-10", "@\(xr),-12", "\(cf).2")
            if clip {
                let cd = "C\(cap + 1)", d1 = "D\(d)", d2 = "D\(d + 1)"
                s.add(.capacitor, cd, xr, -14, rot: 1, ["c": 100e-9])
                s.add(.diode, d1, x - 2, -16, model: "1N914")
                s.add(.diode, d2, x - 2, -18, flip: true, model: "1N914")
                s.net("~\(q).c", "\(cd).2")
                s.net("\(cd).1", "\(d1).k"); s.net("\(cd).1", "@\(xr),-18", "\(d2).a")
                s.net("~\(q).b", "@\(xl),-12", "@\(xl),-16", "\(d1).a")
                s.net("~\(q).b", "@\(xl),-16", "@\(xl),-18", "\(d2).k")
            }
        }

        s.net("IN", "R1.1"); s.net("R1.2", "C1.1")
        stage(&s, 1, x: 16, feed: "C1.2", clip: false, r: 2, cap: 2, d: 0)          // R2–R5, C2
        s.add(.capacitor, "C3", 23, -2, ["c": 100e-9])
        s.add(.pot, "VR1", 27, 0, rot: 1, flip: true, ["r": 100e3, "position": 0.7], model: "B", text: "Sustain")
        s.net("~Q1.c", "@19,-2", "C3.1"); s.net("C3.2", "VR1.3"); s.gnd("VR1.1")
        s.add(.resistor, "R6", 32, 0, ["r": 8.2e3])
        s.add(.capacitor, "C4", 37, 0, ["c": 100e-9])
        s.net("VR1.w", "R6.1"); s.net("R6.2", "C4.1")
        stage(&s, 2, x: 45, feed: "C4.2", clip: true, r: 7, cap: 5, d: 1)           // R7–R10, C5, C6, D1, D2
        s.add(.capacitor, "C7", 52, -2, ["c": 100e-9])
        s.add(.resistor, "R11", 57, 0, ["r": 8.2e3])
        s.add(.capacitor, "C8", 62, 0, ["c": 100e-9])
        s.net("~Q2.c", "@48,-2", "C7.1"); s.net("C7.2", "@55,-2", "R11.1"); s.net("R11.2", "C8.1")
        stage(&s, 3, x: 70, feed: "C8.2", clip: true, r: 12, cap: 9, d: 3)          // R12–R15, C9, C10, D3, D4
        // tone: a low-pass path and a high-pass path, blended by the pot
        s.add(.capacitor, "C11", 77, -2, ["c": 100e-9])
        s.add(.resistor, "R16", 84, -6, ["r": 39e3])
        s.add(.capacitor, "C12", 86, -4, rot: 1, ["c": 10e-9])
        s.add(.capacitor, "C13", 84, 2, ["c": 3.9e-9])
        s.add(.resistor, "R17", 86, 4, rot: 1, ["r": 22e3])
        s.add(.pot, "VR2", 90, -2, rot: 1, ["r": 100e3, "position": 0.5], model: "B", text: "Tone")
        s.net("~Q3.c", "@73,-2", "C11.1")
        s.net("C11.2", "@81,-2", "@81,-6", "R16.1")
        s.net("~C11.2", "@81,-2", "@81,2", "C13.1")
        s.net("R16.2", "C12.1"); s.gnd("C12.2")
        s.net("C13.2", "R17.1"); s.gnd("R17.2")
        s.net("R16.2", "@90,-6", "VR2.1"); s.net("C13.2", "@90,2", "VR2.3")
        // recovery stage
        s.add(.capacitor, "C14", 95, -2, ["c": 100e-9])
        s.add(.resistor, "R18", 99, -4, rot: 1, ["r": 430e3])
        s.add(.resistor, "R19", 99, 0, rot: 1, ["r": 100e3])
        s.add(.npn, "Q4", 103, -2, model: "2N5088")
        s.add(.resistor, "R20", 104, -6, rot: 1, ["r": 10e3])
        s.add(.resistor, "R21", 104, 2, rot: 1, ["r": 2.7e3])
        s.add(.capacitor, "C15", 108, -4, ["c": 100e-9])
        s.add(.pot, "VR3", 112, -2, rot: 1, flip: true, ["r": 100e3, "position": 0.6], model: "A", text: "Volume")
        s.add(.output, "OUT", 116, -2)
        s.net("VR2.w", "C14.1")
        s.net("C14.2", "R18.2", "R19.1", "Q4.b"); s.rail("R18.1", 9); s.gnd("R19.2")
        s.net("R20.2", "Q4.c"); s.rail("R20.1", 9)
        s.net("Q4.e", "R21.1"); s.gnd("R21.2")
        s.net("Q4.c", "C15.1"); s.net("C15.2", "VR3.3"); s.gnd("VR3.1")
        s.net("VR3.w", "OUT")
        return s
    }

    // MARK: Amps

    /// Treble/bass/middle stack with its top-left corner at (sx, sy), then a master volume and the output.
    static func toneStack(_ s: inout Sheet, from: String, sx: Int, sy: Int, slope: Double, treble: Double, firstPot: Int,
                          firstCap: Int, slopeR: String, outScale: Double,
                          bassCap: Double = 22e-9, midCap: Double = 22e-9) {
        let ct = "C\(firstCap)", cb = "C\(firstCap + 1)", cm = "C\(firstCap + 2)"
        let vt = "VR\(firstPot)", vb = "VR\(firstPot + 1)", vm = "VR\(firstPot + 2)", vmaster = "VR\(firstPot + 3)"
        s.add(.capacitor, ct, sx + 4, sy - 8, ["c": treble])
        s.add(.pot, vt, sx + 8, sy - 6, rot: 1, flip: true, ["r": 250e3, "position": 0.6], model: "A", text: "Treble")
        s.add(.resistor, slopeR, sx + 2, sy, ["r": slope])
        s.add(.capacitor, cb, sx + 6, sy - 4, ["c": bassCap])
        s.add(.capacitor, cm, sx + 6, sy, ["c": midCap])
        s.add(.pot, vb, sx + 8, sy - 2, rot: 1, ["r": 1e6, "position": 0.5], model: "A", text: "Bass")
        s.add(.pot, vm, sx + 8, sy + 2, rot: 1, ["r": 25e3, "position": 0.5], model: "B", text: "Middle")
        s.add(.pot, vmaster, sx + 14, sy - 4, rot: 1, flip: true, ["r": 1e6, "position": 0.5], model: "A", text: "Master")
        s.add(.output, "OUT", sx + 18, sy - 4, ["rl": 1e6, "scale": outScale])
        s.net(from, "\(slopeR).1")
        s.net("~\(slopeR).1", "@\(sx),\(sy)", "@\(sx),\(sy - 8)", "\(ct).1")
        s.net("\(ct).2", "\(vt).3")
        s.net("\(slopeR).2", "\(cm).1"); s.net("~\(slopeR).2", "@\(sx + 4),\(sy)", "|\(cb).1")
        s.net("\(cb).2", "\(vt).1", "\(vb).1")
        s.net("\(cm).2", "\(vb).3", "\(vm).1")
        s.net("\(vb).w", "|\(vb).3")
        s.net("\(vm).w", "|\(vm).3"); s.gnd("\(vm).3")
        s.net("\(vt).w", "\(vmaster).3"); s.gnd("\(vmaster).1")
        s.net("\(vmaster).w", "OUT")
    }

    /// Input jack, grid-leak and grid-stopper resistors, and the first triode stage, common to the amps.
    static func firstStage(_ s: inout Sheet, bPlus: Double, rk: Double, ck: Double, coupling: Double = 22e-9) {
        s.add(.input, "IN", 0, 0)
        s.add(.resistor, "R1", 2, 2, rot: 1, ["r": 1e6])
        s.add(.resistor, "R2", 5, 0, ["r": 68e3])
        s.add(.triode, "V1", 10, 0, model: "12AX7")
        s.add(.resistor, "R3", 11, 4, rot: 1, ["r": rk])
        s.add(.capacitor, "C1", 13, 4, rot: 1, ["c": ck])
        s.add(.resistor, "R4", 11, -4, rot: 1, ["r": 100e3])
        s.add(.capacitor, "C2", 15, -2, ["c": coupling])
        s.net("IN", "R1.1", "R2.1"); s.gnd("R1.2")
        s.net("R2.2", "V1.g")
        s.net("V1.k", "R3.1", "C1.1"); s.gnd("R3.2"); s.gnd("C1.2")
        s.net("R4.2", "V1.p"); s.rail("R4.1", bPlus, text: "B+ \(Eng.format(bPlus))V")
        s.net("V1.p", "C2.1")
    }

    /// 1950s-style: two stages, one volume, one tone.
    static var tweedSheet: Sheet {
        var s = Sheet("Tweed-Style Preamp",
                      notes: "The simplest classic valve amp: two 12AX7 stages with a volume control between them and a single tone knob that bleeds treble to ground. Warm, and it breaks up early and smoothly.")
        firstStage(&s, bPlus: 250, rk: 1.5e3, ck: 22e-6)
        s.add(.pot, "VR1", 19, 0, rot: 1, flip: true, ["r": 1e6, "position": 0.6], model: "A", text: "Volume")
        s.add(.triode, "V2", 25, 0, model: "12AX7")
        s.add(.resistor, "R5", 26, 4, rot: 1, ["r": 1.5e3])
        s.add(.capacitor, "C3", 28, 4, rot: 1, ["c": 22e-6])
        s.add(.resistor, "R6", 26, -4, rot: 1, ["r": 100e3])
        s.add(.capacitor, "C4", 30, -2, ["c": 22e-9])
        s.add(.capacitor, "C5", 34, 0, rot: 1, ["c": 4.7e-9])
        s.add(.pot, "VR2", 34, 4, rot: 1, ["r": 1e6, "position": 0.6], model: "A", text: "Tone")
        s.add(.pot, "VR3", 38, 0, rot: 1, flip: true, ["r": 1e6, "position": 0.5], model: "A", text: "Master")
        s.add(.output, "OUT", 42, 0, ["rl": 1e6, "scale": 0.05])
        s.net("C2.2", "VR1.3"); s.gnd("VR1.1")
        s.net("VR1.w", "V2.g")
        s.net("V2.k", "R5.1", "C3.1"); s.gnd("R5.2"); s.gnd("C3.2")
        s.net("R6.2", "V2.p"); s.rail("R6.1", 250, text: "B+ 250V")
        s.net("V2.p", "C4.1")
        s.net("C4.2", "C5.1", "VR3.3")
        s.net("C5.2", "VR2.1"); s.net("VR2.w", "|VR2.3"); s.gnd("VR2.3")
        s.gnd("VR3.1")
        s.net("VR3.w", "OUT")
        return s
    }

    /// 1960s British: two stages, a cathode follower, then the tone stack.
    static var britishSheet: Sheet {
        var s = Sheet("British Stack Preamp",
                      notes: "The 1960s British 100-watt preamp: a bright first stage, a second stage wired straight into a cathode follower (which squashes the peaks as it's pushed), then the treble/bass/middle stack. Crunchy and mid-forward.")
        firstStage(&s, bPlus: 300, rk: 2.7e3, ck: 680e-9)
        s.add(.pot, "VR1", 19, 0, rot: 1, flip: true, ["r": 1e6, "position": 0.7], model: "A", text: "Gain")
        s.add(.resistor, "R5", 24, 0, ["r": 470e3])
        s.add(.triode, "V2", 29, 0, model: "12AX7")
        s.add(.resistor, "R6", 30, 4, rot: 1, ["r": 820])
        s.add(.resistor, "R7", 30, -4, rot: 1, ["r": 100e3])
        s.add(.triode, "V3", 36, -2, model: "12AX7")
        s.add(.resistor, "R8", 37, 2, rot: 1, ["r": 100e3])
        s.net("C2.2", "VR1.3"); s.gnd("VR1.1")
        s.net("VR1.w", "R5.1"); s.net("R5.2", "V2.g")
        s.net("V2.k", "R6.1"); s.gnd("R6.2")
        s.net("R7.2", "V2.p"); s.rail("R7.1", 300, text: "B+ 300V")
        s.net("V2.p", "V3.g")
        s.rail("V3.p", 300, dy: -2, text: "B+ 300V")
        s.net("V3.k", "R8.1"); s.gnd("R8.2")
        toneStack(&s, from: "V3.k", sx: 39, sy: 0, slope: 33e3, treble: 470e-12, firstPot: 2, firstCap: 3, slopeR: "R9", outScale: 0.05)
        return s
    }

    /// Valve bass preamp: the British layout with every low-frequency corner moved down.
    static var bassPreampSheet: Sheet {
        var s = Sheet("Bass Tube Preamp",
                      notes: "A valve preamp voiced for bass: fully bypassed cathodes and large coupling capacitors keep the bottom octave, and the tone stack's capacitors are several times larger than a guitar amp's so Bass and Middle work an octave or two lower. It stays clean until Volume is well up, then growls.")
        firstStage(&s, bPlus: 320, rk: 1.5e3, ck: 47e-6, coupling: 47e-9)
        s.add(.pot, "VR1", 19, 0, rot: 1, flip: true, ["r": 1e6, "position": 0.55], model: "A", text: "Volume")
        s.add(.resistor, "R5", 24, 0, ["r": 100e3])
        s.add(.triode, "V2", 29, 0, model: "12AX7")
        s.add(.resistor, "R6", 30, 4, rot: 1, ["r": 1.5e3])
        s.add(.resistor, "R7", 30, -4, rot: 1, ["r": 100e3])
        s.add(.triode, "V3", 36, -2, model: "12AX7")
        s.add(.resistor, "R8", 37, 2, rot: 1, ["r": 100e3])
        s.net("C2.2", "VR1.3"); s.gnd("VR1.1")
        s.net("VR1.w", "R5.1"); s.net("R5.2", "V2.g")
        s.net("V2.k", "R6.1"); s.gnd("R6.2")
        s.net("R7.2", "V2.p"); s.rail("R7.1", 320, text: "B+ 320V")
        s.net("V2.p", "V3.g")
        s.rail("V3.p", 320, dy: -2, text: "B+ 320V")
        s.net("V3.k", "R8.1"); s.gnd("R8.2")
        toneStack(&s, from: "V3.k", sx: 39, sy: 0, slope: 56e3, treble: 470e-12, firstPot: 2, firstCap: 3, slopeR: "R9", outScale: 0.05,
                  bassCap: 100e-9, midCap: 47e-9)
        return s
    }

    /// 1980s–90s high gain: four cascaded stages with a cold-biased clipper.
    static var highGainSheet: Sheet {
        var s = Sheet("High-Gain Cascade Preamp",
                      notes: "Four 12AX7 stages in a row, as in the high-gain amps of the 1980s and 90s. The third is biased cold so it clips one side of the wave hard; dividers between stages keep each from swamping the next. Tight, saturated and compressed.")
        firstStage(&s, bPlus: 320, rk: 1.8e3, ck: 1e-6)
        s.add(.pot, "VR1", 19, 0, rot: 1, flip: true, ["r": 1e6, "position": 0.6], model: "A", text: "Gain")
        s.add(.resistor, "R5", 24, 0, ["r": 470e3])
        s.add(.triode, "V2", 29, 0, model: "12AX7")
        s.add(.resistor, "R6", 30, 4, rot: 1, ["r": 1.8e3])
        s.add(.capacitor, "C3", 32, 4, rot: 1, ["c": 1e-6])
        s.add(.resistor, "R7", 30, -4, rot: 1, ["r": 100e3])
        s.add(.capacitor, "C4", 34, -2, ["c": 22e-9])
        s.add(.resistor, "R8", 39, -2, ["r": 470e3])
        s.add(.resistor, "R9", 42, 0, rot: 1, ["r": 470e3])
        s.add(.triode, "V3", 46, -2, model: "12AX7")
        s.add(.resistor, "R10", 47, 2, rot: 1, ["r": 10e3])
        s.add(.resistor, "R11", 47, -6, rot: 1, ["r": 100e3])
        s.add(.capacitor, "C5", 51, -4, ["c": 22e-9])
        s.add(.resistor, "R12", 56, -4, ["r": 470e3])
        s.add(.resistor, "R13", 59, -2, rot: 1, ["r": 220e3])
        s.add(.triode, "V4", 63, -4, model: "12AX7")
        s.add(.resistor, "R14", 64, 0, rot: 1, ["r": 1.8e3])
        s.add(.capacitor, "C6", 66, 0, rot: 1, ["c": 1e-6])
        s.add(.resistor, "R15", 64, -8, rot: 1, ["r": 100e3])
        s.net("C2.2", "VR1.3"); s.gnd("VR1.1")
        s.net("VR1.w", "R5.1"); s.net("R5.2", "V2.g")
        s.net("V2.k", "R6.1", "C3.1"); s.gnd("R6.2"); s.gnd("C3.2")
        s.net("R7.2", "V2.p"); s.rail("R7.1", 320, text: "B+ 320V")
        s.net("V2.p", "C4.1"); s.net("C4.2", "R8.1")
        s.net("R8.2", "R9.1", "V3.g"); s.gnd("R9.2")
        s.net("V3.k", "R10.1"); s.gnd("R10.2")
        s.net("R11.2", "V3.p"); s.rail("R11.1", 320, text: "B+ 320V")
        s.net("V3.p", "C5.1"); s.net("C5.2", "R12.1")
        s.net("R12.2", "R13.1", "V4.g"); s.gnd("R13.2")
        s.net("V4.k", "R14.1", "C6.1"); s.gnd("R14.2"); s.gnd("C6.2")
        s.net("R15.2", "V4.p"); s.rail("R15.1", 320, text: "B+ 320V")
        toneStack(&s, from: "V4.p", sx: 68, sy: -6, slope: 39e3, treble: 470e-12, firstPot: 2, firstCap: 7, slopeR: "R16", outScale: 0.03)
        return s
    }

    static var sheets: [Sheet] {
        [hardClipSheet, slewDistortionSheet, germaniumFuzzSheet, sustainFuzzSheet, transistorBoostSheet, trebleBoosterSheet,
         jfetOverdriveSheet, mosfetBoostSheet, selectableClipSheet, bassBlendDriveSheet, bassPreampSheet, tweedSheet, britishSheet, highGainSheet]
    }

    /// Checks every library schematic against the connections it was drawn from. Empty when all are right.
    public static func auditLibrary() -> [String] { sheets.flatMap { $0.audit() } }
}
