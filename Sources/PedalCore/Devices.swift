import Foundation

/// Physical parameters for the semiconductor and tube models.
/// Values follow commonly published SPICE models of each part.
public struct DiodeModel: Sendable {
    public var Is: Double; public var n: Double; public var rs: Double; public var cj: Double
    /// Reverse breakdown (zeners): the rated voltage, the test current it is rated at, and how sharp the knee is
    /// (in thermal voltages). bv 0 = no breakdown.
    public var bv = 0.0; public var ibv = 5e-3; public var nbv = 2.0
}
public struct BJTModel: Sendable {
    public var pnp: Bool; public var Is: Double; public var bf: Double; public var br: Double; public var va: Double
    public var nf: Double; public var cbe: Double; public var cbc: Double
}
public struct JFETModel: Sendable {
    public var beta: Double; public var vto: Double; public var lambda: Double; public var cgs: Double; public var cgd: Double
    public var pch = false
}
/// Enhancement MOSFET. `vto` is the threshold as a positive number for both polarities; `kp` is the
/// SPICE level-1 transconductance parameter for the whole device (saturation current = kp/2 · (Vgs − Vto)²).
public struct MOSFETModel: Sendable {
    public var pmos: Bool; public var vto: Double; public var kp: Double; public var lambda: Double
    public var cgs: Double; public var cgd: Double
}
public struct OpAmpModel: Sendable {
    public var gain: Double      // open-loop DC gain
    public var gbw: Double       // gain-bandwidth product, Hz
    public var headroom: Double  // how close the output swings to the rails, V
    public var rout: Double      // output resistance, Ω
    public var slew: Double      // slew rate, V/µs
}
public struct TriodeModel: Sendable {
    public var mu: Double; public var ex: Double; public var kg1: Double; public var kp: Double; public var kvb: Double
    public var cgp: Double; public var cgk: Double; public var cpk: Double
}

