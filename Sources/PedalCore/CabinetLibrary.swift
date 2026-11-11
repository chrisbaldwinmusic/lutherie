import Foundation

/// A built-in speaker cabinet: which box, which microphone, and where the microphone points.
public struct CabinetChoice: Codable, Hashable, Sendable {
    public var cabinet: String
    public var mic: String
    public var position: String
    public init(cabinet: String, mic: String = CabinetLibrary.mics[0], position: String = CabinetLibrary.positions[1]) {
        self.cabinet = cabinet; self.mic = mic; self.position = position
    }
    public var title: String { "\(cabinet) · \(mic) · \(position)" }
}

/// Speaker cabinets built into the app. Each one is an impulse response computed from a model of the
/// speaker, the box, the neighbouring speakers and the microphone. They are designed voicings of the
/// familiar cabinet types, not measurements of particular cabinets.
public enum CabinetLibrary {
    struct Speaker {
        var resonance: Double        // Hz, free-air
        var q: Double
        var body: (f: Double, gain: Double, q: Double)       // low-mid character
        var mid: (f: Double, gain: Double, q: Double)        // midrange dip or hump
        var breakup: (f: Double, gain: Double, q: Double)    // cone break-up peak
        var edge: (f: Double, gain: Double, q: Double)       // upper peak before the roll-off
        var rolloff: Double          // Hz, where the cone stops radiating
        var inches = 12
    }

    struct Box {
        var name: String
        var speaker: Speaker
        var count: Int
        var openBack: Bool
        var size: Double             // rough internal size in metres; sets the box resonance and rear-wave delay
        var notes: String
    }

    // Speaker voicings by family.
    static let american12 = Speaker(resonance: 90, q: 1.1, body: (140, 2.5, 1.2), mid: (450, -3.5, 0.9),
                                    breakup: (2900, 5, 1.6), edge: (4300, 2.5, 3), rolloff: 5600)
    static let alnico12 = Speaker(resonance: 75, q: 0.9, body: (120, 1.5, 1.0), mid: (700, -1.5, 0.8),
                                  breakup: (2500, 6.5, 1.4), edge: (4600, 3.5, 2.5), rolloff: 6000)
    static let british25 = Speaker(resonance: 78, q: 1.2, body: (130, 3, 1.3), mid: (650, 2.5, 0.8),
                                   breakup: (2200, 5.5, 1.5), edge: (3600, 1.5, 3), rolloff: 4700)
    static let modern60 = Speaker(resonance: 72, q: 1.0, body: (110, 3.5, 1.4), mid: (400, -2.5, 1.0),
                                  breakup: (1900, 6, 1.2), edge: (4000, 5, 3.5), rolloff: 5200)
    static let tweed10 = Speaker(resonance: 105, q: 1.2, body: (180, 2, 1.2), mid: (600, -1, 0.9),
                                 breakup: (3100, 6, 1.5), edge: (4700, 2, 3), rolloff: 5400, inches: 10)
    static let ceramic10 = Speaker(resonance: 95, q: 1.0, body: (160, 2.5, 1.2), mid: (500, -3, 0.9),
                                   breakup: (3300, 4.5, 1.5), edge: (4800, 3, 3), rolloff: 5900, inches: 10)
    static let big15 = Speaker(resonance: 52, q: 1.0, body: (90, 4, 1.2), mid: (350, -2, 0.9),
                               breakup: (1700, 4.5, 1.3), edge: (2900, 2, 3), rolloff: 3900, inches: 15)
    // Bass speakers: lower resonance, flatter midrange, less break-up.
    static let bass10 = Speaker(resonance: 42, q: 0.8, body: (85, 2.5, 1.0), mid: (450, -2.5, 0.8),
                                breakup: (2300, 3, 1.4), edge: (3600, 1.5, 3), rolloff: 4400, inches: 10)
    static let bassSealed10 = Speaker(resonance: 48, q: 0.9, body: (100, 3, 1.1), mid: (800, 2, 0.8),
                                      breakup: (2000, 3.5, 1.4), edge: (3200, 1, 3), rolloff: 3800, inches: 10)
    static let bass15 = Speaker(resonance: 33, q: 0.8, body: (65, 3.5, 1.0), mid: (380, -3, 0.8),
                                breakup: (1500, 2.5, 1.3), edge: (2400, 1, 3), rolloff: 3000, inches: 15)

