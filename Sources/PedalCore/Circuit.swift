import Foundation

/// A point on the schematic grid (one unit = one grid step).
public struct GridPoint: Hashable, Codable, Sendable {
    public var x: Int
    public var y: Int
    public init(_ x: Int, _ y: Int) { self.x = x; self.y = y }
    public static func + (a: GridPoint, b: GridPoint) -> GridPoint { GridPoint(a.x + b.x, a.y + b.y) }
    public static func - (a: GridPoint, b: GridPoint) -> GridPoint { GridPoint(a.x - b.x, a.y - b.y) }
}

public enum PartKind: String, Codable, CaseIterable, Sendable {
    case resistor, capacitor, inductor, pot, diode, led, zener
    case npn, pnp, njfet, pjfet, nmos, pmos, opamp, triode
    case spst, spdt
    case ground, supply, input, output, label

    public var displayName: String {
        switch self {
        case .resistor: return "Resistor"
        case .capacitor: return "Capacitor"
        case .inductor: return "Inductor"
        case .pot: return "Potentiometer"
        case .diode: return "Diode"
        case .led: return "LED"
        case .zener: return "Zener diode"
        case .pjfet: return "P-JFET"
        case .npn: return "NPN transistor"
        case .pnp: return "PNP transistor"
        case .njfet: return "N-JFET"
        case .nmos: return "N-MOSFET"
        case .pmos: return "P-MOSFET"
        case .spst: return "Switch"
        case .spdt: return "Selector switch"
        case .opamp: return "Op-amp"
        case .triode: return "Triode (tube)"
        case .ground: return "Ground"
        case .supply: return "Supply"
        case .input: return "Guitar in"
        case .output: return "Output"
        case .label: return "Net label"
        }
    }

    /// Reference designator prefix used for automatic names and netlists.
    public var prefix: String {
        switch self {
        case .resistor: return "R"
        case .capacitor: return "C"
        case .inductor: return "L"
        case .pot: return "VR"
        case .diode, .led, .zener: return "D"
        case .npn, .pnp: return "Q"
        case .njfet, .pjfet: return "J"
        case .nmos, .pmos: return "M"
        case .spst, .spdt: return "SW"
        case .opamp: return "U"
        case .triode: return "V"
        case .ground: return "GND"
        case .supply: return "VCC"
        case .input: return "IN"
        case .output: return "OUT"
        case .label: return "NET"
        }
    }

    /// Pin positions in local grid units before rotation.
    public var localPins: [GridPoint] {
        switch self {
        case .resistor, .capacitor, .inductor, .diode, .led, .zener, .spst:
            return [GridPoint(-2, 0), GridPoint(2, 0)]
        case .spdt:
            return [GridPoint(-2, 0), GridPoint(2, -1), GridPoint(2, 1)]
        case .pot:
            return [GridPoint(-2, 0), GridPoint(2, 0), GridPoint(0, -2)]
        case .npn, .pnp, .njfet, .pjfet, .nmos, .pmos, .triode:
            return [GridPoint(1, -2), GridPoint(-2, 0), GridPoint(1, 2)]
        case .opamp:
            return [GridPoint(-2, 1), GridPoint(-2, -1), GridPoint(2, 0)]
        case .ground, .supply, .input, .output, .label:
            return [GridPoint(0, 0)]
        }
    }

    public var pinNames: [String] {
        switch self {
        case .resistor, .capacitor, .inductor: return ["1", "2"]
        case .diode, .led, .zener: return ["Anode", "Cathode"]
        case .pot: return ["End 1", "End 3", "Wiper"]
        case .npn, .pnp: return ["Collector", "Base", "Emitter"]
        case .njfet, .pjfet, .nmos, .pmos: return ["Drain", "Gate", "Source"]
        case .spst: return ["1", "2"]
        case .spdt: return ["Common", "A", "B"]
        case .triode: return ["Plate", "Grid", "Cathode"]
        case .opamp: return ["+ In", "− In", "Out"]
        default: return ["Pin"]
        }
    }

    public var defaultProps: [String: Double] {
        switch self {
        case .resistor: return ["r": 10_000]
        case .capacitor: return ["c": 100e-9]
        case .inductor: return ["l": 0.5, "rs": 50]
        case .pot: return ["r": 100_000, "position": 0.5]
        case .supply: return ["v": 9]
        case .spst: return ["state": 1]
        case .spdt: return ["state": 0]
        case .input: return ["rs": 1_000, "scale": 1]
        case .output: return ["rl": 1_000_000, "scale": 1]
        default: return [:]
        }
    }

