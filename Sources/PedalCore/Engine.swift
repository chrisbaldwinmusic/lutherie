import Accelerate
import Foundation

/// Errors raised while turning a drawing into something the solver can run.
public struct CircuitError: Error, CustomStringConvertible {
    public let description: String
    public init(_ d: String) { description = d }
}

// MARK: - Element records (plain structs so the audio loop never allocates)

struct ResistorEl { var a: Int; var b: Int; var g: Double }
struct PotEl { var a: Int; var b: Int; var w: Int; var r: Double; var taper: Int; var pos: Double; var target: Double; var knob: Int }
struct CapEl { var a: Int; var b: Int; var c: Double; var geq: Double; var vPrev: Double; var iPrev: Double }
struct IndEl { var m: Int; var b: Int; var l: Double; var geq: Double; var vPrev: Double; var iPrev: Double }
struct SupplyEl { var a: Int; var v: Double; var g: Double }
struct DiodeEl {
    var a: Int; var c: Int; var Is: Double; var nvt: Double; var vcrit: Double; var vOld: Double
    var bv = 0.0, bvt = 1.0, bcrit = 0.0, ibv = 5e-3     // reverse breakdown (zeners); bv 0 = none
}
struct BJTEl {
    var c: Int; var b: Int; var e: Int; var pol: Double
    var Is: Double; var bf: Double; var br: Double; var va: Double; var vt: Double; var vcrit: Double
    var vbeOld: Double; var vbcOld: Double
}
struct JFETEl { var d: Int; var g: Int; var s: Int; var beta: Double; var vto: Double; var lambda: Double; var pol = 1.0 }
/// MOSFET: `a` is the subthreshold slope voltage (2·n·Vt), `beta` = kp/2, `pol` +1 for N, −1 for P.
struct MOSEl { var d: Int; var g: Int; var s: Int; var pol: Double; var beta: Double; var vto: Double; var lambda: Double; var a: Double }
struct TriodeEl {
    var p: Int; var g: Int; var k: Int
    var mu: Double; var ex: Double; var kg1: Double; var kp: Double; var kvb: Double
    var vgkOld: Double; var vpkOld: Double
}
struct PentodeEl {
    var p: Int; var g: Int; var k: Int; var s: Int
    var mu: Double; var ex: Double; var kg1: Double; var kg2: Double; var kp: Double; var kvb: Double
    var vgOld: Double; var vpOld: Double; var vsOld: Double
}
/// Three magnetically coupled windings (an output transformer). `gamma` is the inverse of the inductance matrix,
/// row by row; each winding runs from a to b.
struct XfmrEl {
    var a: (Int, Int, Int); var b: (Int, Int, Int)
    var gamma: (Double, Double, Double, Double, Double, Double, Double, Double, Double)
    var iPrev: (Double, Double, Double) = (0, 0, 0); var vPrev: (Double, Double, Double) = (0, 0, 0)
    @inline(__always) func na(_ i: Int) -> Int { i == 0 ? a.0 : (i == 1 ? a.1 : a.2) }
    @inline(__always) func nb(_ i: Int) -> Int { i == 0 ? b.0 : (i == 1 ? b.1 : b.2) }
    @inline(__always) func gm(_ i: Int, _ j: Int) -> Double {
        switch i * 3 + j {
        case 0: return gamma.0; case 1: return gamma.1; case 2: return gamma.2
        case 3: return gamma.3; case 4: return gamma.4; case 5: return gamma.5
        case 6: return gamma.6; case 7: return gamma.7; default: return gamma.8
        }
    }
}
struct OpAmpEl {
    var inP: Int; var inN: Int; var m: Int; var out: Int
    var gm: Double; var iMax: Double; var mid: Double; var half: Double; var gout: Double; var vClamp: Double
}

@inline(__always) func softplus(_ u: Double) -> Double { u > 30 ? u : (u < -30 ? exp(u) : log1p(exp(u))) }
@inline(__always) func sigmoid(_ u: Double) -> Double { 1 / (1 + exp(-u)) }
/// softplus and its derivative (the logistic function) from one exponential
@inline(__always) func softplusPair(_ u: Double) -> (Double, Double) {
    if u > 30 { return (u, 1) }
    let e = exp(u)
    if u < -30 { return (e, e) }
    return (log1p(e), e / (1 + e))
}
@inline(__always) func limexp(_ x: Double) -> (Double, Double) {
    // exp with a linear continuation above 80 so huge steps can't overflow
    if x < 80 { let e = exp(x); return (e, e) }
    let e = exp(80.0); return (e * (1 + x - 80), e)
}
@inline(__always) func pnjlim(_ vnew: Double, _ vold: Double, _ vt: Double, _ vcrit: Double) -> Double {
    if vnew > vcrit && abs(vnew - vold) > 2 * vt {
        if vold > 0 {
            let arg = 1 + (vnew - vold) / vt
            return arg > 0 ? vold + vt * log(arg) : vcrit
        }
        return vt * log(max(vnew / vt, 1e-30))
    }
    return vnew
}

/// Modified nodal analysis solver for one circuit: Newton–Raphson on every sample,
/// trapezoidal integration for capacitors and inductors, physical device models.
public final class CircuitEngine {
    public let circuit: Circuit
    public let sampleRate: Double
    public let dt: Double
    public let n: Int
    public let netlist: Netlist
    public private(set) var potNames: [String] = []
    public private(set) var potLabels: [String] = []
    public private(set) var potIDs: [UUID] = []
    public private(set) var nonConverged = 0
    public private(set) var warnings: [String] = []

    var resistors: [ResistorEl] = []
    var pots: UnsafeMutableBufferPointer<PotEl>
    var caps: UnsafeMutableBufferPointer<CapEl>
    var inds: UnsafeMutableBufferPointer<IndEl>
    var supplies: [SupplyEl] = []
    var diodes: UnsafeMutableBufferPointer<DiodeEl>
    var bjts: UnsafeMutableBufferPointer<BJTEl>
    var jfets: UnsafeMutableBufferPointer<JFETEl>
    var mosfets: UnsafeMutableBufferPointer<MOSEl>
    var pentodes: UnsafeMutableBufferPointer<PentodeEl>
    var xfmrs: UnsafeMutableBufferPointer<XfmrEl>
    var triodes: UnsafeMutableBufferPointer<TriodeEl>
    var opamps: UnsafeMutableBufferPointer<OpAmpEl>

    var inputNode = -1
    var inputG = 1e-3
    var inputScale = 1.0
    var outputNode = -1
    var outputScale = 1.0
    var outputG = 1e-6
    let gmin = 1e-12

    let G0: UnsafeMutablePointer<Double>
    let A: UnsafeMutablePointer<Double>
    let rhs0: UnsafeMutablePointer<Double>
    let rhs: UnsafeMutablePointer<Double>
    let x: UnsafeMutablePointer<Double>
    let perm: UnsafeMutablePointer<Int>
    var linear: Bool

    // Reduced solve. Unknowns are ordered with the nodes that only touch linear parts first (0..<nl)
    // and the nodes of nonlinear devices last (nl..<n). The linear block is eliminated once (whenever a
    // knob moves), so each Newton iteration only factors the small ns×ns nonlinear block.
    public let nl: Int
    public let ns: Int
    let nodeMap: [Int]                       // netlist node - 1 → index in x
    let K: UnsafeMutablePointer<Double>      // ns×ns  Schur complement of the linear block
    let As: UnsafeMutablePointer<Double>     // ns×ns  working Jacobian
    let rS: UnsafeMutablePointer<Double>     // ns     reduced right-hand side for this step
    let bS: UnsafeMutablePointer<Double>     // ns     working right-hand side
    let Minv: UnsafeMutablePointer<Double>   // nl×nl  inverse of the linear block
    let Y: UnsafeMutablePointer<Double>      // nl×ns  Minv · (linear→nonlinear coupling)
    let zL: UnsafeMutablePointer<Double>     // nl
    let LLw: UnsafeMutablePointer<Double>    // nl×nl  scratch for the factorisation
    let permS: UnsafeMutablePointer<Int>
    let LUs: UnsafeMutablePointer<Double>    // ns×ns  scratch for timing tests
    /// Stop iterating once the next Newton step is predicted to be below the tolerance.
    public var earlyExit = true
    /// Factorisations so far (for performance checks).
    public private(set) var factorCount = 0
    let permL: UnsafeMutablePointer<Int>
    var reducedValid = false
    let xPrev: UnsafeMutablePointer<Double>  // ns     nonlinear-node voltages of the previous sample
    /// Start each sample's Newton solve from a straight-line extrapolation of the last two samples.
    public var predictor = true
    /// Newton stops when the largest voltage update is below this (relative to 1 V + the node voltage).
    public var tolerance = 1e-6
    /// Testing aid: solve the whole matrix on every iteration (the original method) instead of the reduced one.
    public var useFullSolver = false
    /// Total Newton iterations so far (for performance checks).
    public private(set) var iterationCount = 0
    // where stampNonlinear writes: the full matrix, or the reduced block
    var sA: UnsafeMutablePointer<Double>
    var sR: UnsafeMutablePointer<Double>
    var sStride = 0
    var sOff = 0
    var luValid = false
    var dcMode = false
    var sourceScale = 1.0
    var dvLimit = 1e9
    var maxSupply = 9.0
    var potsDirty = false
    public var maxIterations = 40

