import Foundation
import os

/// Parameter slots shared by the app, the Audio Unit and the VST3 plugin.
public enum RigParam: Int, CaseIterable {
    case inputLevel = 0, outputLevel, pedalOn, ampMode, cabMode, powerDrive, presence, gate, mix
    case pedalKnob1 = 10, pedalKnob2, pedalKnob3, pedalKnob4, pedalKnob5, pedalKnob6, pedalKnob7, pedalKnob8
    case ampKnob1 = 20, ampKnob2, ampKnob3, ampKnob4, ampKnob5, ampKnob6, ampKnob7, ampKnob8

    public static let count = 32

    public var name: String {
        switch self {
        case .inputLevel: return "Input Level"
        case .outputLevel: return "Output Level"
        case .pedalOn: return "Pedal On"
        case .ampMode: return "Amp"
        case .cabMode: return "Cabinet"
        case .powerDrive: return "Power Amp Drive"
        case .presence: return "Presence"
        case .gate: return "Noise Gate"
        case .mix: return "Mix"
        default:
            let r = rawValue
            return r >= 20 ? "Amp Knob \(r - 19)" : "Pedal Knob \(r - 9)"
        }
    }
    public var range: ClosedRange<Float> {
        switch self {
        case .inputLevel: return -24...24
        case .outputLevel: return -48...12
        case .pedalOn: return 0...1
        case .ampMode: return 0...2
        case .cabMode: return 0...2
        case .presence: return -8...8
        case .gate: return -100 ... -30
        default: return 0...1
        }
    }
    public var defaultValue: Float {
        switch self {
        case .inputLevel: return 0
        case .outputLevel: return -6
        case .pedalOn: return 1
        case .ampMode: return 1
        case .cabMode: return 1
        case .powerDrive: return 0.35
        case .presence: return 0
        case .gate: return -100
        case .mix: return 1
        default: return 0.5
        }
    }
    public var unit: String {
        switch self {
        case .inputLevel, .outputLevel, .presence, .gate: return "dB"
        default: return ""
        }
    }
    public var isIndexed: Bool { self == .pedalOn || self == .ampMode || self == .cabMode }
    public var valueNames: [String]? {
        switch self {
        case .pedalOn: return ["Bypassed", "On"]
        case .ampMode: return ["Off", "Tube circuit", "Amp profile"]
        case .cabMode: return ["Off", "Built-in", "Impulse response"]
        default: return nil
        }
    }
}

/// One circuit running at an oversampled rate between an interpolator and a decimator.
/// The amp's power stage runs here too, at the oversampled rate, so its clipping is anti-aliased with the circuit's.
public final class CircuitStage {
    public let engine: CircuitEngine
    public let factor: Int
    let os: Oversampler
    let buf: UnsafeMutablePointer<Double>
    var powerOn = false
    var powerDrive = 1.0, powerMakeup = 1.0
    var powerDC: DCBlocker
    var chainDC: DCBlocker

    public init(circuit: Circuit, hostRate: Double, factor: Int) throws {
        self.factor = max(1, factor)
        engine = try CircuitEngine(circuit: circuit, sampleRate: hostRate * Double(self.factor))
        os = Oversampler(factor: self.factor)
        buf = .allocate(capacity: self.factor)
        powerDC = DCBlocker(sr: hostRate * Double(self.factor))
        chainDC = DCBlocker(sr: hostRate * Double(self.factor))
    }
    deinit { buf.deallocate() }

    /// Delay through this stage in host samples.
    public var latency: Int { os.latency }

    /// Push-pull power stage: smooth, slightly asymmetric saturation (after removing the plate's DC level).
    @inline(__always) func power(_ v: Double) -> Double {
        let x = powerDC.run(v) * powerDrive
        let y = x >= 0 ? tanh(x) : tanh(x * 0.92) / 0.92
        return y * powerMakeup * 0.5
    }