    public var defaultModel: String {
        switch self {
        case .diode: return "1N4148"
        case .led: return "Red LED"
        case .zener: return "5.1 V (1N4733A)"
        case .pjfet: return "2N5460"
        case .npn: return "2N3904"
        case .pnp: return "2N3906"
        case .njfet: return "J201"
        case .nmos: return "2N7000"
        case .pmos: return "BS250"
        case .opamp: return "TL072"
        case .triode: return "12AX7"
        case .pot: return "B"
        default: return ""
        }
    }

    public var models: [String] {
        switch self {
        case .diode: return DeviceLibrary.diodes.keys.sorted()
        case .led: return DeviceLibrary.leds.keys.sorted()
        case .zener: return DeviceLibrary.zeners.keys.sorted { DeviceLibrary.zeners[$0]!.bv < DeviceLibrary.zeners[$1]!.bv }
        case .npn: return DeviceLibrary.bjts.filter { !$0.value.pnp }.keys.sorted()
        case .pnp: return DeviceLibrary.bjts.filter { $0.value.pnp }.keys.sorted()
        case .njfet: return DeviceLibrary.jfets.filter { !$0.value.pch }.keys.sorted()
        case .pjfet: return DeviceLibrary.jfets.filter { $0.value.pch }.keys.sorted()
        case .nmos: return DeviceLibrary.mosfets.filter { !$0.value.pmos }.keys.sorted()
        case .pmos: return DeviceLibrary.mosfets.filter { $0.value.pmos }.keys.sorted()
        case .opamp: return DeviceLibrary.opamps.keys.sorted()
        case .triode: return DeviceLibrary.triodes.keys.sorted()
        case .pot: return ["A", "B", "C"]
        default: return []
        }
    }
}

public struct Part: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var kind: PartKind
    public var name: String
    public var position: GridPoint
    public var rotation: Int  // quarter turns clockwise
    public var flipped: Bool  // mirrored left-right before rotation
    public var props: [String: Double]
    public var model: String
    /// Knob caption for pots, net name for labels.
    public var text: String

    public init(_ kind: PartKind, name: String, at p: GridPoint, rotation: Int = 0, flipped: Bool = false,
                props: [String: Double]? = nil, model: String? = nil, text: String = "") {
        self.id = UUID()
        self.kind = kind
        self.name = name
        self.position = p
        self.rotation = ((rotation % 4) + 4) % 4
        self.flipped = flipped
        self.props = kind.defaultProps.merging(props ?? [:]) { _, new in new }
        self.model = model ?? kind.defaultModel
        self.text = text
    }

    public func transform(_ p: GridPoint) -> GridPoint {
        var q = p
        if flipped { q = GridPoint(-q.x, q.y) }
        switch rotation {
        case 1: q = GridPoint(-q.y, q.x)
        case 2: q = GridPoint(-q.x, -q.y)
        case 3: q = GridPoint(q.y, -q.x)
        default: break
        }
        return q
    }

    public var pins: [GridPoint] { kind.localPins.map { position + transform($0) } }
    public func pin(_ i: Int) -> GridPoint { pins[i] }

    /// Pots with the same gang number (1 and up) share one knob; 0 means the pot has a knob to itself.
    public var gang: Int { kind == .pot ? Int(self["gang"].rounded()) : 0 }

    /// Switch position: SPST 0 = open, 1 = closed; selector 0 = A, 1 = B, 2 = centre (off).
    public var switchState: Int { Int(self["state"].rounded()) }
    public var switchStateName: String {
        if kind == .spst { return switchState == 0 ? "off" : "on" }
        return ["A", "B", "off"][min(max(switchState, 0), 2)]
    }

    public subscript(key: String) -> Double {
        get { props[key] ?? kind.defaultProps[key] ?? 0 }
        set { props[key] = newValue }
    }
}

public struct Wire: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var a: GridPoint
    public var b: GridPoint
    public init(_ a: GridPoint, _ b: GridPoint) { id = UUID(); self.a = a; self.b = b }

    /// True when p lies strictly between the ends of this straight segment.
    public func passesThrough(_ p: GridPoint) -> Bool {
        if p == a || p == b { return false }
        if a.x == b.x && p.x == a.x { return p.y > min(a.y, b.y) && p.y < max(a.y, b.y) }
        if a.y == b.y && p.y == a.y { return p.x > min(a.x, b.x) && p.x < max(a.x, b.x) }
        return false
    }
}

