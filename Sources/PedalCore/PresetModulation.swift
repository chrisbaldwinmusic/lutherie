import Foundation

/// Modulation and time effects, drawn as whole circuits: the phaser's sweep is four JFETs used as resistors, the
/// tremolo's a vactrol, and the chorus and the delay run through a bucket-brigade chip. The low-frequency
/// oscillators are LFO parts (a triangle source whose rate follows a control voltage) rather than op-amp loops:
/// a Schmitt trigger's snap from one rail to the other can't be followed sample by sample, and the LFO only
/// sets the sweep, so its shape is all that matters.
extension Presets {
    /// LFO with its Rate pot: a divider from 9 V sets the rate (exponentially, fmin to fmax); the triangle
    /// (mid ± amp volts) is on the net named `tri`.
    static func lfo(_ s: inout Sheet, ox: Int, oy: Int, rate: Double, label: String = "Rate", fmin: Double, fmax: Double,
                    mid: Double = 4.5, amp: Double = 2, wave: Double = 0, tri: String = "TRI") {
        s.add(.pot, "VRL", ox, oy, ["r": 100e3, "position": rate], model: "B", text: label)
        s.add(.lfo, "LFO1", ox + 4, oy - 2, ["fmin": fmin, "fmax": fmax, "vref": 9, "mid": mid, "amp": amp, "wave": wave])
        s.gnd("VRL.1", dy: 2)
        s.rail("VRL.3", 9, dy: 2)
        s.net("VRL.w", "LFO1.cv")
        s.net("LFO1.o", "#\(tri)@\(ox + 8),\(oy - 2)")
    }

    /// Four JFET all-pass stages swept by an LFO, mixed half and half with the dry signal.
    static var phaserSheet: Sheet {
        var s = Sheet("Four-Stage Phaser",
                      notes: "Four all-pass stages, each an op-amp with a capacitor and a JFET: the JFET, biased just above pinch-off, is a resistor whose value the LFO sweeps, so every stage's phase shift slides up and down the spectrum. Mixed half and half with the dry signal, the shifts cancel at two frequencies and the notches swoosh. The same plan as the classic one-knob orange phaser.")
        s.add(.input, "IN", 0, 0)
        s.add(.capacitor, "C1", 3, 0, ["c": 100e-9])
        s.add(.resistor, "R1", 7, 3, rot: 1, ["r": 1e6])
        s.add(.opamp, "U1", 11, 0, ["vneg": 0, "vpos": 9], model: "TL072")
        s.net("IN", "C1.1")
        s.net("C1.2", "R1.1", "U1.+")
        s.rail("R1.2", 4.5, dy: 2)
        s.net("U1.-", "@9,-3", "@13,-3", "U1.o", "#DRY@13,-6")
        var prev = "U1.o"
        for k in 1...4 {
            let x0 = 16 + 18 * (k - 1)
            s.add(.resistor, "R\(k)a", x0 + 4, -1, ["r": 10e3])
            s.add(.resistor, "R\(k)b", x0 + 10, -4, ["r": 10e3])
            s.add(.capacitor, "C\(k)a", x0 + 4, 3, ["c": 100e-9])
            s.add(.opamp, "U\(k)a", x0 + 10, 0, ["vneg": 0, "vpos": 9], model: "TL072")
            s.add(.njfet, "J\(k)", x0 + 7, 7, model: "2N5457")
            s.net(prev, "R\(k)a.1", "|C\(k)a.1")
            s.net("R\(k)a.2", "U\(k)a.-", "|R\(k)b.1")
            s.net("R\(k)b.2", "U\(k)a.o")
            s.net("C\(k)a.2", "U\(k)a.+", "|J\(k).d")
            s.rail("J\(k).s", 4.5, dy: 2)
            s.net("J\(k).g", "#GATE@\(x0 + 3),7,2")
            prev = "U\(k)a.o"
        }
        s.add(.resistor, "R5", 86, 0, ["r": 10e3])
        s.add(.resistor, "R6", 86, -6, ["r": 10e3])
        s.add(.capacitor, "C5", 91, 0, ["c": 1e-6])
        s.add(.resistor, "R7", 95, 3, rot: 1, ["r": 100e3])
        s.add(.output, "OUT", 98, 0)
        s.net(prev, "R5.1")
        s.net("#DRY@82,-6,2", "R6.1")
        s.net("R6.2", "R5.2", "C5.1")
        s.net("C5.2", "OUT")
        s.net("R7.1", "@95,0", "~C5.2")
        s.gnd("R7.2")
        // LFO and the gate bias: the triangle, scaled down and lowered, holds each JFET between nearly off and well on
        lfo(&s, ox: 30, oy: 28, rate: 0.45, label: "Speed", fmin: 0.15, fmax: 8)
        s.add(.resistor, "RG1", 50, 28, ["r": 100e3])
        s.add(.resistor, "RG2", 54, 25, rot: 1, ["r": 220e3])
        s.add(.resistor, "RG3", 54, 31, rot: 1, ["r": 100e3])
        s.net("#TRI@46,28,2", "RG1.1")
        s.net("RG2.2", "RG3.1")
        s.net("RG1.2", "@54,28", "~RG2.2")
        s.net("#GATE@57,28", "@54,28", "~RG2.2")
        s.rail("RG2.1", 9, dy: -2)
        s.gnd("RG3.2")
        return s
    }