    @inline(__always) func run(_ x: Float) -> Float {
        if factor == 1 {
            let y = engine.tick(Double(x))
            return Float(powerOn ? power(y) : y)
        }
        os.up(Double(x), buf)
        if powerOn {
            for k in 0..<factor { buf[k] = power(engine.tick(buf[k])) }
        } else {
            for k in 0..<factor { buf[k] = engine.tick(buf[k]) }
        }
        let y = os.down(buf)
        return y.isFinite ? Float(y) : 0
    }

    /// Processes a block in place. `powerDrive` (0…1) adds the power stage after the circuit; nil leaves it out.
    func process(_ x: UnsafeMutablePointer<Float>, _ frames: Int, knobs: UnsafePointer<Float>, powerDrive pd: Float? = nil) {
        for i in 0..<min(engine.knobCount, 8) { engine.setKnob(i, Double(knobs[i])) }
        setPower(pd)
        var start = 0
        while start < frames {
            let n = min(32, frames - start)
            engine.applyKnobs()
            for f in start..<(start + n) { x[f] = run(x[f]) }
            start += n
        }
        checkHealth()
    }

    func setPower(_ pd: Float?) {
        // a circuit with real power tubes needs no stand-in power stage
        if let pd, !engine.circuit.hasPowerStage {
            powerOn = true
            powerDrive = 0.5 + 6 * Double(pd)
            powerMakeup = 1 / tanh(powerDrive * 0.5)
        } else { powerOn = false }
    }

    func checkHealth() {
        if !engine.isHealthy { engine.recover() }
        if !(powerDC.y1.isFinite && powerDC.x1.isFinite) { powerDC.x1 = 0; powerDC.y1 = 0 }
        if !(chainDC.y1.isFinite && chainDC.x1.isFinite) { chainDC.x1 = 0; chainDC.y1 = 0 }
    }

    /// This circuit straight into `next` (pedal into amp) inside one oversampled pass: one interpolator and one
    /// decimator for both, so half the delay and filtering of running them separately. Needs equal factors.
    func processChained(_ x: UnsafeMutablePointer<Float>, _ frames: Int, knobs: UnsafePointer<Float>,
                        next: CircuitStage, nextKnobs: UnsafePointer<Float>, powerDrive pd: Float?) {
        for i in 0..<min(engine.knobCount, 8) { engine.setKnob(i, Double(knobs[i])) }
        for i in 0..<min(next.engine.knobCount, 8) { next.engine.setKnob(i, Double(nextKnobs[i])) }
        next.setPower(pd)
        let a = engine, b = next.engine
        var start = 0
        while start < frames {
            let n = min(32, frames - start)
            a.applyKnobs(); b.applyKnobs()
            for f in start..<(start + n) {
                os.up(Double(x[f]), buf)
                for k in 0..<factor {
                    let y = b.tick(chainDC.run(a.tick(buf[k])))
                    buf[k] = next.powerOn ? next.power(y) : y
                }
                let y = os.down(buf)
                x[f] = y.isFinite ? Float(y) : 0
            }
            start += n
        }
        checkHealth(); next.checkHealth()
    }
}

/// An amp profile running at its own sample rate when that differs from the host.
public final class ProfileStage {
    public let model: NAMModel
    let hostRate: Double
    let toModel: StreamResampler?
    let toHost: StreamResampler?
    let work: UnsafeMutablePointer<Float>
    let workCap = 8192
    var primed = false

    public init(model: NAMModel, hostRate: Double) {
        self.model = model
        self.hostRate = hostRate
        if abs(model.modelSampleRate - hostRate) > 1 {
            toModel = StreamResampler(from: hostRate, to: model.modelSampleRate)
            toHost = StreamResampler(from: model.modelSampleRate, to: hostRate)
        } else { toModel = nil; toHost = nil }
        work = .allocate(capacity: workCap)
        work.initialize(repeating: 0, count: workCap)
    }
    deinit { work.deallocate() }

    /// Delay through the two resamplers in host samples (zero when the profile runs at the host rate).
    public var latency: Int {
        guard toModel != nil else { return 0 }
        // each resampler: 24 samples of priming plus its 8-sample filter delay, at its own input rate
        return Int((32 + 32 * hostRate / model.modelSampleRate).rounded())
    }

