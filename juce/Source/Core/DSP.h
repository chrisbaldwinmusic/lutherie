#pragma once

// Filters, the oversampler, delay lines, convolution and resampling (port of PedalCore/DSP.swift).

#include <algorithm>
#include <cmath>
#include <cstring>
#include <vector>

namespace lutherie
{
constexpr double kPiD = 3.14159265358979323846;

/// Standard second-order filter (RBJ cookbook), transposed direct form II.
struct Biquad
{
    enum Kind { lowpass, highpass, peak, lowShelf, highShelf };
    double b0 = 1, b1 = 0, b2 = 0, a1 = 0, a2 = 0, z1 = 0, z2 = 0;

    Biquad() = default;
    Biquad (Kind k, double f, double q, double gainDB, double sr) { set (k, f, q, gainDB, sr); }

    void set (Kind kind, double f, double q, double gainDB, double sr)
    {
        const double w0 = 2 * kPiD * std::min (f, sr * 0.49) / sr;
        const double cw = std::cos (w0), sw = std::sin (w0), alpha = sw / (2 * q), A = std::pow (10.0, gainDB / 40);
        double nb0 = 0, nb1 = 0, nb2 = 0, na0 = 1, na1 = 0, na2 = 0;
        switch (kind)
        {
            case lowpass:  nb0 = (1 - cw) / 2; nb1 = 1 - cw; nb2 = nb0; na0 = 1 + alpha; na1 = -2 * cw; na2 = 1 - alpha; break;
            case highpass: nb0 = (1 + cw) / 2; nb1 = -(1 + cw); nb2 = nb0; na0 = 1 + alpha; na1 = -2 * cw; na2 = 1 - alpha; break;
            case peak:     nb0 = 1 + alpha * A; nb1 = -2 * cw; nb2 = 1 - alpha * A; na0 = 1 + alpha / A; na1 = -2 * cw; na2 = 1 - alpha / A; break;
            case lowShelf:
            {
                const double s = 2 * std::sqrt (A) * alpha;
                nb0 = A * ((A + 1) - (A - 1) * cw + s); nb1 = 2 * A * ((A - 1) - (A + 1) * cw); nb2 = A * ((A + 1) - (A - 1) * cw - s);
                na0 = (A + 1) + (A - 1) * cw + s; na1 = -2 * ((A - 1) + (A + 1) * cw); na2 = (A + 1) + (A - 1) * cw - s;
                break;
            }
            case highShelf:
            {
                const double s = 2 * std::sqrt (A) * alpha;
                nb0 = A * ((A + 1) + (A - 1) * cw + s); nb1 = -2 * A * ((A - 1) + (A + 1) * cw); nb2 = A * ((A + 1) + (A - 1) * cw - s);
                na0 = (A + 1) - (A - 1) * cw + s; na1 = 2 * ((A - 1) - (A + 1) * cw); na2 = (A + 1) - (A - 1) * cw - s;
                break;
            }
        }
        b0 = nb0 / na0; b1 = nb1 / na0; b2 = nb2 / na0; a1 = na1 / na0; a2 = na2 / na0;
    }

    double run (double x)
    {
        const double y = b0 * x + z1;
        z1 = b1 * x - a1 * y + z2;
        z2 = b2 * x - a2 * y;
        return y;
    }