    // MARK: Build

    public init(circuit: Circuit, sampleRate: Double) throws {
        self.circuit = circuit
        self.sampleRate = sampleRate
        self.dt = 1 / sampleRate
        let net = Netlist.build(circuit)
        self.netlist = net
        if let p = net.problems.first(where: { $0.hasPrefix("Add") }) { throw CircuitError(p) }

        var nextIndex = net.nodeCount - 1
        func idx(_ node: Int) -> Int { node - 1 }  // ground (0) becomes -1
        func newInternal() -> Int { nextIndex += 1; return nextIndex - 1 }

        var potList: [PotEl] = [], capList: [CapEl] = [], indList: [IndEl] = []
        var diodeList: [DiodeEl] = [], bjtList: [BJTEl] = [], jfetList: [JFETEl] = []
        var triodeList: [TriodeEl] = [], opList: [OpAmpEl] = [], mosList: [MOSEl] = []
        var pentList: [PentodeEl] = [], xfList: [XfmrEl] = []
        var warn: [String] = []
        let vt = 0.025852
        var resList: [ResistorEl] = [], supList: [SupplyEl] = []
        var inNode = -1, inG = 1e-3, inScale = 1.0, outNode = -1, outG = 1e-6, outScale = 1.0
        let vmax = max(1, circuit.parts.filter { $0.kind == .supply }.map { abs($0["v"]) }.max() ?? 9)

        func addCap(_ a: Int, _ b: Int, _ c: Double) {
            if c > 0 && a != b { capList.append(CapEl(a: a, b: b, c: c, geq: 0, vPrev: 0, iPrev: 0)) }
        }
        func addDiode(_ a: Int, _ c: Int, _ m: DiodeModel) {
            var anode = a
            if m.rs > 1e-6 {
                let inner = newInternal()
                resList.append(ResistorEl(a: a, b: inner, g: 1 / m.rs))
                anode = inner
            }
            let nvt = m.n * vt
            var el = DiodeEl(a: anode, c: c, Is: m.Is, nvt: nvt, vcrit: nvt * log(nvt / (sqrt(2) * m.Is)), vOld: 0)
            if m.bv > 0 { el.bv = m.bv; el.ibv = m.ibv; el.bvt = m.nbv * vt; el.bcrit = el.bvt * log(el.bvt / (sqrt(2) * m.ibv)) }
            diodeList.append(el)
            addCap(a, c, m.cj)
        }

        let orderedPots = circuit.pots
        let knobParts = circuit.knobs
        for p in circuit.parts {
            let nodes = (net.pinNodes[p.id] ?? []).map(idx)
            switch p.kind {
            case .resistor:
                let r = max(p["r"], 1e-3)
                if nodes[0] != nodes[1] { resList.append(ResistorEl(a: nodes[0], b: nodes[1], g: 1 / r)) }
            case .capacitor:
                addCap(nodes[0], nodes[1], p["c"])
            case .inductor:
                let m = newInternal()
                resList.append(ResistorEl(a: nodes[0], b: m, g: 1 / max(p["rs"], 1e-3)))
                indList.append(IndEl(m: m, b: nodes[1], l: max(p["l"], 1e-9), geq: 0, vPrev: 0, iPrev: 0))
            case .pot:
                let taper = ["A": 1, "B": 0, "C": 2][p.model] ?? 0
                // ganged pots follow the position of the pot that owns the knob
                let knob = circuit.knobIndex(of: p) ?? 0
                let pos = min(max(knobParts[knob]["position"], 0), 1)
                potList.append(PotEl(a: nodes[0], b: nodes[1], w: nodes[2], r: max(p["r"], 2), taper: taper, pos: pos, target: pos, knob: knob))
            case .diode, .led:
                addDiode(nodes[0], nodes[1], DeviceLibrary.diode(p.model, led: p.kind == .led))
            case .zener:
                addDiode(nodes[0], nodes[1], DeviceLibrary.zener(p.model))
            case .npn, .pnp:
                let m = DeviceLibrary.bjt(p.model, pnp: p.kind == .pnp)
                let bvt = m.nf * vt
                bjtList.append(BJTEl(c: nodes[0], b: nodes[1], e: nodes[2], pol: m.pnp ? -1 : 1, Is: m.Is, bf: m.bf,
                                     br: m.br, va: m.va, vt: bvt, vcrit: bvt * log(bvt / (sqrt(2) * m.Is)),
                                     vbeOld: 0.6, vbcOld: -1))
                addCap(nodes[1], nodes[2], m.cbe)
                addCap(nodes[1], nodes[0], m.cbc)
            case .njfet, .pjfet:
                let m = DeviceLibrary.jfet(p.model, pch: p.kind == .pjfet)
                jfetList.append(JFETEl(d: nodes[0], g: nodes[1], s: nodes[2], beta: m.beta, vto: m.vto, lambda: m.lambda, pol: m.pch ? -1 : 1))
                let gate = DiodeModel(Is: 1e-14, n: 1, rs: 0, cj: 0)
                if m.pch { addDiode(nodes[2], nodes[1], gate); addDiode(nodes[0], nodes[1], gate) }
                else { addDiode(nodes[1], nodes[2], gate); addDiode(nodes[1], nodes[0], gate) }
                addCap(nodes[1], nodes[2], m.cgs)
                addCap(nodes[1], nodes[0], m.cgd)
            case .nmos, .pmos:
                let m = DeviceLibrary.mosfet(p.model, pmos: p.kind == .pmos)
                mosList.append(MOSEl(d: nodes[0], g: nodes[1], s: nodes[2], pol: m.pmos ? -1 : 1, beta: m.kp / 2, vto: m.vto,
                                     lambda: m.lambda, a: 2 * 1.4 * vt))
                // The body is tied to the source inside the package, which leaves a diode from source to drain.
                let body = DiodeModel(Is: 1e-13, n: 1, rs: 0, cj: 0)
                if m.pmos { addDiode(nodes[0], nodes[2], body) } else { addDiode(nodes[2], nodes[0], body) }
                addCap(nodes[1], nodes[2], m.cgs)
                addCap(nodes[1], nodes[0], m.cgd)
            case .spst:
                if p.switchState != 0 && nodes[0] != nodes[1] { resList.append(ResistorEl(a: nodes[0], b: nodes[1], g: 1 / 0.05)) }
            case .spdt:
                let to = p.switchState == 0 ? nodes[1] : (p.switchState == 1 ? nodes[2] : nodes[0])
                if to != nodes[0] { resList.append(ResistorEl(a: nodes[0], b: to, g: 1 / 0.05)) }
            case .triode:
                let m = DeviceLibrary.triode(p.model)
                triodeList.append(TriodeEl(p: nodes[0], g: nodes[1], k: nodes[2], mu: m.mu, ex: m.ex, kg1: m.kg1, kp: m.kp,
                                           kvb: m.kvb, vgkOld: -1, vpkOld: 100))
                addCap(nodes[1], nodes[0], m.cgp)
                addCap(nodes[1], nodes[2], m.cgk)
                addCap(nodes[0], nodes[2], m.cpk)
            case .pentode:
                let m = DeviceLibrary.pentode(p.model)
                pentList.append(PentodeEl(p: nodes[0], g: nodes[1], k: nodes[2], s: nodes[3], mu: m.mu, ex: m.ex, kg1: m.kg1, kg2: m.kg2,
                                          kp: m.kp, kvb: m.kvb, vgOld: -20, vpOld: 300, vsOld: 300))
                addCap(nodes[1], nodes[2], m.cgk)
                addCap(nodes[1], nodes[0], m.cgp)
                addCap(nodes[0], nodes[2], m.cpk)
            case .transformer:
                // two primary halves and a secondary on one core, each winding running "downwards" on the drawing
                let ratio = sqrt(max(p["zpp"], 1) / max(p["zs"], 0.1))          // whole primary : secondary turns
                let lh = max(p["lp"], 0.01) / 4, ls = max(p["lp"], 0.01) / (ratio * ratio)
                let k = min(max(p["k"], 0), 0.99999)
                let l = [lh, lh, ls]
                var L = [Double](repeating: 0, count: 9)
                for i in 0..<3 { for j in 0..<3 { L[i * 3 + j] = i == j ? l[i] : k * sqrt(l[i] * l[j]) } }
                let det = L[0] * (L[4] * L[8] - L[5] * L[7]) - L[1] * (L[3] * L[8] - L[5] * L[6]) + L[2] * (L[3] * L[7] - L[4] * L[6])
                let g = [(L[4] * L[8] - L[5] * L[7]) / det, (L[2] * L[7] - L[1] * L[8]) / det, (L[1] * L[5] - L[2] * L[4]) / det,
                         (L[5] * L[6] - L[3] * L[8]) / det, (L[0] * L[8] - L[2] * L[6]) / det, (L[2] * L[3] - L[0] * L[5]) / det,
                         (L[3] * L[7] - L[4] * L[6]) / det, (L[1] * L[6] - L[0] * L[7]) / det, (L[0] * L[4] - L[1] * L[3]) / det]
                let p1 = newInternal(), p2 = newInternal(), s1 = newInternal()
                resList.append(ResistorEl(a: nodes[0], b: p1, g: 2 / max(p["rp"], 1e-3)))
                resList.append(ResistorEl(a: p2, b: nodes[2], g: 2 / max(p["rp"], 1e-3)))
                resList.append(ResistorEl(a: nodes[3], b: s1, g: 1 / max(p["rsec"], 1e-3)))
                xfList.append(XfmrEl(a: (p1, nodes[1], s1), b: (nodes[1], p2, nodes[4]),
                                     gamma: (g[0], g[1], g[2], g[3], g[4], g[5], g[6], g[7], g[8])))
            case .opamp:
                let m = DeviceLibrary.opamp(p.model)
                let vneg = p.props["vneg"] ?? 0, vpos = p.props["vpos"] ?? vmax
                let lo = vneg + m.headroom, hi = max(lo + 0.1, vpos - m.headroom)
                let inner = newInternal()
                let r1 = 1e6
                let gm = m.gain / r1
                let fp = m.gbw / m.gain
                let c1 = 1 / (2 * Double.pi * fp * r1)
                resList.append(ResistorEl(a: inner, b: -1, g: 1 / r1))
                addCap(inner, -1, c1)
                let half = (hi - lo) / 2
                opList.append(OpAmpEl(inP: nodes[0], inN: nodes[1], m: inner, out: nodes[2], gm: gm,
                                      iMax: m.slew * 1e6 * c1, mid: (hi + lo) / 2, half: half,
                                      gout: 1 / max(m.rout, 0.1), vClamp: 2.5 * half))
            case .supply:
                // "rs" is the supply's own resistance: tens of ohms with a reservoir capacitor makes a rail that sags
                if nodes[0] >= 0 { supList.append(SupplyEl(a: nodes[0], v: p["v"], g: 1 / max(p["rs"], 1e-3))) }
            case .input:
                inNode = nodes[0]
                inG = 1 / max(p["rs"], 1)
                inScale = p["scale"]
            case .output:
                outNode = nodes[0]
                outG = 1 / max(p["rl"], 1)
                outScale = p["scale"]
            case .ground, .label:
                break
            }
        }
        // Several supply symbols on one net are one source.
        var seen = Set<Int>()
        supList = supList.filter { seen.insert($0.a).inserted }
        if inNode < 0 { warn.append("The guitar input is connected straight to ground.") }
        if outNode < 0 { warn.append("The output is connected straight to ground.") }

        n = nextIndex
        guard n > 0 else { throw CircuitError("The circuit has no nodes yet.") }
        guard n <= 400 else { throw CircuitError("The circuit is too large (\(n) nodes).") }

        // Order the unknowns: linear-only nodes first, nodes touched by a nonlinear device last.
        let total = nextIndex
        var isNL = [Bool](repeating: false, count: total)
        func mark(_ i: Int) { if i >= 0 { isNL[i] = true } }
        for d in diodeList { mark(d.a); mark(d.c) }
        for q in bjtList { mark(q.c); mark(q.b); mark(q.e) }
        for j in jfetList { mark(j.d); mark(j.g); mark(j.s) }
        for q in mosList { mark(q.d); mark(q.g); mark(q.s) }
        for q in pentList { mark(q.p); mark(q.g); mark(q.k); mark(q.s) }
        for t in triodeList { mark(t.p); mark(t.g); mark(t.k) }
        for o in opList { mark(o.inP); mark(o.inN); mark(o.m); mark(o.out) }
        let linCount = isNL.filter { !$0 }.count
        var map = [Int](repeating: 0, count: total)
        var li = 0, si = linCount
        for i in 0..<total { if isNL[i] { map[i] = si; si += 1 } else { map[i] = li; li += 1 } }
        func m(_ i: Int) -> Int { i < 0 ? -1 : map[i] }
        resList = resList.map { ResistorEl(a: m($0.a), b: m($0.b), g: $0.g) }
        supList = supList.map { SupplyEl(a: m($0.a), v: $0.v, g: $0.g) }
        for i in potList.indices { potList[i].a = m(potList[i].a); potList[i].b = m(potList[i].b); potList[i].w = m(potList[i].w) }
        for i in capList.indices { capList[i].a = m(capList[i].a); capList[i].b = m(capList[i].b) }
        for i in indList.indices { indList[i].m = m(indList[i].m); indList[i].b = m(indList[i].b) }
        for i in diodeList.indices { diodeList[i].a = m(diodeList[i].a); diodeList[i].c = m(diodeList[i].c) }
        for i in bjtList.indices { bjtList[i].c = m(bjtList[i].c); bjtList[i].b = m(bjtList[i].b); bjtList[i].e = m(bjtList[i].e) }
        for i in jfetList.indices { jfetList[i].d = m(jfetList[i].d); jfetList[i].g = m(jfetList[i].g); jfetList[i].s = m(jfetList[i].s) }
        for i in pentList.indices { pentList[i].p = m(pentList[i].p); pentList[i].g = m(pentList[i].g); pentList[i].k = m(pentList[i].k); pentList[i].s = m(pentList[i].s) }
        for i in xfList.indices {
            let t = xfList[i]
            xfList[i].a = (m(t.a.0), m(t.a.1), m(t.a.2)); xfList[i].b = (m(t.b.0), m(t.b.1), m(t.b.2))
        }
        for i in mosList.indices { mosList[i].d = m(mosList[i].d); mosList[i].g = m(mosList[i].g); mosList[i].s = m(mosList[i].s) }
        for i in triodeList.indices { triodeList[i].p = m(triodeList[i].p); triodeList[i].g = m(triodeList[i].g); triodeList[i].k = m(triodeList[i].k) }
        for i in opList.indices {
            opList[i].inP = m(opList[i].inP); opList[i].inN = m(opList[i].inN)
            opList[i].m = m(opList[i].m); opList[i].out = m(opList[i].out)
        }
        inNode = m(inNode); outNode = m(outNode)
        nl = linCount
        ns = total - linCount
        nodeMap = map

        resistors = resList; supplies = supList
        inputNode = inNode; inputG = inG; inputScale = inScale
        outputNode = outNode; outputG = outG; outputScale = outScale
        maxSupply = vmax
        potNames = knobParts.map(\.name)
        potLabels = knobParts.map { $0.text.isEmpty ? $0.name : $0.text }
        potIDs = knobParts.map(\.id)
        knobCount = knobParts.count
        // keep pot records in knob order
        let potOrder = Dictionary(uniqueKeysWithValues: orderedPots.enumerated().map { ($1.id, $0) })
        let potsByPart = circuit.parts.filter { $0.kind == .pot }
        var sortedPots = Array(repeating: PotEl(a: -1, b: -1, w: -1, r: 1, taper: 0, pos: 0, target: 0, knob: 0), count: potList.count)
        for (i, part) in potsByPart.enumerated() { sortedPots[potOrder[part.id]!] = potList[i] }

        func buffer<T>(_ a: [T]) -> UnsafeMutableBufferPointer<T> {
            let p = UnsafeMutableBufferPointer<T>.allocate(capacity: max(a.count, 1))
            _ = p.initialize(from: a)
            return UnsafeMutableBufferPointer(rebasing: p[0..<a.count])
        }
        pots = buffer(sortedPots); caps = buffer(capList); inds = buffer(indList)
        diodes = buffer(diodeList); bjts = buffer(bjtList); jfets = buffer(jfetList)
        triodes = buffer(triodeList); opamps = buffer(opList); mosfets = buffer(mosList)
        pentodes = buffer(pentList); xfmrs = buffer(xfList)
        linear = pentList.isEmpty && mosList.isEmpty && diodeList.isEmpty && bjtList.isEmpty && jfetList.isEmpty && triodeList.isEmpty && opList.isEmpty

        G0 = .allocate(capacity: n * n); A = .allocate(capacity: n * n)
        rhs0 = .allocate(capacity: n); rhs = .allocate(capacity: n); x = .allocate(capacity: n)
        perm = .allocate(capacity: n)
        x.initialize(repeating: 0, count: n)
        K = .allocate(capacity: max(ns * ns, 1)); As = .allocate(capacity: max(ns * ns, 1))
        rS = .allocate(capacity: max(ns, 1)); bS = .allocate(capacity: max(ns, 1))
        Minv = .allocate(capacity: max(nl * nl, 1)); Y = .allocate(capacity: max(nl * ns, 1))
        zL = .allocate(capacity: max(nl, 1)); LLw = .allocate(capacity: max(nl * nl, 1))
        permS = .allocate(capacity: max(ns, 1)); permL = .allocate(capacity: max(nl, 1))
        LUs = .allocate(capacity: max(ns * ns, 1))
        sA = A; sR = rhs; sStride = n; sOff = 0
        xPrev = .allocate(capacity: max(ns, 1)); xPrev.initialize(repeating: 0, count: max(ns, 1))
        warnings = warn + net.problems.filter { !$0.hasPrefix("Add") }
        dvLimit = max(0.5, vmax * 0.05)
        try solveOperatingPoint()
    }