    func process(_ x: UnsafeMutablePointer<Float>, _ frames: Int) {
        let g = model.normalizationGain
        guard let up = toModel, let down = toHost else {
            model.process(x, frames)
            for i in 0..<frames { x[i] *= g }
            return
        }
        if !primed { for _ in 0..<24 { up.push(0); down.push(0) }; primed = true }
        for i in 0..<frames { up.push(x[i]) }
        let m = up.pull(into: work, max: workCap)
        model.process(work, m)
        for i in 0..<m { down.push(work[i] * g) }
        let got = down.pull(into: x, max: frames)
        if got < frames { for i in got..<frames { x[i] = 0 } }
    }
}

/// The whole signal chain: input level → pedal circuit → amp (tube circuit or profile) → power stage → cabinet → output.
public final class Rig {
    public private(set) var sampleRate: Double
    public let maxFrames: Int
    public let params: UnsafeMutablePointer<Float>

    // installed processing (swapped from the main thread)
    var pedal: CircuitStage?
    var amp: CircuitStage?
    var profile: ProfileStage?
    var ir: Convolver?
    var lock = os_unfair_lock()
    var pendingPedal: CircuitStage??
    var pendingAmp: CircuitStage??
    var pendingProfile: ProfileStage??
    var pendingIR: Convolver??
    var retired: [AnyObject] = []

    var cab: CabinetSim
    var presence: Biquad
    var presenceDB: Float = 0
    var dcPedal: DCBlocker
    var gateEnv: Float = 0, gateGain: Float = 1
    var gateOpen = false, gateHold = 0
    var gateEnvDecay: Float = 0, gateAttack: Float = 0, gateRelease: Float = 0, gateHoldSamples = 0
    let dryDelay = DelayLine()
    let bypassDelay = DelayLine()
    var trash: [AnyObject] = []
    let dry: UnsafeMutablePointer<Float>
    let scratch: UnsafeMutablePointer<Float>

    // meters (read by the UI)
    public private(set) var inputPeak: Float = 0
    public private(set) var outputPeak: Float = 0
    public private(set) var load: Double = 0
    /// Delay through the rig in samples, as last processed (oversampling filters and profile resampling).
    /// Hosts use it to keep other tracks in time; the dry side of Mix is delayed by the same amount.
    public private(set) var latencySamples = 0

    public init(sampleRate: Double, maxFrames: Int = 4096) {
        self.sampleRate = sampleRate
        self.maxFrames = maxFrames
        params = .allocate(capacity: RigParam.count)
        params.initialize(repeating: 0, count: RigParam.count)
        for p in RigParam.allCases { params[p.rawValue] = p.defaultValue }
        cab = CabinetSim(sr: sampleRate)
        presence = Biquad(.highShelf, f: 3500, q: 0.7, gainDB: 0, sr: sampleRate)
        dcPedal = DCBlocker(sr: sampleRate)
        dry = .allocate(capacity: maxFrames)
        scratch = .allocate(capacity: maxFrames)
        retired.reserveCapacity(16)
        trash.reserveCapacity(16)
        setGateTiming()
    }

    /// Gate timing in real time, whatever the sample rate: 2 ms opening, 40 ms closing, 20 ms hold.
    private func setGateTiming() {
        gateEnvDecay = Float(exp(-1 / (0.040 * sampleRate)))
        gateAttack = Float(1 - exp(-1 / (0.002 * sampleRate)))
        gateRelease = Float(1 - exp(-1 / (0.040 * sampleRate)))
        gateHoldSamples = Int(0.020 * sampleRate)
    }
    deinit { params.deallocate(); dry.deallocate(); scratch.deallocate() }

    public subscript(_ p: RigParam) -> Float {
        get { params[p.rawValue] }
        set { params[p.rawValue] = min(max(newValue, p.range.lowerBound), p.range.upperBound) }
    }

