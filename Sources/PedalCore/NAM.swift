import Accelerate
import Foundation

/// Loads and runs Neural Amp Modeler profiles (.nam): the standard WaveNet and LSTM architectures.
/// Written from the published file format and the reference implementation's maths.
public final class NAMModel {
    public let name: String
    public let architecture: String
    public let modelSampleRate: Double
    public let loudness: Double?
    public let detail: String
    let runner: NAMRunner

    public static let maxBlock = 1024

    public init(data: Data, name: String) throws {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CircuitError("This file isn't a Neural Amp Modeler profile.")
        }
        guard let arch = root["architecture"] as? String, let config = root["config"] as? [String: Any],
              let wAny = root["weights"] as? [Any] else {
            throw CircuitError("This profile is missing its architecture, config or weights.")
        }
        let weights = wAny.compactMap { ($0 as? NSNumber)?.floatValue }
        guard weights.count == wAny.count else { throw CircuitError("This profile's weights are not numbers.") }
        self.name = name
        self.architecture = arch
        self.modelSampleRate = (root["sample_rate"] as? NSNumber)?.doubleValue ?? 48_000
        let meta = root["metadata"] as? [String: Any]
        self.loudness = (meta?["loudness"] as? NSNumber)?.doubleValue
        switch arch {
        case "WaveNet":
            let w = try NAMWaveNet(config: config, weights: weights)
            runner = w
            detail = "WaveNet, \(w.arrays.count) layer arrays, \(weights.count) weights"
        case "LSTM":
            let l = try NAMLSTM(config: config, weights: weights)
            runner = l
            detail = "LSTM, \(l.layers.count) layer(s) × \(l.hidden) cells"
        default:
            throw CircuitError("Profiles of type \(arch) aren't supported yet (WaveNet and LSTM are).")
        }
        runner.reset()
        // Let the network settle on silence so the first notes don't start with a click.
        var silence = [Float](repeating: 0, count: 4096)
        silence.withUnsafeMutableBufferPointer { b in
            var done = 0
            while done < runner.prewarm { runner.process(b.baseAddress!, min(NAMModel.maxBlock, 4096)); done += 1024 }
        }
    }

    /// Gain that brings the profile to a −18 dB reference loudness, as NAM players do.
    public var normalizationGain: Float {
        guard let l = loudness else { return 1 }
        return Float(pow(10, (-18 - l) / 20))
    }

    /// In-place processing of mono audio at the profile's sample rate.
    public func process(_ x: UnsafeMutablePointer<Float>, _ frames: Int) {
        var done = 0
        while done < frames {
            let n = min(NAMModel.maxBlock, frames - done)
            runner.process(x + done, n)
            done += n
        }
    }

    public func reset() { runner.reset() }
}

protocol NAMRunner: AnyObject {
    func process(_ x: UnsafeMutablePointer<Float>, _ frames: Int)
    func reset()
    var prewarm: Int { get }
}

enum NAMActivation {
    case tanh, relu, sigmoid, hardtanh, leakyRelu, silu, softsign, identity

    init(_ any: Any?) throws {
        var name = any as? String
        if let d = any as? [String: Any] { name = (d["type"] ?? d["name"]) as? String }
        switch (name ?? "Tanh").lowercased() {
        case "tanh", "fasttanh": self = .tanh
        case "relu": self = .relu
        case "sigmoid": self = .sigmoid
        case "hardtanh": self = .hardtanh
        case "leakyrelu": self = .leakyRelu
        case "silu", "swish": self = .silu
        case "softsign": self = .softsign
        case "identity", "linear": self = .identity
        default: throw CircuitError("Unsupported activation \(name ?? "?") in this profile.")
        }
    }

    func apply(_ p: UnsafeMutablePointer<Float>, _ n: Int) {
        switch self {
        case .tanh: var c = Int32(n); vvtanhf(p, p, &c)
        case .relu: for i in 0..<n where p[i] < 0 { p[i] = 0 }
        case .sigmoid: for i in 0..<n { p[i] = 1 / (1 + expf(-p[i])) }
        case .hardtanh: for i in 0..<n { p[i] = min(max(p[i], -1), 1) }
        case .leakyRelu: for i in 0..<n where p[i] < 0 { p[i] *= 0.01 }
        case .silu: for i in 0..<n { p[i] = p[i] / (1 + expf(-p[i])) }
        case .softsign: for i in 0..<n { p[i] = p[i] / (1 + abs(p[i])) }
        case .identity: break
        }
    }
}