    double magnitudeDB (double f, double sr) const
    {
        const double w = 2 * kPiD * f / sr;
        const double c1 = std::cos (w), s1 = std::sin (w), c2 = std::cos (2 * w), s2 = std::sin (2 * w);
        const double nr = b0 + b1 * c1 + b2 * c2, ni = -(b1 * s1 + b2 * s2);
        const double dr = 1 + a1 * c1 + a2 * c2, di = -(a1 * s1 + a2 * s2);
        return 10 * std::log10 ((nr * nr + ni * ni) / std::max (dr * dr + di * di, 1e-30));
    }
};

/// Removes DC at 8 Hz.
struct DCBlocker
{
    double x1 = 0, y1 = 0, r = 0.999;
    explicit DCBlocker (double sr = 48000) : r (1 - 2 * kPiD * 8 / sr) {}
    double run (double x) { const double y = x - x1 + r * y1; x1 = x; y1 = y; return y; }
    void heal() { if (! (std::isfinite (x1) && std::isfinite (y1))) x1 = y1 = 0; }
};

/// Windowed-sinc FIR interpolator/decimator: linear phase, exactly 48 host samples of delay at any factor,
/// flat to 0.38 × the host rate and 90 dB down from half the host rate up.
class Oversampler
{
public:
    explicit Oversampler (int f) : factor (std::max (1, f))
    {
        const int L = 48 * factor + 1;
        len = L;
        const double fc = 0.44 / factor, beta = 9.0;
        auto bessel0 = [] (double x)
        {
            double s = 1, t = 1;
            for (int k = 1; k < 25; ++k) { t *= (x / (2.0 * k)) * (x / (2.0 * k)); s += t; }
            return s;
        };
        std::vector<double> h ((size_t) L);
        const double mid = (L - 1) / 2.0;
        double sum = 0;
        for (int i = 0; i < L; ++i)
        {
            const double t = i - mid;
            const double sinc = t == 0 ? 2 * fc : std::sin (2 * kPiD * fc * t) / (kPiD * t);
            const double r = (i - mid) / mid;
            h[(size_t) i] = sinc * bessel0 (beta * std::sqrt (std::max (0.0, 1 - r * r))) / bessel0 (beta);
            sum += h[(size_t) i];
        }
        for (auto& v : h) v /= sum;
        upN = (L + factor - 1) / factor;
        upTaps.assign ((size_t) (factor * upN), 0);
        for (int k = 0; k < factor; ++k)
            for (int i = 0; i < upN; ++i)
            {
                const int idx = k + (upN - 1 - i) * factor;
                upTaps[(size_t) (k * upN + i)] = idx < L ? factor * h[(size_t) idx] : 0;
            }
        upHist.assign ((size_t) (2 * upN), 0);
        downTaps = h;
        downHist.assign ((size_t) (2 * L), 0);
    }

    const int factor;

    void up (double x, double* out)
    {
        if (factor == 1) { out[0] = x; return; }
        const int N = upN;
        upHist[(size_t) upPos] = x; upHist[(size_t) (upPos + N)] = x;
        if (++upPos == N) upPos = 0;
        const double* window = upHist.data() + upPos;
        for (int k = 0; k < factor; ++k) out[k] = dot (window, upTaps.data() + k * N, N);
    }

    double down (const double* in)
    {
        if (factor == 1) return in[0];
        const int L = len;
        downHist[(size_t) downPos] = in[0]; downHist[(size_t) (downPos + L)] = in[0];
        if (++downPos == L) downPos = 0;
        const double acc = dot (downHist.data() + downPos, downTaps.data(), L);
        for (int k = 1; k < factor; ++k)
        {
            downHist[(size_t) downPos] = in[k]; downHist[(size_t) (downPos + L)] = in[k];
            if (++downPos == L) downPos = 0;
        }
        return acc;
    }

    int latency() const { return factor == 1 ? 0 : (len - 1) / factor; }

private:
    int len = 1, upN = 1, upPos = 0, downPos = 0;
    std::vector<double> upTaps, upHist, downTaps, downHist;