    /// LFO-driven LED in a vactrol; the cell shunts the signal to ground through the Depth pot.
    static var optoTremoloSheet: Sheet {
        var s = Sheet("Opto Tremolo",
                      notes: "The LFO's triangle drives a transistor that lights the LED inside a vactrol. The light-dependent resistor sealed in with it shunts the guitar signal to ground, so the volume dips each time the LED brightens. The cell brightens quickly but darkens slowly, which gives the soft, lopsided throb of an amp's optical tremolo. Depth sets how much resistance stays in series with the cell.")
        s.add(.input, "IN", 0, 0)
        s.add(.capacitor, "C1", 3, 0, ["c": 100e-9])
        s.add(.resistor, "R1", 8, 0, ["r": 47e3])
        s.add(.vactrol, "OC1", 14, 4, model: "VTL5C3")
        s.add(.pot, "VR2", 20, 7, rot: 3, ["r": 100e3, "position": 0.8], model: "C", text: "Depth")
        s.add(.capacitor, "C2", 21, 0, ["c": 100e-9])
        s.add(.resistor, "R2", 25, 3, rot: 1, ["r": 1e6])
        s.add(.opamp, "U1", 29, 1, ["vneg": 0, "vpos": 9], model: "TL072")
        s.add(.resistor, "R3", 29, -3, ["r": 33e3])
        s.add(.resistor, "R4", 23, -5, rot: 1, ["r": 10e3])
        s.add(.capacitor, "C3", 23, -10, rot: 1, ["c": 10e-6])
        s.add(.capacitor, "C4", 35, 1, ["c": 1e-6])
        s.add(.pot, "VR3", 39, 3, rot: 1, flip: true, ["r": 100e3, "position": 0.7], model: "A", text: "Volume")
        s.add(.output, "OUT", 43, 3)
        s.net("IN", "C1.1")
        s.net("C1.2", "R1.1")
        s.net("R1.2", "@16,0", "|OC1.3")
        s.net("OC1.4", "VR2.3")             // the cell, then the Depth pot as a variable resistor to ground
        s.net("VR2.w", "VR2.1")
        s.gnd("VR2.1")
        s.net("@16,0", "C2.1", "~OC1.3")
        s.net("C2.2", "R2.1", "U1.+")
        s.rail("R2.2", 4.5, dy: 2)
        s.net("U1.-", "R3.1")
        s.net("R4.2", "R3.1")
        s.net("R4.1", "C3.2")
        s.gnd("C3.1", dy: -2)
        s.net("R3.2", "@31,-3", "U1.o", "C4.1")
        s.net("C4.2", "VR3.3")
        s.gnd("VR3.1")
        s.net("VR3.w", "OUT")
        // LED driver: the triangle, divided down, on an NPN with 180 Ω in its emitter. The LED is dark for the
        // bottom of each sweep and takes about 7 mA at the top.
        lfo(&s, ox: 20, oy: 28, rate: 0.5, label: "Speed", fmin: 0.5, fmax: 12, amp: 2.5)
        s.add(.resistor, "RD1", 38, 28, ["r": 27e3])
        s.add(.resistor, "RD2", 41, 31, rot: 1, ["r": 10e3])
        s.add(.npn, "Q1", 45, 28, model: "2N3904")
        s.add(.resistor, "RD3", 46, 33, rot: 1, ["r": 180])
        s.add(.resistor, "RD4", 46, 17, rot: 1, ["r": 220])
        s.net("#TRI@34,28,2", "RD1.1")
        s.net("RD1.2", "Q1.b", "~RD2.1")
        s.net("RD2.1", "@41,28")
        s.gnd("RD2.2")
        s.net("Q1.e", "RD3.1"); s.gnd("RD3.2")
        s.net("Q1.c", "@46,22", "#LEDK@48,22")
        s.rail("RD4.1", 9, dy: -2)
        s.net("RD4.2", "#LEDA@48,19")
        s.net("OC1.1", "#LEDA@10,3,2")
        s.net("OC1.2", "#LEDK@10,5,2")
        return s
    }