    deinit {
        for b in [UnsafeMutableRawPointer(pots.baseAddress), UnsafeMutableRawPointer(caps.baseAddress),
                  UnsafeMutableRawPointer(inds.baseAddress), UnsafeMutableRawPointer(diodes.baseAddress),
                  UnsafeMutableRawPointer(bjts.baseAddress), UnsafeMutableRawPointer(jfets.baseAddress),
                  UnsafeMutableRawPointer(triodes.baseAddress), UnsafeMutableRawPointer(opamps.baseAddress),
                  UnsafeMutableRawPointer(mosfets.baseAddress), UnsafeMutableRawPointer(pentodes.baseAddress),
                  UnsafeMutableRawPointer(xfmrs.baseAddress)] {
            b?.deallocate()
        }
        G0.deallocate(); A.deallocate(); rhs0.deallocate(); rhs.deallocate(); x.deallocate(); perm.deallocate()
        K.deallocate(); As.deallocate(); rS.deallocate(); bS.deallocate(); Minv.deallocate(); Y.deallocate()
        LUs.deallocate(); xPrev.deallocate(); zL.deallocate(); LLw.deallocate(); permS.deallocate(); permL.deallocate()
    }

    // MARK: Stamping helpers

    @inline(__always) func addG(_ m: UnsafeMutablePointer<Double>, _ i: Int, _ j: Int, _ g: Double) {
        if i >= 0 && j >= 0 { m[i * n + j] += g }
    }
    @inline(__always) func conductance(_ m: UnsafeMutablePointer<Double>, _ a: Int, _ b: Int, _ g: Double) {
        addG(m, a, a, g); addG(m, b, b, g); addG(m, a, b, -g); addG(m, b, a, -g)
    }
    @inline(__always) func v(_ i: Int) -> Double { i >= 0 ? x[i] : 0 }
    // Nonlinear stamps go to whichever system is being solved (full matrix or reduced block).
    @inline(__always) func inject(_ i: Int, _ cur: Double) { if i >= 0 { sR[i - sOff] += cur } }
    @inline(__always) func nlG(_ i: Int, _ j: Int, _ g: Double) {
        if i >= 0 && j >= 0 { sA[(i - sOff) * sStride + (j - sOff)] += g }
    }
    @inline(__always) func nlConductance(_ a: Int, _ b: Int, _ g: Double) {
        nlG(a, a, g); nlG(b, b, g); nlG(a, b, -g); nlG(b, a, -g)
    }
    @inline(__always) func targetFull() { sA = A; sR = rhs; sStride = n; sOff = 0 }
    @inline(__always) func targetReduced() { sA = As; sR = bS; sStride = ns; sOff = nl }

