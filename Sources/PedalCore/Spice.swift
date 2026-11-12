import Foundation

/// Writes a circuit as a SPICE netlist (LTspice-friendly) using the same device models as the simulator,
/// so results can be cross-checked in LTspice or ngspice.
public enum SpiceExport {
    /// The name the netlist gives the output node (nil if the output is grounded or missing).
    public static func outputNode(_ c: Circuit) -> String? {
        let net = Netlist.build(c)
        guard let p = c.parts.first(where: { $0.kind == .output }), let n = net.pinNodes[p.id]?.first, n != 0 else { return nil }
        return net.name(of: n).replacingOccurrences(of: " ", with: "_")
    }

    /// `analysis` replaces the closing analysis lines (used by the ngspice cross-check).
    public static func netlist(_ c: Circuit, testFrequency: Double = 220, testAmplitude: Double = 0.3, analysis: [String]? = nil) -> String {
        let net = Netlist.build(c)
        func node(_ p: Part, _ i: Int) -> String {
            let n = net.pinNodes[p.id]?[i] ?? 0
            return n == 0 ? "0" : net.name(of: n).replacingOccurrences(of: " ", with: "_")
        }
        func val(_ v: Double) -> String {
            let s = Eng.format(v).replacingOccurrences(of: "µ", with: "u")
            return s.hasSuffix("M") ? String(s.dropLast()) + "Meg" : s
        }
        var lines: [String] = ["* \(c.name) — exported from Lutherie", "* \(c.notes)", ""]
        var models: [String: String] = [:]
        var subckts: Set<String> = []
        var supplyNodes = Set<String>()
        for p in c.parts {
            let id = p.name.replacingOccurrences(of: " ", with: "_")
            switch p.kind {
            case .resistor: lines.append("R\(id) \(node(p, 0)) \(node(p, 1)) \(val(p["r"]))")
            case .capacitor: lines.append("C\(id) \(node(p, 0)) \(node(p, 1)) \(val(p["c"]))")
            case .inductor:
                // winding resistance as its own part (the Rser= shorthand only works in LTspice)
                lines.append("R\(id)s \(node(p, 0)) \(id)_w \(val(p["rs"]))")
                lines.append("L\(id) \(id)_w \(node(p, 1)) \(val(p["l"]))")
            case .pot:
                let t = DeviceLibrary.taper(p.model, p["position"])
                lines.append("* \(p.text.isEmpty ? p.name : p.text) pot \(val(p["r"])) \(p.model) taper at \(Int(p["position"] * 100))%")
                lines.append("R\(id)a \(node(p, 0)) \(node(p, 2)) \(val(max(p["r"] * t, 0.5)))")
                lines.append("R\(id)b \(node(p, 2)) \(node(p, 1)) \(val(max(p["r"] * (1 - t), 0.5)))")
            case .diode, .led:
                let m = DeviceLibrary.diode(p.model, led: p.kind == .led)
                let mn = "D_" + p.model.filter { $0.isLetter || $0.isNumber }
                models[mn] = ".model \(mn) D(Is=\(m.Is) N=\(m.n) Rs=\(m.rs) Cjo=\(m.cj) M=0)"
                lines.append("D\(id) \(node(p, 0)) \(node(p, 1)) \(mn)")
            case .zener:
                let m = DeviceLibrary.zener(p.model)
                let mn = "DZ_" + p.model.filter { $0.isLetter || $0.isNumber }
                models[mn] = ".model \(mn) D(Is=\(m.Is) N=\(m.n) Rs=\(m.rs) Cjo=\(m.cj) M=0 Bv=\(m.bv) Ibv=\(m.ibv) Nbv=\(m.nbv))"
                lines.append("D\(id) \(node(p, 0)) \(node(p, 1)) \(mn)")
            case .npn, .pnp:
                let m = DeviceLibrary.bjt(p.model, pnp: p.kind == .pnp)
                let mn = "Q_" + p.model.filter { $0.isLetter || $0.isNumber }
                models[mn] = ".model \(mn) \(m.pnp ? "PNP" : "NPN")(Is=\(m.Is) Bf=\(m.bf) Br=\(m.br) Vaf=\(m.va) Nf=\(m.nf) Cje=\(m.cbe) Cjc=\(m.cbc) Mje=0 Mjc=0)"
                lines.append("Q\(id) \(node(p, 0)) \(node(p, 1)) \(node(p, 2)) \(mn)")
            case .njfet, .pjfet:
                let m = DeviceLibrary.jfet(p.model, pch: p.kind == .pjfet)
                let mn = "J_" + p.model.filter { $0.isLetter || $0.isNumber }
                models[mn] = ".model \(mn) \(m.pch ? "PJF" : "NJF")(Beta=\(m.beta) Vto=\(m.vto) Lambda=\(m.lambda))"
                lines.append("J\(id) \(node(p, 0)) \(node(p, 1)) \(node(p, 2)) \(mn)")
                // fixed gate capacitances, as the simulator uses (SPICE's own would vary with bias)
                lines.append("C\(id)gs \(node(p, 1)) \(node(p, 2)) \(val(m.cgs))")
                lines.append("C\(id)gd \(node(p, 1)) \(node(p, 0)) \(val(m.cgd))")
            case .nmos, .pmos:
                let m = DeviceLibrary.mosfet(p.model, pmos: p.kind == .pmos)
                let mn = "M_" + p.model.filter { $0.isLetter || $0.isNumber }
                models[mn] = ".model \(mn) \(m.pmos ? "PMOS" : "NMOS")(Level=1 Vto=\(m.pmos ? -m.vto : m.vto) Kp=\(m.kp) Lambda=\(m.lambda) Is=1e-13)"
                lines.append("M\(id) \(node(p, 0)) \(node(p, 1)) \(node(p, 2)) \(node(p, 2)) \(mn)")
                lines.append("C\(id)gs \(node(p, 1)) \(node(p, 2)) \(val(m.cgs))")
                lines.append("C\(id)gd \(node(p, 1)) \(node(p, 0)) \(val(m.cgd))")
            case .spst:
                if p.switchState != 0 { lines.append("R\(id) \(node(p, 0)) \(node(p, 1)) 0.05") }
                else { lines.append("* \(p.name) switch is open") }
            case .spdt:
                if p.switchState < 2 { lines.append("R\(id) \(node(p, 0)) \(node(p, p.switchState + 1)) 0.05") }
                else { lines.append("* \(p.name) selector is in its centre (off) position") }
            case .triode:
                let m = DeviceLibrary.triode(p.model)
                let sn = "TRIODE_" + p.model.filter { $0.isLetter || $0.isNumber }
                if subckts.insert(sn).inserted {
                    models[sn] = """
                    * Koren triode model
                    .subckt \(sn) P G K
                    Bp P K I=V(E1)>0 ? 2*pwr(V(E1),\(m.ex))/\(m.kg1) : 0
                    Be E1 0 V=V(P,K)/\(m.kp)*ln(1+exp(\(m.kp)*(1/\(m.mu)+V(G,K)/sqrt(\(m.kvb)+V(P,K)*V(P,K)))))
                    Bg G K I=V(G,K)>0 ? pwr(V(G,K),1.5)/1300 : 0
                    Cgp G P \(m.cgp)
                    Cgk G K \(m.cgk)
                    Cpk P K \(m.cpk)
                    .ends
                    """
                }
                lines.append("X\(id) \(node(p, 0)) \(node(p, 1)) \(node(p, 2)) \(sn)")
            case .pentode:
                let m = DeviceLibrary.pentode(p.model)
                let sn = "PENTODE_" + p.model.filter { $0.isLetter || $0.isNumber }
                if subckts.insert(sn).inserted {
                    models[sn] = """
                    * Koren pentode / beam tetrode model
                    .subckt \(sn) P G K S
                    Be E1 0 V=max(V(S,K),1)/\(m.kp)*ln(1+exp(\(m.kp)*(1/\(m.mu)+V(G,K)/max(V(S,K),1))))
                    Bp P K I=V(E1)>0 ? 2*pwr(V(E1),\(m.ex))/\(m.kg1)*atan(max(V(P,K),0)/\(m.kvb)) : 0
                    Bs S K I=(V(G,K)+max(V(S,K),1)/\(m.mu))>0 ? pwr(V(G,K)+max(V(S,K),1)/\(m.mu),\(m.ex))/\(m.kg2) : 0
                    Bg G K I=V(G,K)>0 ? pwr(V(G,K),1.5)/1300 : 0
                    Cgk G K \(m.cgk)
                    Cgp G P \(m.cgp)
                    Cpk P K \(m.cpk)
                    .ends
                    """
                }
                lines.append("X\(id) \(node(p, 0)) \(node(p, 1)) \(node(p, 2)) \(node(p, 3)) \(sn)")
            case .transformer:
                let ratio = sqrt(max(p["zpp"], 1) / max(p["zs"], 0.1))
                let lh = max(p["lp"], 0.01) / 4, ls = max(p["lp"], 0.01) / (ratio * ratio)
                let k = min(max(p["k"], 0), 0.99999)
                lines.append("* \(p.name): output transformer, \(val(p["zpp"])) plate to plate into \(val(p["zs"])) ohms")
                lines.append("R\(id)p1 \(node(p, 0)) \(id)_p1 \(max(p["rp"], 1e-3) / 2)")
                lines.append("R\(id)p2 \(id)_p2 \(node(p, 2)) \(max(p["rp"], 1e-3) / 2)")
                lines.append("R\(id)s \(node(p, 3)) \(id)_s1 \(max(p["rsec"], 1e-3))")
                lines.append("L\(id)a \(id)_p1 \(node(p, 1)) \(lh)")
                lines.append("L\(id)b \(node(p, 1)) \(id)_p2 \(lh)")
                lines.append("L\(id)c \(id)_s1 \(node(p, 4)) \(ls)")
                lines.append("K\(id)ab L\(id)a L\(id)b \(k)")
                lines.append("K\(id)ac L\(id)a L\(id)c \(k)")
                lines.append("K\(id)bc L\(id)b L\(id)c \(k)")
            case .opamp:
                let m = DeviceLibrary.opamp(p.model)
                let vneg = p.props["vneg"] ?? 0, vpos = p.props["vpos"] ?? 9
                let lo = vneg + m.headroom, hi = vpos - m.headroom
                let sn = "OPAMP_" + p.model.filter { $0.isLetter || $0.isNumber } + "_\(Int(lo * 10))_\(Int(hi * 10))"
                if subckts.insert(sn).inserted {
                    let c1 = m.gain / (2 * Double.pi * m.gbw * 1e6)
                    let imax = m.slew * 1e6 * c1
                    let half = max(hi - lo, 0.1) / 2, kk = 20 / max(half, 0.1), vc = 2.5 * half
                    models[sn] = """
                    * Behavioural op-amp: gain, gain-bandwidth, slew rate and output swing
                    .subckt \(sn) INP INN OUT
                    Bin 0 M I=\(imax)*tanh(\(m.gain / 1e6)*V(INP,INN)/\(imax))
                    R1 M 0 1Meg
                    C1 M 0 \(c1)
                    * keeps the internal node inside the swing, so the amplifier recovers from clipping at once
                    Bcl M 0 I=(ln(1+exp(min(\(kk)*(V(M)-\(vc)),60)))-ln(1+exp(min(\(kk)*(-V(M)-\(vc)),60))))/\(kk)
                    * soft saturation x/(1+x^4)^(1/4), written without pwr() because simulators disagree on its sign
                    Bout X 0 V=\((hi + lo) / 2)+V(M)/sqrt(sqrt(1+(V(M)/\(half))*(V(M)/\(half))*(V(M)/\(half))*(V(M)/\(half))))
                    Rout X OUT \(m.rout)
                    .ends
                    """
                }
                lines.append("X\(id) \(node(p, 0)) \(node(p, 1)) \(node(p, 2)) \(sn)")
            case .supply:
                let n = node(p, 0)
                if supplyNodes.insert(n).inserted {
                    lines.append("V\(id) \(n)_src 0 DC \(p["v"])")
                    lines.append("R\(id)s \(n)_src \(n) \(max(p["rs"], 1e-3))")
                }
            case .input:
                lines.append("Vsig SIGSRC 0 SIN(0 \(testAmplitude) \(testFrequency)) AC 1")
                lines.append("Rsig SIGSRC \(node(p, 0)) \(val(p["rs"]))")
            case .output:
                lines.append("Rload \(node(p, 0)) 0 \(val(p["rl"]))")
            case .ground, .label: break
            }
        }
        lines.append("")
        lines.append(contentsOf: models.keys.sorted().map { models[$0]! })
        lines.append("")
        if let analysis {
            lines.append(contentsOf: analysis)
        } else {
            lines.append("* Pick one analysis:")
            lines.append(".tran 0 50m 0 5u")
            lines.append("*.ac dec 50 20 20k")
        }
        lines.append(".end")
        return lines.joined(separator: "\n")
    }
}