public struct Circuit: Codable, Hashable, Sendable {
    public var name: String
    public var parts: [Part]
    public var wires: [Wire]
    public var notes: String

    public init(name: String, parts: [Part] = [], wires: [Wire] = [], notes: String = "") {
        self.name = name; self.parts = parts; self.wires = wires; self.notes = notes
    }

    /// Pots in a stable order (by name), which is the order of the knobs.
    public var pots: [Part] {
        parts.filter { $0.kind == .pot }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// One pot per knob, in knob order: every pot that isn't ganged, and the first pot of each gang.
    public var knobs: [Part] {
        var seen = Set<Int>()
        return pots.filter { $0.gang == 0 || seen.insert($0.gang).inserted }
    }

    /// Which knob turns this pot.
    public func knobIndex(of p: Part) -> Int? {
        knobs.firstIndex { $0.id == p.id || (p.gang != 0 && $0.gang == p.gang) }
    }

    /// Indices in `parts` of every pot turned by knob `i`, the knob's own pot first.
    public func partIndices(forKnob i: Int) -> [Int] {
        let k = knobs
        guard i >= 0 && i < k.count else { return [] }
        let lead = k[i]
        return parts.indices.filter { parts[$0].id == lead.id } +
            parts.indices.filter { parts[$0].kind == .pot && parts[$0].id != lead.id && lead.gang != 0 && parts[$0].gang == lead.gang }
    }

    public func nextName(for kind: PartKind) -> String {
        let used = Set(parts.map(\.name))
        var i = 1
        while used.contains("\(kind.prefix)\(i)") { i += 1 }
        return "\(kind.prefix)\(i)"
    }

    /// Add a wire, splitting any wire whose middle it ends on so the junction connects.
    public mutating func addWire(_ a: GridPoint, _ b: GridPoint) {
        guard a != b else { return }
        for end in [a, b] {
            if let i = wires.firstIndex(where: { $0.passesThrough(end) }) {
                let w = wires.remove(at: i)
                wires.append(Wire(w.a, end))
                wires.append(Wire(end, w.b))
            }
        }
        wires.append(Wire(a, b))
    }

    /// Add an L-shaped connection (horizontal first, then vertical, unless verticalFirst).
    public mutating func connect(_ a: GridPoint, _ b: GridPoint, verticalFirst: Bool = false) {
        if a.x == b.x || a.y == b.y { addWire(a, b); return }
        let corner = verticalFirst ? GridPoint(a.x, b.y) : GridPoint(b.x, a.y)
        addWire(a, corner)
        addWire(corner, b)
    }
}

// MARK: - Netlist

/// The connectivity of a circuit: which node every pin of every part is on. Node 0 is ground.
public struct Netlist {
    public var nodeCount: Int  // including ground
    public var pinNodes: [UUID: [Int]]
    public var nodeNames: [Int: String]
    public var problems: [String]