public enum DeviceLibrary {
    public static let diodes: [String: DiodeModel] = [
        "1N4148": DiodeModel(Is: 2.52e-9, n: 1.752, rs: 0.568, cj: 4e-12),
        "1N914": DiodeModel(Is: 2.52e-9, n: 1.752, rs: 0.568, cj: 4e-12),
        "1N4001": DiodeModel(Is: 14.11e-9, n: 1.984, rs: 0.0339, cj: 25.9e-12),
        "1N34A (germanium)": DiodeModel(Is: 2.6e-6, n: 1.6, rs: 7.0, cj: 0.5e-12),
        "BAT41 (Schottky)": DiodeModel(Is: 2e-8, n: 1.17, rs: 8.0, cj: 2e-12),
    ]
    public static let leds: [String: DiodeModel] = [
        "Red LED": DiodeModel(Is: 1e-19, n: 1.8, rs: 5, cj: 30e-12),
        "Green LED": DiodeModel(Is: 1e-21, n: 2.0, rs: 5, cj: 30e-12),
    ]
    // 1 W zeners, rated at the data-sheet test current (a quarter of a watt: 76 mA for 3.3 V down to 21 mA for 12 V),
    // so at the few milliamps a pedal passes they sit a little under their rated voltage, as real ones do.
    // Below about 5 V the knee is soft (true Zener effect); above it, sharp (avalanche). Knee softness is an estimate.
    public static let zeners: [String: DiodeModel] = [
        "3.3 V (1N4728A)": DiodeModel(Is: 1e-12, n: 1.2, rs: 2, cj: 150e-12, bv: 3.3, ibv: 76e-3, nbv: 5),
        "4.7 V (1N4732A)": DiodeModel(Is: 1e-12, n: 1.2, rs: 2, cj: 120e-12, bv: 4.7, ibv: 53e-3, nbv: 3.5),
        "5.1 V (1N4733A)": DiodeModel(Is: 1e-12, n: 1.2, rs: 2, cj: 110e-12, bv: 5.1, ibv: 49e-3, nbv: 2.5),
        "9.1 V (1N4739A)": DiodeModel(Is: 1e-12, n: 1.2, rs: 2, cj: 70e-12, bv: 9.1, ibv: 28e-3, nbv: 1.5),
        "12 V (1N4742A)": DiodeModel(Is: 1e-12, n: 1.2, rs: 2, cj: 55e-12, bv: 12, ibv: 21e-3, nbv: 1.5),
    ]
    public static let bjts: [String: BJTModel] = [
        "2N3904": BJTModel(pnp: false, Is: 6.734e-15, bf: 416.4, br: 0.7371, va: 74.03, nf: 1, cbe: 4.5e-12, cbc: 3.6e-12),
        "2N5088": BJTModel(pnp: false, Is: 5.911e-15, bf: 1122, br: 1.271, va: 62.4, nf: 1, cbe: 4.5e-12, cbc: 3e-12),
        "BC109": BJTModel(pnp: false, Is: 1.8e-14, bf: 400, br: 35.5, va: 80, nf: 1, cbe: 8e-12, cbc: 4e-12),
        "2N3906": BJTModel(pnp: true, Is: 1.41e-15, bf: 180.7, br: 4.977, va: 18.7, nf: 1, cbe: 4.5e-12, cbc: 4.5e-12),
        "Germanium PNP (AC128 type)": BJTModel(pnp: true, Is: 1.2e-6, bf: 90, br: 5, va: 30, nf: 1.1, cbe: 50e-12, cbc: 20e-12),
        "Germanium NPN (AC127 type)": BJTModel(pnp: false, Is: 1.2e-6, bf: 100, br: 5, va: 30, nf: 1.1, cbe: 50e-12, cbc: 20e-12),
    ]
    public static let jfets: [String: JFETModel] = [
        "J201": JFETModel(beta: 1.304e-3, vto: -0.5, lambda: 0.0125, cgs: 4e-12, cgd: 4e-12),
        "2N5457": JFETModel(beta: 1.125e-3, vto: -1.8, lambda: 0.0023, cgs: 3e-12, cgd: 1.5e-12),
        "MPF102": JFETModel(beta: 1.0e-3, vto: -2.0, lambda: 0.0022, cgs: 3e-12, cgd: 3e-12),
        // P-channel: mid-range of the onsemi data-sheet limits (2N5460: cut-off 0.75-6 V, Idss 1-5 mA;
        // J175: 3-6 V, 7-60 mA). Pinch-off is written negative, as for N-channel.
        "2N5460": JFETModel(beta: 0.75e-3, vto: -2.0, lambda: 0.004, cgs: 5e-12, cgd: 1.5e-12, pch: true),
        "J175": JFETModel(beta: 1.5e-3, vto: -4.5, lambda: 0.01, cgs: 11e-12, cgd: 5.5e-12, pch: true),
    ]
    // Small-signal MOSFETs, fitted to the makers' data sheets (onsemi 2N7000 and BS170, Diodes BS250P):
    // threshold at 1 mA, transconductance at 200-250 mA and on-resistance at 10 V all land on the typical
    // figures where one is given, and inside the limits otherwise.
    public static let mosfets: [String: MOSFETModel] = [
        "2N7000": MOSFETModel(pmos: false, vto: 2.0, kp: 0.12, lambda: 0.0003, cgs: 20e-12, cgd: 5e-12),
        "BS170": MOSFETModel(pmos: false, vto: 1.9, kp: 0.08, lambda: 0.0003, cgs: 24e-12, cgd: 7e-12),
        "BS250": MOSFETModel(pmos: true, vto: 2.0, kp: 0.056, lambda: 0.012, cgs: 45e-12, cgd: 15e-12),
    ]
    public static let opamps: [String: OpAmpModel] = [
        "TL072": OpAmpModel(gain: 2e5, gbw: 3e6, headroom: 1.5, rout: 75, slew: 13),
        "NE5532": OpAmpModel(gain: 1e5, gbw: 10e6, headroom: 1.2, rout: 30, slew: 9),
        "LM741": OpAmpModel(gain: 2e5, gbw: 1e6, headroom: 2.0, rout: 75, slew: 0.5),
        "LM308": OpAmpModel(gain: 3e5, gbw: 0.3e6, headroom: 1.0, rout: 100, slew: 0.3),
        "JRC4558": OpAmpModel(gain: 1e5, gbw: 3e6, headroom: 1.4, rout: 75, slew: 1.0),
        "Ideal": OpAmpModel(gain: 1e6, gbw: 1e9, headroom: 0.0, rout: 1, slew: 1e6),
    ]
    public static let triodes: [String: TriodeModel] = [
        "12AX7": TriodeModel(mu: 100, ex: 1.4, kg1: 1060, kp: 600, kvb: 300, cgp: 1.7e-12, cgk: 1.6e-12, cpk: 0.46e-12),
        "12AT7": TriodeModel(mu: 60, ex: 1.35, kg1: 460, kp: 300, kvb: 300, cgp: 1.5e-12, cgk: 2.2e-12, cpk: 0.5e-12),
        "12AU7": TriodeModel(mu: 21.5, ex: 1.3, kg1: 1180, kp: 84, kvb: 300, cgp: 1.5e-12, cgk: 1.6e-12, cpk: 0.5e-12),
        "ECC83 (EU 12AX7)": TriodeModel(mu: 100, ex: 1.4, kg1: 1060, kp: 600, kvb: 300, cgp: 1.7e-12, cgk: 1.6e-12, cpk: 0.46e-12),
    ]