    /// Resets filters for a new host sample rate. Call from the main thread, then reinstall circuits.
    public func setSampleRate(_ sr: Double) {
        os_unfair_lock_lock(&lock)
        sampleRate = sr
        cab = CabinetSim(sr: sr)
        presence = Biquad(.highShelf, f: 3500, q: 0.7, gainDB: Double(presenceDB), sr: sr)
        dcPedal = DCBlocker(sr: sr)
        setGateTiming()
        dryDelay.reset(); bypassDelay.reset()
        os_unfair_lock_unlock(&lock)
    }

    public func install(pedal stage: CircuitStage?) { swapIn { self.pendingPedal = .some(stage) } }
    public func install(amp stage: CircuitStage?) { swapIn { self.pendingAmp = .some(stage) } }
    public func install(profile stage: ProfileStage?) { swapIn { self.pendingProfile = .some(stage) } }
    public func install(impulse ir: [Float]?) {
        let conv = ir.map { Convolver(ir: $0, maxFrames: 512) }
        swapIn { self.pendingIR = .some(conv) }
    }

    private func swapIn(_ body: () -> Void) {
        // Objects the audio thread has finished with are freed here, on the caller's thread, after the lock
        // is released: the lock is only ever held for a few pointer moves, so audio never waits on it.
        os_unfair_lock_lock(&lock)
        swap(&trash, &retired)
        body()
        os_unfair_lock_unlock(&lock)
        trash.removeAll(keepingCapacity: true)
    }

    /// What latencySamples will be once the audio thread has picked up everything installed.
    public var expectedLatency: Int {
        os_unfair_lock_lock(&lock)
        let p: CircuitStage? = pendingPedal ?? pedal
        let a: CircuitStage? = pendingAmp ?? amp
        let pr: ProfileStage? = pendingProfile ?? profile
        os_unfair_lock_unlock(&lock)
        return latency(pedal: p, amp: a, profile: pr)
    }

    private func latency(pedal p: CircuitStage?, amp a: CircuitStage?, profile pr: ProfileStage?) -> Int {
        // Pedal and amp circuits share one oversampled pass, and a bypassed pedal is delayed to match,
        // so switching the pedal on and off never shifts timing.
        let mode = Int(self[.ampMode].rounded())
        let circuits = max(p?.latency ?? 0, mode == 1 ? (a?.latency ?? 0) : 0)
        return circuits + (mode == 2 ? (pr?.latency ?? 0) : 0)
    }

    public var pedalEngine: CircuitEngine? { pedal?.engine }
    public var ampEngine: CircuitEngine? { amp?.engine }
    public var hasProfile: Bool { profile != nil }
    public var hasImpulse: Bool { ir != nil }

    /// Mono processing, in place is allowed (input may equal output).
    public func process(_ input: UnsafePointer<Float>, _ output: UnsafeMutablePointer<Float>, _ frames: Int) {
        let t0 = mach_absolute_time()
        // Pick up newly installed circuits. If the main thread holds the lock this instant, carry on with
        // the current ones and pick the new ones up next block: audio never stops for a swap.
        if os_unfair_lock_trylock(&lock) {
            if let p = pendingPedal { if let old = pedal { retired.append(old) }; pedal = p; pendingPedal = nil }
            if let p = pendingAmp { if let old = amp { retired.append(old) }; amp = p; pendingAmp = nil }
            if let p = pendingProfile { if let old = profile { retired.append(old) }; profile = p; pendingProfile = nil }
            if let p = pendingIR { if let old = ir { retired.append(old) }; ir = p; pendingIR = nil }
            os_unfair_lock_unlock(&lock)
        }
        latencySamples = latency(pedal: pedal, amp: amp, profile: profile)

        var done = 0
        while done < frames {
            let n = min(maxFrames, frames - done)
            processChunk(input + done, output + done, n)
            done += n
        }
        let elapsed = Double(mach_absolute_time() - t0) * Rig.tickSeconds
        load = load * 0.9 + 0.1 * (elapsed / (Double(frames) / sampleRate))
    }

