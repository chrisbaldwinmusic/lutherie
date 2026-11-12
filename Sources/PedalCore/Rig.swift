import Foundation
import os

/// Parameter slots shared by the app, the Audio Unit and the VST3 plugin.
///
/// Ids never change, so host automation keeps working across versions. The pedalboard has six slots: slot 1
/// keeps the ids of the original single pedal (On at 2, knobs at 10…17); slots 2…6 each take a block of ten from
/// 32 (On, then eight knobs). A pedal keeps its slot when it is moved along the board, so its automation follows it.
public struct RigParam: RawRepresentable, Hashable, CaseIterable, Comparable, Sendable {
    public let rawValue: Int
    public init?(rawValue: Int) {
        guard RigParam.valid.contains(rawValue) else { return nil }
        self.rawValue = rawValue
    }
    private init(_ r: Int) { rawValue = r }
    public static func < (a: RigParam, b: RigParam) -> Bool { a.rawValue < b.rawValue }

    public static let inputLevel = RigParam(0), outputLevel = RigParam(1), pedalOn = RigParam(2), ampMode = RigParam(3),
                      cabMode = RigParam(4), powerDrive = RigParam(5), presence = RigParam(6), gate = RigParam(7), mix = RigParam(8)
    public static let pedalKnob1 = RigParam(10)
    public static let ampKnob1 = RigParam(20)

    /// Pedals the board can hold.
    public static let pedalSlots = 6
    /// Knobs per circuit that reach the host.
    public static let knobsPerCircuit = 8

    /// The on/off switch of a pedal slot (0-based).
    public static func pedalOn(_ slot: Int) -> RigParam { slot == 0 ? .pedalOn : RigParam(32 + (slot - 1) * 10) }
    /// Knob `index` (0-based) of a pedal slot.
    public static func pedalKnob(_ slot: Int, _ index: Int) -> RigParam {
        slot == 0 ? RigParam(10 + index) : RigParam(33 + (slot - 1) * 10 + index)
    }
    /// Knob `index` (0-based) of the amp circuit.
    public static func ampKnob(_ index: Int) -> RigParam { RigParam(20 + index) }

    /// Size of the storage that holds every parameter, indexed by id.
    public static let count = 32 + (pedalSlots - 1) * 10

    public static let allCases: [RigParam] = {
        var ids = Array(0...8) + Array(10...17) + Array(20...27)
        for s in 1..<pedalSlots { ids += Array((32 + (s - 1) * 10)...(40 + (s - 1) * 10)) }
        return ids.map(RigParam.init)
    }()
    private static let valid: Set<Int> = Set(allCases.map(\.rawValue))

    /// The pedal slot whose on/off switch this is.
    public var pedalOnSlot: Int? {
        if rawValue == 2 { return 0 }
        guard rawValue >= 32 else { return nil }
        let r = rawValue - 32
        return r % 10 == 0 ? r / 10 + 1 : nil
    }
    /// The pedal slot and knob index, when this is a pedal knob.
    public var pedalKnob: (slot: Int, index: Int)? {
        if (10...17).contains(rawValue) { return (0, rawValue - 10) }
        guard rawValue >= 32 else { return nil }
        let r = rawValue - 32
        return r % 10 == 0 ? nil : (r / 10 + 1, r % 10 - 1)
    }
    /// The amp knob index, when this is an amp knob.
    public var ampKnob: Int? { (20...27).contains(rawValue) ? rawValue - 20 : nil }
    /// True for knobs whose positions are also drawn in a circuit.
    public var isCircuitKnob: Bool { pedalKnob != nil || ampKnob != nil }