    static double dot (const double* a, const double* b, int n)
    {
        double s0 = 0, s1 = 0, s2 = 0, s3 = 0;
        int i = 0;
        for (; i + 4 <= n; i += 4) { s0 += a[i] * b[i]; s1 += a[i + 1] * b[i + 1]; s2 += a[i + 2] * b[i + 2]; s3 += a[i + 3] * b[i + 3]; }
        for (; i < n; ++i) s0 += a[i] * b[i];
        return (s0 + s1) + (s2 + s3);
    }
};

/// A plain ring-buffer delay, used to keep the dry signal and bypassed stages in step with the processed path.
class DelayLine
{
public:
    explicit DelayLine (int capacity = 8192) : buf ((size_t) capacity, 0.0f) {}
    void reset() { std::fill (buf.begin(), buf.end(), 0.0f); pos = 0; }
    void push (const float* x, int n)
    {
        const int cap = (int) buf.size();
        for (int i = 0; i < n; ++i) { buf[(size_t) pos] = x[i]; if (++pos == cap) pos = 0; }
    }
    void process (float* x, int n, int delay)
    {
        const int cap = (int) buf.size();
        const int d = std::clamp (delay, 0, cap - 1);
        if (d == 0) { push (x, n); return; }
        for (int i = 0; i < n; ++i)
        {
            buf[(size_t) pos] = x[i];
            int r = pos - d; if (r < 0) r += cap;
            x[i] = buf[(size_t) r];
            if (++pos == cap) pos = 0;
        }
    }
private:
    std::vector<float> buf;
    int pos = 0;
};

/// Direct convolution with a speaker impulse response.
class Convolver
{
public:
    explicit Convolver (std::vector<float> ir) : rev (ir.rbegin(), ir.rend()), history (ir.size() - 1 + kBlock, 0.0f) {}
    void process (float* x, int frames)
    {
        const int m = (int) rev.size();
        for (int done = 0; done < frames; done += kBlock)
        {
            const int n = std::min (kBlock, frames - done);
            std::memcpy (history.data() + m - 1, x + done, sizeof (float) * (size_t) n);
            for (int i = 0; i < n; ++i)
            {
                const float* h = history.data() + i;
                float acc = 0;
                for (int k = 0; k < m; ++k) acc += h[k] * rev[(size_t) k];
                x[done + i] = acc;
            }
            if (m > 1) std::memmove (history.data(), history.data() + n, sizeof (float) * (size_t) (m - 1));
        }
    }
private:
    static constexpr int kBlock = 512;
    std::vector<float> rev, history;
};

/// A windowed-sinc resampler for streaming audio (an amp profile captured at another sample rate).
class StreamResampler
{
public:
    StreamResampler (double inRate, double outRate) : ratio (outRate / inRate), buf (16384, 0.0)
    {
        count = 2 * half - 1;
        pos = half - 1;
    }
    void push (float x)
    {
        if (count >= (int) buf.size())
        {
            const int drop = (int) pos - half;
            if (drop <= 0) return;
            std::memmove (buf.data(), buf.data() + drop, sizeof (double) * (size_t) (count - drop));
            count -= drop; pos -= drop;
        }
        buf[(size_t) count++] = x;
    }
    int pull (float* out, int limit)
    {
        int made = 0;
        const double step = 1 / ratio, cutoff = std::min (1.0, ratio);
        while (made < limit)
        {
            const int base = (int) pos;
            if (base + half + 1 >= count) break;
            const double frac = pos - base;
            double acc = 0, wsum = 0;
            for (int k = -half + 1; k <= half; ++k)
            {
                const double t = k - frac, xx = t * cutoff;
                const double sinc = std::abs (xx) < 1e-9 ? 1 : std::sin (kPiD * xx) / (kPiD * xx);
                const double w = sinc * (0.5 + 0.5 * std::cos (kPiD * t / half));
                acc += w * buf[(size_t) (base + k)]; wsum += w;
            }
            out[made++] = (float) (acc / std::max (wsum, 1e-9));
            pos += step;
        }
        const int drop = (int) pos - half;
        if (drop > 4096)
        {
            std::memmove (buf.data(), buf.data() + drop, sizeof (double) * (size_t) (count - drop));
            count -= drop; pos -= drop;
        }
        return made;
    }
private:
    const double ratio;
    static constexpr int half = 8;
    std::vector<double> buf;
    int count = 0;
    double pos = 0;
};

/// The built-in speaker voicing (one 12" speaker, closed back) for when no impulse response is loaded.
struct CabinetSim
{
    std::vector<Biquad> filters;
    explicit CabinetSim (double sr = 48000)
    {
        filters = { Biquad (Biquad::highpass, 75, 0.8, 0, sr), Biquad (Biquad::peak, 115, 1.4, 5, sr),
                    Biquad (Biquad::peak, 420, 1.0, -3.5, sr), Biquad (Biquad::peak, 2300, 1.2, 4, sr),
                    Biquad (Biquad::lowpass, 4800, 0.75, 0, sr), Biquad (Biquad::lowpass, 6000, 0.6, 0, sr) };
    }
    double run (double x) { for (auto& f : filters) x = f.run (x); return x; }
};
} // namespace lutherie