    static let boxes: [Box] = [
        Box(name: "1×12 Open American", speaker: american12, count: 1, openBack: true, size: 0.50,
            notes: "One 12-inch ceramic speaker in an open-back combo: scooped mids, glassy top, loose low end."),
        Box(name: "2×12 Open Alnico", speaker: alnico12, count: 2, openBack: true, size: 0.68,
            notes: "Two alnico 12s in an open-back combo: chiming upper mids and a bright, complex top."),
        Box(name: "2×12 Closed British", speaker: british25, count: 2, openBack: false, size: 0.70,
            notes: "Two 25-watt-style 12s in a closed box: woody mids with a firmer low end than the open cabinets."),
        Box(name: "4×12 Closed British", speaker: british25, count: 4, openBack: false, size: 0.76,
            notes: "Four 25-watt-style 12s in a closed cabinet: thick low mids, a mid hump and a soft top. Classic rock."),
        Box(name: "4×12 Closed Modern", speaker: modern60, count: 4, openBack: false, size: 0.76,
            notes: "Four 60-watt-style 12s in a closed cabinet: tight lows, forward upper mids and a sharp top. Heavy rhythm."),
        Box(name: "1×10 Open Tweed", speaker: tweed10, count: 1, openBack: true, size: 0.40,
            notes: "One alnico 10 in a small open-back combo: boxy, midrange-forward, little deep bass."),
        Box(name: "4×10 Open American", speaker: ceramic10, count: 4, openBack: true, size: 0.62,
            notes: "Four 10s in an open-back combo: punchy and clear with a quick attack."),
        Box(name: "1×15 Closed", speaker: big15, count: 1, openBack: false, size: 0.66,
            notes: "One 15-inch speaker in a closed box: deep lows and a dark, smooth top."),
        Box(name: "Bass 1×15 Closed", speaker: bass15, count: 1, openBack: false, size: 0.70,
            notes: "Bass cabinet. One 15: round, deep and warm with a soft top. Old-school fingerstyle and studio bass."),
        Box(name: "Bass 4×10 Closed", speaker: bass10, count: 4, openBack: false, size: 0.62,
            notes: "Bass cabinet. Four 10s: punchy low mids and a clear, quick top. The modern all-rounder."),
        Box(name: "Bass 8×10 Sealed", speaker: bassSealed10, count: 8, openBack: false, size: 1.20,
            notes: "Bass cabinet. Eight 10s in a tall sealed box: a tight low end with a strong midrange push. Rock and pick playing."),
    ]

    public static var cabinets: [String] { boxes.map(\.name) }
    public static let mics = ["Dynamic", "Large dynamic", "Ribbon", "Condenser"]
    public static let positions = ["Cap", "Cap edge", "Cone"]
    public static func notes(_ cabinet: String) -> String { boxes.first { $0.name == cabinet }?.notes ?? "" }
    public static func contains(_ c: CabinetChoice) -> Bool {
        cabinets.contains(c.cabinet) && mics.contains(c.mic) && positions.contains(c.position)
    }

    static func run(_ filters: [Biquad], _ x: [Double]) -> [Double] {
        var f = filters, y = x
        for i in 0..<y.count { var v = y[i]; for k in 0..<f.count { v = f[k].run(v) }; y[i] = v }
        return y
    }

