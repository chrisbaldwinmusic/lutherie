import Foundation

/// Writes a circuit as a SPICE netlist (LTspice-friendly) using the same device models as the simulator,
/// so results can be cross-checked in LTspice or ngspice.
public enum SpiceExport {
    public static func netlist(_ c: Circuit, testFrequency: Double = 220, testAmplitude: Double = 0.3) -> String {
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
            case .inductor: lines.append("L\(id) \(node(p, 0)) \(node(p, 1)) \(val(p["l"])) Rser=\(val(p["rs"]))")
            case .pot:
                let t = DeviceLibrary.taper(p.model, p["position"])
                lines.append("* \(p.text.isEmpty ? p.name : p.text) pot \(val(p["r"])) \(p.model) taper at \(Int(p["position"] * 100))%")
                lines.append("R\(id)a \(node(p, 0)) \(node(p, 2)) \(val(max(p["r"] * t, 0.5)))")
                lines.append("R\(id)b \(node(p, 2)) \(node(p, 1)) \(val(max(p["r"] * (1 - t), 0.5)))")
            case .diode, .led:
                let m = DeviceLibrary.diode(p.model, led: p.kind == .led)
                let mn = "D_" + p.model.filter { $0.isLetter || $0.isNumber }
                models[mn] = ".model \(mn) D(Is=\(m.Is) N=\(m.n) Rs=\(m.rs) Cjo=\(m.cj))"
                lines.append("D\(id) \(node(p, 0)) \(node(p, 1)) \(mn)")
            case .zener:
                let m = DeviceLibrary.zener(p.model)
                let mn = "DZ_" + p.model.filter { $0.isLetter || $0.isNumber }
                models[mn] = ".model \(mn) D(Is=\(m.Is) N=\(m.n) Rs=\(m.rs) Cjo=\(m.cj) Bv=\(m.bv) Ibv=5m Nbv=\(m.nbv))"
                lines.append("D\(id) \(node(p, 0)) \(node(p, 1)) \(mn)")
            case .npn, .pnp:
                let m = DeviceLibrary.bjt(p.model, pnp: p.kind == .pnp)
                let mn = "Q_" + p.model.filter { $0.isLetter || $0.isNumber }
                models[mn] = ".model \(mn) \(m.pnp ? "PNP" : "NPN")(Is=\(m.Is) Bf=\(m.bf) Br=\(m.br) Vaf=\(m.va) Nf=\(m.nf) Cje=\(m.cbe) Cjc=\(m.cbc))"
                lines.append("Q\(id) \(node(p, 0)) \(node(p, 1)) \(node(p, 2)) \(mn)")
            case .njfet, .pjfet:
                let m = DeviceLibrary.jfet(p.model, pch: p.kind == .pjfet)
                let mn = "J_" + p.model.filter { $0.isLetter || $0.isNumber }
                models[mn] = ".model \(mn) \(m.pch ? "PJF" : "NJF")(Beta=\(m.beta) Vto=\(m.vto) Lambda=\(m.lambda) Cgs=\(m.cgs) Cgd=\(m.cgd))"
                lines.append("J\(id) \(node(p, 0)) \(node(p, 1)) \(node(p, 2)) \(mn)")
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
            case .opamp:
                let m = DeviceLibrary.opamp(p.model)
                let vneg = p.props["vneg"] ?? 0, vpos = p.props["vpos"] ?? 9
                let lo = vneg + m.headroom, hi = vpos - m.headroom
                let sn = "OPAMP_" + p.model.filter { $0.isLetter || $0.isNumber } + "_\(Int(lo * 10))_\(Int(hi * 10))"
                if subckts.insert(sn).inserted {
                    let c1 = m.gain / (2 * Double.pi * m.gbw * 1e6)
                    let imax = m.slew * 1e6 * c1
                    models[sn] = """
                    * Behavioural op-amp: gain, gain-bandwidth, slew rate and output swing
                    .subckt \(sn) INP INN OUT
                    Bin 0 M I=\(imax)*tanh(\(m.gain / 1e6)*V(INP,INN)/\(imax))
                    R1 M 0 1Meg
                    C1 M 0 \(c1)
                    Bout X 0 V=\((hi + lo) / 2)+\((hi - lo) / 2)*V(M)/\((hi - lo) / 2)/pwr(1+pwr(V(M)/\((hi - lo) / 2),4),0.25)
                    Rout X OUT \(m.rout)
                    .ends
                    """
                }
                lines.append("X\(id) \(node(p, 0)) \(node(p, 1)) \(node(p, 2)) \(sn)")
            case .supply:
                let n = node(p, 0)
                if supplyNodes.insert(n).inserted { lines.append("V\(id) \(n) 0 DC \(p["v"])") }
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
        lines.append("* Pick one analysis:")
        lines.append(".tran 0 50m 0 5u")
        lines.append("*.ac dec 50 20 20k")
        lines.append(".end")
        return lines.joined(separator: "\n")
    }
}