    /// The classic compact chorus: bucket-brigade delay of a few milliseconds, swept by the LFO, mixed with the dry.
    static var bbdChorusSheet: Sheet {
        var s = Sheet("Bucket-Brigade Chorus",
                      notes: "A 1024-stage bucket-brigade chip delays the guitar by about 7 ms; the LFO slides the chip's clock up and down, so the delay, and with it the pitch, wavers. Mixed half and half with the dry signal it doubles and shimmers. Op-amp low-pass filters either side of the chip keep its clock out of the audio, as in the real pedals, and the chip's own sampling and hiss are part of the model.")
        s.add(.input, "IN", 0, 0)
        s.add(.capacitor, "C1", 3, 0, ["c": 100e-9])
        s.add(.resistor, "R1", 7, 3, rot: 1, ["r": 1e6])
        s.add(.opamp, "U1", 11, 0, ["vneg": 0, "vpos": 9], model: "TL072")
        s.net("IN", "C1.1")
        s.net("C1.2", "R1.1", "U1.+")
        s.rail("R1.2", 4.5, dy: 2)
        s.net("U1.-", "@9,-3", "@13,-3", "U1.o", "#DRY@13,-6")
        lowPass(&s, x: 16, prefix: "A", from: "U1.o", r: 15e3)
        s.add(.bbd, "IC1", 38, 0, ["fmin": 10e3, "fmax": 100e3, "vref": 9], model: "MN3207 (1024 stages)")
        s.net("UA.o", "IC1.1")
        s.net("IC1.3", "#CV@38,4")
        lowPass(&s, x: 42, prefix: "B", from: "IC1.2", r: 15e3)
        s.add(.resistor, "R5", 66, 0, ["r": 10e3])
        s.add(.resistor, "R6", 66, -6, ["r": 10e3])
        s.add(.capacitor, "C5", 71, 0, ["c": 1e-6])
        s.add(.resistor, "R7", 75, 3, rot: 1, ["r": 100e3])
        s.add(.output, "OUT", 78, 0)
        s.net("UB.o", "R5.1")
        s.net("#DRY@62,-6,2", "R6.1")
        s.net("R6.2", "R5.2", "C5.1")
        s.net("C5.2", "OUT")
        s.net("R7.1", "@75,0", "~C5.2")
        s.gnd("R7.2")
        // clock control: Depth blends between a steady 4.5 V and the triangle, then a divider brings it to about 1.1 V
        // (a 75 kHz clock: 6.8 ms), swinging about ±0.5 V at full depth
        lfo(&s, ox: 30, oy: 28, rate: 0.35, fmin: 0.1, fmax: 8)
        s.add(.pot, "VR2", 44, 28, ["r": 10e3, "position": 0.6], model: "B", text: "Depth")
        s.add(.resistor, "RC1", 50, 26, ["r": 33e3])
        s.add(.resistor, "RC2", 54, 29, rot: 1, ["r": 12e3])
        s.net("VR2.3", "#TRI@48,29")
        s.rail("VR2.1", 4.5, dy: 2)
        s.net("VR2.w", "RC1.1")
        s.net("RC1.2", "@54,26", "#CV@57,26")
        s.net("RC2.1", "@54,26", "~RC1.2")
        s.gnd("RC2.2")
        return s
    }

    /// Unity-gain Sallen-Key low-pass (Butterworth) at 1 / (2π R √(C1 C2)), C1 = 2.2 nF from the middle to the output.
    static func lowPass(_ s: inout Sheet, x: Int, prefix p: String, from: String, r: Double, c1: Double = 2.2e-9, c2: Double = 1e-9) {
        s.add(.resistor, "R\(p)1", x + 2, 0, ["r": r])
        s.add(.resistor, "R\(p)2", x + 8, 0, ["r": r])
        s.add(.capacitor, "C\(p)1", x + 8, -5, ["c": c1])
        s.add(.capacitor, "C\(p)2", x + 10, 4, rot: 1, ["c": c2])
        s.add(.opamp, "U\(p)", x + 15, -1, ["vneg": 0, "vpos": 9], model: "TL072")
        s.net(from, "R\(p)1.1")
        s.net("R\(p)1.2", "R\(p)2.1", "|C\(p)1.1")
        s.net("C\(p)2.1", "R\(p)2.2", "U\(p).+")
        s.gnd("C\(p)2.2")
        s.net("C\(p)1.2", "@\(x + 17),-5", "U\(p).o")
        s.net("U\(p).-", "@\(x + 13),-3", "@\(x + 17),-3", "~U\(p).o")
    }

