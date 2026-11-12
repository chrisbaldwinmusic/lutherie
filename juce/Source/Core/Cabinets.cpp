#include "Cabinets.h"

#include <algorithm>
#include <cmath>

namespace lutherie::CabinetLibrary
{
namespace
{
struct Band { double f, gain, q; };
struct Speaker { double resonance, q; Band body, mid, breakup, edge; double rolloff; int inches = 12; };
struct Box { std::string name; Speaker speaker; int count; bool openBack; double size; std::string notes; };

const Speaker american12 { 90, 1.1, { 140, 2.5, 1.2 }, { 450, -3.5, 0.9 }, { 2900, 5, 1.6 }, { 4300, 2.5, 3 }, 5600 };
const Speaker alnico12 { 75, 0.9, { 120, 1.5, 1.0 }, { 700, -1.5, 0.8 }, { 2500, 6.5, 1.4 }, { 4600, 3.5, 2.5 }, 6000 };
const Speaker british25 { 78, 1.2, { 130, 3, 1.3 }, { 650, 2.5, 0.8 }, { 2200, 5.5, 1.5 }, { 3600, 1.5, 3 }, 4700 };
const Speaker modern60 { 72, 1.0, { 110, 3.5, 1.4 }, { 400, -2.5, 1.0 }, { 1900, 6, 1.2 }, { 4000, 5, 3.5 }, 5200 };
const Speaker tweed10 { 105, 1.2, { 180, 2, 1.2 }, { 600, -1, 0.9 }, { 3100, 6, 1.5 }, { 4700, 2, 3 }, 5400, 10 };
const Speaker ceramic10 { 95, 1.0, { 160, 2.5, 1.2 }, { 500, -3, 0.9 }, { 3300, 4.5, 1.5 }, { 4800, 3, 3 }, 5900, 10 };
const Speaker big15 { 52, 1.0, { 90, 4, 1.2 }, { 350, -2, 0.9 }, { 1700, 4.5, 1.3 }, { 2900, 2, 3 }, 3900, 15 };
const Speaker bass10 { 42, 0.8, { 85, 2.5, 1.0 }, { 450, -2.5, 0.8 }, { 2300, 3, 1.4 }, { 3600, 1.5, 3 }, 4400, 10 };
const Speaker bassSealed10 { 48, 0.9, { 100, 3, 1.1 }, { 800, 2, 0.8 }, { 2000, 3.5, 1.4 }, { 3200, 1, 3 }, 3800, 10 };
const Speaker bass15 { 33, 0.8, { 65, 3.5, 1.0 }, { 380, -3, 0.8 }, { 1500, 2.5, 1.3 }, { 2400, 1, 3 }, 3000, 15 };

const std::vector<Box>& boxes()
{
    static const std::vector<Box> b {
        { "1\xc3\x97" "12 Open American", american12, 1, true, 0.50, "One 12-inch ceramic speaker in an open-back combo: scooped mids, glassy top, loose low end." },
        { "2\xc3\x97" "12 Open Alnico", alnico12, 2, true, 0.68, "Two alnico 12s in an open-back combo: chiming upper mids and a bright, complex top." },
        { "2\xc3\x97" "12 Closed British", british25, 2, false, 0.70, "Two 25-watt-style 12s in a closed box: woody mids with a firmer low end than the open cabinets." },
        { "4\xc3\x97" "12 Closed British", british25, 4, false, 0.76, "Four 25-watt-style 12s in a closed cabinet: thick low mids, a mid hump and a soft top. Classic rock." },
        { "4\xc3\x97" "12 Closed Modern", modern60, 4, false, 0.76, "Four 60-watt-style 12s in a closed cabinet: tight lows, forward upper mids and a sharp top. Heavy rhythm." },
        { "1\xc3\x97" "10 Open Tweed", tweed10, 1, true, 0.40, "One alnico 10 in a small open-back combo: boxy, midrange-forward, little deep bass." },
        { "4\xc3\x97" "10 Open American", ceramic10, 4, true, 0.62, "Four 10s in an open-back combo: punchy and clear with a quick attack." },
        { "1\xc3\x97" "15 Closed", big15, 1, false, 0.66, "One 15-inch speaker in a closed box: deep lows and a dark, smooth top." },
        { "Bass 1\xc3\x97" "15 Closed", bass15, 1, false, 0.70, "Bass cabinet. One 15: round, deep and warm with a soft top. Old-school fingerstyle and studio bass." },
        { "Bass 4\xc3\x97" "10 Closed", bass10, 4, false, 0.62, "Bass cabinet. Four 10s: punchy low mids and a clear, quick top. The modern all-rounder." },
        { "Bass 8\xc3\x97" "10 Sealed", bassSealed10, 8, false, 1.20, "Bass cabinet. Eight 10s in a tall sealed box: a tight low end with a strong midrange push. Rock and pick playing." },
    };
    return b;
}

using Filters = std::vector<Biquad>;
Biquad bq (Biquad::Kind k, double f, double q, double g, double sr) { return Biquad (k, f, q, g, sr); }

std::vector<double> run (Filters f, std::vector<double> y)
{
    for (auto& v : y) { double s = v; for (auto& b : f) s = b.run (s); v = s; }
    return y;
}

void addDelayed (std::vector<double>& y, const std::vector<double>& x, double seconds, double gain, const Filters& filters, double sr)
{
    const auto wet = run (filters, x);
    const double d = seconds * sr;
    const int whole = (int) d;
    const double frac = d - whole;
    for (int i = 0; i < (int) y.size(); ++i)
    {
        const int a = i - whole, b = a - 1;
        double v = 0;
        if (a >= 0) v += wet[(size_t) a] * (1 - frac);
        if (b >= 0) v += wet[(size_t) b] * frac;
        y[(size_t) i] += gain * v;
    }
}
} // namespace

std::vector<std::string> cabinets()
{
    std::vector<std::string> out;
    for (auto& b : boxes()) out.push_back (b.name);
    return out;
}
const std::vector<std::string>& mics() { static const std::vector<std::string> m { "Dynamic", "Large dynamic", "Ribbon", "Condenser" }; return m; }
const std::vector<std::string>& positions() { static const std::vector<std::string> p { "Cap", "Cap edge", "Cone" }; return p; }

std::string notes (const std::string& cabinet)
{
    for (auto& b : boxes()) if (b.name == cabinet) return b.notes;
    return {};
}

bool contains (const CabinetChoice& c)
{
    auto has = [] (const std::vector<std::string>& v, const std::string& s) { return std::find (v.begin(), v.end(), s) != v.end(); };
    return has (cabinets(), c.cabinet) && has (mics(), c.mic) && has (positions(), c.position);
}

std::optional<std::vector<float>> impulse (const CabinetChoice& choice, double sr)
{
    auto it = std::find_if (boxes().begin(), boxes().end(), [&] (const Box& b) { return b.name == choice.cabinet; });
    if (it == boxes().end() || ! contains (choice)) return std::nullopt;
    const Box& box = *it;
    const int n = (int) (0.045 * sr);
    std::vector<double> x ((size_t) n, 0.0);
    x[0] = 1;
    const Speaker& s = box.speaker;
    const double top = std::min (s.rolloff, sr * 0.45);
    using B = Biquad;

    auto y = run ({ bq (B::peak, s.body.f, s.body.q, s.body.gain, sr), bq (B::peak, s.mid.f, s.mid.q, s.mid.gain, sr),
                    bq (B::peak, s.breakup.f, s.breakup.q, s.breakup.gain, sr),
                    bq (B::peak, std::min (s.edge.f, sr * 0.4), s.edge.q, s.edge.gain, sr),
                    bq (B::lowpass, top, 0.9, 0, sr), bq (B::lowpass, std::min (top * 1.25, sr * 0.45), 0.6, 0, sr) }, x);

    if (box.openBack)
    {
        const auto direct = run ({ bq (B::highpass, s.resonance, s.q * 0.75, 0, sr) }, y);
        y = direct;
        addDelayed (y, direct, (box.size * 1.5 + 0.12) / 343, -0.42, { bq (B::lowpass, 900, 0.6, 0, sr) }, sr);
    }
    else
    {
        const double fc = s.resonance * 1.35;
        y = run ({ bq (B::highpass, fc, s.q * 1.05, 0, sr), bq (B::peak, 343 / (2 * box.size), 3, 1.8, sr),
                   bq (B::peak, 343 / box.size, 4, -1.5, sr) }, y);
    }

    if (box.count > 1)
    {
        const auto single = y;
        const Filters off { bq (B::lowpass, 2600, 0.6, 0, sr), bq (B::highShelf, 1500, 0.7, -4, sr) };
        const double spacing = box.speaker.inches >= 15 ? 0.42 : (box.speaker.inches <= 10 ? 0.27 : 0.33);
        addDelayed (y, single, spacing * 0.55 / 343, 0.34, off, sr);
        if (box.count >= 4)
        {
            addDelayed (y, single, spacing * 0.6 / 343, 0.30, off, sr);
            addDelayed (y, single, spacing * 1.0 / 343, 0.20, off, sr);
        }
        if (box.count >= 8)
        {
            addDelayed (y, single, spacing * 1.7 / 343, 0.16, off, sr);
            addDelayed (y, single, spacing * 2.6 / 343, 0.10, off, sr);
        }
    }
    const auto dry = y;
    addDelayed (y, dry, 0.0031 + box.size * 0.001, 0.11, { bq (B::lowpass, 2200, 0.6, 0, sr) }, sr);

    if (choice.position == "Cap edge")
        y = run ({ bq (B::highShelf, 3200, 0.7, -3, sr), bq (B::peak, 300, 0.8, 0.8, sr) }, y);
    else if (choice.position == "Cone")
        y = run ({ bq (B::highShelf, 2400, 0.7, -7, sr), bq (B::peak, 260, 0.8, 2, sr), bq (B::lowpass, std::min (top * 0.9, sr * 0.45), 0.7, 0, sr) }, y);

    const double hi = sr * 0.45;
    if (choice.mic == "Large dynamic")
        y = run ({ bq (B::highpass, 32, 0.7, 0, sr), bq (B::peak, 80, 0.9, 2.5, sr), bq (B::peak, 380, 0.9, -3, sr),
                   bq (B::peak, std::min (3800.0, hi), 1.2, 3.5, sr), bq (B::lowpass, std::min (11'000.0, hi), 0.7, 0, sr) }, y);
    else if (choice.mic == "Ribbon")
        y = run ({ bq (B::lowShelf, 220, 0.7, 4, sr), bq (B::peak, 1200, 0.7, 1, sr), bq (B::highShelf, 4500, 0.7, -5.5, sr),
                   bq (B::lowpass, std::min (11'000.0, hi), 0.7, 0, sr) }, y);
    else if (choice.mic == "Condenser")
        y = run ({ bq (B::highpass, 45, 0.7, 0, sr), bq (B::peak, 180, 0.8, 1.2, sr), bq (B::peak, std::min (8500.0, hi), 1.0, 2.5, sr),
                   bq (B::lowpass, std::min (17'000.0, hi), 0.7, 0, sr) }, y);
    else
        y = run ({ bq (B::highpass, 95, 0.6, 0, sr), bq (B::peak, 170, 0.9, 2.5, sr), bq (B::peak, 420, 1.0, -1.5, sr),
                   bq (B::peak, std::min (5600.0, hi), 1.3, 4.5, sr), bq (B::lowpass, std::min (13'000.0, hi), 0.7, 0, sr) }, y);

    const int fade = n / 4;
    for (int i = 0; i < fade; ++i) y[(size_t) (n - 1 - i)] *= 0.5 - 0.5 * std::cos (kPiD * i / fade);
    double energy = 0;
    for (double v : y) energy += v * v;
    energy = std::sqrt (energy);
    if (! (energy > 0) || ! std::isfinite (energy)) return std::nullopt;
    std::vector<float> out ((size_t) n);
    for (int i = 0; i < n; ++i) out[(size_t) i] = (float) (y[(size_t) i] / energy * 0.5);
    return out;
}
} // namespace lutherie::CabinetLibrary
