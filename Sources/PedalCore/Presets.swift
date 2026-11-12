import Foundation

/// Starter circuits. They are generic textbook topologies, drawn on the grid.
public enum Presets {
    struct Builder {
        var c: Circuit
        init(_ name: String, notes: String) { c = Circuit(name: name, notes: notes) }

        @discardableResult
        mutating func add(_ k: PartKind, _ name: String, _ x: Int, _ y: Int, rot: Int = 0, flip: Bool = false,
                          _ props: [String: Double] = [:], model: String? = nil, text: String = "") -> Part {
            let p = Part(k, name: name, at: GridPoint(x, y), rotation: rot, flipped: flip, props: props, model: model, text: text)
            c.parts.append(p)
            return p
        }
        mutating func w(_ a: (Int, Int), _ b: (Int, Int), vfirst: Bool = false) {
            c.connect(GridPoint(a.0, a.1), GridPoint(b.0, b.1), verticalFirst: vfirst)
        }
    }

    public static var pedals: [Circuit] {
        [boost, transistorBoostSheet.c, mosfetBoostSheet.c, trebleBoosterSheet.c,
         overdrive, jfetOverdriveSheet.c, selectableClipSheet.c,
         hardClipSheet.c, slewDistortionSheet.c,
         fuzz, germaniumFuzzSheet.c, sustainFuzzSheet.c,
         bassBlendDriveSheet.c,
         blank("Empty pedal")]
    }
    public static var amps: [Circuit] { [tweedSheet.c, tubePreamp, britishSheet.c, highGainSheet.c, bassPreampSheet.c, britishHeadSheet.c, blank("Empty amp")] }

    public static func blank(_ name: String) -> Circuit {
        var b = Builder(name, notes: "Start from an empty board.")
        b.add(.input, "IN", 0, 0)
        b.add(.output, "OUT", 20, 0)
        b.add(.ground, "GND1", 10, 6)
        return b.c
    }

    /// Op-amp soft clipper: diodes in the feedback loop, treble-cut tone control, level.
    public static var overdrive: Circuit {
        var b = Builder("Diode Overdrive",
                        notes: "Non-inverting op-amp stage with silicon diodes in the feedback loop (soft clipping), a treble-cut tone control and an output level.")
        b.add(.input, "IN", 0, 0, ["rs": 1000])
        b.add(.capacitor, "C1", 4, 0, ["c": 47e-9])
        b.w((2, 0), (0, 0))
        b.w((6, 0), (12, 0))
        b.add(.resistor, "R1", 8, 2, rot: 1, ["r": 1e6])
        b.add(.supply, "VREF1", 8, 4, rot: 2, ["v": 4.5], text: "4.5V")
        b.add(.opamp, "U1", 14, -1, ["vneg": 0, "vpos": 9], model: "JRC4558")
        b.w((12, -2), (10, -2))
        b.w((10, -2), (10, -12))
        b.w((16, -1), (18, -1))
        b.w((18, -1), (18, -12))
        b.add(.diode, "D1", 14, -4)
        b.w((10, -4), (12, -4)); b.w((16, -4), (18, -4))
        b.add(.diode, "D2", 14, -6, flip: true)
        b.w((10, -6), (12, -6)); b.w((16, -6), (18, -6))
        b.add(.capacitor, "C2", 14, -8, ["c": 51e-12])
        b.w((10, -8), (12, -8)); b.w((16, -8), (18, -8))
        b.add(.resistor, "R2", 12, -12, ["r": 51e3])
        b.add(.pot, "VR1", 16, -12, ["r": 500e3, "position": 0.5], model: "A", text: "Drive")
        b.w((16, -14), (18, -12))
        b.add(.resistor, "R3", 8, -2, ["r": 4.7e3])
        b.add(.capacitor, "C3", 6, -4, rot: 1, ["c": 47e-9])
        b.add(.supply, "VREF2", 6, -6, ["v": 4.5], text: "4.5V")
        // tone
        b.add(.resistor, "R4", 20, -1, ["r": 1e3])
        b.add(.capacitor, "C4", 22, 1, rot: 1, ["c": 220e-9])
        b.add(.pot, "VR2", 22, 5, rot: 1, ["r": 20e3, "position": 0.5], model: "B", text: "Tone")
        b.w((24, 5), (22, 7), vfirst: true)
        b.add(.supply, "VREF3", 22, 7, rot: 2, ["v": 4.5], text: "4.5V")
        // level
        b.add(.capacitor, "C5", 30, -1, ["c": 1e-6])
        b.w((22, -1), (28, -1))
        b.add(.pot, "VR3", 32, 1, rot: 1, flip: true, ["r": 100e3, "position": 0.8], model: "A", text: "Level")
        b.add(.ground, "GND1", 32, 3)
        b.add(.output, "OUT", 36, 1, ["rl": 1e6])
        b.w((34, 1), (36, 1))
        return b.c
    }