    public static func diode(_ name: String, led: Bool) -> DiodeModel {
        (led ? leds[name] : diodes[name]) ?? (led ? leds["Red LED"]! : diodes["1N4148"]!)
    }
    public static func bjt(_ name: String, pnp: Bool) -> BJTModel {
        if let m = bjts[name], m.pnp == pnp { return m }
        return pnp ? bjts["2N3906"]! : bjts["2N3904"]!
    }
    public static func jfet(_ name: String, pch: Bool = false) -> JFETModel {
        if let m = jfets[name], m.pch == pch { return m }
        return pch ? jfets["2N5460"]! : jfets["J201"]!
    }
    public static func zener(_ name: String) -> DiodeModel { zeners[name] ?? zeners["5.1 V (1N4733A)"]! }
    public static func mosfet(_ name: String, pmos: Bool) -> MOSFETModel {
        if let m = mosfets[name], m.pmos == pmos { return m }
        return pmos ? mosfets["BS250"]! : mosfets["2N7000"]!
    }
    public static func opamp(_ name: String) -> OpAmpModel { opamps[name] ?? opamps["TL072"]! }
    public static func triode(_ name: String) -> TriodeModel { triodes[name] ?? triodes["12AX7"]! }

    /// Taper by index (0 = B linear, 1 = A audio, 2 = C reverse audio); no allocation, for the audio thread.
    @inline(__always) public static func taper(index: Int, _ pos: Double) -> Double {
        let p = min(max(pos, 0), 1)
        let k = 4.394449
        switch index {
        case 1: return (exp(k * p) - 1) / (exp(k) - 1)
        case 2: return 1 - (exp(k * (1 - p)) - 1) / (exp(k) - 1)
        default: return p
        }
    }

    /// Potentiometer taper: fraction of the track resistance between end 1 and the wiper.
    public static func taper(_ kind: String, _ pos: Double) -> Double {
        let p = min(max(pos, 0), 1)
        let k = 4.394449  // 2·ln 9: 10 % at mid travel
        switch kind {
        case "A": return (exp(k * p) - 1) / (exp(k) - 1)
        case "C": return 1 - (exp(k * (1 - p)) - 1) / (exp(k) - 1)
        default: return p
        }
    }
}