/// Reads weights in file order.
struct WeightReader {
    let w: [Float]
    var i = 0
    mutating func next() throws -> Float {
        guard i < w.count else { throw CircuitError("This profile has fewer weights than its layout needs.") }
        defer { i += 1 }
        return w[i]
    }
    /// out×in matrix stored column-major (element (r,c) at c*out + r); file order is row by row.
    mutating func matrix(_ out: Int, _ inn: Int) throws -> [Float] {
        var m = [Float](repeating: 0, count: out * inn)
        for r in 0..<out { for c in 0..<inn { m[c * out + r] = try next() } }
        return m
    }
    mutating func vector(_ n: Int) throws -> [Float] { try (0..<n).map { _ in try next() } }
}

@inline(__always) func gemm(_ M: Int, _ N: Int, _ K: Int, _ A: UnsafePointer<Float>, _ B: UnsafePointer<Float>,
                            _ C: UnsafeMutablePointer<Float>, accumulate: Bool) {
    cblas_sgemm(CblasColMajor, CblasNoTrans, CblasNoTrans, Int32(M), Int32(N), Int32(K), 1, A, Int32(M), B, Int32(K),
                accumulate ? 1 : 0, C, Int32(M))
}

final class NAMWaveNet: NAMRunner {
    final class Layer {
        let ch: Int, out: Int, k: Int, dil: Int, cond: Int, gated: Bool, act: NAMActivation
        var convW: [[Float]]  // per tap, out×ch column-major
        var convB: [Float]
        var mixW: [Float]     // out×cond
        var w1: [Float]       // ch×ch
        var b1: [Float]
        // history of this layer's input: ch × (R + capacity)
        let R: Int
        let cap: Int
        var hist: UnsafeMutablePointer<Float>
        var pos: Int
        var z: UnsafeMutablePointer<Float>

        init(ch: Int, cond: Int, k: Int, dil: Int, gated: Bool, act: NAMActivation, r: inout WeightReader) throws {
            self.ch = ch; self.cond = cond; self.k = k; self.dil = dil; self.gated = gated; self.act = act
            out = gated ? 2 * ch : ch
            // conv: for each out i, in j, tap t
            var taps = [[Float]](repeating: [Float](repeating: 0, count: out * ch), count: k)
            for i in 0..<out { for j in 0..<ch { for t in 0..<k { taps[t][j * out + i] = try r.next() } } }
            convW = taps
            convB = try r.vector(out)
            mixW = try r.matrix(out, cond)
            w1 = try r.matrix(ch, ch)
            b1 = try r.vector(ch)
            R = (k - 1) * dil
            cap = R + NAMModel.maxBlock * 4
            hist = .allocate(capacity: ch * cap)
            hist.initialize(repeating: 0, count: ch * cap)
            pos = R
            z = .allocate(capacity: out * NAMModel.maxBlock)
        }
        deinit { hist.deallocate(); z.deallocate() }

        func reset() { hist.update(repeating: 0, count: ch * cap); pos = R }

        /// Room for `frames` new input columns at `pos`; returns the write pointer.
        func inputSlot(_ frames: Int) -> UnsafeMutablePointer<Float> {
            if pos + frames > cap {
                memmove(hist, hist + (pos - R) * ch, R * ch * MemoryLayout<Float>.size)
                pos = R
            }
            return hist + pos * ch
        }

        /// Runs the layer on the `frames` columns at pos. Adds to headAcc, writes the next layer's input to `next`.
        func run(_ frames: Int, condition: UnsafePointer<Float>, headAcc: UnsafeMutablePointer<Float>,
                 next: UnsafeMutablePointer<Float>) {
            // bias
            for f in 0..<frames { (z + f * out).update(from: convB, count: out) }
            for t in 0..<k {
                let off = dil * (t + 1 - k)
                convW[t].withUnsafeBufferPointer { w in
                    gemm(out, frames, ch, w.baseAddress!, hist + (pos + off) * ch, z, accumulate: true)
                }
            }
            mixW.withUnsafeBufferPointer { w in gemm(out, frames, cond, w.baseAddress!, condition, z, accumulate: true) }
            if gated {
                for f in 0..<frames {
                    let col = z + f * out
                    var c = Int32(ch); vvtanhf(col, col, &c)
                    for i in 0..<ch { col[i] *= 1 / (1 + expf(-col[ch + i])) }
                }
            } else {
                act.apply(z, out * frames)
            }
            // head accumulation and residual output
            let input = hist + pos * ch
            for f in 0..<frames {
                let col = z + f * out
                let h = headAcc + f * ch
                let nx = next + f * ch
                let inp = input + f * ch
                for i in 0..<ch { h[i] += col[i]; nx[i] = inp[i] + b1[i] }
            }
            if gated {
                // z columns have 2·ch rows: multiply using the top half only
                for f in 0..<frames {
                    w1.withUnsafeBufferPointer { w in gemm(ch, 1, ch, w.baseAddress!, z + f * out, next + f * ch, accumulate: true) }
                }
            } else {
                w1.withUnsafeBufferPointer { w in gemm(ch, frames, ch, w.baseAddress!, z, next, accumulate: true) }
            }
            pos += frames
        }
    }