    /// Two-transistor fuzz with DC feedback bias.
    public static var fuzz: Circuit {
        var b = Builder("Two-Transistor Fuzz",
                        notes: "Two directly coupled transistors with feedback bias through R3. Fuzz sets how much emitter degeneration is bypassed.")
        b.add(.input, "IN", 0, 0, ["rs": 1000])
        b.add(.capacitor, "C1", 4, 0, ["c": 2.2e-6])
        b.w((0, 0), (2, 0))
        b.add(.npn, "Q1", 8, 0, model: "BC109")
        b.add(.ground, "GND1", 9, 2)
        b.add(.resistor, "R1", 9, -4, rot: 1, ["r": 33e3])
        b.add(.supply, "VCC1", 9, -6, ["v": 9], text: "9V")
        b.add(.npn, "Q2", 14, -2, model: "BC109")
        b.w((9, -2), (12, -2))
        b.add(.resistor, "R2", 15, -6, rot: 1, ["r": 8.2e3])
        b.add(.supply, "VCC2", 15, -8, ["v": 9], text: "9V")
        b.add(.pot, "VR1", 15, 2, rot: 3, ["r": 1e3, "position": 0.8], model: "B", text: "Fuzz")
        b.add(.ground, "GND2", 15, 4)
        b.add(.capacitor, "C2", 11, 2, ["c": 22e-6])
        b.w((6, 0), (6, 6))
        b.add(.resistor, "R3", 10, 6, ["r": 100e3])
        b.w((6, 6), (8, 6))
        b.w((12, 6), (17, 6))
        b.w((17, 6), (17, 0))
        b.w((17, 0), (15, 0))
        b.add(.capacitor, "C3", 19, -4, ["c": 10e-9])
        b.w((15, -4), (17, -4))
        b.add(.pot, "VR2", 21, -2, rot: 1, flip: true, ["r": 500e3, "position": 0.5], model: "A", text: "Volume")
        b.add(.ground, "GND3", 21, 0)
        b.add(.output, "OUT", 25, -2, ["rl": 1e6])
        b.w((23, -2), (25, -2))
        return b.c
    }

    /// Single JFET common-source booster.
    public static var boost: Circuit {
        var b = Builder("JFET Clean Boost",
                        notes: "One JFET in common source with a bypassed source resistor: up to about 20 dB of clean gain.")
        b.add(.input, "IN", 0, 0, ["rs": 1000])
        b.add(.capacitor, "C1", 4, 0, ["c": 100e-9])
        b.w((0, 0), (2, 0))
        b.add(.njfet, "J1", 8, 0, model: "J201")
        b.add(.resistor, "R1", 6, 2, rot: 1, ["r": 1e6])
        b.add(.ground, "GND1", 6, 4)
        b.add(.resistor, "R2", 9, 4, rot: 1, ["r": 680])
        b.add(.ground, "GND2", 9, 6)
        b.add(.capacitor, "C2", 11, 4, rot: 1, ["c": 10e-6])
        b.w((9, 2), (11, 2))
        b.add(.ground, "GND3", 11, 6)
        b.add(.resistor, "R3", 9, -4, rot: 1, ["r": 6.8e3])
        b.add(.supply, "VCC1", 9, -6, ["v": 9], text: "9V")
        b.add(.capacitor, "C3", 13, -2, ["c": 1e-6])
        b.w((9, -2), (11, -2))
        b.add(.pot, "VR1", 15, 0, rot: 1, flip: true, ["r": 100e3, "position": 0.7], model: "A", text: "Level")
        b.add(.ground, "GND4", 15, 2)
        b.add(.output, "OUT", 19, 0, ["rl": 1e6])
        b.w((17, 0), (19, 0))
        return b.c
    }

