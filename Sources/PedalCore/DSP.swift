import Accelerate
import Foundation

/// Standard second-order filter (RBJ cookbook), transposed direct form II.
public struct Biquad {
    var b0 = 1.0, b1 = 0.0, b2 = 0.0, a1 = 0.0, a2 = 0.0
    var z1 = 0.0, z2 = 0.0

    public enum Kind { case lowpass, highpass, peak, lowShelf, highShelf }

    public init() {}
    public init(_ kind: Kind, f: Double, q: Double = 0.707, gainDB: Double = 0, sr: Double) { set(kind, f: f, q: q, gainDB: gainDB, sr: sr) }

    public mutating func set(_ kind: Kind, f: Double, q: Double = 0.707, gainDB: Double = 0, sr: Double) {
        let w0 = 2 * Double.pi * min(f, sr * 0.49) / sr
        let cw = cos(w0), sw = sin(w0)
        let alpha = sw / (2 * q)
        let A = pow(10, gainDB / 40)
        var nb0 = 0.0, nb1 = 0.0, nb2 = 0.0, na0 = 1.0, na1 = 0.0, na2 = 0.0
        switch kind {
        case .lowpass:
            nb0 = (1 - cw) / 2; nb1 = 1 - cw; nb2 = nb0; na0 = 1 + alpha; na1 = -2 * cw; na2 = 1 - alpha
        case .highpass:
            nb0 = (1 + cw) / 2; nb1 = -(1 + cw); nb2 = nb0; na0 = 1 + alpha; na1 = -2 * cw; na2 = 1 - alpha
        case .peak:
            nb0 = 1 + alpha * A; nb1 = -2 * cw; nb2 = 1 - alpha * A; na0 = 1 + alpha / A; na1 = -2 * cw; na2 = 1 - alpha / A
        case .lowShelf:
            let s = 2 * sqrt(A) * alpha
            nb0 = A * ((A + 1) - (A - 1) * cw + s); nb1 = 2 * A * ((A - 1) - (A + 1) * cw); nb2 = A * ((A + 1) - (A - 1) * cw - s)
            na0 = (A + 1) + (A - 1) * cw + s; na1 = -2 * ((A - 1) + (A + 1) * cw); na2 = (A + 1) + (A - 1) * cw - s
        case .highShelf:
            let s = 2 * sqrt(A) * alpha
            nb0 = A * ((A + 1) + (A - 1) * cw + s); nb1 = -2 * A * ((A - 1) + (A + 1) * cw); nb2 = A * ((A + 1) + (A - 1) * cw - s)
            na0 = (A + 1) - (A - 1) * cw + s; na1 = 2 * ((A - 1) - (A + 1) * cw); na2 = (A + 1) - (A - 1) * cw - s
        }
        b0 = nb0 / na0; b1 = nb1 / na0; b2 = nb2 / na0; a1 = na1 / na0; a2 = na2 / na0
    }

    @inline(__always) public mutating func run(_ x: Double) -> Double {
        let y = b0 * x + z1
        z1 = b1 * x - a1 * y + z2
        z2 = b2 * x - a2 * y
        return y
    }

    public func magnitudeDB(_ f: Double, sr: Double) -> Double {
        let w = 2 * Double.pi * f / sr
        let (c1, s1, c2, s2) = (cos(w), sin(w), cos(2 * w), sin(2 * w))
        let nr = b0 + b1 * c1 + b2 * c2, ni = -(b1 * s1 + b2 * s2)
        let dr = 1 + a1 * c1 + a2 * c2, di = -(a1 * s1 + a2 * s2)
        return 10 * log10((nr * nr + ni * ni) / max(dr * dr + di * di, 1e-30))
    }
}

/// Removes DC (circuits biased at 4.5 V or a tube plate) at 8 Hz.
public struct DCBlocker {
    var x1 = 0.0, y1 = 0.0, r = 0.999
    public init(sr: Double) { r = 1 - 2 * Double.pi * 8 / sr }
    @inline(__always) public mutating func run(_ x: Double) -> Double { let y = x - x1 + r * y1; x1 = x; y1 = y; return y }
}

/// Windowed-sinc FIR interpolator/decimator so clipping circuits can run at 2×, 4× or 8× the host rate
/// without aliasing. Linear phase; the pair delays the signal by exactly 48 host samples at any factor.
/// The filter is flat to 0.38 × the host rate (18 kHz at 48 kHz) and 90 dB down from half the host rate up,
/// so nothing the circuits generate above the audio band can fold back into it.
public final class Oversampler {
    public let factor: Int
    let len: Int                                  // prototype filter length: 48·factor + 1
    let upN: Int                                  // taps per interpolation phase
    let upTaps: UnsafeMutablePointer<Double>      // factor × upN, each phase stored oldest-sample-first
    let upHist: UnsafeMutablePointer<Double>      // 2·upN, written twice so the window is always contiguous
    var upPos = 0
    let downTaps: UnsafeMutablePointer<Double>    // len
    let downHist: UnsafeMutablePointer<Double>    // 2·len
    var downPos = 0