    final class LayerArray {
        let inSize: Int, ch: Int, headSize: Int
        let rechannel: [Float]  // ch×inSize
        var layers: [Layer]
        let headW: [Float]      // headSize×ch
        let headB: [Float]?
        let headAcc: UnsafeMutablePointer<Float>
        let out: UnsafeMutablePointer<Float>   // last layer output ch×F
        let headOut: UnsafeMutablePointer<Float>

        init(_ cfg: [String: Any], r: inout WeightReader) throws {
            func int(_ k: String) throws -> Int {
                guard let v = (cfg[k] as? NSNumber)?.intValue else { throw CircuitError("Profile layer is missing \(k).") }
                return v
            }
            for key in ["bottleneck", "head1x1", "film", "groups_input", "groups"] where cfg[key] != nil && !(cfg[key] is NSNull) {
                if key == "bottleneck", let b = cfg[key] as? NSNumber, b.intValue == (cfg["channels"] as? NSNumber)?.intValue { continue }
                if let d = cfg[key] as? [String: Any], (d["active"] as? Bool) == false { continue }
                if key.hasPrefix("groups"), (cfg[key] as? NSNumber)?.intValue == 1 { continue }
                throw CircuitError("This profile uses a newer WaveNet layout (\(key)) that isn't supported yet.")
            }
            let inSize = try int("input_size")
            let cond = try int("condition_size")
            let headSize = try int("head_size")
            let ch = try int("channels")
            self.inSize = inSize; self.headSize = headSize; self.ch = ch
            let k = try int("kernel_size")
            guard let dils = (cfg["dilations"] as? [NSNumber])?.map(\.intValue) else { throw CircuitError("Profile layer has no dilations.") }
            var gated = (cfg["gated"] as? Bool) ?? false
            if let gm = cfg["gating_mode"] as? String { gated = gm.lowercased() == "gated"; if gm.lowercased() == "blended" { throw CircuitError("Blended gating isn't supported yet.") } }
            let act = try NAMActivation(cfg["activation"])
            let headBias = (cfg["head_bias"] as? Bool) ?? false
            rechannel = try r.matrix(ch, inSize)
            layers = try dils.map { try Layer(ch: ch, cond: cond, k: k, dil: $0, gated: gated, act: act, r: &r) }
            headW = try r.matrix(headSize, ch)
            headB = headBias ? try r.vector(headSize) : nil
            let mb = NAMModel.maxBlock
            headAcc = .allocate(capacity: ch * mb)
            out = .allocate(capacity: ch * mb)
            headOut = .allocate(capacity: headSize * mb)
        }
        deinit { headAcc.deallocate(); out.deallocate(); headOut.deallocate() }

        var receptive: Int { layers.reduce(1) { $0 + $1.R } }

        func run(input: UnsafePointer<Float>, condition: UnsafePointer<Float>, headIn: UnsafePointer<Float>?, frames: Int) {
            if let h = headIn { headAcc.update(from: h, count: ch * frames) } else { headAcc.update(repeating: 0, count: ch * frames) }
            // rechannel into the first layer's history
            let slot0 = layers[0].inputSlot(frames)
            rechannel.withUnsafeBufferPointer { w in gemm(ch, frames, inSize, w.baseAddress!, input, slot0, accumulate: false) }
            for (i, layer) in layers.enumerated() {
                let dest = i + 1 < layers.count ? layers[i + 1].inputSlot(frames) : out
                layer.run(frames, condition: condition, headAcc: headAcc, next: dest)
            }
            for f in 0..<frames {
                if let b = headB { (headOut + f * headSize).update(from: b, count: headSize) }
                else { (headOut + f * headSize).update(repeating: 0, count: headSize) }
            }
            headW.withUnsafeBufferPointer { w in gemm(headSize, frames, ch, w.baseAddress!, headAcc, headOut, accumulate: true) }
        }
    }

    var arrays: [LayerArray]
    var headScale: Float
    let cond: UnsafeMutablePointer<Float>

    init(config: [String: Any], weights: [Float]) throws {
        if let head = config["head"], !(head is NSNull) {
            throw CircuitError("This profile has a post-stack head, which isn't supported yet.")
        }
        if let c = config["condition_dsp"], !(c is NSNull) { throw CircuitError("Profiles with a condition network aren't supported yet.") }
        guard let layerCfgs = config["layers"] as? [[String: Any]], !layerCfgs.isEmpty else {
            throw CircuitError("This WaveNet profile has no layers.")
        }
        var r = WeightReader(w: weights)
        arrays = try layerCfgs.map { try LayerArray($0, r: &r) }
        for i in 1..<max(arrays.count, 1) where i < arrays.count && arrays[i].ch != arrays[i - 1].headSize {
            throw CircuitError("Profile layer arrays don't line up.")
        }
        headScale = try r.next()
        if r.i != weights.count { throw CircuitError("This profile has \(weights.count - r.i) more weights than its layout uses.") }
        cond = .allocate(capacity: NAMModel.maxBlock)
    }
    deinit { cond.deallocate() }