    /// The linear part of the matrix: resistors, pots, companion conductances, sources' internal resistance.
    func stampLinear() {
        G0.update(repeating: 0, count: n * n)
        for i in 0..<n { G0[i * n + i] = gmin }
        for r in resistors { conductance(G0, r.a, r.b, r.g) }
        for i in pots.indices {
            let p = pots[i]
            let t = DeviceLibrary.taper(index: p.taper, p.pos)
            conductance(G0, p.a, p.w, 1 / max(p.r * t, 0.5))
            conductance(G0, p.w, p.b, 1 / max(p.r * (1 - t), 0.5))
        }
        for i in caps.indices {
            caps[i].geq = dcMode ? 0 : 2 * caps[i].c / dt
            conductance(G0, caps[i].a, caps[i].b, caps[i].geq)
        }
        for i in inds.indices {
            inds[i].geq = dcMode ? 1e3 : dt / (2 * inds[i].l)
            conductance(G0, inds[i].m, inds[i].b, inds[i].geq)
        }
        for t in xfmrs {
            for i in 0..<3 {
                for j in 0..<3 {
                    let g = dcMode ? (i == j ? 1e3 : 0) : 0.5 * dt * t.gm(i, j)
                    if g == 0 { continue }
                    addG(G0, t.na(i), t.na(j), g); addG(G0, t.nb(i), t.nb(j), g)
                    addG(G0, t.na(i), t.nb(j), -g); addG(G0, t.nb(i), t.na(j), -g)
                }
            }
        }
        for s in supplies { addG(G0, s.a, s.a, s.g) }
        if inputNode >= 0 { addG(G0, inputNode, inputNode, inputG) }
        if outputNode >= 0 { addG(G0, outputNode, outputNode, outputG) }
        for o in opamps { addG(G0, o.out, o.out, o.gout) }
        luValid = false
        if !dcMode && !linear { reduce() } else { reducedValid = false }
    }

    /// Eliminates the linear-only nodes from G0: afterwards a time step needs one small matrix–vector
    /// product for them, and Newton iterates on the ns nonlinear nodes alone. No allocation (audio-thread safe).
    func reduce() {
        let l = nl, s = ns
        reducedValid = false
        if l > 0 {
            for i in 0..<l { for j in 0..<l { LLw[i * l + j] = G0[i * n + j] } }
            guard CircuitEngine.luFactor(LLw, l, permL) else { return }
            // explicit inverse, one unit vector at a time (column c of Minv)
            for c in 0..<l {
                for i in 0..<l { zL[i] = i == c ? 1 : 0 }
                CircuitEngine.luSolve(LLw, l, permL, zL)
                for i in 0..<l { Minv[i * l + c] = zL[i] }
            }
            // Y = Minv · G0[L,S]
            for i in 0..<l {
                let row = Minv + i * l
                for j in 0..<s {
                    var acc = 0.0
                    for k in 0..<l { acc += row[k] * G0[k * n + l + j] }
                    Y[i * s + j] = acc
                }
            }
        }
        // K = G0[S,S] − G0[S,L] · Y
        for i in 0..<s {
            let gRow = G0 + (l + i) * n
            for j in 0..<s {
                var acc = gRow[l + j]
                for k in 0..<l { acc -= gRow[k] * Y[k * s + j] }
                K[i * s + j] = acc
            }
        }
        reducedValid = true
    }

    /// Right-hand side for this time step before the nonlinear devices: history currents and sources.
    @inline(__always) func buildRHS(_ u: Double) {
        rhs0.update(repeating: 0, count: n)
        if !dcMode {
            for i in caps.indices {
                let c = caps[i]
                let ieq = c.geq * c.vPrev + c.iPrev
                if c.a >= 0 { rhs0[c.a] += ieq }
                if c.b >= 0 { rhs0[c.b] -= ieq }
            }
            for i in inds.indices {
                let l = inds[i]
                let ieq = l.iPrev + l.geq * l.vPrev
                if l.m >= 0 { rhs0[l.m] -= ieq }
                if l.b >= 0 { rhs0[l.b] += ieq }
            }
            for t in xfmrs {
                for i in 0..<3 {
                    let pi = i == 0 ? t.iPrev.0 : (i == 1 ? t.iPrev.1 : t.iPrev.2)
                    let ieq = pi + 0.5 * dt * (t.gm(i, 0) * t.vPrev.0 + t.gm(i, 1) * t.vPrev.1 + t.gm(i, 2) * t.vPrev.2)
                    if t.na(i) >= 0 { rhs0[t.na(i)] -= ieq }
                    if t.nb(i) >= 0 { rhs0[t.nb(i)] += ieq }
                }
            }
        }
        for s in supplies { rhs0[s.a] += s.v * s.g * sourceScale }
        if inputNode >= 0 { rhs0[inputNode] += u * inputScale * inputG * sourceScale }
    }