    public var name: String {
        switch self {
        case .inputLevel: return "Input Level"
        case .outputLevel: return "Output Level"
        case .ampMode: return "Amp"
        case .cabMode: return "Cabinet"
        case .powerDrive: return "Power Amp Drive"
        case .presence: return "Presence"
        case .gate: return "Noise Gate"
        case .mix: return "Mix"
        default:
            if let s = pedalOnSlot { return "Pedal \(s + 1) On" }
            if let k = pedalKnob { return "Pedal \(k.slot + 1) Knob \(k.index + 1)" }
            if let k = ampKnob { return "Amp Knob \(k + 1)" }
            return "Parameter \(rawValue)"
        }
    }
    public var range: ClosedRange<Float> {
        switch self {
        case .inputLevel: return -24...24
        case .outputLevel: return -48...12
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
        case .ampMode: return 1
        case .cabMode: return 1
        case .powerDrive: return 0.35
        case .presence: return 0
        case .gate: return -100
        case .mix: return 1
        default: return pedalOnSlot != nil ? 1 : 0.5
        }
    }
    public var unit: String {
        switch self {
        case .inputLevel, .outputLevel, .presence, .gate: return "dB"
        default: return ""
        }
    }
    public var isIndexed: Bool { pedalOnSlot != nil || self == .ampMode || self == .cabMode }
    public var valueNames: [String]? {
        if pedalOnSlot != nil { return ["Bypassed", "On"] }
        switch self {
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

/// The whole signal chain: input level → gate → pedalboard (up to six circuits, in any order) → amp (tube circuit
/// or profile) → power stage → cabinet → output.
public final class Rig {
    public static let maxPedals = RigParam.pedalSlots
    public private(set) var sampleRate: Double
    public let maxFrames: Int
    public let params: UnsafeMutablePointer<Float>

    // installed processing (swapped from the main thread)
    var pedals: [CircuitStage?] = Array(repeating: nil, count: Rig.maxPedals)   // indexed by slot
    let order: UnsafeMutablePointer<Int>                                         // slots in signal order
    var orderCount = 0
    var amp: CircuitStage?
    var profile: ProfileStage?
    var ir: Convolver?
    /// One interpolator and decimator around every circuit on the board, so they all share a single
    /// oversampled pass: the delay and filtering stay the same however many pedals are on.
    var chainOS: Oversampler?
    var lock = os_unfair_lock()
    var pendingPedals: [CircuitStage??] = Array(repeating: nil, count: Rig.maxPedals)
    let pendingOrder: UnsafeMutablePointer<Int>
    var pendingOrderCount: Int?
    var pendingAmp: CircuitStage??
    var pendingProfile: ProfileStage??
    var pendingIR: Convolver??
    var pendingOS: Oversampler??
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
    let chainBuf: UnsafeMutablePointer<Double>
    // the pedals running this block, in order (capacity reserved up front: no allocation on the audio thread)
    var active = ContiguousArray<CircuitStage>()
    var activeSlots = ContiguousArray<Int>()

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
        order = .allocate(capacity: Rig.maxPedals)
        pendingOrder = .allocate(capacity: Rig.maxPedals)
        for i in 0..<Rig.maxPedals { order[i] = i; pendingOrder[i] = i }
        orderCount = Rig.maxPedals
        cab = CabinetSim(sr: sampleRate)
        presence = Biquad(.highShelf, f: 3500, q: 0.7, gainDB: 0, sr: sampleRate)
        dcPedal = DCBlocker(sr: sampleRate)
        dry = .allocate(capacity: maxFrames)
        scratch = .allocate(capacity: maxFrames)
        chainBuf = .allocate(capacity: 16)
        retired.reserveCapacity(64)
        trash.reserveCapacity(64)
        active.reserveCapacity(Rig.maxPedals)
        activeSlots.reserveCapacity(Rig.maxPedals)
        setGateTiming()
    }

    /// Gate timing in real time, whatever the sample rate: 2 ms opening, 40 ms closing, 20 ms hold.
    private func setGateTiming() {
        gateEnvDecay = Float(exp(-1 / (0.040 * sampleRate)))
        gateAttack = Float(1 - exp(-1 / (0.002 * sampleRate)))
        gateRelease = Float(1 - exp(-1 / (0.040 * sampleRate)))
        gateHoldSamples = Int(0.020 * sampleRate)
    }
    deinit {
        params.deallocate(); dry.deallocate(); scratch.deallocate(); chainBuf.deallocate()
        order.deallocate(); pendingOrder.deallocate()
    }

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

    /// Puts a pedal circuit in a slot of the board (nil empties the slot). Slot 0 is the original single pedal.
    public func install(pedal stage: CircuitStage?, slot: Int = 0) {
        guard (0..<Rig.maxPedals).contains(slot) else { return }
        swapIn { self.pendingPedals[slot] = .some(stage); self.prepareOversampler(for: stage) }
    }
    /// Sets the order the slots run in. Slots left out don't run.
    public func setOrder(_ slots: [Int]) {
        var seen = Set<Int>()
        let s = slots.filter { (0..<Rig.maxPedals).contains($0) && seen.insert($0).inserted }
        swapIn {
            for (i, v) in s.enumerated() { self.pendingOrder[i] = v }
            self.pendingOrderCount = s.count
        }
    }
    public func install(amp stage: CircuitStage?) { swapIn { self.pendingAmp = .some(stage); self.prepareOversampler(for: stage) } }
    public func install(profile stage: ProfileStage?) { swapIn { self.pendingProfile = .some(stage) } }
    public func install(impulse ir: [Float]?) {
        let conv = ir.map { Convolver(ir: $0, maxFrames: 512) }
        swapIn { self.pendingIR = .some(conv) }
    }

    /// Makes sure the shared oversampler matches a newly installed circuit's factor (called with the lock held).
    private func prepareOversampler(for stage: CircuitStage?) {
        guard let s = stage, s.factor > 1 else { return }
        let current: Oversampler? = pendingOS ?? chainOS
        if current?.factor != s.factor { pendingOS = .some(Oversampler(factor: s.factor)) }
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
        var circuits = 0
        let pending = pendingOrderCount != nil
        for j in 0..<(pendingOrderCount ?? orderCount) {
            let s = pending ? pendingOrder[j] : order[j]
            let st: CircuitStage? = pendingPedals[s] ?? pedals[s]
            circuits = max(circuits, st?.latency ?? 0)
        }
        let a: CircuitStage? = pendingAmp ?? amp
        let pr: ProfileStage? = pendingProfile ?? profile
        os_unfair_lock_unlock(&lock)
        return latency(circuits: circuits, amp: a, profile: pr)
    }

    private func latency(circuits: Int, amp a: CircuitStage?, profile pr: ProfileStage?) -> Int {
        // Every circuit shares one oversampled pass, and bypassed pedals are delayed to match,
        // so switching pedals on and off never shifts timing.
        let mode = Int(self[.ampMode].rounded())
        return max(circuits, mode == 1 ? (a?.latency ?? 0) : 0) + (mode == 2 ? (pr?.latency ?? 0) : 0)
    }

    /// Delay of the pedals on the board (audio thread).
    private var boardLatency: Int {
        var l = 0
        for j in 0..<orderCount { if let st = pedals[order[j]] { l = max(l, st.latency) } }
        return l
    }

    public var pedalEngine: CircuitEngine? { pedals[0]?.engine }
    public func pedalEngine(slot: Int) -> CircuitEngine? { pedals[slot]?.engine }
    public var ampEngine: CircuitEngine? { amp?.engine }
    public var hasProfile: Bool { profile != nil }
    public var hasImpulse: Bool { ir != nil }

    /// Mono processing, in place is allowed (input may equal output).
    public func process(_ input: UnsafePointer<Float>, _ output: UnsafeMutablePointer<Float>, _ frames: Int) {
        let t0 = mach_absolute_time()
        // Pick up newly installed circuits. If the main thread holds the lock this instant, carry on with
        // the current ones and pick the new ones up next block: audio never stops for a swap.
        if os_unfair_lock_trylock(&lock) {
            for s in 0..<Rig.maxPedals {
                if let p = pendingPedals[s] { if let old = pedals[s] { retired.append(old) }; pedals[s] = p; pendingPedals[s] = nil }
            }
            if let c = pendingOrderCount {
                for i in 0..<c { order[i] = pendingOrder[i] }
                orderCount = c; pendingOrderCount = nil
            }
            if let p = pendingAmp { if let old = amp { retired.append(old) }; amp = p; pendingAmp = nil }
            if let p = pendingProfile { if let old = profile { retired.append(old) }; profile = p; pendingProfile = nil }
            if let p = pendingIR { if let old = ir { retired.append(old) }; ir = p; pendingIR = nil }
            if let p = pendingOS { if let old = chainOS { retired.append(old) }; chainOS = p; pendingOS = nil }
            os_unfair_lock_unlock(&lock)
        }
        latencySamples = latency(circuits: boardLatency, amp: amp, profile: profile)

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

        // noise gate (before the pedals, like a real one in front): opens at the threshold, closes 6 dB below it
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
        let ampStage = mode == 1 ? amp : nil
        var circuitDelay = ampStage?.latency ?? 0
        active.removeAll(keepingCapacity: true)
        activeSlots.removeAll(keepingCapacity: true)
        for j in 0..<orderCount {
            let s = order[j]
            guard let st = pedals[s] else { continue }
            circuitDelay = max(circuitDelay, st.latency)
            if params[RigParam.pedalOn(s).rawValue] > 0.5 { active.append(st); activeSlots.append(s) }
        }
        if active.isEmpty && ampStage == nil {
            // nothing oversampled is running: wait as long as it would have taken
            if circuitDelay > 0 { bypassDelay.process(scratch, n, delay: circuitDelay) }
        } else {
            if circuitDelay > 0 { bypassDelay.push(scratch, n) }
            let f = ampStage?.factor ?? active[0].factor
            var same = true
            for st in active where st.factor != f { same = false }
            if same && (f == 1 || chainOS?.factor == f) {
                runChain(scratch, n, amp: ampStage, os: f > 1 ? chainOS : nil)
            } else {
                // Only for the moment while circuits rebuilt at a new oversampling factor arrive one by one.
                for j in 0..<active.count {
                    active[j].process(scratch, n, knobs: params + RigParam.pedalKnob(activeSlots[j], 0).rawValue)
                    for i in 0..<n { scratch[i] = Float(dcPedal.run(Double(scratch[i]))) }
                }
                if let a = ampStage { a.process(scratch, n, knobs: params + RigParam.ampKnob1.rawValue, powerDrive: self[.powerDrive]) }
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

    /// Every pedal that is on, then the amp circuit and its power stage, inside one oversampled pass (or at the
    /// host rate when `os` is nil). A DC blocker after each pedal stands in for its output coupling capacitor.
    private func runChain(_ x: UnsafeMutablePointer<Float>, _ n: Int, amp a: CircuitStage?, os: Oversampler?) {
        let count = active.count
        for j in 0..<count {
            let st = active[j], k = params + RigParam.pedalKnob(activeSlots[j], 0).rawValue
            for i in 0..<min(st.engine.knobCount, RigParam.knobsPerCircuit) { st.engine.setKnob(i, Double(k[i])) }
        }
        if let a {
            let k = params + RigParam.ampKnob1.rawValue
            for i in 0..<min(a.engine.knobCount, RigParam.knobsPerCircuit) { a.engine.setKnob(i, Double(k[i])) }
            a.setPower(self[.powerDrive])
        }
        let f = os?.factor ?? 1
        var start = 0
        while start < n {
            let m = min(32, n - start)
            for j in 0..<count { active[j].engine.applyKnobs() }
            a?.engine.applyKnobs()
            for i in start..<(start + m) {
                let y: Double
                if let os {
                    os.up(Double(x[i]), chainBuf)
                    for k in 0..<f { chainBuf[k] = tickChain(chainBuf[k], count, a) }
                    y = os.down(chainBuf)
                } else {
                    y = tickChain(Double(x[i]), count, a)
                }
                x[i] = y.isFinite ? Float(y) : 0
            }
            start += m
        }
        for j in 0..<count { active[j].checkHealth() }
        a?.checkHealth()
    }

    @inline(__always) private func tickChain(_ v0: Double, _ count: Int, _ a: CircuitStage?) -> Double {
        var v = v0
        for j in 0..<count {
            let st = active[j]
            v = st.chainDC.run(st.engine.tick(v))
        }
        if let a {
            let y = a.engine.tick(v)
            v = a.powerOn ? a.power(y) : y
        }
        return v
    }
}