    var prewarm: Int { arrays.reduce(1) { $0 + $1.receptive } }

    func reset() { for a in arrays { for l in a.layers { l.reset() } } }

    func process(_ x: UnsafeMutablePointer<Float>, _ frames: Int) {
        cond.update(from: x, count: frames)
        for (i, a) in arrays.enumerated() {
            if i == 0 {
                a.run(input: cond, condition: cond, headIn: nil, frames: frames)
            } else {
                let prev = arrays[i - 1]
                a.run(input: prev.out, condition: cond, headIn: prev.headOut, frames: frames)
            }
        }
        let last = arrays[arrays.count - 1]
        for f in 0..<frames { x[f] = headScale * last.headOut[f * last.headSize] }
    }
}

final class NAMLSTM: NAMRunner {
    struct Cell {
        var w: [Float]   // 4H × (in+H), row-major
        var b: [Float]
        var xh: [Float]
        var c: [Float]
        let h0: [Float], c0: [Float]
        let inSize: Int, hidden: Int
        var ifgo: [Float]
    }
    var layers: [Cell]
    let hidden: Int
    var headW: [Float]
    var headB: Float

    init(config: [String: Any], weights: [Float]) throws {
        guard let inSize = (config["input_size"] as? NSNumber)?.intValue,
              let h = (config["hidden_size"] as? NSNumber)?.intValue,
              let nl = (config["num_layers"] as? NSNumber)?.intValue else { throw CircuitError("This LSTM profile is missing its sizes.") }
        hidden = h
        var r = WeightReader(w: weights)
        layers = []
        for l in 0..<nl {
            let isz = l == 0 ? inSize : h
            var w = [Float](repeating: 0, count: 4 * h * (isz + h))
            for i in 0..<(4 * h) { for j in 0..<(isz + h) { w[i * (isz + h) + j] = try r.next() } }
            let b = try r.vector(4 * h)
            let h0 = try r.vector(h)
            let c0 = try r.vector(h)
            var xh = [Float](repeating: 0, count: isz + h)
            for i in 0..<h { xh[isz + i] = h0[i] }
            layers.append(Cell(w: w, b: b, xh: xh, c: c0, h0: h0, c0: c0, inSize: isz, hidden: h,
                               ifgo: [Float](repeating: 0, count: 4 * h)))
        }
        headW = try r.vector(h)
        headB = try r.next()
        if r.i != weights.count { throw CircuitError("This profile has \(weights.count - r.i) more weights than its layout uses.") }
    }

    var prewarm: Int { 4096 }

    func reset() {
        for i in layers.indices {
            for k in 0..<hidden { layers[i].xh[layers[i].inSize + k] = layers[i].h0[k] }
            layers[i].c = layers[i].c0
        }
    }

    func process(_ x: UnsafeMutablePointer<Float>, _ frames: Int) {
        let H = hidden
        for f in 0..<frames {
            var input = x[f]
            for li in layers.indices {
                layers[li].withCell { cell in
                    let cols = cell.inSize + H
                    if li == 0 { cell.xh[0] = input }
                    for i in 0..<(4 * H) {
                        var s = cell.b[i]
                        let row = i * cols
                        for j in 0..<cols { s += cell.w[row + j] * cell.xh[j] }
                        cell.ifgo[i] = s
                    }
                    for i in 0..<H {
                        let ig = 1 / (1 + expf(-cell.ifgo[i]))
                        let fg = 1 / (1 + expf(-cell.ifgo[H + i]))
                        let gg = tanhf(cell.ifgo[2 * H + i])
                        cell.c[i] = fg * cell.c[i] + ig * gg
                    }
                    for i in 0..<H {
                        let og = 1 / (1 + expf(-cell.ifgo[3 * H + i]))
                        cell.xh[cell.inSize + i] = og * tanhf(cell.c[i])
                    }
                }
                if li + 1 < layers.count {
                    let hOut = layers[li].xh[layers[li].inSize...]
                    for (k, v) in hOut.enumerated() { layers[li + 1].xh[k] = v }
                }
                input = 0
            }
            let last = layers[layers.count - 1]
            var y = headB
            for i in 0..<H { y += headW[i] * last.xh[last.inSize + i] }
            x[f] = y
        }
    }
}

extension NAMLSTM.Cell {
    mutating func withCell(_ body: (inout NAMLSTM.Cell) -> Void) { body(&self) }
}