    /// Adds every nonlinear device, linearised around the present guess x.
    @inline(__always) func stampNonlinear() {
        // Diodes
        for i in diodes.indices {
            var d = diodes[i]
            var vd = v(d.a) - v(d.c)
            if d.bv > 0 && vd < -0.5 * d.bv {
                // in breakdown the same step limiting applies to the voltage past the knee
                vd = -(pnjlim(-(vd + d.bv), -(d.vOld + d.bv), d.bvt, d.bcrit) + d.bv)
            } else {
                vd = pnjlim(vd, d.vOld, d.nvt, d.vcrit)
            }
            d.vOld = vd
            diodes[i] = d
            let (e, de) = limexp(vd / d.nvt)
            var id = d.Is * (e - 1) + gmin * vd
            var gd = d.Is * de / d.nvt + gmin
            if d.bv > 0 {
                let (eb, deb) = limexp(-(vd + d.bv) / d.bvt)
                id -= d.ibv * eb
                gd += d.ibv * deb / d.bvt
            }
            nlConductance(d.a, d.c, gd)
            let ieq = id - gd * vd
            inject(d.a, -ieq); inject(d.c, ieq)
        }
        // Bipolar transistors (Ebers–Moll transport model with Early effect)
        for i in bjts.indices {
            var q = bjts[i]
            let p = q.pol
            var vbe = p * (v(q.b) - v(q.e)), vbc = p * (v(q.b) - v(q.c))
            vbe = pnjlim(vbe, q.vbeOld, q.vt, q.vcrit)
            vbc = pnjlim(vbc, q.vbcOld, q.vt, q.vcrit)
            q.vbeOld = vbe; q.vbcOld = vbc
            bjts[i] = q
            let (ef, def) = limexp(vbe / q.vt), (er, der) = limexp(vbc / q.vt)
            let iF = q.Is * (ef - 1), iR = q.Is * (er - 1)
            let gf = q.Is * def / q.vt + gmin, gr = q.Is * der / q.vt + gmin
            var k = 1 - vbc / q.va
            var dk = -1 / q.va
            if k < 0.05 { k = 0.05; dk = 0 }
            let ic = (iF - iR) * k - iR / q.br
            let ib = iF / q.bf + iR / q.br
            let dic_dvbe = gf * k
            let dic_dvbc = -gr * k + (iF - iR) * dk - gr / q.br
            let dib_dvbe = gf / q.bf
            let dib_dvbc = gr / q.br
            // actual-polarity currents into collector and base; controlling voltages vbe=(b,e), vbc=(b,c)
            let icA = p * ic, ibA = p * ib
            let vbeA = p * vbe, vbcA = p * vbc
            stamp3(q.c, i0: icA, g1: dic_dvbe, c1p: q.b, c1n: q.e, v1: vbeA, g2: dic_dvbc, c2p: q.b, c2n: q.c, v2: vbcA)
            stamp3(q.b, i0: ibA, g1: dib_dvbe, c1p: q.b, c1n: q.e, v1: vbeA, g2: dib_dvbc, c2p: q.b, c2n: q.c, v2: vbcA)
            stamp3(q.e, i0: -(icA + ibA), g1: -(dic_dvbe + dib_dvbe), c1p: q.b, c1n: q.e, v1: vbeA,
                   g2: -(dic_dvbc + dib_dvbc), c2p: q.b, c2n: q.c, v2: vbcA)
        }
        // JFETs (Shichman–Hodges, symmetric drain/source)
        for i in jfets.indices {
            let j = jfets[i]
            var d = j.d, s = j.s
            if j.pol * (v(d) - v(s)) < 0 { swap(&d, &s) }
            let vgsA = v(j.g) - v(s), vdsA = v(d) - v(s)
            let vgs = j.pol * vgsA, vds = j.pol * vdsA
            let vov = vgs - j.vto
            var id = 0.0, gm = 0.0, gds = 0.0
            if vov > 0 {
                let lam = 1 + j.lambda * vds
                if vds < vov {
                    id = j.beta * vds * (2 * vov - vds) * lam
                    gm = 2 * j.beta * vds * lam
                    gds = j.beta * (2 * vov - 2 * vds) * lam + j.beta * vds * (2 * vov - vds) * j.lambda
                } else {
                    id = j.beta * vov * vov * lam
                    gm = 2 * j.beta * vov * lam
                    gds = j.beta * vov * vov * j.lambda
                }
            }
            gds += gmin
            stamp3(d, i0: j.pol * id, g1: gm, c1p: j.g, c1n: s, v1: vgsA, g2: gds, c2p: d, c2n: s, v2: vdsA)
            stamp3(s, i0: -j.pol * id, g1: -gm, c1p: j.g, c1n: s, v1: vgsA, g2: -gds, c2p: d, c2n: s, v2: vdsA)
        }
        // MOSFETs: square law above threshold running smoothly into an exponential below it, the same
        // expression in both directions so drain and source can swap roles.
        for i in mosfets.indices {
            let q = mosfets[i]
            let vgsA = v(q.g) - v(q.s), vgdA = v(q.g) - v(q.d)
            let vgs = q.pol * vgsA, vgd = q.pol * vgdA
            let (sps, sgs) = softplusPair((vgs - q.vto) / q.a), (spd, sgd) = softplusPair((vgd - q.vto) / q.a)
            let qs = q.a * sps, qd = q.a * spd
            let diff = q.beta * (qs * qs - qd * qd)
            let vds = vgs - vgd
            let lam = 1 + q.lambda * abs(vds)
            let dl = diff * q.lambda * (vds >= 0 ? 1 : -1)
            let id = diff * lam
            let g1 = q.beta * 2 * qs * sgs * lam + dl      // d id / d vgs
            let g2 = -q.beta * 2 * qd * sgd * lam - dl     // d id / d vgd
            stamp3(q.d, i0: q.pol * id, g1: g1, c1p: q.g, c1n: q.s, v1: vgsA, g2: g2, c2p: q.g, c2n: q.d, v2: vgdA)
            stamp3(q.s, i0: -q.pol * id, g1: -g1, c1p: q.g, c1n: q.s, v1: vgsA, g2: -g2, c2p: q.g, c2n: q.d, v2: vgdA)
        }
        // Triodes (Koren model, with grid conduction)
        for i in triodes.indices {
            var t = triodes[i]
            var vgk = v(t.g) - v(t.k), vpk = v(t.p) - v(t.k)
            let pstep = max(10, 0.2 * abs(t.vpkOld))
            vpk = t.vpkOld + min(max(vpk - t.vpkOld, -pstep), pstep)
            // Grid steps are limited to 0.5 V only where the valve conducts. Below cut-off the current is
            // zero whatever the grid does, so the grid may move any distance there in one step.
            let cutoff = -(1 / t.mu + 10 / t.kp) * sqrt(t.kvb + vpk * vpk)
            if vgk > cutoff {
                let from = max(t.vgkOld, cutoff)
                vgk = from + min(max(vgk - from, -0.5), 0.5)
            }
            t.vgkOld = vgk; t.vpkOld = vpk
            triodes[i] = t
            let s = sqrt(t.kvb + vpk * vpk)
            let u = t.kp * (1 / t.mu + vgk / s)
            let (sp, sg) = softplusPair(u)
            let e1 = vpk / t.kp * sp
            var ip = 0.0, gpg = 0.0, gpp = 0.0
            if e1 > 1e-12 {
                let pw = 2 * pow(e1, t.ex - 1) / t.kg1
                ip = pw * e1
                let dip = t.ex * pw
                let de_dvgk = vpk * sg / s
                let de_dvpk = sp / t.kp - vpk * sg * vgk * vpk / (s * s * s)
                gpg = dip * de_dvgk
                gpp = dip * de_dvpk
            }
            gpp += 1e-9
            ip += 1e-9 * vpk
            stamp3(t.p, i0: ip, g1: gpp, c1p: t.p, c1n: t.k, v1: vpk, g2: gpg, c2p: t.g, c2n: t.k, v2: vgk)
            stamp3(t.k, i0: -ip, g1: -gpp, c1p: t.p, c1n: t.k, v1: vpk, g2: -gpg, c2p: t.g, c2n: t.k, v2: vgk)
            // grid current when the grid goes positive of the cathode
            var ig = 0.0, gg = gmin
            if vgk > 0 { ig = pow(vgk, 1.5) / 1300; gg += 1.5 * sqrt(vgk) / 1300 }
            nlConductance(t.g, t.k, gg)
            let ieq = ig - gg * vgk
            inject(t.g, -ieq); inject(t.k, ieq)
        }
        // Power pentodes and beam tetrodes (Koren): the screen sets the current, the plate "knee" is an arctangent
        for i in pentodes.indices {
            var t = pentodes[i]
            var vg = v(t.g) - v(t.k), vp = v(t.p) - v(t.k), vs = v(t.s) - v(t.k)
            let pstep = max(10, 0.2 * abs(t.vpOld)), sstep = max(10, 0.2 * abs(t.vsOld))
            vp = t.vpOld + min(max(vp - t.vpOld, -pstep), pstep)
            vs = t.vsOld + min(max(vs - t.vsOld, -sstep), sstep)
            let vse = max(vs, 1)
            let cutoff = -vse * (1 / t.mu + 10 / t.kp)
            if vg > cutoff {
                let from = max(t.vgOld, cutoff)
                vg = from + min(max(vg - from, -1), 1)
            }
            t.vgOld = vg; t.vpOld = vp; t.vsOld = vs
            pentodes[i] = t
            let (sp, sg) = softplusPair(t.kp * (1 / t.mu + vg / vse))
            let e1 = vse / t.kp * sp
            var ip = 0.0, gpg = 0.0, gps = 0.0, gpp = 1e-9
            if e1 > 1e-12 {
                let knee = vp > 0 ? atan(vp / t.kvb) : 0
                let pw = 2 * pow(e1, t.ex - 1) / t.kg1
                ip = pw * e1 * knee
                let dE = t.ex * pw * knee
                gpg = dE * sg
                if vs > 1 { gps = dE * (sp / t.kp - sg * vg / vse) }
                if vp > 0 { gpp += pw * e1 / (t.kvb * (1 + vp * vp / (t.kvb * t.kvb))) }
            }
            ip += 1e-9 * vp
            // screen current
            let u = vg + vse / t.mu
            var isc = 0.0, gsg = 0.0, gss = 1e-9
            if u > 0 {
                let pw = pow(u, t.ex - 1) / t.kg2
                isc = pw * u
                gsg = t.ex * pw
                if vs > 1 { gss += gsg / t.mu }
            }
            isc += 1e-9 * vs
            stamp3(t.p, i0: ip, g1: gpp, c1p: t.p, c1n: t.k, v1: vp, g2: gpg, c2p: t.g, c2n: t.k, v2: vg)
            stamp3(t.p, i0: 0, g1: gps, c1p: t.s, c1n: t.k, v1: vs, g2: 0, c2p: -1, c2n: -1, v2: 0)
            stamp3(t.s, i0: isc, g1: gss, c1p: t.s, c1n: t.k, v1: vs, g2: gsg, c2p: t.g, c2n: t.k, v2: vg)
            stamp3(t.k, i0: -(ip + isc), g1: -gpp, c1p: t.p, c1n: t.k, v1: vp, g2: -(gpg + gsg), c2p: t.g, c2n: t.k, v2: vg)
            stamp3(t.k, i0: 0, g1: -(gps + gss), c1p: t.s, c1n: t.k, v1: vs, g2: 0, c2p: -1, c2n: -1, v2: 0)
            // grid current when the grid goes positive of the cathode
            var ig = 0.0, gg = gmin
            if vg > 0 { ig = pow(vg, 1.5) / 1300; gg += 1.5 * sqrt(vg) / 1300 }
            nlConductance(t.g, t.k, gg)
            let ieq = ig - gg * vg
            inject(t.g, -ieq); inject(t.k, ieq)
        }
        // Op-amps: slew-limited input stage → integrator node → soft-saturating output
        for i in opamps.indices {
            let o = opamps[i]
            let vd = v(o.inP) - v(o.inN)
            let arg = o.gm * vd / o.iMax
            let th = tanh(arg)
            let iin = o.iMax * th
            let gin = o.gm * (1 - th * th)
            // current injected into m: iin(vd). As "current leaving m" it is -iin.
            stamp3(o.m, i0: -iin, g1: -gin, c1p: o.inP, c1n: o.inN, v1: vd, g2: 0, c2p: -1, c2n: -1, v2: 0)
            // keep the integrator node inside the swing (fast recovery from clipping)
            let vm = v(o.m)
            let kk = 20.0 / max(o.half, 0.1)
            let a1 = kk * (vm - o.vClamp), a2 = kk * (-vm - o.vClamp)
            if a1 > -30 || a2 > -30 {   // well inside the swing the clamp carries no current
                let (s1, g1) = softplusPair(a1), (s2, g2) = softplusPair(a2)
                let ic = (s1 - s2) / kk
                let gcl = g1 + g2 + gmin
                nlG(o.m, o.m, gcl)
                inject(o.m, -(ic - gcl * vm))
            }
            // output: Norton source f(vm)·gout into out
            let xh = vm / max(o.half, 1e-3)
            let x4 = xh * xh * xh * xh
            let den = (1 + x4).squareRoot().squareRoot()
            let f = o.mid + o.half * xh / den
            let fp = 1 / (den * (1 + x4))
            // current into out = gout·f(vm) ≈ gout·(f0 + fp·(vm − vm0))
            nlG(o.out, o.m, -o.gout * fp)
            inject(o.out, o.gout * (f - fp * vm))
        }
    }