    /// Two 12AX7 gain stages into a three-knob passive tone stack and a master volume.
    public static var tubePreamp: Circuit {
        var b = Builder("Two-Stage Tube Preamp",
                        notes: "Two common-cathode 12AX7 stages, a treble/bass/middle passive tone stack driven from the second plate, and a master volume.")
        b.add(.input, "IN", 0, 0, ["rs": 1000, "scale": 1])
        b.w((0, 0), (2, 0))
        b.add(.resistor, "R1", 2, 2, rot: 1, ["r": 1e6])
        b.add(.ground, "GND1", 2, 4)
        b.add(.resistor, "R2", 4, 0, ["r": 68e3])
        b.add(.triode, "V1", 8, 0, model: "12AX7")
        b.add(.resistor, "R3", 9, 4, rot: 1, ["r": 1.5e3])
        b.add(.ground, "GND2", 9, 6)
        b.add(.capacitor, "C1", 11, 4, rot: 1, ["c": 22e-6])
        b.w((9, 2), (11, 2))
        b.add(.ground, "GND3", 11, 6)
        b.add(.resistor, "R4", 9, -4, rot: 1, ["r": 100e3])
        b.add(.supply, "VB1", 9, -6, ["v": 250], text: "B+ 250V")
        b.add(.capacitor, "C2", 13, -2, ["c": 22e-9])
        b.w((9, -2), (11, -2))
        b.add(.pot, "VR1", 15, 0, rot: 1, flip: true, ["r": 1e6, "position": 0.6], model: "A", text: "Gain")
        b.add(.ground, "GND4", 15, 2)
        b.add(.resistor, "R5", 19, 0, ["r": 68e3])
        b.add(.triode, "V2", 23, 0, model: "12AX7")
        b.add(.resistor, "R6", 24, 4, rot: 1, ["r": 1.5e3])
        b.add(.ground, "GND5", 24, 6)
        b.add(.capacitor, "C3", 26, 4, rot: 1, ["c": 1e-6])
        b.w((24, 2), (26, 2))
        b.add(.ground, "GND6", 26, 6)
        b.add(.resistor, "R7", 24, -4, rot: 1, ["r": 100e3])
        b.add(.supply, "VB2", 24, -6, ["v": 250], text: "B+ 250V")
        // tone stack
        b.w((24, -2), (28, -2))
        b.w((28, -2), (28, -8))
        b.add(.capacitor, "C4", 30, -8, ["c": 250e-12])
        b.add(.pot, "VR2", 32, -6, rot: 1, ["r": 250e3, "position": 0.6], model: "A", text: "Treble")
        b.w((28, -2), (28, 2))
        b.add(.resistor, "R8", 30, 2, ["r": 100e3])
        b.add(.capacitor, "C5", 32, 0, rot: 1, ["c": 100e-9])
        b.w((32, -4), (32, -2))
        b.add(.pot, "VR3", 36, -4, rot: 2, ["r": 1e6, "position": 0.5], model: "A", text: "Bass")
        b.w((32, -4), (34, -4))
        b.w((36, -2), (34, -4))
        b.add(.capacitor, "C6", 38, 0, rot: 1, ["c": 47e-9])
        b.w((32, 2), (38, 2))
        b.w((38, -4), (38, -2))
        b.add(.pot, "VR4", 42, -4, ["r": 25e3, "position": 0.5], model: "B", text: "Middle")
        b.w((38, -4), (40, -4))
        b.w((42, -6), (44, -4))
        b.add(.ground, "GND7", 44, -4)
        // master
        b.w((34, -6), (34, -10), vfirst: true)
        b.w((34, -10), (48, -10))
        b.add(.pot, "VR5", 48, -8, rot: 1, flip: true, ["r": 1e6, "position": 0.5], model: "A", text: "Master")
        b.add(.ground, "GND8", 48, -6)
        b.add(.output, "OUT", 52, -8, ["rl": 1e6, "scale": 0.1])
        b.w((50, -8), (52, -8))
        return b.c
    }
}