    public init(factor: Int) {
        self.factor = max(1, factor)
        let f = self.factor
        let L = 48 * f + 1
        len = L
        let fc = 0.44 / Double(f)
        let beta = 9.0
        func bessel0(_ x: Double) -> Double {
            var s = 1.0, t = 1.0
            for k in 1..<25 { t *= (x / (2 * Double(k))) * (x / (2 * Double(k))); s += t }
            return s
        }
        var h = [Double](repeating: 0, count: L)
        let mid = Double(L - 1) / 2
        for i in 0..<L {
            let t = Double(i) - mid
            let sinc = t == 0 ? 2 * fc : sin(2 * Double.pi * fc * t) / (Double.pi * t)
            let r = (Double(i) - mid) / mid
            h[i] = sinc * bessel0(beta * sqrt(max(0, 1 - r * r))) / bessel0(beta)
        }
        let sum = h.reduce(0, +)
        h = h.map { $0 / sum }
        // Interpolation only ever multiplies the non-zero (real) input samples: one short filter per output phase.
        let N = (L + f - 1) / f
        upN = N
        upTaps = .allocate(capacity: f * N)
        for k in 0..<f {
            for i in 0..<N {
                let idx = k + (N - 1 - i) * f
                upTaps[k * N + i] = idx < L ? Double(f) * h[idx] : 0
            }
        }
        upHist = .allocate(capacity: 2 * N); upHist.initialize(repeating: 0, count: 2 * N)
        downTaps = .allocate(capacity: L)
        for i in 0..<L { downTaps[i] = h[i] }
        downHist = .allocate(capacity: 2 * L); downHist.initialize(repeating: 0, count: 2 * L)
    }
    deinit { upTaps.deallocate(); upHist.deallocate(); downTaps.deallocate(); downHist.deallocate() }

    /// Writes `factor` high-rate samples for one input sample.
    @inline(__always) public func up(_ x: Double, _ out: UnsafeMutablePointer<Double>) {
        if factor == 1 { out[0] = x; return }
        let N = upN
        upHist[upPos] = x; upHist[upPos + N] = x
        upPos += 1; if upPos == N { upPos = 0 }
        let window = upHist + upPos
        for k in 0..<factor { vDSP_dotprD(window, 1, upTaps + k * N, 1, out + k, vDSP_Length(N)) }
    }

    /// Takes `factor` high-rate samples and returns one output sample.
    @inline(__always) public func down(_ input: UnsafePointer<Double>) -> Double {
        if factor == 1 { return input[0] }
        let L = len
        // The output is taken on the first sample of each group, so the delay is a whole number of host samples.
        downHist[downPos] = input[0]; downHist[downPos + L] = input[0]
        downPos += 1; if downPos == L { downPos = 0 }
        var acc = 0.0
        vDSP_dotprD(downHist + downPos, 1, downTaps, 1, &acc, vDSP_Length(L))
        for k in 1..<factor {
            downHist[downPos] = input[k]; downHist[downPos + L] = input[k]
            downPos += 1; if downPos == L { downPos = 0 }
        }
        return acc
    }

    /// Delay of the up/down pair in host samples.
    public var latency: Int { factor == 1 ? 0 : (len - 1) / factor }
}

/// A plain delay (ring buffer), used to keep the dry signal and bypassed stages in step with the processed path.
public final class DelayLine {
    let cap: Int
    let buf: UnsafeMutablePointer<Float>
    var pos = 0

    public init(capacity: Int = 8192) {
        cap = capacity
        buf = .allocate(capacity: capacity)
        buf.initialize(repeating: 0, count: capacity)
    }
    deinit { buf.deallocate() }

    public func reset() { buf.update(repeating: 0, count: cap); pos = 0 }

    /// Records samples without reading (keeps the history fresh while the delayed path isn't in use).
    @inline(__always) public func push(_ x: UnsafePointer<Float>, _ n: Int) {
        for i in 0..<n { buf[pos] = x[i]; pos += 1; if pos == cap { pos = 0 } }
    }

    /// Delays x in place by `delay` samples.
    @inline(__always) public func process(_ x: UnsafeMutablePointer<Float>, _ n: Int, delay: Int) {
        let d = min(max(delay, 0), cap - 1)
        if d == 0 { push(x, n); return }
        for i in 0..<n {
            buf[pos] = x[i]
            var r = pos - d; if r < 0 { r += cap }
            x[i] = buf[r]
            pos += 1; if pos == cap { pos = 0 }
        }
    }
}