    /// Current i0 leaving node t into a device, linear in two controlling voltages.
    @inline(__always) func stamp3(_ t: Int, i0: Double, g1: Double, c1p: Int, c1n: Int, v1: Double,
                                  g2: Double, c2p: Int, c2n: Int, v2: Double) {
        guard t >= 0 else { return }
        let row = sA + (t - sOff) * sStride - sOff
        if g1 != 0 { if c1p >= 0 { row[c1p] += g1 }; if c1n >= 0 { row[c1n] -= g1 } }
        if g2 != 0 { if c2p >= 0 { row[c2p] += g2 }; if c2n >= 0 { row[c2n] -= g2 } }
        sR[t - sOff] -= i0 - g1 * v1 - g2 * v2
    }

    // MARK: Linear algebra

    /// Dot product with four running sums, so the additions don't wait on one another (a single running sum
    /// is limited by the latency of each add, which made these short loops several times slower than they need be).
    @inline(__always) static func dot(_ a: UnsafePointer<Double>, _ b: UnsafePointer<Double>, _ n: Int) -> Double {
        var s0 = 0.0, s1 = 0.0, s2 = 0.0, s3 = 0.0
        var i = 0
        while i + 4 <= n {
            s0 += a[i] * b[i]; s1 += a[i + 1] * b[i + 1]; s2 += a[i + 2] * b[i + 2]; s3 += a[i + 3] * b[i + 3]
            i += 4
        }
        while i < n { s0 += a[i] * b[i]; i += 1 }
        return (s0 + s1) + (s2 + s3)
    }

    /// y[i] -= f · x[i], four at a time.
    @inline(__always) static func subtractScaled(_ y: UnsafeMutablePointer<Double>, _ x: UnsafePointer<Double>, _ f: Double, _ n: Int) {
        var i = 0
        let fv = SIMD4<Double>(repeating: f)
        while i + 4 <= n {
            let yv = UnsafeRawPointer(y + i).loadUnaligned(as: SIMD4<Double>.self)
            let xv = UnsafeRawPointer(x + i).loadUnaligned(as: SIMD4<Double>.self)
            UnsafeMutableRawPointer(y + i).storeBytes(of: yv - fv * xv, as: SIMD4<Double>.self)
            i += 4
        }
        while i < n { y[i] -= f * x[i]; i += 1 }
    }

    /// In-place LU factorisation with partial pivoting of the n×n matrix M. Returns false if singular.
    @inline(__always) static func luFactor(_ M: UnsafeMutablePointer<Double>, _ n: Int, _ perm: UnsafeMutablePointer<Int>) -> Bool {
        for k in 0..<n {
            var piv = k
            var best = abs(M[k * n + k])
            var r = k + 1
            while r < n { let a = abs(M[r * n + k]); if a > best { best = a; piv = r }; r += 1 }
            if best < 1e-300 { return false }
            perm[k] = piv
            if piv != k {
                for c in 0..<n { let t = M[k * n + c]; M[k * n + c] = M[piv * n + c]; M[piv * n + c] = t }
            }
            let inv = 1 / M[k * n + k]
            r = k + 1
            while r < n {
                let f = M[r * n + k] * inv
                if f != 0 {
                    M[r * n + k] = f
                    subtractScaled(M + r * n + k + 1, M + k * n + k + 1, f, n - k - 1)
                } else {
                    M[r * n + k] = 0
                }
                r += 1
            }
        }
        return true
    }

    /// Solves with the factors in M, overwriting b.
    @inline(__always) static func luSolve(_ M: UnsafeMutablePointer<Double>, _ n: Int, _ perm: UnsafeMutablePointer<Int>,
                                          _ b: UnsafeMutablePointer<Double>) {
        for k in 0..<n { let p = perm[k]; if p != k { let t = b[k]; b[k] = b[p]; b[p] = t } }
        // forward substitution with the unit lower factor, then back substitution with the upper one
        cblas_dtrsv(CblasRowMajor, CblasLower, CblasNoTrans, CblasUnit, Int32(n), M, Int32(n), b, 1)
        cblas_dtrsv(CblasRowMajor, CblasUpper, CblasNoTrans, CblasNonUnit, Int32(n), M, Int32(n), b, 1)
    }

    @inline(__always) func factor() -> Bool { CircuitEngine.luFactor(A, n, perm) }
    @inline(__always) func substitute(_ b: UnsafeMutablePointer<Double>) { CircuitEngine.luSolve(A, n, perm, b) }

    // MARK: Time stepping

    /// One Newton solve at the present sources. Returns true when it converged.
    @discardableResult
    func newton(maxIter: Int, tol: Double) -> Bool {
        if linear {
            if !luValid {
                A.update(from: G0, count: n * n)
                guard factor() else { return false }
                luValid = true
            }
            rhs.update(from: rhs0, count: n)
            substitute(rhs)
            x.update(from: rhs, count: n)
            return true
        }
        if reducedValid && !dcMode && !useFullSolver { return newtonReduced(maxIter: maxIter, tol: tol) }
        targetFull()
        for _ in 0..<maxIter {
            iterationCount &+= 1
            A.update(from: G0, count: n * n)
            rhs.update(from: rhs0, count: n)
            stampNonlinear()
            guard factor() else { return false }
            substitute(rhs)
            var delta = 0.0
            for i in 0..<n {
                var d = rhs[i] - x[i]
                if d > dvLimit { d = dvLimit } else if d < -dvLimit { d = -dvLimit }
                x[i] += d
                let a = abs(d) / (1 + abs(x[i]))
                if a > delta { delta = a }
            }
            if delta < tol { return true }
        }
        return false
    }

