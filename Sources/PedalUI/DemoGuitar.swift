import Foundation

/// A plucked-string guitar (Karplus–Strong) playing a looping riff, so the rig can be heard without an instrument.
/// Levels are like a real guitar at the jack: a few hundred millivolts.
public final class DemoGuitar: @unchecked Sendable {
    struct Voice {
        var buf: UnsafeMutablePointer<Float>
        var len = 1
        var pos = 0
        var damp: Float = 0.996
        var bright: Float = 0.5
        var last: Float = 0
        var active = false
    }
    struct Event { let beat: Double; let notes: [Int]; let muted: Bool; let length: Double }

    var voices: [Voice] = []
    var sr: Double = 48_000
    var sample = 0
    var nextEvent = 0
    var rng: UInt32 = 22_222
    let bpm = 112.0
    let events: [Event]
    let loopBeats = 16.0

    public init() {
        func power(_ root: Int) -> [Int] { [root, root + 7, root + 12] }
        var e: [Event] = []
        // bar 1: chugging low E, then G and A
        for i in 0..<6 { e.append(Event(beat: Double(i) * 0.5, notes: power(40), muted: true, length: 0.5)) }
        e.append(Event(beat: 3.0, notes: power(43), muted: false, length: 0.5))
        e.append(Event(beat: 3.5, notes: power(45), muted: false, length: 0.5))
        // bar 2: ringing A and G, chugs
        e.append(Event(beat: 4.0, notes: power(45), muted: false, length: 1))
        e.append(Event(beat: 5.0, notes: power(43), muted: false, length: 1))
        for i in 0..<4 { e.append(Event(beat: 6.0 + Double(i) * 0.5, notes: power(40), muted: true, length: 0.5)) }
        // bar 3: repeat of bar 1
        for i in 0..<6 { e.append(Event(beat: 8.0 + Double(i) * 0.5, notes: power(40), muted: true, length: 0.5)) }
        e.append(Event(beat: 11.0, notes: power(43), muted: false, length: 0.5))
        e.append(Event(beat: 11.5, notes: power(45), muted: false, length: 0.5))
        // bar 4: D chord and a single-note lick
        e.append(Event(beat: 12.0, notes: power(50), muted: false, length: 1.5))
        for (i, n) in [52, 55, 57, 59, 62].enumerated() {
            e.append(Event(beat: 13.5 + Double(i) * 0.5, notes: [n], muted: false, length: 0.5))
        }
        events = e
        for _ in 0..<6 {
            let b = UnsafeMutablePointer<Float>.allocate(capacity: 4096)
            b.initialize(repeating: 0, count: 4096)
            voices.append(Voice(buf: b))
        }
    }

    deinit { for v in voices { v.buf.deallocate() } }

    public func prepare(sampleRate: Double) {
        sr = sampleRate
        sample = 0
        nextEvent = 0
        for i in voices.indices { voices[i].active = false }
    }

    @inline(__always) func noise() -> Float {
        rng = rng &* 1_664_525 &+ 1_013_904_223
        return Float(rng >> 8) / 8_388_608 - 1
    }

    func pluck(_ notes: [Int], muted: Bool) {
        for (i, n) in notes.enumerated() where i < voices.count {
            let f = 440 * pow(2, Double(n - 69) / 12)
            var v = voices[i]
            v.len = min(4095, max(2, Int(sr / f)))
            v.pos = 0
            v.damp = muted ? 0.93 : 0.9975
            v.bright = muted ? 0.25 : 0.55
            // pick: a filtered noise burst
            var lp: Float = 0
            let amp: Float = (muted ? 0.22 : 0.3) / Float(notes.count).squareRoot()
            for k in 0..<v.len {
                lp += (noise() - lp) * (muted ? 0.35 : 0.7)
                v.buf[k] = lp * amp
            }
            v.last = 0
            v.active = true
            voices[i] = v
        }
        for i in notes.count..<voices.count { voices[i].damp = 0.9 }  // stop other strings
    }

    public func render(_ out: UnsafeMutablePointer<Float>, _ frames: Int) {
        let samplesPerBeat = sr * 60 / bpm
        let loopLen = Int(loopBeats * samplesPerBeat)
        for f in 0..<frames {
            let t = sample % loopLen
            if t == 0 { nextEvent = 0 }
            while nextEvent < events.count && Int(events[nextEvent].beat * samplesPerBeat) == t {
                pluck(events[nextEvent].notes, muted: events[nextEvent].muted)
                nextEvent += 1
            }
            var y: Float = 0
            for i in voices.indices where voices[i].active {
                var v = voices[i]
                let a = v.buf[v.pos]
                let nextPos = v.pos + 1 == v.len ? 0 : v.pos + 1
                let b = v.buf[nextPos]
                let s = (a * (1 - v.bright) + b * v.bright) * v.damp
                v.buf[v.pos] = s
                v.pos = nextPos
                y += a
                voices[i] = v
            }
            out[f] = y
            sample += 1
        }
    }
}
