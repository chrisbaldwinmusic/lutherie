#include "Engine.h"
#include "Devices.h"

#include <algorithm>
#include <cmath>
#include <map>
#include <set>
#include <cstdlib>

namespace lutherie
{
using K = PartKind;

namespace
{
constexpr double kPi = 3.14159265358979323846;
constexpr double vtTherm = 0.025852;
/// Output transformers are integrated by the θ-method a little past the trapezoidal rule (θ = ½). The leakage
/// inductance with the tubes' few picofarads makes a resonance far above the sample rate; the trapezoidal rule leaves
/// such a mode ringing at half the sample rate forever (driving the power-tube plates hundreds of volts each step
/// when they cut off), where θ slightly above ½ lets it die away. In the audio band the difference is a fraction of
/// a percent. ngspice's trapezoidal rule rings the same way on these circuits; its Gear method doesn't.
constexpr double kTheta = 0.55;

inline std::pair<double, double> softplusPair (double u)
{
    if (u > 30) return { u, 1 };
    const double e = std::exp (u);
    if (u < -30) return { e, e };
    return { std::log1p (e), e / (1 + e) };
}

/// exp with a linear continuation above 80 so huge steps can't overflow
inline std::pair<double, double> limexp (double x)
{
    if (x < 80) { const double e = std::exp (x); return { e, e }; }
    const double e = std::exp (80.0);
    return { e * (1 + x - 80), e };
}

inline double pnjlim (double vnew, double vold, double vt, double vcrit)
{
    if (vnew > vcrit && std::abs (vnew - vold) > 2 * vt)
    {
        if (vold > 0)
        {
            const double arg = 1 + (vnew - vold) / vt;
            return arg > 0 ? vold + vt * std::log (arg) : vcrit;
        }
        return vt * std::log (std::max (vnew / vt, 1e-30));
    }
    return vnew;
}

inline double clampD (double v, double lo, double hi) { return std::min (std::max (v, lo), hi); }
} // namespace

double CircuitEngine::LFOEl::value() const
{
    switch (wave)
    {
        case 1: return mid + amp * std::sin (2 * kPi * phase);
        case 2: return mid + amp * std::tanh (20 * std::sin (2 * kPi * phase)) / std::tanh (20.0);
        default:
        {
            const double t = phase < 0.25 ? 4 * phase : (phase < 0.75 ? 2 - 4 * phase : 4 * phase - 4);
            return mid + amp * t;
        }
    }
}

// MARK: Build

CircuitEngine::CircuitEngine (const Circuit& c, double sr)
    : circuit (c), sampleRate (sr), dt (1 / sr), h (1 / sr), netlist (Netlist::build (c))
{
    for (auto& p : netlist.problems)
        if (p.rfind ("Add", 0) == 0) throw CircuitError (p);

    int nextIndex = netlist.nodeCount - 1;
    auto idx = [] (int node) { return node - 1; };   // ground (0) becomes -1
    auto newInternal = [&nextIndex] { return nextIndex++; };

    std::vector<PotEl> potList;
    std::vector<std::string> warn;
    double vmax = 0;
    bool anySupply = false;
    for (auto& p : c.parts) if (p.kind == K::supply) { vmax = std::max (vmax, std::abs (p.get ("v"))); anySupply = true; }
    vmax = std::max (1.0, anySupply ? vmax : 9.0);

    auto addCap = [this] (int a, int b, double cap) { if (cap > 0 && a != b) caps.push_back ({ a, b, cap }); };
    auto addDiode = [&] (int a, int k, const DiodeModel& m)
    {
        int anode = a;
        if (m.rs > 1e-6)
        {
            const int inner = newInternal();
            resistors.push_back ({ a, inner, 1 / m.rs });
            anode = inner;
        }
        const double nvt = m.n * vtTherm;
        DiodeEl el { anode, k, m.Is, nvt, nvt * std::log (nvt / (std::sqrt (2.0) * m.Is)), 0 };
        if (m.bv > 0) { el.bv = m.bv; el.ibv = m.ibv; el.bvt = m.nbv * vtTherm; el.bcrit = el.bvt * std::log (el.bvt / (std::sqrt (2.0) * m.ibv)); }
        diodes.push_back (el);
        addCap (a, k, m.cj);
    };

    const auto orderedPots = c.pots();
    const auto knobParts = c.knobs();
    for (auto& p : c.parts)
    {
        std::vector<int> nodes;
        for (int nd : netlist.pinNodes.at (p.id)) nodes.push_back (idx (nd));
        switch (p.kind)
        {
            case K::resistor:
            {
                const double r = std::max (p.get ("r"), 1e-3);
                if (nodes[0] != nodes[1]) resistors.push_back ({ nodes[0], nodes[1], 1 / r });
                break;
            }
            case K::capacitor: addCap (nodes[0], nodes[1], p.get ("c")); break;
            case K::inductor:
            {
                const int m = newInternal();
                resistors.push_back ({ nodes[0], m, 1 / std::max (p.get ("rs"), 1e-3) });
                inds.push_back ({ m, nodes[1], std::max (p.get ("l"), 1e-9) });
                break;
            }
            case K::pot:
            {
                const int taper = DeviceLibrary::taperIndex (p.model == "A" || p.model == "C" ? p.model : "B");
                const int knob = c.knobIndex (p).value_or (0);
                const double pos = clampD (knobParts[(size_t) knob].get ("position"), 0, 1);
                potList.push_back ({ nodes[0], nodes[1], nodes[2], std::max (p.get ("r"), 2.0), taper, pos, pos, knob });
                break;
            }
            case K::diode: case K::led: addDiode (nodes[0], nodes[1], DeviceLibrary::diode (p.model, p.kind == K::led)); break;
            case K::zener: addDiode (nodes[0], nodes[1], DeviceLibrary::zener (p.model)); break;
            case K::npn: case K::pnp:
            {
                const auto m = DeviceLibrary::bjt (p.model, p.kind == K::pnp);
                const double bvt = m.nf * vtTherm;
                bjts.push_back ({ nodes[0], nodes[1], nodes[2], m.pnp ? -1.0 : 1.0, m.Is, m.bf, m.br, m.va, bvt,
                                  bvt * std::log (bvt / (std::sqrt (2.0) * m.Is)), 0.6, -1 });
                addCap (nodes[1], nodes[2], m.cbe);
                addCap (nodes[1], nodes[0], m.cbc);
                break;
            }
            case K::njfet: case K::pjfet:
            {
                const auto m = DeviceLibrary::jfet (p.model, p.kind == K::pjfet);
                jfets.push_back ({ nodes[0], nodes[1], nodes[2], m.beta, m.vto, m.lambda, m.pch ? -1.0 : 1.0 });
                const DiodeModel gate { 1e-14, 1, 0, 0 };
                if (m.pch) { addDiode (nodes[2], nodes[1], gate); addDiode (nodes[0], nodes[1], gate); }
                else       { addDiode (nodes[1], nodes[2], gate); addDiode (nodes[1], nodes[0], gate); }
                addCap (nodes[1], nodes[2], m.cgs);
                addCap (nodes[1], nodes[0], m.cgd);
                break;
            }
            case K::nmos: case K::pmos:
            {
                const auto m = DeviceLibrary::mosfet (p.model, p.kind == K::pmos);
                mosfets.push_back ({ nodes[0], nodes[1], nodes[2], m.pmos ? -1.0 : 1.0, m.kp / 2, m.vto, m.lambda, 2 * 1.4 * vtTherm });
                const DiodeModel body { 1e-13, 1, 0, 0 };
                if (m.pmos) addDiode (nodes[0], nodes[2], body); else addDiode (nodes[2], nodes[0], body);
                addCap (nodes[1], nodes[2], m.cgs);
                addCap (nodes[1], nodes[0], m.cgd);
                break;
            }
            case K::spst:
                if (p.switchState() != 0 && nodes[0] != nodes[1]) resistors.push_back ({ nodes[0], nodes[1], 1 / 0.05 });
                break;
            case K::spdt:
            {
                const int s = p.switchState();
                const int to = s == 0 ? nodes[1] : (s == 1 ? nodes[2] : nodes[0]);
                if (to != nodes[0]) resistors.push_back ({ nodes[0], to, 1 / 0.05 });
                break;
            }
            case K::triode:
            {
                const auto m = DeviceLibrary::triode (p.model);
                triodes.push_back ({ nodes[0], nodes[1], nodes[2], m.mu, m.ex, m.kg1, m.kp, m.kvb, -1, 100 });
                addCap (nodes[1], nodes[0], m.cgp);
                addCap (nodes[1], nodes[2], m.cgk);
                addCap (nodes[0], nodes[2], m.cpk);
                break;
            }
            case K::pentode:
            {
                const auto m = DeviceLibrary::pentode (p.model);
                pentodes.push_back ({ nodes[0], nodes[1], nodes[2], nodes[3], m.mu, m.ex, m.kg1, m.kg2, m.kp, m.kvb, -20, 300, 300 });
                addCap (nodes[1], nodes[2], m.cgk);
                addCap (nodes[1], nodes[0], m.cgp);
                addCap (nodes[0], nodes[2], m.cpk);
                break;
            }
            case K::transformer:
            {
                const double ratio = std::sqrt (std::max (p.get ("zpp"), 1.0) / std::max (p.get ("zs"), 0.1));
                const double lh = std::max (p.get ("lp"), 0.01) / 4, ls = std::max (p.get ("lp"), 0.01) / (ratio * ratio);
                const double k = clampD (p.get ("k"), 0, 0.99999);
                const double l[3] = { lh, lh, ls };
                double L[9];
                for (int i = 0; i < 3; ++i) for (int j = 0; j < 3; ++j) L[i * 3 + j] = i == j ? l[i] : k * std::sqrt (l[i] * l[j]);
                const double det = L[0] * (L[4] * L[8] - L[5] * L[7]) - L[1] * (L[3] * L[8] - L[5] * L[6]) + L[2] * (L[3] * L[7] - L[4] * L[6]);
                const double g[9] = { (L[4] * L[8] - L[5] * L[7]) / det, (L[2] * L[7] - L[1] * L[8]) / det, (L[1] * L[5] - L[2] * L[4]) / det,
                                      (L[5] * L[6] - L[3] * L[8]) / det, (L[0] * L[8] - L[2] * L[6]) / det, (L[2] * L[3] - L[0] * L[5]) / det,
                                      (L[3] * L[7] - L[4] * L[6]) / det, (L[1] * L[6] - L[0] * L[7]) / det, (L[0] * L[4] - L[1] * L[3]) / det };
                const int p1 = newInternal(), p2 = newInternal(), s1 = newInternal();
                resistors.push_back ({ nodes[0], p1, 2 / std::max (p.get ("rp"), 1e-3) });
                resistors.push_back ({ p2, nodes[2], 2 / std::max (p.get ("rp"), 1e-3) });
                resistors.push_back ({ nodes[3], s1, 1 / std::max (p.get ("rsec"), 1e-3) });
                XfmrEl t {};
                t.a[0] = p1; t.a[1] = nodes[1]; t.a[2] = s1;
                t.b[0] = nodes[1]; t.b[1] = p2; t.b[2] = nodes[4];
                std::copy (g, g + 9, t.gamma);
                xfmrs.push_back (t);
                break;
            }
            case K::opamp:
            {
                const auto m = DeviceLibrary::opamp (p.model);
                const double vneg = p.props.count ("vneg") ? p.props.at ("vneg") : 0;
                const double vpos = p.props.count ("vpos") ? p.props.at ("vpos") : vmax;
                const double lo = vneg + m.headroom, hi = std::max (lo + 0.1, vpos - m.headroom);
                const int inner = newInternal();
                const double r1 = 1e6, gm = m.gain / r1, fp = m.gbw / m.gain;
                const double c1 = 1 / (2 * kPi * fp * r1);
                resistors.push_back ({ inner, -1, 1 / r1 });
                addCap (inner, -1, c1);
                const double half = (hi - lo) / 2;
                opamps.push_back ({ nodes[0], nodes[1], inner, nodes[2], gm, m.slew * 1e6 * c1, (hi + lo) / 2, half,
                                    1 / std::max (m.rout, 0.1), 2.5 * half });
                break;
            }
            case K::ota:
            {
                const auto m = DeviceLibrary::ota (p.model);
                const int di = (int) diodes.size();
                addDiode (nodes[3], -1, { m.isAbc, m.nAbc, 0, 0 });
                otas.push_back ({ nodes[0], nodes[1], nodes[2], nodes[3], di, m.iMax });
                break;
            }
            case K::vactrol:
            {
                const auto m = DeviceLibrary::vactrol (p.model);
                const int di = (int) diodes.size();
                addDiode (nodes[0], nodes[1], DeviceLibrary::diode ("Red LED", true));
                vactrols.push_back ({ di, nodes[2], nodes[3], 1 / m.rDark, 1 / m.r10, m.gamma,
                                      1 - std::exp (-dt / m.tauOn), 1 - std::exp (-dt / m.tauOff), 0, 1 / m.rDark });
                break;
            }
            case K::bbd:
            {
                const auto m = DeviceLibrary::bbd (p.model);
                const int half = std::max (m.stages / 2, 1);
                int size = 16;
                while (size < half + 8) size <<= 1;
                const double fmax = std::max (p.get ("fmax"), 100.0), fmin = std::min (std::max (p.get ("fmin"), 10.0), fmax);
                BBDEl b { nodes[0], nodes[1], nodes[2], half, fmin, fmax, std::max (p.get ("vref"), 0.1), 1.0 / 100,
                          (double) m.stages * m.inefficiency / 8, std::vector<double> ((size_t) size, 0.0), size - 1, 0,
                          0, 0, 0, 0, 1 - std::exp (-2 * kPi * 0.5 / sampleRate), 0x2545f491u };
                bbds.push_back (std::move (b));
                break;
            }
            case K::lfo:
            {
                const double fmax = std::max (p.get ("fmax"), 0.001), fmin = std::min (std::max (p.get ("fmin"), 0.001), fmax);
                lfos.push_back ({ nodes[0], nodes[1], 1.0 / 100, fmin, fmax, std::max (p.get ("vref"), 0.1), p.get ("mid"), p.get ("amp"),
                                  (int) std::lround (p.get ("wave")), 0 });
                break;
            }
            case K::supply:
                if (nodes[0] >= 0) supplies.push_back ({ nodes[0], p.get ("v"), 1 / std::max (p.get ("rs"), 1e-3) });
                break;
            case K::input:
                inputNode = nodes[0];
                inputG = 1 / std::max (p.get ("rs"), 1.0);
                inputScale = p.get ("scale");
                break;
            case K::output:
                outputNode = nodes[0];
                outputG = 1 / std::max (p.get ("rl"), 1.0);
                outputScale = p.get ("scale");
                break;
            case K::ground: case K::label: break;
        }
    }
    {   // several supply symbols on one net are one source
        std::set<int> seen;
        std::vector<SupplyEl> kept;
        for (auto& s : supplies) if (seen.insert (s.a).second) kept.push_back (s);
        supplies = kept;
    }
    if (inputNode < 0) warn.push_back ("The guitar input is connected straight to ground.");
    if (outputNode < 0) warn.push_back ("The output is connected straight to ground.");

    n = nextIndex;
    if (n <= 0) throw CircuitError ("The circuit has no nodes yet.");
    if (n > 400) throw CircuitError ("The circuit is too large (" + std::to_string (n) + " nodes).");

    // Order the unknowns: linear-only nodes first, nodes touched by a nonlinear device last.
    std::vector<bool> isNL ((size_t) n, false);
    auto mark = [&isNL] (int i) { if (i >= 0) isNL[(size_t) i] = true; };
    for (auto& d : diodes) { mark (d.a); mark (d.c); }
    for (auto& q : bjts) { mark (q.c); mark (q.b); mark (q.e); }
    for (auto& j : jfets) { mark (j.d); mark (j.g); mark (j.s); }
    for (auto& q : mosfets) { mark (q.d); mark (q.g); mark (q.s); }
    for (auto& q : pentodes) { mark (q.p); mark (q.g); mark (q.k); mark (q.s); }
    for (auto& t : triodes) { mark (t.p); mark (t.g); mark (t.k); }
    for (auto& o : opamps) { mark (o.inP); mark (o.inN); mark (o.m); mark (o.out); }
    for (auto& o : otas) { mark (o.p); mark (o.n); mark (o.out); mark (o.abc); }
    for (auto& vc : vactrols) { mark (vc.r1); mark (vc.r2); }
    const int linCount = (int) std::count (isNL.begin(), isNL.end(), false);
    nodeMap.assign ((size_t) n, 0);
    {
        int li = 0, si = linCount;
        for (int i = 0; i < n; ++i) nodeMap[(size_t) i] = isNL[(size_t) i] ? si++ : li++;
    }
    auto m = [this] (int& i) { if (i >= 0) i = nodeMap[(size_t) i]; };
    for (auto& r : resistors) { m (r.a); m (r.b); }
    for (auto& s : supplies) m (s.a);
    for (auto& p : potList) { m (p.a); m (p.b); m (p.w); }
    for (auto& cp : caps) { m (cp.a); m (cp.b); }
    for (auto& l : inds) { m (l.m); m (l.b); }
    for (auto& d : diodes) { m (d.a); m (d.c); }
    for (auto& q : bjts) { m (q.c); m (q.b); m (q.e); }
    for (auto& j : jfets) { m (j.d); m (j.g); m (j.s); }
    for (auto& q : pentodes) { m (q.p); m (q.g); m (q.k); m (q.s); }
    for (auto& t : xfmrs) for (int i = 0; i < 3; ++i) { m (t.a[i]); m (t.b[i]); }
    for (auto& q : mosfets) { m (q.d); m (q.g); m (q.s); }
    for (auto& t : triodes) { m (t.p); m (t.g); m (t.k); }
    for (auto& o : opamps) { m (o.inP); m (o.inN); m (o.m); m (o.out); }
    for (auto& o : otas) { m (o.p); m (o.n); m (o.out); m (o.abc); }
    for (auto& vc : vactrols) { m (vc.r1); m (vc.r2); }
    for (auto& b : bbds) { m (b.inp); m (b.out); m (b.cv); }
    for (auto& o : lfos) { m (o.cv); m (o.out); }
    m (inputNode); m (outputNode);
    nl = linCount;
    ns = n - linCount;

    maxSupply = vmax;
    for (auto& k : knobParts)
    {
        potNames.push_back (k.name);
        potLabels.push_back (k.text.empty() ? k.name : k.text);
        potIDs.push_back (k.id);
    }
    knobCount = (int) knobParts.size();
    // keep pot records in knob order (by name)
    std::map<PartID, size_t> potOrder;
    for (size_t i = 0; i < orderedPots.size(); ++i) potOrder[orderedPots[i].id] = i;
    pots.assign (potList.size(), PotEl { -1, -1, -1, 1, 0, 0, 0, 0 });
    {
        size_t i = 0;
        for (auto& part : c.parts) if (part.kind == K::pot) pots[potOrder[part.id]] = potList[i++];
    }
    linear = otas.empty() && vactrols.empty() && pentodes.empty() && mosfets.empty() && diodes.empty() && bjts.empty()
             && jfets.empty() && triodes.empty() && opamps.empty();

    const size_t nn = (size_t) (n * n);
    G0.assign (nn, 0); A.assign (nn, 0);
    rhs0.assign ((size_t) n, 0); rhs.assign ((size_t) n, 0); x.assign ((size_t) n, 0);
    perm.assign ((size_t) n, 0);
    K.assign ((size_t) std::max (ns * ns, 1), 0); As.assign ((size_t) std::max (ns * ns, 1), 0);
    rS.assign ((size_t) std::max (ns, 1), 0); bS.assign ((size_t) std::max (ns, 1), 0);
    Minv.assign ((size_t) std::max (nl * nl, 1), 0); Y.assign ((size_t) std::max (nl * ns, 1), 0);
    zL.assign ((size_t) std::max (nl, 1), 0); LLw.assign ((size_t) std::max (nl * nl, 1), 0);
    permS.assign ((size_t) std::max (ns, 1), 0); permL.assign ((size_t) std::max (nl, 1), 0);
    xPrev.assign ((size_t) std::max (ns, 1), 0);
    xSave.assign ((size_t) n, 0);
    xPrevSave.assign ((size_t) std::max (ns, 1), 0);
    targetFull();
    warnings = warn;
    for (auto& p : netlist.problems) if (p.rfind ("Add", 0) != 0) warnings.push_back (p);
    dvLimit = std::max (0.5, vmax * 0.05);
    solveOperatingPoint();
}

void CircuitEngine::stamp3 (int t, double i0, double g1, int c1p, int c1n, double v1, double g2, int c2p, int c2n, double v2)
{
    if (t < 0) return;
    double* row = sA + (t - sOff) * sStride - sOff;
    if (g1 != 0) { if (c1p >= 0) row[c1p] += g1; if (c1n >= 0) row[c1n] -= g1; }
    if (g2 != 0) { if (c2p >= 0) row[c2p] += g2; if (c2n >= 0) row[c2n] -= g2; }
    sR[t - sOff] -= i0 - g1 * v1 - g2 * v2;
}

// MARK: Linear part

void CircuitEngine::stampLinear()
{
    std::fill (G0.begin(), G0.end(), 0.0);
    for (int i = 0; i < n; ++i) G0[(size_t) (i * n + i)] = gmin;
    for (auto& r : resistors) conductance (G0, r.a, r.b, r.g);
    for (auto& p : pots)
    {
        const double t = DeviceLibrary::taper (p.taper, p.pos);
        conductance (G0, p.a, p.w, 1 / std::max (p.r * t, 0.5));
        conductance (G0, p.w, p.b, 1 / std::max (p.r * (1 - t), 0.5));
    }
    for (auto& c : caps) { c.geq = dcMode ? 0 : 2 * c.c / h; conductance (G0, c.a, c.b, c.geq); }
    for (auto& l : inds) { l.geq = dcMode ? 1e3 : h / (2 * l.l); conductance (G0, l.m, l.b, l.geq); }
    for (auto& t : xfmrs)
        for (int i = 0; i < 3; ++i)
            for (int j = 0; j < 3; ++j)
            {
                const double g = dcMode ? (i == j ? 1e3 : 0) : kTheta * h * t.gm (i, j);
                if (g == 0) continue;
                addG (G0, t.a[i], t.a[j], g); addG (G0, t.b[i], t.b[j], g);
                addG (G0, t.a[i], t.b[j], -g); addG (G0, t.b[i], t.a[j], -g);
            }
    for (auto& s : supplies) addG (G0, s.a, s.a, s.g);
    if (inputNode >= 0) addG (G0, inputNode, inputNode, inputG);
    if (outputNode >= 0) addG (G0, outputNode, outputNode, outputG);
    for (auto& o : opamps) addG (G0, o.out, o.out, o.gout);
    for (auto& o : lfos) addG (G0, o.out, o.out, o.g);
    for (auto& b : bbds)
    {
        addG (G0, b.out, b.out, b.g);
        if (dcMode) addG (G0, b.out, b.inp, -b.g);
    }
    luValid = false;
    if (! dcMode && ! linear) reduce(); else reducedValid = false;
}

void CircuitEngine::reduce()
{
    const int l = nl, s = ns;
    reducedValid = false;
    if (l > 0)
    {
        for (int i = 0; i < l; ++i) for (int j = 0; j < l; ++j) LLw[(size_t) (i * l + j)] = G0[(size_t) (i * n + j)];
        if (! luFactor (LLw.data(), l, permL.data())) return;
        for (int c = 0; c < l; ++c)
        {
            for (int i = 0; i < l; ++i) zL[(size_t) i] = i == c ? 1 : 0;
            luSolve (LLw.data(), l, permL.data(), zL.data());
            for (int i = 0; i < l; ++i) Minv[(size_t) (i * l + c)] = zL[(size_t) i];
        }
        for (int i = 0; i < l; ++i)
        {
            const double* row = Minv.data() + i * l;
            for (int j = 0; j < s; ++j)
            {
                double acc = 0;
                for (int k = 0; k < l; ++k) acc += row[k] * G0[(size_t) (k * n + l + j)];
                Y[(size_t) (i * s + j)] = acc;
            }
        }
    }
    for (int i = 0; i < s; ++i)
    {
        const double* gRow = G0.data() + (l + i) * n;
        for (int j = 0; j < s; ++j)
        {
            double acc = gRow[l + j];
            for (int k = 0; k < l; ++k) acc -= gRow[k] * Y[(size_t) (k * s + j)];
            K[(size_t) (i * s + j)] = acc;
        }
    }
    reducedValid = true;
}

void CircuitEngine::buildRHS (double u)
{
    std::fill (rhs0.begin(), rhs0.end(), 0.0);
    if (! dcMode)
    {
        for (auto& c : caps)
        {
            const double ieq = c.geq * c.vPrev + c.iPrev;
            if (c.a >= 0) rhs0[(size_t) c.a] += ieq;
            if (c.b >= 0) rhs0[(size_t) c.b] -= ieq;
        }
        for (auto& l : inds)
        {
            const double ieq = l.iPrev + l.geq * l.vPrev;
            if (l.m >= 0) rhs0[(size_t) l.m] -= ieq;
            if (l.b >= 0) rhs0[(size_t) l.b] += ieq;
        }
        for (auto& t : xfmrs)
            for (int i = 0; i < 3; ++i)
            {
                const double ieq = t.iPrev[i] + (1 - kTheta) * h * (t.gm (i, 0) * t.vPrev[0] + t.gm (i, 1) * t.vPrev[1] + t.gm (i, 2) * t.vPrev[2]);
                if (t.a[i] >= 0) rhs0[(size_t) t.a[i]] -= ieq;
                if (t.b[i] >= 0) rhs0[(size_t) t.b[i]] += ieq;
            }
        for (auto& b : bbds) if (b.out >= 0) rhs0[(size_t) b.out] += b.g * b.held;
    }
    for (auto& o : lfos) if (o.out >= 0) rhs0[(size_t) o.out] += o.g * o.value() * (dcMode ? sourceScale : 1);
    for (auto& s : supplies) rhs0[(size_t) s.a] += s.v * s.g * sourceScale;
    if (inputNode >= 0) rhs0[(size_t) inputNode] += u * inputScale * inputG * sourceScale;
}

// MARK: Nonlinear devices

void CircuitEngine::stampNonlinear()
{
    for (auto& d : diodes)
    {
        double vd = v (d.a) - v (d.c);
        if (d.bv > 0 && vd < -0.5 * d.bv) vd = -(pnjlim (-(vd + d.bv), -(d.vOld + d.bv), d.bvt, d.bcrit) + d.bv);
        else vd = pnjlim (vd, d.vOld, d.nvt, d.vcrit);
        d.vOld = vd;
        auto [e, de] = limexp (vd / d.nvt);
        double id = d.Is * (e - 1) + gmin * vd;
        double gd = d.Is * de / d.nvt + gmin;
        if (d.bv > 0)
        {
            auto [eb, deb] = limexp (-(vd + d.bv) / d.bvt);
            id -= d.ibv * eb;
            gd += d.ibv * deb / d.bvt;
        }
        nlConductance (d.a, d.c, gd);
        const double ieq = id - gd * vd;
        inject (d.a, -ieq); inject (d.c, ieq);
    }
    for (auto& q : bjts)
    {
        const double p = q.pol;
        double vbe = p * (v (q.b) - v (q.e)), vbc = p * (v (q.b) - v (q.c));
        vbe = pnjlim (vbe, q.vbeOld, q.vt, q.vcrit);
        vbc = pnjlim (vbc, q.vbcOld, q.vt, q.vcrit);
        q.vbeOld = vbe; q.vbcOld = vbc;
        auto [ef, def] = limexp (vbe / q.vt);
        auto [er, der] = limexp (vbc / q.vt);
        const double iF = q.Is * (ef - 1), iR = q.Is * (er - 1);
        const double gf = q.Is * def / q.vt + gmin, gr = q.Is * der / q.vt + gmin;
        double k = 1 - vbc / q.va, dk = -1 / q.va;
        if (k < 0.05) { k = 0.05; dk = 0; }
        const double ic = (iF - iR) * k - iR / q.br;
        const double ib = iF / q.bf + iR / q.br;
        const double dic_dvbe = gf * k;
        const double dic_dvbc = -gr * k + (iF - iR) * dk - gr / q.br;
        const double dib_dvbe = gf / q.bf, dib_dvbc = gr / q.br;
        const double icA = p * ic, ibA = p * ib, vbeA = p * vbe, vbcA = p * vbc;
        stamp3 (q.c, icA, dic_dvbe, q.b, q.e, vbeA, dic_dvbc, q.b, q.c, vbcA);
        stamp3 (q.b, ibA, dib_dvbe, q.b, q.e, vbeA, dib_dvbc, q.b, q.c, vbcA);
        stamp3 (q.e, -(icA + ibA), -(dic_dvbe + dib_dvbe), q.b, q.e, vbeA, -(dic_dvbc + dib_dvbc), q.b, q.c, vbcA);
    }
    for (auto& j : jfets)
    {
        int d = j.d, s = j.s;
        if (j.pol * (v (d) - v (s)) < 0) std::swap (d, s);
        const double vgsA = v (j.g) - v (s), vdsA = v (d) - v (s);
        const double vgs = j.pol * vgsA, vds = j.pol * vdsA;
        const double vov = vgs - j.vto;
        double id = 0, gm = 0, gds = 0;
        if (vov > 0)
        {
            const double lam = 1 + j.lambda * vds;
            if (vds < vov)
            {
                id = j.beta * vds * (2 * vov - vds) * lam;
                gm = 2 * j.beta * vds * lam;
                gds = j.beta * (2 * vov - 2 * vds) * lam + j.beta * vds * (2 * vov - vds) * j.lambda;
            }
            else
            {
                id = j.beta * vov * vov * lam;
                gm = 2 * j.beta * vov * lam;
                gds = j.beta * vov * vov * j.lambda;
            }
        }
        gds += gmin;
        stamp3 (d, j.pol * id, gm, j.g, s, vgsA, gds, d, s, vdsA);
        stamp3 (s, -j.pol * id, -gm, j.g, s, vgsA, -gds, d, s, vdsA);
    }
    for (auto& q : mosfets)
    {
        const double vgsA = v (q.g) - v (q.s), vgdA = v (q.g) - v (q.d);
        const double vgs = q.pol * vgsA, vgd = q.pol * vgdA;
        auto [sps, sgs] = softplusPair ((vgs - q.vto) / q.a);
        auto [spd, sgd] = softplusPair ((vgd - q.vto) / q.a);
        const double qs = q.a * sps, qd = q.a * spd;
        const double diff = q.beta * (qs * qs - qd * qd);
        const double vds = vgs - vgd;
        const double lam = 1 + q.lambda * std::abs (vds);
        const double dl = diff * q.lambda * (vds >= 0 ? 1 : -1);
        const double id = diff * lam;
        const double g1 = q.beta * 2 * qs * sgs * lam + dl;
        const double g2 = -q.beta * 2 * qd * sgd * lam - dl;
        stamp3 (q.d, q.pol * id, g1, q.g, q.s, vgsA, g2, q.g, q.d, vgdA);
        stamp3 (q.s, -q.pol * id, -g1, q.g, q.s, vgsA, -g2, q.g, q.d, vgdA);
    }
    for (auto& t : triodes)
    {
        double vgk = v (t.g) - v (t.k), vpk = v (t.p) - v (t.k);
        const double pstep = std::max (10.0, 0.2 * std::abs (t.vpkOld));
        vpk = t.vpkOld + clampD (vpk - t.vpkOld, -pstep, pstep);
        const double cutoff = -(1 / t.mu + 10 / t.kp) * std::sqrt (t.kvb + vpk * vpk);
        if (vgk > cutoff)
        {
            const double from = std::max (t.vgkOld, cutoff);
            vgk = from + clampD (vgk - from, -0.5, 0.5);
        }
        t.vgkOld = vgk; t.vpkOld = vpk;
        const double s = std::sqrt (t.kvb + vpk * vpk);
        const double u = t.kp * (1 / t.mu + vgk / s);
        auto [sp, sg] = softplusPair (u);
        const double e1 = vpk / t.kp * sp;
        double ip = 0, gpg = 0, gpp = 0;
        if (e1 > 1e-12)
        {
            const double pw = 2 * std::pow (e1, t.ex - 1) / t.kg1;
            ip = pw * e1;
            const double dip = t.ex * pw;
            const double de_dvgk = vpk * sg / s;
            const double de_dvpk = sp / t.kp - vpk * sg * vgk * vpk / (s * s * s);
            gpg = dip * de_dvgk;
            gpp = dip * de_dvpk;
        }
        gpp += 1e-9;
        ip += 1e-9 * vpk;
        stamp3 (t.p, ip, gpp, t.p, t.k, vpk, gpg, t.g, t.k, vgk);
        stamp3 (t.k, -ip, -gpp, t.p, t.k, vpk, -gpg, t.g, t.k, vgk);
        double ig = 0, gg = gmin;
        if (vgk > 0) { ig = std::pow (vgk, 1.5) / 1300; gg += 1.5 * std::sqrt (vgk) / 1300; }
        nlConductance (t.g, t.k, gg);
        const double ieq = ig - gg * vgk;
        inject (t.g, -ieq); inject (t.k, ieq);
    }
    for (auto& t : pentodes)
    {
        double vg = v (t.g) - v (t.k), vp = v (t.p) - v (t.k), vs = v (t.s) - v (t.k);
        const double pstep = std::max (10.0, 0.2 * std::abs (t.vpOld)), sstep = std::max (10.0, 0.2 * std::abs (t.vsOld));
        vp = t.vpOld + clampD (vp - t.vpOld, -pstep, pstep);
        vs = t.vsOld + clampD (vs - t.vsOld, -sstep, sstep);
        const double vse = std::max (vs, 1.0);
        const double cutoff = -vse * (1 / t.mu + 10 / t.kp);
        if (vg > cutoff)
        {
            const double from = std::max (t.vgOld, cutoff);
            vg = from + clampD (vg - from, -1, 1);
        }
        t.vgOld = vg; t.vpOld = vp; t.vsOld = vs;
        auto [sp, sg] = softplusPair (t.kp * (1 / t.mu + vg / vse));
        const double e1 = vse / t.kp * sp;
        double ip = 0, gpg = 0, gps = 0, gpp = 1e-9;
        if (e1 > 1e-12)
        {
            const double knee = vp > 0 ? std::atan (vp / t.kvb) : 0;
            const double pw = 2 * std::pow (e1, t.ex - 1) / t.kg1;
            ip = pw * e1 * knee;
            const double dE = t.ex * pw * knee;
            gpg = dE * sg;
            if (vs > 1) gps = dE * (sp / t.kp - sg * vg / vse);
            if (vp > 0) gpp += pw * e1 / (t.kvb * (1 + vp * vp / (t.kvb * t.kvb)));
        }
        ip += 1e-9 * vp;
        const double u = vg + vse / t.mu;
        double isc = 0, gsg = 0, gss = 1e-9;
        if (u > 0)
        {
            const double pw = std::pow (u, t.ex - 1) / t.kg2;
            isc = pw * u;
            gsg = t.ex * pw;
            if (vs > 1) gss += gsg / t.mu;
        }
        isc += 1e-9 * vs;
        stamp3 (t.p, ip, gpp, t.p, t.k, vp, gpg, t.g, t.k, vg);
        stamp3 (t.p, 0, gps, t.s, t.k, vs, 0, -1, -1, 0);
        stamp3 (t.s, isc, gss, t.s, t.k, vs, gsg, t.g, t.k, vg);
        stamp3 (t.k, -(ip + isc), -gpp, t.p, t.k, vp, -(gpg + gsg), t.g, t.k, vg);
        stamp3 (t.k, 0, -(gps + gss), t.s, t.k, vs, 0, -1, -1, 0);
        double ig = 0, gg = gmin;
        if (vg > 0) { ig = std::pow (vg, 1.5) / 1300; gg += 1.5 * std::sqrt (vg) / 1300; }
        nlConductance (t.g, t.k, gg);
        const double ieq = ig - gg * vg;
        inject (t.g, -ieq); inject (t.k, ieq);
    }
    for (auto& o : opamps)
    {
        const double vd = v (o.inP) - v (o.inN);
        const double th = std::tanh (o.gm * vd / o.iMax);
        const double iin = o.iMax * th;
        const double gin = o.gm * (1 - th * th);
        stamp3 (o.m, -iin, -gin, o.inP, o.inN, vd, 0, -1, -1, 0);
        const double vm = v (o.m);
        const double kk = 20.0 / std::max (o.half, 0.1);
        const double a1 = kk * (vm - o.vClamp), a2 = kk * (-vm - o.vClamp);
        if (a1 > -30 || a2 > -30)
        {
            auto [s1, g1] = softplusPair (a1);
            auto [s2, g2] = softplusPair (a2);
            const double ic = (s1 - s2) / kk;
            const double gcl = g1 + g2 + gmin;
            nlG (o.m, o.m, gcl);
            inject (o.m, -(ic - gcl * vm));
        }
        const double xh = vm / std::max (o.half, 1e-3);
        const double x4 = xh * xh * xh * xh;
        const double den = std::sqrt (std::sqrt (1 + x4));
        const double f = o.mid + o.half * xh / den;
        const double fp = 1 / (den * (1 + x4));
        nlG (o.out, o.m, -o.gout * fp);
        inject (o.out, o.gout * (f - fp * vm));
    }
    for (auto& o : otas)
    {
        const auto& d = diodes[(size_t) o.di];
        const double vb = d.vOld;
        auto [e, de] = limexp (vb / d.nvt);
        double iabc = d.Is * (e - 1), gabc = d.Is * de / d.nvt;
        if (iabc > o.iMax) { gabc *= o.iMax / iabc; iabc = o.iMax; }
        if (iabc < 0) { iabc = 0; gabc = 0; }
        const double vd = v (o.p) - v (o.n);
        const double th = std::tanh (vd * (0.5 / vtTherm));
        const double iout = iabc * th;
        const double gd = iabc * (1 - th * th) * (0.5 / vtTherm);
        stamp3 (o.out, -iout, -gd, o.p, o.n, vd, -gabc * th, o.abc, -1, vb);
    }
    for (auto& c : vactrols) nlConductance (c.r1, c.r2, c.g);
}

// MARK: Linear algebra (plain loops: no platform library, so the same code builds everywhere)

bool CircuitEngine::luFactor (double* M, int n, int* perm)
{
    for (int k = 0; k < n; ++k)
    {
        int piv = k;
        double best = std::abs (M[k * n + k]);
        for (int r = k + 1; r < n; ++r) { const double a = std::abs (M[r * n + k]); if (a > best) { best = a; piv = r; } }
        if (best < 1e-300) return false;
        perm[k] = piv;
        if (piv != k) for (int c = 0; c < n; ++c) std::swap (M[k * n + c], M[piv * n + c]);
        const double inv = 1 / M[k * n + k];
        const double* pivRow = M + k * n;
        for (int r = k + 1; r < n; ++r)
        {
            double* row = M + r * n;
            const double f = row[k] * inv;
            row[k] = f;
            if (f != 0) for (int c = k + 1; c < n; ++c) row[c] -= f * pivRow[c];
        }
    }
    return true;
}

void CircuitEngine::luSolve (const double* M, int n, const int* perm, double* b)
{
    for (int k = 0; k < n; ++k) { const int p = perm[k]; if (p != k) std::swap (b[k], b[p]); }
    for (int i = 0; i < n; ++i)
    {
        double s = b[i];
        const double* row = M + i * n;
        for (int j = 0; j < i; ++j) s -= row[j] * b[j];
        b[i] = s;
    }
    for (int i = n - 1; i >= 0; --i)
    {
        double s = b[i];
        const double* row = M + i * n;
        for (int j = i + 1; j < n; ++j) s -= row[j] * b[j];
        b[i] = s / row[i];
    }
}

// MARK: Time stepping

bool CircuitEngine::newton (int maxIter, double tol)
{
    if (linear)
    {
        if (! luValid)
        {
            A = G0;
            if (! luFactor (A.data(), n, perm.data())) return false;
            luValid = true;
        }
        rhs = rhs0;
        luSolve (A.data(), n, perm.data(), rhs.data());
        x = rhs;
        return true;
    }
    if (reducedValid && ! dcMode && ! useFullSolver) return newtonReduced (maxIter, tol);
    targetFull();
    for (int it = 0; it < maxIter; ++it)
    {
        ++iterationCount;
        A = G0;
        rhs = rhs0;
        stampNonlinear();
        if (! luFactor (A.data(), n, perm.data())) return false;
        luSolve (A.data(), n, perm.data(), rhs.data());
        double delta = 0;
        for (int i = 0; i < n; ++i)
        {
            double d = clampD (rhs[(size_t) i] - x[(size_t) i], -dvLimit, dvLimit);
            x[(size_t) i] += d;
            const double a = std::abs (d) / (1 + std::abs (x[(size_t) i]));
            if (a > delta) delta = a;
        }
        if (delta < tol) return true;
    }
    return false;
}

bool CircuitEngine::newtonReduced (int maxIter, double tol)
{
    const int l = nl, s = ns;
    // zL = Minv · rhs0[L];  rS = rhs0[S] − G0[S,L] · zL
    for (int i = 0; i < l; ++i)
    {
        const double* row = Minv.data() + i * l;
        double acc = 0;
        for (int k = 0; k < l; ++k) acc += row[k] * rhs0[(size_t) k];
        zL[(size_t) i] = acc;
    }
    for (int i = 0; i < s; ++i)
    {
        const double* row = G0.data() + (l + i) * n;
        double acc = rhs0[(size_t) (l + i)];
        for (int k = 0; k < l; ++k) acc -= row[k] * zL[(size_t) k];
        rS[(size_t) i] = acc;
    }
    targetReduced();
    double* xs = x.data() + l;
    bool converged;
    if (predictor)
    {
        for (int i = 0; i < s; ++i) { const double now = xs[i]; xs[i] = 2 * now - xPrev[(size_t) i]; xPrev[(size_t) i] = now; }
        converged = iterateReduced (std::min (maxIter, 8), tol);
        if (! converged)
        {
            for (int i = 0; i < s; ++i) xs[i] = xPrev[(size_t) i];
            resetLimiters();
            converged = iterateReduced (maxIter, tol);
        }
    }
    else converged = iterateReduced (maxIter, tol);
    // linear nodes: x[L] = zL − Y · x[S]
    for (int i = 0; i < l; ++i)
    {
        const double* row = Y.data() + i * s;
        double acc = zL[(size_t) i];
        for (int k = 0; k < s; ++k) acc -= row[k] * xs[k];
        x[(size_t) i] = acc;
    }
    return converged;
}

bool CircuitEngine::iterateReduced (int maxIter, double tol)
{
    const int s = ns;
    double* xs = x.data() + nl;
    double prevDelta = INFINITY;
    for (int it = 0; it < maxIter; ++it)
    {
        ++iterationCount;
        std::copy (K.begin(), K.begin() + s * s, As.begin());
        std::copy (rS.begin(), rS.begin() + s, bS.begin());
        stampNonlinear();
        if (! luFactor (As.data(), s, permS.data())) return false;
        ++factorCount;
        luSolve (As.data(), s, permS.data(), bS.data());
        double delta = 0;
        for (int i = 0; i < s; ++i)
        {
            const double d = clampD (bS[(size_t) i] - xs[i], -dvLimit, dvLimit);
            xs[i] += d;
            const double a = std::abs (d) / (1 + std::abs (xs[i]));
            if (! (a <= delta)) delta = a;   // also catches NaN
        }
        if (traceNewton) std::printf ("    it %2d  delta %.3g\n", it, delta);
        if (delta < tol) return true;
        if (! std::isfinite (delta)) return false;
        if (earlyExit && prevDelta < 1e-3 && delta * delta < tol * prevDelta) return true;
        prevDelta = delta;
    }
    return false;
}

void CircuitEngine::resetLimiters()
{
    for (auto& d : diodes) d.vOld = v (d.a) - v (d.c);
    for (auto& q : bjts) { q.vbeOld = q.pol * (v (q.b) - v (q.e)); q.vbcOld = q.pol * (v (q.b) - v (q.c)); }
    for (auto& t : triodes) { t.vgkOld = v (t.g) - v (t.k); t.vpkOld = v (t.p) - v (t.k); }
    for (auto& t : pentodes) { t.vgOld = v (t.g) - v (t.k); t.vpOld = v (t.p) - v (t.k); t.vsOld = v (t.s) - v (t.k); }
}

bool CircuitEngine::isHealthy() const
{
    for (double xi : x) if (! std::isfinite (xi)) return false;
    return true;
}

void CircuitEngine::recover()
{
    try { solveOperatingPoint(); } catch (...) {}
}

void CircuitEngine::acceptStep()
{
    for (auto& c : caps)
    {
        const double vNow = v (c.a) - v (c.b);
        c.iPrev = c.geq * (vNow - c.vPrev) - c.iPrev;
        c.vPrev = vNow;
    }
    for (auto& l : inds)
    {
        const double vNow = v (l.m) - v (l.b);
        l.iPrev = l.iPrev + l.geq * (vNow + l.vPrev);
        l.vPrev = vNow;
    }
    for (auto& t : xfmrs)
    {
        double vn[3], s[3];
        for (int i = 0; i < 3; ++i) { vn[i] = v (t.a[i]) - v (t.b[i]); s[i] = kTheta * vn[i] + (1 - kTheta) * t.vPrev[i]; }
        for (int i = 0; i < 3; ++i) t.iPrev[i] += h * (t.gamma[i * 3] * s[0] + t.gamma[i * 3 + 1] * s[1] + t.gamma[i * 3 + 2] * s[2]);
        for (int i = 0; i < 3; ++i) t.vPrev[i] = vn[i];
    }
    for (auto& c : vactrols) stepVactrol (c);
    for (auto& b : bbds) stepBBD (b);
    for (auto& o : lfos)
    {
        const double u = clampD (v (o.cv) / o.vref, 0, 1);
        double ph = o.phase + o.fmin * std::pow (o.fmax / o.fmin, u) * h;
        if (ph >= 1) ph -= 1;
        o.phase = ph;
    }
}

double CircuitEngine::diodeCurrent (int i) const
{
    const auto& d = diodes[(size_t) i];
    const double vd = v (d.a) - v (d.c);
    return d.Is * (std::exp (std::min (vd / d.nvt, 80.0)) - 1);
}

void CircuitEngine::stepVactrol (VactrolEl& c)
{
    const double target = std::max (diodeCurrent (c.di), 0.0);
    double k = target > c.light ? c.kOn : c.kOff;
    if (h != dt) k = 1 - std::pow (1 - k, h / dt);   // a sub-step: the same time constant over a shorter step
    c.light += (target - c.light) * k;
    c.g = c.gDark + c.g10 * std::pow (c.light * 100, c.gamma);
}

void CircuitEngine::stepBBD (BBDEl& b)
{
    const double vin = v (b.inp);
    const double u = clampD (v (b.cv) / b.vref, 0, 1);
    const double clock = b.fmax * std::pow (b.fmin / b.fmax, u);
    const double step = clock * h;
    b.phase += step;
    b.bias += (vin - b.bias) * b.biasCoef;
    while (b.phase >= 1)
    {
        b.phase -= 1;
        const double frac = step > 0 ? 1 - b.phase / step : 1;
        const double s = b.vinPrev + (vin - b.vinPrev) * clampD (frac, 0, 1);
        double q = b.bias + 2 * std::tanh ((s - b.bias) * 0.5);
        b.seed ^= b.seed << 13; b.seed ^= b.seed >> 17; b.seed ^= b.seed << 5;
        q += 1e-4 * ((double) b.seed * (2 / 4294967296.0) - 1);
        b.ring[(size_t) b.w] = q;
        b.w = (b.w + 1) & b.mask;
        const auto& r = b.ring;
        const int m = b.mask, at = b.w - 1 - b.half;
        const double y0 = r[(size_t) (at & m)], y1 = r[(size_t) ((at - 1) & m)], ym = r[(size_t) ((at + 1) & m)], y2 = r[(size_t) ((at - 2) & m)];
        const double a = (1 - 2 * b.smear) * y0 + b.smear * (ym + y1);
        const double c = (1 - 2 * b.smear) * y1 + b.smear * (y0 + y2);
        b.held = 0.5 * (a + c);
    }
    b.vinPrev = vin;
}

void CircuitEngine::solveOperatingPoint()
{
    dcMode = true;
    stampLinear();
    std::fill (x.begin(), x.end(), 0.0);
    bool ok = false;
    const double saveLimit = dvLimit;
    dvLimit = std::max (0.25, maxSupply * 0.02);
    const int steps = 20;
    for (int s = 1; s <= steps; ++s)
    {
        sourceScale = (double) s / steps;
        buildRHS (0);
        ok = newton (300, 1e-9);
    }
    if (! ok)
        for (int i = 0; i < 3; ++i) { buildRHS (0); ok = newton (500, 1e-8); if (ok) break; }
    dvLimit = saveLimit;
    sourceScale = 1;
    if (! ok) warnings.push_back ("The bias point did not fully settle; check for missing bias resistors.");
    for (double xi : x) if (! std::isfinite (xi)) throw CircuitError ("The circuit could not be solved (a node has no path to ground?).");
    for (auto& c : caps) { c.vPrev = v (c.a) - v (c.b); c.iPrev = 0; }
    for (auto& l : inds) { l.iPrev = 1e3 * (v (l.m) - v (l.b)); l.vPrev = 0; }
    for (auto& t : xfmrs) for (int i = 0; i < 3; ++i) { t.iPrev[i] = 1e3 * (v (t.a[i]) - v (t.b[i])); t.vPrev[i] = 0; }
    for (auto& c : vactrols)
    {
        const double l = std::max (diodeCurrent (c.di), 0.0);
        c.light = l;
        c.g = c.gDark + c.g10 * std::pow (l * 100, c.gamma);
    }
    for (auto& b : bbds)
    {
        const double vin = v (b.inp);
        std::fill (b.ring.begin(), b.ring.end(), vin);
        b.held = vin; b.vinPrev = vin; b.bias = vin; b.phase = 0;
    }
    dcMode = false;
    stampLinear();
    for (int i = 0; i < ns; ++i) xPrev[(size_t) i] = x[(size_t) (nl + i)];
}

double CircuitEngine::tick (double u)
{
    buildRHS (u);
    std::copy (x.begin(), x.end(), xSave.begin());
    std::copy (xPrev.begin(), xPrev.end(), xPrevSave.begin());
    if (newton (maxIterations, tolerance)) acceptStep();
    else if (! cutBackEnabled) { ++nonConverged; acceptStep(); }
    else
    {
        // Time-step cutback, as SPICE does: when a sample won't converge (a power tube cutting off into the output
        // transformer flies its plate up hundreds of volts in one step), go back to the start of the sample and
        // cross it in shorter steps, the input rising along a straight line. Samples that converge never come here.
        // the state that sub-steps move on, kept in case the first cut isn't fine enough (copies into storage of
        // the same size, so nothing is allocated)
        capsSave = caps; indsSave = inds; xfmrsSave = xfmrs; vactrolsSave = vactrols; bbdsSave = bbds; lfosSave = lfos;
        bool ok = false;
        for (int parts : { 8, 64 })
        {
            if (parts != 8) { caps = capsSave; inds = indsSave; xfmrs = xfmrsSave; vactrols = vactrolsSave; bbds = bbdsSave; lfos = lfosSave; }
            std::copy (xSave.begin(), xSave.end(), x.begin());
            resetLimiters();
            h = dt / parts;
            stampLinear();
            ok = true;
            for (int j = 1; j <= parts; ++j)
            {
                buildRHS (uPrev + (u - uPrev) * j / parts);
                ok = newton (maxIterations, tolerance) && ok;
                acceptStep();
            }
            if (ok) break;
        }
        h = dt;
        stampLinear();
        // the predictor's history is whole samples: the one before this, then this one
        std::copy (xSave.begin() + nl, xSave.begin() + nl + ns, xPrev.begin());
        if (! ok) ++nonConverged;
        ++cutbacks;
    }
    uPrev = u;
    return v (outputNode) * outputScale;
}

void CircuitEngine::setKnob (int i, double pos)
{
    if (i < 0 || i >= knobCount) return;
    const double p = clampD (pos, 0, 1);
    for (auto& pt : pots) if (pt.knob == i && pt.target != p) { pt.target = p; potsDirty = true; }
}

double CircuitEngine::knob (int i) const
{
    for (auto& pt : pots) if (pt.knob == i) return pt.target;
    return 0;
}

void CircuitEngine::applyKnobs()
{
    if (! potsDirty) return;
    bool moving = false;
    for (auto& p : pots)
    {
        const double d = p.target - p.pos;
        if (std::abs (d) > 1e-4) { p.pos += d * 0.25; moving = true; } else p.pos = p.target;
    }
    stampLinear();
    potsDirty = moving;
}

void CircuitEngine::process (const float* input, float* output, int frames)
{
    for (int start = 0; start < frames; start += 32)
    {
        const int count = std::min (32, frames - start);
        applyKnobs();
        for (int f = start; f < start + count; ++f)
        {
            const double y = tick (input[f]);
            output[f] = std::isfinite (y) ? (float) y : 0.0f;
        }
    }
    if (! isHealthy()) recover();
}

// MARK: Analysis

std::string CircuitEngine::nameOfIndex (int idx) const
{
    for (int node = 1; node < netlist.nodeCount; ++node) if (nodeMap[(size_t) (node - 1)] == idx) return netlist.nameOf (node);
    return "internal#" + std::to_string (idx);
}

std::vector<std::pair<std::string, double>> CircuitEngine::operatingPoint() const
{
    std::vector<std::pair<std::string, double>> out;
    for (int node = 1; node < netlist.nodeCount; ++node) out.emplace_back (netlist.nameOf (node), x[(size_t) nodeMap[(size_t) (node - 1)]]);
    return out;
}

namespace
{
/// Gaussian elimination with partial pivoting on a complex system (split real/imaginary storage).
bool complexSolve (std::vector<double>& re, std::vector<double>& im, std::vector<double>& br, std::vector<double>& bi, int n,
                   std::vector<double>& xr, std::vector<double>& xi)
{
    for (int k = 0; k < n; ++k)
    {
        int piv = k; double best = 0;
        for (int r = k; r < n; ++r)
        {
            const double m = re[(size_t) (r * n + k)] * re[(size_t) (r * n + k)] + im[(size_t) (r * n + k)] * im[(size_t) (r * n + k)];
            if (m > best) { best = m; piv = r; }
        }
        if (best < 1e-300) return false;
        if (piv != k)
        {
            for (int c = 0; c < n; ++c) { std::swap (re[(size_t) (k * n + c)], re[(size_t) (piv * n + c)]); std::swap (im[(size_t) (k * n + c)], im[(size_t) (piv * n + c)]); }
            std::swap (br[(size_t) k], br[(size_t) piv]); std::swap (bi[(size_t) k], bi[(size_t) piv]);
        }
        const double pr = re[(size_t) (k * n + k)], pi = im[(size_t) (k * n + k)], pd = pr * pr + pi * pi;
        for (int r = k + 1; r < n; ++r)
        {
            const double ar = re[(size_t) (r * n + k)], ai = im[(size_t) (r * n + k)];
            if (ar == 0 && ai == 0) continue;
            const double fr = (ar * pr + ai * pi) / pd, fi = (ai * pr - ar * pi) / pd;
            for (int c = k; c < n; ++c)
            {
                const double kr = re[(size_t) (k * n + c)], ki = im[(size_t) (k * n + c)];
                re[(size_t) (r * n + c)] -= fr * kr - fi * ki;
                im[(size_t) (r * n + c)] -= fr * ki + fi * kr;
            }
            const double kbr = br[(size_t) k], kbi = bi[(size_t) k];
            br[(size_t) r] -= fr * kbr - fi * kbi;
            bi[(size_t) r] -= fr * kbi + fi * kbr;
        }
    }
    xr.assign ((size_t) n, 0); xi.assign ((size_t) n, 0);
    for (int r = n - 1; r >= 0; --r)
    {
        double sr = br[(size_t) r], si = bi[(size_t) r];
        for (int c = r + 1; c < n; ++c)
        {
            const double ar = re[(size_t) (r * n + c)], ai = im[(size_t) (r * n + c)];
            sr -= ar * xr[(size_t) c] - ai * xi[(size_t) c];
            si -= ar * xi[(size_t) c] + ai * xr[(size_t) c];
        }
        const double pr = re[(size_t) (r * n + r)], pi = im[(size_t) (r * n + r)], pd = pr * pr + pi * pi;
        xr[(size_t) r] = (sr * pr + si * pi) / pd;
        xi[(size_t) r] = (si * pr - sr * pi) / pd;
    }
    return true;
}
} // namespace

std::vector<double> CircuitEngine::frequencyResponse (const std::vector<double>& freqs)
{
    if (inputNode < 0 || outputNode < 0) return std::vector<double> (freqs.size(), -120.0);
    const auto saveX = x;
    std::vector<std::pair<double, double>> savedCaps, savedInds;
    for (auto& c : caps) savedCaps.emplace_back (c.vPrev, c.iPrev);
    for (auto& l : inds) savedInds.emplace_back (l.vPrev, l.iPrev);
    std::vector<double> savedDiodes;
    for (auto& d : diodes) savedDiodes.push_back (d.vOld);
    std::vector<std::pair<double, double>> savedBjts, savedTriodes;
    for (auto& q : bjts) savedBjts.emplace_back (q.vbeOld, q.vbcOld);
    for (auto& t : triodes) savedTriodes.emplace_back (t.vgkOld, t.vpkOld);

    dcMode = true;
    stampLinear();
    for (auto& l : inds) conductance (G0, l.m, l.b, -l.geq);
    for (auto& t : xfmrs) for (int i = 0; i < 3; ++i) conductance (G0, t.a[i], t.b[i], -1e3);
    A = G0;
    std::fill (rhs.begin(), rhs.end(), 0.0);
    targetFull();
    stampNonlinear();
    const std::vector<double> Gr = A;
    const size_t nn = (size_t) (n * n);
    std::vector<double> Cm (nn, 0), Lm (nn, 0);
    auto st = [this] (std::vector<double>& m, int a, int b, double g)
    {
        if (a >= 0) m[(size_t) (a * n + a)] += g;
        if (b >= 0) m[(size_t) (b * n + b)] += g;
        if (a >= 0 && b >= 0) { m[(size_t) (a * n + b)] -= g; m[(size_t) (b * n + a)] -= g; }
    };
    for (auto& c : caps) st (Cm, c.a, c.b, c.c);
    for (auto& l : inds) st (Lm, l.m, l.b, 1 / l.l);
    for (auto& t : xfmrs)
        for (int i = 0; i < 3; ++i)
            for (int j = 0; j < 3; ++j)
            {
                const double g = t.gm (i, j);
                auto put = [&] (int r, int c, double val) { if (r >= 0 && c >= 0) Lm[(size_t) (r * n + c)] += val; };
                put (t.a[i], t.a[j], g); put (t.b[i], t.b[j], g); put (t.a[i], t.b[j], -g); put (t.b[i], t.a[j], -g);
            }
    dcMode = false;
    x = saveX;
    stampLinear();
    for (size_t i = 0; i < caps.size(); ++i) { caps[i].vPrev = savedCaps[i].first; caps[i].iPrev = savedCaps[i].second; }
    for (size_t i = 0; i < inds.size(); ++i) { inds[i].vPrev = savedInds[i].first; inds[i].iPrev = savedInds[i].second; }
    for (size_t i = 0; i < diodes.size(); ++i) diodes[i].vOld = savedDiodes[i];
    for (size_t i = 0; i < bjts.size(); ++i) { bjts[i].vbeOld = savedBjts[i].first; bjts[i].vbcOld = savedBjts[i].second; }
    for (size_t i = 0; i < triodes.size(); ++i) { triodes[i].vgkOld = savedTriodes[i].first; triodes[i].vpkOld = savedTriodes[i].second; }

    std::vector<double> out, re (nn), im (nn), br ((size_t) n), bi ((size_t) n), xr, xi;
    for (double f : freqs)
    {
        const double w = 2 * kPi * f;
        for (size_t i = 0; i < nn; ++i) { re[i] = Gr[i]; im[i] = w * Cm[i] - Lm[i] / w; }
        std::fill (br.begin(), br.end(), 0.0); std::fill (bi.begin(), bi.end(), 0.0);
        br[(size_t) inputNode] = inputG * inputScale;
        if (complexSolve (re, im, br, bi, n, xr, xi))
        {
            const double vr = xr[(size_t) outputNode] * outputScale, vi = xi[(size_t) outputNode] * outputScale;
            out.push_back (10 * std::log10 (std::max (vr * vr + vi * vi, 1e-24)));
        }
        else out.push_back (-120);
    }
    return out;
}
} // namespace lutherie