    /// Newton on the nonlinear nodes only; the linear nodes follow from them exactly.
    @inline(__always) func newtonReduced(maxIter: Int, tol: Double) -> Bool {
        let l = nl, s = ns
        // zL = Minv · rhs0[L]
        if l > 0 { cblas_dgemv(CblasRowMajor, CblasNoTrans, Int32(l), Int32(l), 1, Minv, Int32(l), rhs0, 1, 0, zL, 1) }
        // rS = rhs0[S] − G0[S,L] · zL
        rS.update(from: rhs0 + l, count: s)
        if l > 0 { cblas_dgemv(CblasRowMajor, CblasNoTrans, Int32(s), Int32(l), -1, G0 + l * n, Int32(n), zL, 1, 1, rS, 1) }
        targetReduced()
        let xs = x + l
        var converged = false
        if predictor {
            // Guess from the trend of the last two samples: usually saves an iteration, more when oversampling.
            for i in 0..<s { let now = xs[i]; xs[i] = 2 * now - xPrev[i]; xPrev[i] = now }
            converged = iterateReduced(maxIter: min(maxIter, 8), tol: tol)
            if !converged {
                // The guess overshot (a device switching hard): go back to the last sample and solve plainly.
                for i in 0..<s { xs[i] = xPrev[i] }
                resetLimiters()
                converged = iterateReduced(maxIter: maxIter, tol: tol)
            }
        } else {
            converged = iterateReduced(maxIter: maxIter, tol: tol)
        }
        // linear nodes: x[L] = zL − Y · x[S]
        if l > 0 {
            x.update(from: zL, count: l)
            cblas_dgemv(CblasRowMajor, CblasNoTrans, Int32(l), Int32(s), -1, Y, Int32(s), xs, 1, 1, x, 1)
        }
        return converged
    }

    @inline(__always) func iterateReduced(maxIter: Int, tol: Double) -> Bool {
        let s = ns
        let xs = x + nl
        var prevDelta = Double.infinity
        for _ in 0..<maxIter {
            iterationCount &+= 1
            As.update(from: K, count: s * s)
            bS.update(from: rS, count: s)
            stampNonlinear()
            guard CircuitEngine.luFactor(As, s, permS) else { return false }
            factorCount &+= 1
            CircuitEngine.luSolve(As, s, permS, bS)
            var delta = 0.0
            for i in 0..<s {
                var d = bS[i] - xs[i]
                if d > dvLimit { d = dvLimit } else if d < -dvLimit { d = -dvLimit }
                xs[i] += d
                let a = abs(d) / (1 + abs(xs[i]))
                if !(a <= delta) { delta = a }   // also catches NaN
            }
            if delta < tol { return true }
            if !delta.isFinite { return false }
            // Close to the answer Newton's steps shrink quadratically: the next would be about delta²/previous.
            // When that is already below the tolerance, taking it would change nothing that matters.
            if earlyExit && prevDelta < 1e-3 && delta * delta < tol * prevDelta { return true }
            prevDelta = delta
        }
        return false
    }

    /// Sets the junction-voltage limiters to the voltages in x (after stepping back to a known-good solution).
    func resetLimiters() {
        for i in diodes.indices { diodes[i].vOld = v(diodes[i].a) - v(diodes[i].c) }
        for i in bjts.indices {
            let q = bjts[i]
            bjts[i].vbeOld = q.pol * (v(q.b) - v(q.e)); bjts[i].vbcOld = q.pol * (v(q.b) - v(q.c))
        }
        for i in triodes.indices {
            let t = triodes[i]
            triodes[i].vgkOld = v(t.g) - v(t.k); triodes[i].vpkOld = v(t.p) - v(t.k)
        }
        for i in pentodes.indices {
            let t = pentodes[i]
            pentodes[i].vgOld = v(t.g) - v(t.k); pentodes[i].vpOld = v(t.p) - v(t.k); pentodes[i].vsOld = v(t.s) - v(t.k)
        }
    }

    /// Testing aid: nanoseconds for one pass of each part of a Newton iteration at the present state.
    public func profile(passes: Int = 200_000) -> [(String, Double)] {
        guard reducedValid else { return [] }
        targetReduced()
        let s = ns
        func time(_ body: () -> Void) -> Double {
            let t0 = DispatchTime.now().uptimeNanoseconds
            for _ in 0..<passes { body() }
            return Double(DispatchTime.now().uptimeNanoseconds - t0) / Double(passes)
        }
        let copy = time { As.update(from: K, count: s * s); bS.update(from: rS, count: s) }
        let stamp = time { stampNonlinear() }
        let lu = time { LUs.update(from: K, count: s * s); for i in 0..<s { LUs[i * s + i] += 1e-3 }; _ = CircuitEngine.luFactor(LUs, s, permS) }
        let solve = time { bS.update(from: rS, count: s); CircuitEngine.luSolve(LUs, s, permS, bS) }
        let l = nl
        let reduceRHS = time {
            cblas_dgemv(CblasRowMajor, CblasNoTrans, Int32(l), Int32(l), 1, Minv, Int32(l), rhs0, 1, 0, zL, 1)
            rS.update(from: rhs0 + l, count: s)
            cblas_dgemv(CblasRowMajor, CblasNoTrans, Int32(s), Int32(l), -1, G0 + l * n, Int32(n), zL, 1, 1, rS, 1)
            x.update(from: zL, count: l)
            cblas_dgemv(CblasRowMajor, CblasNoTrans, Int32(l), Int32(s), -1, Y, Int32(s), x + l, 1, 1, x, 1)
        }
        let whole = time { _ = tick(0.05) }
        let rhs = time { buildRHS(0.1) }
        let accept = time { acceptStep() }
        try? solveOperatingPoint()
        return [("copy K", copy), ("device stamps", stamp), ("factorise", lu), ("solve", solve), ("build right-hand side", rhs), ("accept step", accept),
                ("linear nodes in and out", reduceRHS), ("whole sample, small steady input", whole)]
    }

    /// True while every node voltage is a number. After a blow-up, call recover().
    public var isHealthy: Bool {
        for i in 0..<n where !x[i].isFinite { return false }
        return true
    }

    /// Restarts the circuit from its bias point (after bad parameters made it blow up).
    public func recover() { try? solveOperatingPoint() }

    func acceptStep() {
        for i in caps.indices {
            var c = caps[i]
            let vNow = v(c.a) - v(c.b)
            c.iPrev = c.geq * (vNow - c.vPrev) - c.iPrev
            c.vPrev = vNow
            caps[i] = c
        }
        for i in inds.indices {
            var l = inds[i]
            let vNow = v(l.m) - v(l.b)
            l.iPrev = l.iPrev + l.geq * (vNow + l.vPrev)
            l.vPrev = vNow
            inds[i] = l
        }
        for i in xfmrs.indices {
            var t = xfmrs[i]
            let v0 = v(t.a.0) - v(t.b.0), v1 = v(t.a.1) - v(t.b.1), v2 = v(t.a.2) - v(t.b.2)
            let s0 = v0 + t.vPrev.0, s1 = v1 + t.vPrev.1, s2 = v2 + t.vPrev.2
            t.iPrev.0 += 0.5 * dt * (t.gamma.0 * s0 + t.gamma.1 * s1 + t.gamma.2 * s2)
            t.iPrev.1 += 0.5 * dt * (t.gamma.3 * s0 + t.gamma.4 * s1 + t.gamma.5 * s2)
            t.iPrev.2 += 0.5 * dt * (t.gamma.6 * s0 + t.gamma.7 * s1 + t.gamma.8 * s2)
            t.vPrev = (v0, v1, v2)
            xfmrs[i] = t
        }
    }

    /// Finds the DC bias point (capacitors open, inductors shorted), ramping the supplies up for robustness.
    func solveOperatingPoint() throws {
        dcMode = true
        stampLinear()
        x.update(repeating: 0, count: n)
        var ok = false
        let saveLimit = dvLimit
        dvLimit = max(0.25, maxSupply * 0.02)
        let steps = 20
        for s in 1...steps {
            sourceScale = Double(s) / Double(steps)
            buildRHS(0)
            ok = newton(maxIter: 300, tol: 1e-9)
        }
        if !ok {
            // try once more from the result with smaller steps
            for _ in 0..<3 { buildRHS(0); ok = newton(maxIter: 500, tol: 1e-8); if ok { break } }
        }
        dvLimit = saveLimit
        sourceScale = 1
        if !ok { warnings.append("The bias point did not fully settle; check for missing bias resistors.") }
        for i in 0..<n where !x[i].isFinite { throw CircuitError("The circuit could not be solved (a node has no path to ground?).") }
        // capacitors start charged to their bias voltage, inductors carry their bias current
        for i in caps.indices { caps[i].vPrev = v(caps[i].a) - v(caps[i].b); caps[i].iPrev = 0 }
        for i in inds.indices {
            let vv = v(inds[i].m) - v(inds[i].b)
            inds[i].iPrev = 1e3 * vv
            inds[i].vPrev = 0
        }
        for i in xfmrs.indices {
            let t = xfmrs[i]
            xfmrs[i].iPrev = (1e3 * (v(t.a.0) - v(t.b.0)), 1e3 * (v(t.a.1) - v(t.b.1)), 1e3 * (v(t.a.2) - v(t.b.2)))
            xfmrs[i].vPrev = (0, 0, 0)
        }
        dcMode = false
        stampLinear()
        for i in 0..<ns { xPrev[i] = x[nl + i] }
    }