    /// Adds `gain` × a filtered copy of `x`, `seconds` late, to `y` (fractional delays by linear interpolation).
    static func addDelayed(_ y: inout [Double], _ x: [Double], seconds: Double, gain: Double, filters: [Biquad], sr: Double) {
        let wet = run(filters, x)
        let d = seconds * sr
        let whole = Int(d), frac = d - Double(whole)
        for i in 0..<y.count {
            let a = i - whole, b = a - 1
            var v = 0.0
            if a >= 0 { v += wet[a] * (1 - frac) }
            if b >= 0 { v += wet[b] * frac }
            y[i] += gain * v
        }
    }

    /// The impulse response of a cabinet at this sample rate, or nil if the choice isn't in the library.
    public static func impulse(_ choice: CabinetChoice, sampleRate sr: Double) -> [Float]? {
        guard let box = boxes.first(where: { $0.name == choice.cabinet }), contains(choice) else { return nil }
        let n = Int(0.045 * sr)
        var x = [Double](repeating: 0, count: n)
        x[0] = 1
        let s = box.speaker
        let top = min(s.rolloff, sr * 0.45)

        // The speaker itself.
        var y = run([
            Biquad(.peak, f: s.body.f, q: s.body.q, gainDB: s.body.gain, sr: sr),
            Biquad(.peak, f: s.mid.f, q: s.mid.q, gainDB: s.mid.gain, sr: sr),
            Biquad(.peak, f: s.breakup.f, q: s.breakup.q, gainDB: s.breakup.gain, sr: sr),
            Biquad(.peak, f: min(s.edge.f, sr * 0.4), q: s.edge.q, gainDB: s.edge.gain, sr: sr),
            Biquad(.lowpass, f: top, q: 0.9, sr: sr),
            Biquad(.lowpass, f: min(top * 1.25, sr * 0.45), q: 0.6, sr: sr),
        ], x)

        // The box. Closed: the trapped air stiffens the cone, raising and sharpening its resonance.
        // Open: the cone keeps its own resonance, and the sound from its back comes round the cabinet
        // late and inverted, which thins the bass and ripples the low mids.
        if box.openBack {
            let direct = run([Biquad(.highpass, f: s.resonance, q: s.q * 0.75, sr: sr)], y)
            y = direct
            addDelayed(&y, direct, seconds: (box.size * 1.5 + 0.12) / 343, gain: -0.42,
                       filters: [Biquad(.lowpass, f: 900, q: 0.6, sr: sr)], sr: sr)
        } else {
            let fc = s.resonance * 1.35
            y = run([Biquad(.highpass, f: fc, q: s.q * 1.05, sr: sr),
                     Biquad(.peak, f: 343 / (2 * box.size), q: 3, gainDB: 1.8, sr: sr),      // air mode across the box
                     Biquad(.peak, f: 343 / box.size, q: 4, gainDB: -1.5, sr: sr)], y)
        }

        // The other speakers reach the microphone later, quieter and duller (it points at one of them).
        if box.count > 1 {
            let single = y
            let off = [Biquad(.lowpass, f: 2600, q: 0.6, sr: sr), Biquad(.highShelf, f: 1500, q: 0.7, gainDB: -4, sr: sr)]
            let spacing = box.speaker.inches >= 15 ? 0.42 : (box.speaker.inches <= 10 ? 0.27 : 0.33)
            addDelayed(&y, single, seconds: spacing * 0.55 / 343, gain: 0.34, filters: off, sr: sr)
            if box.count >= 4 {
                addDelayed(&y, single, seconds: spacing * 0.6 / 343, gain: 0.30, filters: off, sr: sr)
                addDelayed(&y, single, seconds: spacing * 1.0 / 343, gain: 0.20, filters: off, sr: sr)
            }
            if box.count >= 8 {
                addDelayed(&y, single, seconds: spacing * 1.7 / 343, gain: 0.16, filters: off, sr: sr)
                addDelayed(&y, single, seconds: spacing * 2.6 / 343, gain: 0.10, filters: off, sr: sr)
            }
        }
        // A weak bounce off the floor.
        let dry = y
        addDelayed(&y, dry, seconds: 0.0031 + box.size * 0.001, gain: 0.11, filters: [Biquad(.lowpass, f: 2200, q: 0.6, sr: sr)], sr: sr)

        // Where the microphone points: the dust cap is brightest, the cone darker and fuller.
        switch choice.position {
        case "Cap edge":
            y = run([Biquad(.highShelf, f: 3200, q: 0.7, gainDB: -3, sr: sr), Biquad(.peak, f: 300, q: 0.8, gainDB: 0.8, sr: sr)], y)
        case "Cone":
            y = run([Biquad(.highShelf, f: 2400, q: 0.7, gainDB: -7, sr: sr), Biquad(.peak, f: 260, q: 0.8, gainDB: 2, sr: sr),
                     Biquad(.lowpass, f: min(top * 0.9, sr * 0.45), q: 0.7, sr: sr)], y)
        default: break
        }

        // The microphone.
        let hi = sr * 0.45
        switch choice.mic {
        case "Large dynamic":
            // the kind used on bass cabinets and kick drums: keeps the bottom octave, dips the low mids
            y = run([Biquad(.highpass, f: 32, q: 0.7, sr: sr), Biquad(.peak, f: 80, q: 0.9, gainDB: 2.5, sr: sr),
                     Biquad(.peak, f: 380, q: 0.9, gainDB: -3, sr: sr), Biquad(.peak, f: min(3800, hi), q: 1.2, gainDB: 3.5, sr: sr),
                     Biquad(.lowpass, f: min(11_000, hi), q: 0.7, sr: sr)], y)
        case "Ribbon":
            y = run([Biquad(.lowShelf, f: 220, q: 0.7, gainDB: 4, sr: sr), Biquad(.peak, f: 1200, q: 0.7, gainDB: 1, sr: sr),
                     Biquad(.highShelf, f: 4500, q: 0.7, gainDB: -5.5, sr: sr), Biquad(.lowpass, f: min(11_000, hi), q: 0.7, sr: sr)], y)
        case "Condenser":
            y = run([Biquad(.highpass, f: 45, q: 0.7, sr: sr), Biquad(.peak, f: 180, q: 0.8, gainDB: 1.2, sr: sr),
                     Biquad(.peak, f: min(8500, hi), q: 1.0, gainDB: 2.5, sr: sr), Biquad(.lowpass, f: min(17_000, hi), q: 0.7, sr: sr)], y)
        default:
            y = run([Biquad(.highpass, f: 95, q: 0.6, sr: sr), Biquad(.peak, f: 170, q: 0.9, gainDB: 2.5, sr: sr),
                     Biquad(.peak, f: 420, q: 1.0, gainDB: -1.5, sr: sr), Biquad(.peak, f: min(5600, hi), q: 1.3, gainDB: 4.5, sr: sr),
                     Biquad(.lowpass, f: min(13_000, hi), q: 0.7, sr: sr)], y)
        }

        // Fade the tail out and set the level the same way as a loaded impulse response.
        let fade = n / 4
        for i in 0..<fade { let w = 0.5 - 0.5 * cos(Double.pi * Double(i) / Double(fade)); y[n - 1 - i] *= w }
        let energy = sqrt(y.reduce(0) { $0 + $1 * $1 })
        guard energy > 0, energy.isFinite else { return nil }
        return y.map { Float($0 / energy * 0.5) }
    }

    /// Level of an impulse response at one frequency, in dB.
    public static func responseDB(_ ir: [Float], _ f: Double, sampleRate sr: Double) -> Double {
        var re = 0.0, im = 0.0
        let w = 2 * Double.pi * f / sr
        for (i, v) in ir.enumerated() { re += Double(v) * cos(w * Double(i)); im -= Double(v) * sin(w * Double(i)) }
        return 10 * log10(max(re * re + im * im, 1e-24))
    }
}