    static let tickSeconds: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(info.numer) / Double(info.denom) * 1e-9
    }()

    private func processChunk(_ input: UnsafePointer<Float>, _ out: UnsafeMutablePointer<Float>, _ n: Int) {
        let inGain = powf(10, self[.inputLevel] / 20)
        var peakIn: Float = 0
        for i in 0..<n {
            let v = input[i] * inGain
            scratch[i] = v
            dry[i] = v
            peakIn = max(peakIn, abs(v))
        }
        inputPeak = max(peakIn, inputPeak * 0.9)

        // The dry side of Mix waits as long as the processed side takes, so blending never comb-filters.
        dryDelay.process(dry, n, delay: latencySamples)

        // noise gate (before the pedal, like a real one in front): opens at the threshold, closes 6 dB below it
        let gateDB = self[.gate]
        if gateDB > -99 {
            let thr = powf(10, gateDB / 20), closeThr = thr * 0.5
            for i in 0..<n {
                let a = abs(scratch[i])
                gateEnv = a > gateEnv ? a : gateEnv * gateEnvDecay
                if gateEnv > thr { gateOpen = true; gateHold = gateHoldSamples }
                else if gateEnv < closeThr { if gateHold > 0 { gateHold -= 1 } else { gateOpen = false } }
                let target: Float = gateOpen ? 1 : 0
                gateGain += (target - gateGain) * (target > gateGain ? gateAttack : gateRelease)
                scratch[i] *= gateGain
            }
        } else { gateGain = 1; gateOpen = true }

        let mode = Int(self[.ampMode].rounded())
        let pedalStage = self[.pedalOn] > 0.5 ? pedal : nil
        let ampStage = mode == 1 ? amp : nil
        let circuitDelay = max(pedal?.latency ?? 0, ampStage?.latency ?? 0)
        let pedalKnobs = params + RigParam.pedalKnob1.rawValue, ampKnobs = params + RigParam.ampKnob1.rawValue
        if pedalStage == nil && ampStage == nil {
            // nothing oversampled is running: wait as long as it would have taken
            if circuitDelay > 0 { bypassDelay.process(scratch, n, delay: circuitDelay) }
        } else {
            if circuitDelay > 0 { bypassDelay.push(scratch, n) }
            if let p = pedalStage, let a = ampStage, p.factor == a.factor, p.factor > 1 {
                p.processChained(scratch, n, knobs: pedalKnobs, next: a, nextKnobs: ampKnobs, powerDrive: self[.powerDrive])
            } else {
                if let p = pedalStage {
                    p.process(scratch, n, knobs: pedalKnobs)
                    for i in 0..<n { scratch[i] = Float(dcPedal.run(Double(scratch[i]))) }
                }
                if let a = ampStage { a.process(scratch, n, knobs: ampKnobs, powerDrive: self[.powerDrive]) }
            }
        }
        if mode == 2, let pr = profile { pr.process(scratch, n) }

        let pres = self[.presence]
        if pres != presenceDB {
            presenceDB = pres
            presence.set(.highShelf, f: 3500, q: 0.7, gainDB: Double(pres), sr: sampleRate)
        }
        let cabMode = Int(self[.cabMode].rounded())
        if cabMode == 2, let c = ir {
            c.process(scratch, n)
            for i in 0..<n { scratch[i] = Float(presence.run(Double(scratch[i]))) }
        } else if cabMode >= 1 {
            for i in 0..<n { scratch[i] = Float(presence.run(cab.run(Double(scratch[i])))) }
        } else {
            for i in 0..<n { scratch[i] = Float(presence.run(Double(scratch[i]))) }
        }

        let outGain = powf(10, self[.outputLevel] / 20)
        let mix = self[.mix]
        var peakOut: Float = 0
        for i in 0..<n {
            var y = (scratch[i] * mix + dry[i] * (1 - mix)) * outGain
            if !y.isFinite { y = 0 }
            y = min(max(y, -4), 4)
            out[i] = y
            peakOut = max(peakOut, abs(y))
        }
        outputPeak = max(peakOut, outputPeak * 0.9)
    }
}