    /// Advances one sample with input u (in input units) and returns the output in output units.
    @inline(__always) public func tick(_ u: Double) -> Double {
        buildRHS(u)
        if !newton(maxIter: maxIterations, tol: tolerance) { nonConverged &+= 1 }
        acceptStep()
        return v(outputNode) * outputScale
    }

    /// Knobs, which can be fewer than pots: ganged pots share one.
    public private(set) var knobCount = 0

    /// Sets a knob (0…1). Safe to call from the audio thread; applied gradually in process().
    public func setKnob(_ i: Int, _ pos: Double) {
        guard i >= 0 && i < knobCount else { return }
        let p = min(max(pos, 0), 1)
        for j in pots.indices where pots[j].knob == i && pots[j].target != p { pots[j].target = p; potsDirty = true }
    }
    public func knob(_ i: Int) -> Double {
        for j in pots.indices where pots[j].knob == i { return pots[j].target }
        return 0
    }

    /// Moves knobs a step toward their targets (call every 32 samples or so).
    @inline(__always) public func applyKnobs() {
        guard potsDirty else { return }
        var moving = false
        for i in pots.indices {
            let d = pots[i].target - pots[i].pos
            if abs(d) > 1e-4 { pots[i].pos += d * 0.25; moving = true } else { pots[i].pos = pots[i].target }
        }
        stampLinear()
        potsDirty = moving
    }

    /// Processes a block of mono samples.
    public func process(_ input: UnsafePointer<Float>, _ output: UnsafeMutablePointer<Float>, _ frames: Int) {
        var start = 0
        while start < frames {
            let count = min(32, frames - start)
            applyKnobs()
            for f in start..<(start + count) {
                let y = tick(Double(input[f]))
                output[f] = y.isFinite ? Float(y) : 0
            }
            start += count
        }
        // A blow-up (bad parameters) resets the circuit instead of producing noise forever.
        if !isHealthy { recover() }
    }

    // MARK: Analysis

    /// The DC bias voltage of every named node.
    public func operatingPoint() -> [(String, Double)] {
        (1..<netlist.nodeCount).map { (netlist.name(of: $0), x[nodeMap[$0 - 1]]) }
    }

    /// Small-signal gain from input to output, in dB, at each frequency (linearised at the bias point).
    public func frequencyResponse(_ freqs: [Double]) -> [Double] {
        guard inputNode >= 0, outputNode >= 0 else { return freqs.map { _ in -120 } }
        // Jacobian at the bias point, resistive part only
        let saveX = UnsafeMutablePointer<Double>.allocate(capacity: n)
        saveX.update(from: x, count: n)
        defer { saveX.deallocate() }
        let saved = (caps.map { ($0.vPrev, $0.iPrev) }, inds.map { ($0.vPrev, $0.iPrev) })
        let savedOld = (diodes.map(\.vOld), bjts.map { ($0.vbeOld, $0.vbcOld) }, triodes.map { ($0.vgkOld, $0.vpkOld) })
        dcMode = true
        stampLinear()
        // inductors are handled separately below, so drop their DC short
        for l in inds { conductance(G0, l.m, l.b, -l.geq) }
        for t in xfmrs { for i in 0..<3 { conductance(G0, t.na(i), t.nb(i), -1e3) } }
        A.update(from: G0, count: n * n)
        rhs.update(repeating: 0, count: n)
        targetFull()
        stampNonlinear()
        var Gr = [Double](UnsafeBufferPointer(start: A, count: n * n))
        // remove output/input source conductance? they are part of the circuit's loading: keep them.
        var Cm = [Double](repeating: 0, count: n * n)
        var Lm = [Double](repeating: 0, count: n * n)
        func st(_ m: inout [Double], _ a: Int, _ b: Int, _ g: Double) {
            if a >= 0 { m[a * n + a] += g }
            if b >= 0 { m[b * n + b] += g }
            if a >= 0 && b >= 0 { m[a * n + b] -= g; m[b * n + a] -= g }
        }
        for c in caps { st(&Cm, c.a, c.b, c.c) }
        for l in inds { st(&Lm, l.m, l.b, 1 / l.l) }
        for t in xfmrs {
            for i in 0..<3 {
                for j in 0..<3 {
                    let g = t.gm(i, j)
                    func put(_ r: Int, _ c: Int, _ val: Double) { if r >= 0 && c >= 0 { Lm[r * n + c] += val } }
                    put(t.na(i), t.na(j), g); put(t.nb(i), t.nb(j), g); put(t.na(i), t.nb(j), -g); put(t.nb(i), t.na(j), -g)
                }
            }
        }
        _ = Gr.count
        // restore transient state
        dcMode = false
        x.update(from: saveX, count: n)
        stampLinear()
        for (i, s) in saved.0.enumerated() { caps[i].vPrev = s.0; caps[i].iPrev = s.1 }
        for (i, s) in saved.1.enumerated() { inds[i].vPrev = s.0; inds[i].iPrev = s.1 }
        for (i, s) in savedOld.0.enumerated() { diodes[i].vOld = s }
        for (i, s) in savedOld.1.enumerated() { bjts[i].vbeOld = s.0; bjts[i].vbcOld = s.1 }
        for (i, s) in savedOld.2.enumerated() { triodes[i].vgkOld = s.0; triodes[i].vpkOld = s.1 }

        var out: [Double] = []
        var re = [Double](repeating: 0, count: n * n), im = re
        var br = [Double](repeating: 0, count: n), bi = br
        for f in freqs {
            let w = 2 * Double.pi * f
            for i in 0..<(n * n) { re[i] = Gr[i]; im[i] = w * Cm[i] - Lm[i] / w }
            for i in 0..<n { br[i] = 0; bi[i] = 0 }
            br[inputNode] = inputG * inputScale
            if let h = complexSolve(&re, &im, &br, &bi, n) {
                let vr = h.0[outputNode] * outputScale, vi = h.1[outputNode] * outputScale
                out.append(10 * log10(max(vr * vr + vi * vi, 1e-24)))
            } else { out.append(-120) }
        }
        Gr.removeAll()
        return out
    }
}

/// Gaussian elimination with partial pivoting on a complex system (split real/imag storage).
func complexSolve(_ re: inout [Double], _ im: inout [Double], _ br: inout [Double], _ bi: inout [Double], _ n: Int)
    -> ([Double], [Double])? {
    for k in 0..<n {
        var piv = k; var best = 0.0
        for r in k..<n { let m = re[r * n + k] * re[r * n + k] + im[r * n + k] * im[r * n + k]; if m > best { best = m; piv = r } }
        if best < 1e-300 { return nil }
        if piv != k {
            for c in 0..<n { re.swapAt(k * n + c, piv * n + c); im.swapAt(k * n + c, piv * n + c) }
            br.swapAt(k, piv); bi.swapAt(k, piv)
        }
        let pr = re[k * n + k], pi = im[k * n + k], pd = pr * pr + pi * pi
        for r in (k + 1)..<max(n, k + 1) where r < n {
            let ar = re[r * n + k], ai = im[r * n + k]
            if ar == 0 && ai == 0 { continue }
            let fr = (ar * pr + ai * pi) / pd, fi = (ai * pr - ar * pi) / pd
            for c in k..<n {
                let kr = re[k * n + c], ki = im[k * n + c]
                re[r * n + c] -= fr * kr - fi * ki
                im[r * n + c] -= fr * ki + fi * kr
            }
            let kbr = br[k], kbi = bi[k]
            br[r] -= fr * kbr - fi * kbi
            bi[r] -= fr * kbi + fi * kbr
        }
    }
    var xr = [Double](repeating: 0, count: n), xi = xr
    for r in stride(from: n - 1, through: 0, by: -1) {
        var sr = br[r], si = bi[r]
        for c in (r + 1)..<max(n, r + 1) where c < n {
            let ar = re[r * n + c], ai = im[r * n + c]
            sr -= ar * xr[c] - ai * xi[c]
            si -= ar * xi[c] + ai * xr[c]
        }
        let pr = re[r * n + r], pi = im[r * n + r], pd = pr * pr + pi * pi
        xr[r] = (sr * pr + si * pi) / pd
        xi[r] = (si * pr - sr * pi) / pd
    }
    return (xr, xi)
}