    public static func build(_ c: Circuit) -> Netlist {
        var parent: [GridPoint: GridPoint] = [:]
        func find(_ p: GridPoint) -> GridPoint {
            var r = p
            while let q = parent[r], q != r { r = q }
            var cur = p
            while let q = parent[cur], q != r { parent[cur] = r; cur = q }
            return r
        }
        func touch(_ p: GridPoint) { if parent[p] == nil { parent[p] = p } }
        func union(_ a: GridPoint, _ b: GridPoint) {
            touch(a); touch(b)
            let ra = find(a), rb = find(b)
            if ra != rb { parent[ra] = rb }
        }
        for w in c.wires { union(w.a, w.b) }
        for p in c.parts { for pin in p.pins { touch(pin) } }
        // Wires ending on the middle of another wire join it too.
        for w in c.wires {
            for end in [w.a, w.b] {
                for other in c.wires where other.passesThrough(end) { union(end, other.a) }
            }
        }
        // A pin sitting on the middle of a wire is connected to it.
        for p in c.parts {
            for pin in p.pins {
                for w in c.wires where w.passesThrough(pin) { union(pin, w.a) }
            }
        }
        // Labels with the same text, and supplies with the same voltage, are the same net.
        var labelAnchor: [String: GridPoint] = [:]
        for p in c.parts where p.kind == .label || p.kind == .supply {
            let key = p.kind == .label ? "L:" + p.text.trimmingCharacters(in: .whitespaces).lowercased()
                                       : String(format: "S:%.6g", p["v"])
            if let a = labelAnchor[key] { union(a, p.pin(0)) } else { labelAnchor[key] = p.pin(0) }
        }
        let groundRoots = Set(c.parts.filter { $0.kind == .ground }.map { find($0.pin(0)) })
        var nodeOf: [GridPoint: Int] = [:]
        var count = 1
        var names: [Int: String] = [0: "0"]
        func node(_ p: GridPoint) -> Int {
            let r = find(p)
            if groundRoots.contains(r) { return 0 }
            if let n = nodeOf[r] { return n }
            nodeOf[r] = count; count += 1
            return count - 1
        }
        var pinNodes: [UUID: [Int]] = [:]
        for p in c.parts { pinNodes[p.id] = p.pins.map(node) }
        // Readable names: labels and supplies name their nets, then In/Out.
        for p in c.parts {
            guard let n = pinNodes[p.id]?.first, n != 0 else { continue }
            switch p.kind {
            case .label where !p.text.isEmpty: names[n] = p.text
            case .supply: if names[n] == nil { names[n] = String(format: "VCC_%gV", p["v"]).replacingOccurrences(of: ".", with: "p") }
            case .input: if names[n] == nil { names[n] = "IN" }
            case .output: if names[n] == nil { names[n] = "OUT" }
            default: break
            }
        }
        var problems: [String] = []
        if !c.parts.contains(where: { $0.kind == .input }) { problems.append("Add a Guitar in.") }
        if !c.parts.contains(where: { $0.kind == .output }) { problems.append("Add an Output.") }
        if !c.parts.contains(where: { $0.kind == .ground }) { problems.append("Add a Ground.") }
        // Pins left unconnected (only their own part touches the net).
        var pinsPerNode: [Int: Int] = [:]
        for p in c.parts { for n in pinNodes[p.id] ?? [] { pinsPerNode[n, default: 0] += 1 } }
        let dangling = c.parts.filter { p in
            guard ![.label, .ground, .supply].contains(p.kind) else { return false }
            return (pinNodes[p.id] ?? []).contains { $0 != 0 && (pinsPerNode[$0] ?? 0) < 2 }
        }
        if !dangling.isEmpty {
            problems.append("Not connected: " + dangling.prefix(6).map(\.name).joined(separator: ", ")
                            + (dangling.count > 6 ? "…" : ""))
        }
        return Netlist(nodeCount: count, pinNodes: pinNodes, nodeNames: names, problems: problems)
    }

    public func name(of node: Int) -> String { nodeNames[node] ?? "N\(node)" }
}

// MARK: - Engineering notation

public enum Eng {
    static let prefixes: [(String, Double)] = [("T", 1e12), ("G", 1e9), ("M", 1e6), ("k", 1e3), ("", 1),
                                               ("m", 1e-3), ("µ", 1e-6), ("n", 1e-9), ("p", 1e-12)]

    public static func format(_ v: Double, unit: String = "") -> String {
        if v == 0 { return "0" + unit }
        let a = abs(v)
        for (p, m) in prefixes where a >= m * 0.9999 {
            let s = v / m
            var t = String(format: s >= 100 ? "%.0f" : (s >= 10 ? "%.3g" : "%.3g"), s)
            if t.contains(".") { while t.hasSuffix("0") { t.removeLast() }; if t.hasSuffix(".") { t.removeLast() } }
            return t + p + unit
        }
        return String(format: "%.3g", v) + unit
    }

    /// Parses "4.7k", "100n", "2M2", "1u", "470pF", "250 V".
    public static func parse(_ text: String) -> Double? {
        var s = text.trimmingCharacters(in: .whitespaces)
        for unit in ["Ω", "ohm", "Ohm", "F", "H", "V", "Hz"] where s.hasSuffix(unit) && s.count > unit.count {
            s = String(s.dropLast(unit.count)).trimmingCharacters(in: .whitespaces)
        }
        if let v = Double(s) { return v }
        let map: [Character: Double] = ["T": 1e12, "G": 1e9, "M": 1e6, "k": 1e3, "K": 1e3, "R": 1, "m": 1e-3,
                                        "u": 1e-6, "µ": 1e-6, "n": 1e-9, "p": 1e-12]
        // Forms like 2M2 / 4k7 / 4R7
        for (i, ch) in s.enumerated() where map[ch] != nil {
            let head = String(s.prefix(i)), tail = String(s.dropFirst(i + 1))
            if tail.isEmpty, let h = Double(head) { return h * map[ch]! }
            if let h = Double(head), let t = Double("0." + tail), !tail.contains(".") { return (h + t) * map[ch]! }
            break
        }
        return nil
    }
}