/// Direct convolution with a speaker impulse response (Accelerate).
public final class Convolver {
    let ir: [Float]
    let reversed: [Float]
    var history: [Float]
    let maxFrames: Int

    public init(ir: [Float], maxFrames: Int) {
        self.ir = ir
        self.reversed = ir.reversed()
        self.maxFrames = maxFrames
        history = [Float](repeating: 0, count: ir.count - 1 + maxFrames)
    }

    public func process(_ x: UnsafeMutablePointer<Float>, _ frames: Int) {
        let m = ir.count
        var done = 0
        while done < frames {
            let n = min(maxFrames, frames - done)
            history.withUnsafeMutableBufferPointer { h in
                (h.baseAddress! + m - 1).update(from: x + done, count: n)
                reversed.withUnsafeBufferPointer { r in
                    // vDSP_conv correlates; feeding the reversed IR makes it a convolution
                    vDSP_conv(h.baseAddress!, 1, r.baseAddress!, 1, x + done, 1, vDSP_Length(n), vDSP_Length(m))
                }
                // keep the last m-1 input samples
                if m > 1 { memmove(h.baseAddress!, h.baseAddress! + n, (m - 1) * MemoryLayout<Float>.size) }
            }
            done += n
        }
    }
}

/// A fractional-delay windowed-sinc resampler for streaming audio (used when an amp profile
/// was captured at a different sample rate than the host runs at).
public final class StreamResampler {
    let ratio: Double  // output rate / input rate
    let half = 8
    var buf: [Double]
    var count = 0
    var pos = 0.0  // read position in input samples, relative to buf[0]

    public init(from inRate: Double, to outRate: Double) {
        ratio = outRate / inRate
        buf = [Double](repeating: 0, count: 16384)
        // Start with enough silence behind the read position that the filter never reaches before the buffer.
        count = 2 * half - 1
        pos = Double(half - 1)
    }

    public func push(_ x: Float) {
        if count >= buf.count {
            let drop = Int(pos) - half
            if drop > 0 {
                buf.withUnsafeMutableBufferPointer { b in
                    memmove(b.baseAddress!, b.baseAddress! + drop, (count - drop) * MemoryLayout<Double>.size)
                }
                count -= drop; pos -= Double(drop)
            } else { return }
        }
        buf[count] = Double(x); count += 1
    }

    /// Produces as many output samples as the input allows, up to max.
    public func pull(into out: UnsafeMutablePointer<Float>, max limit: Int) -> Int {
        var made = 0
        let step = 1 / ratio
        let cutoff = min(1.0, ratio)
        while made < limit {
            let base = Int(pos)
            if base + half + 1 >= count { break }
            let frac = pos - Double(base)
            var acc = 0.0, wsum = 0.0
            for k in (-half + 1)...half {
                let t = Double(k) - frac
                let x = t * cutoff
                let sinc = abs(x) < 1e-9 ? 1 : sin(Double.pi * x) / (Double.pi * x)
                let win = 0.5 + 0.5 * cos(Double.pi * t / Double(half))
                let w = sinc * win
                acc += w * buf[base + k]; wsum += w
            }
            out[made] = Float(acc / max(wsum, 1e-9))
            made += 1
            pos += step
        }
        // compact occasionally
        let drop = Int(pos) - half
        if drop > 4096 {
            buf.withUnsafeMutableBufferPointer { b in
                memmove(b.baseAddress!, b.baseAddress! + drop, (count - drop) * MemoryLayout<Double>.size)
            }
            count -= drop; pos -= Double(drop)
        }
        return made
    }
}

/// A built-in speaker cabinet voicing (one 12" speaker, closed back) for when no impulse response is loaded.
public struct CabinetSim {
    var filters: [Biquad]
    public init(sr: Double) {
        filters = [
            Biquad(.highpass, f: 75, q: 0.8, sr: sr),
            Biquad(.peak, f: 115, q: 1.4, gainDB: 5, sr: sr),
            Biquad(.peak, f: 420, q: 1.0, gainDB: -3.5, sr: sr),
            Biquad(.peak, f: 2300, q: 1.2, gainDB: 4, sr: sr),
            Biquad(.lowpass, f: 4800, q: 0.75, sr: sr),
            Biquad(.lowpass, f: 6000, q: 0.6, sr: sr),
        ]
    }
    @inline(__always) public mutating func run(_ x: Double) -> Double {
        var y = x
        for i in 0..<filters.count { y = filters[i].run(y) }
        return y
    }
    public func responseDB(_ f: Double, sr: Double) -> Double { filters.reduce(0) { $0 + $1.magnitudeDB(f, sr: sr) } }
}