    /// Bucket-brigade echo: an inverting mixer feeds the input and the repeats into the chip; the clock sets the time.
    static var bbdDelaySheet: Sheet {
        var s = Sheet("Bucket-Brigade Delay",
                      notes: "A 4096-stage bucket-brigade chip makes echoes from 20 ms to about 300 ms: Time sets its clock (slower clock, longer delay). The echo goes back through the inverting mixer at the front for the repeats, and every pass goes through the chip and its two low-pass filters, so each repeat comes back darker and grainier than the last, which is the sound of an analog delay. Turn Time while it plays for the pitch-bending warble of a real one.")
        s.add(.input, "IN", 0, 0)
        s.add(.capacitor, "C1", 3, 0, ["c": 100e-9])
        s.add(.resistor, "R1", 7, 3, rot: 1, ["r": 1e6])
        s.add(.opamp, "U1", 11, 0, ["vneg": 0, "vpos": 9], model: "TL072")
        s.net("IN", "C1.1")
        s.net("C1.2", "R1.1", "U1.+")
        s.rail("R1.2", 4.5, dy: 2)
        s.net("U1.-", "@9,-3", "@13,-3", "U1.o", "#DRY@13,-6")
        // inverting mixer: the dry signal and the repeats, 10 kΩ feedback
        s.add(.resistor, "R2", 17, -1, ["r": 10e3])
        s.add(.opamp, "U2", 23, 0, ["vneg": 0, "vpos": 9], model: "TL072")
        s.add(.resistor, "R3", 23, -5, ["r": 10e3])
        s.add(.resistor, "R4", 17, -9, ["r": 12e3])
        s.add(.pot, "VR1", 11, -9, ["r": 100e3, "position": 0.4], model: "C", text: "Repeats")
        s.net("U1.o", "R2.1")
        s.net("R2.2", "U2.-", "|R3.1", "~R4.2")
        s.net("R4.2", "@21,-9", "@21,-5")
        s.net("R3.2", "@25,-5", "U2.o")
        s.rail("U2.+", 4.5, dy: 2)
        s.net("VR1.3", "R4.1")
        s.net("VR1.w", "VR1.1", "#WET@6,-9,2")
        lowPass(&s, x: 28, prefix: "A", from: "U2.o", r: 15e3, c1: 4.7e-9, c2: 2.2e-9)
        s.add(.bbd, "IC1", 50, -1, ["fmin": 7e3, "fmax": 100e3, "vref": 9], model: "MN3005 (4096 stages)")
        s.net("UA.o", "IC1.1")
        s.net("IC1.3", "#CV@50,3")
        lowPass(&s, x: 54, prefix: "B", from: "IC1.2", r: 15e3, c1: 4.7e-9, c2: 2.2e-9)
        s.net("UB.o", "#WET@74,-5")
        // output: dry plus the echoes through Level
        s.add(.pot, "VR3", 80, 2, rot: 1, ["r": 100e3, "position": 0.6], model: "B", text: "Level")
        s.add(.resistor, "R5", 85, 2, ["r": 10e3])
        s.add(.resistor, "R6", 85, -6, ["r": 10e3])
        s.add(.capacitor, "C5", 91, 2, ["c": 1e-6])
        s.add(.resistor, "R7", 95, 5, rot: 1, ["r": 100e3])
        s.add(.output, "OUT", 98, 2)
        s.net("VR3.3", "#WET@80,7")
        s.rail("VR3.1", 4.5, dy: -2)
        s.net("VR3.w", "@83,2", "R5.1")
        s.net("#DRY@81,-6,2", "R6.1")
        s.net("R6.2", "R5.2", "C5.1")
        s.net("C5.2", "OUT")
        s.net("R7.1", "@95,2", "~C5.2")
        s.gnd("R7.2")
        // Time: a divider from 9 V sets the clock (0 V: 100 kHz, 20 ms; 9 V: 7 kHz, 290 ms)
        s.add(.pot, "VR2", 50, 10, ["r": 100e3, "position": 0.5], model: "B", text: "Time")
        s.gnd("VR2.1")
        s.rail("VR2.3", 9, dy: -2)
        s.net("VR2.w", "#CV@50,6")
        return s
    }
}
