#pragma once

// Physical parameters for the device models (port of PedalCore/Devices.swift; the values and their sources are
// documented there).

#include <cmath>
#include <map>
#include <string>

namespace lutherie
{
struct DiodeModel   { double Is, n, rs, cj; double bv = 0, ibv = 5e-3, nbv = 2; };
struct BJTModel     { bool pnp; double Is, bf, br, va, nf, cbe, cbc; };
struct JFETModel    { double beta, vto, lambda, cgs, cgd; bool pch = false; };
struct MOSFETModel  { bool pmos; double vto, kp, lambda, cgs, cgd; };
struct OpAmpModel   { double gain, gbw, headroom, rout, slew; };
struct TriodeModel  { double mu, ex, kg1, kp, kvb, cgp, cgk, cpk; };
struct PentodeModel { double mu, ex, kg1, kg2, kp, kvb, cgk, cgp, cpk; };
struct OTAModel     { double isAbc, nAbc, iMax; };
struct VactrolModel { double r10, gamma, rDark, tauOn, tauOff; };
struct BBDModel     { int stages; double inefficiency; };

namespace DeviceLibrary
{
    inline const std::map<std::string, DiodeModel>& diodes()
    {
        static const std::map<std::string, DiodeModel> m {
            { "1N4148", { 2.52e-9, 1.752, 0.568, 4e-12 } },
            { "1N914", { 2.52e-9, 1.752, 0.568, 4e-12 } },
            { "1N4001", { 14.11e-9, 1.984, 0.0339, 25.9e-12 } },
            { "1N34A (germanium)", { 2.6e-6, 1.6, 7.0, 0.5e-12 } },
            { "BAT41 (Schottky)", { 2e-8, 1.17, 8.0, 2e-12 } },
        };
        return m;
    }
    inline const std::map<std::string, DiodeModel>& leds()
    {
        static const std::map<std::string, DiodeModel> m {
            { "Red LED", { 1e-19, 1.8, 5, 30e-12 } },
            { "Green LED", { 1e-21, 2.0, 5, 30e-12 } },
        };
        return m;
    }
    inline const std::map<std::string, DiodeModel>& zeners()
    {
        static const std::map<std::string, DiodeModel> m {
            { "3.3 V (1N4728A)", { 1e-12, 1.2, 2, 150e-12, 3.3, 76e-3, 5 } },
            { "4.7 V (1N4732A)", { 1e-12, 1.2, 2, 120e-12, 4.7, 53e-3, 3.5 } },
            { "5.1 V (1N4733A)", { 1e-12, 1.2, 2, 110e-12, 5.1, 49e-3, 2.5 } },
            { "9.1 V (1N4739A)", { 1e-12, 1.2, 2, 70e-12, 9.1, 28e-3, 1.5 } },
            { "12 V (1N4742A)", { 1e-12, 1.2, 2, 55e-12, 12, 21e-3, 1.5 } },
        };
        return m;
    }
    inline const std::map<std::string, BJTModel>& bjts()
    {
        static const std::map<std::string, BJTModel> m {
            { "2N3904", { false, 6.734e-15, 416.4, 0.7371, 74.03, 1, 4.5e-12, 3.6e-12 } },
            { "2N5088", { false, 5.911e-15, 1122, 1.271, 62.4, 1, 4.5e-12, 3e-12 } },
            { "BC109", { false, 1.8e-14, 400, 35.5, 80, 1, 8e-12, 4e-12 } },
            { "2N3906", { true, 1.41e-15, 180.7, 4.977, 18.7, 1, 4.5e-12, 4.5e-12 } },
            { "Germanium PNP (AC128 type)", { true, 1.2e-6, 90, 5, 30, 1.1, 50e-12, 20e-12 } },
            { "Germanium NPN (AC127 type)", { false, 1.2e-6, 100, 5, 30, 1.1, 50e-12, 20e-12 } },
        };
        return m;
    }
    inline const std::map<std::string, JFETModel>& jfets()
    {
        static const std::map<std::string, JFETModel> m {
            { "J201", { 1.304e-3, -0.5, 0.0125, 4e-12, 4e-12 } },
            { "2N5457", { 1.125e-3, -1.8, 0.0023, 3e-12, 1.5e-12 } },
            { "MPF102", { 1.0e-3, -2.0, 0.0022, 3e-12, 3e-12 } },
            { "2N5460", { 0.75e-3, -2.0, 0.004, 5e-12, 1.5e-12, true } },
            { "J175", { 1.5e-3, -4.5, 0.01, 11e-12, 5.5e-12, true } },
        };
        return m;
    }
    inline const std::map<std::string, MOSFETModel>& mosfets()
    {
        static const std::map<std::string, MOSFETModel> m {
            { "2N7000", { false, 2.0, 0.12, 0.0003, 20e-12, 5e-12 } },
            { "BS170", { false, 1.9, 0.08, 0.0003, 24e-12, 7e-12 } },
            { "BS250", { true, 2.0, 0.056, 0.012, 45e-12, 15e-12 } },
        };
        return m;
    }
    inline const std::map<std::string, OpAmpModel>& opamps()
    {
        static const std::map<std::string, OpAmpModel> m {
            { "TL072", { 2e5, 3e6, 1.5, 75, 13 } },
            { "NE5532", { 1e5, 10e6, 1.2, 30, 9 } },
            { "LM741", { 2e5, 1e6, 2.0, 75, 0.5 } },
            { "LM308", { 3e5, 0.3e6, 1.0, 100, 0.3 } },
            { "JRC4558", { 1e5, 3e6, 1.4, 75, 1.0 } },
            { "Ideal", { 1e6, 1e9, 0.0, 1, 1e6 } },
        };
        return m;
    }
    inline const std::map<std::string, TriodeModel>& triodes()
    {
        static const std::map<std::string, TriodeModel> m {
            { "12AX7", { 100, 1.4, 1060, 600, 300, 1.7e-12, 1.6e-12, 0.46e-12 } },
            { "12AT7", { 60, 1.35, 460, 300, 300, 1.5e-12, 2.2e-12, 0.5e-12 } },
            { "12AU7", { 21.5, 1.3, 1180, 84, 300, 1.5e-12, 1.6e-12, 0.5e-12 } },
            { "ECC83 (EU 12AX7)", { 100, 1.4, 1060, 600, 300, 1.7e-12, 1.6e-12, 0.46e-12 } },
        };
        return m;
    }
    inline const std::map<std::string, PentodeModel>& pentodes()
    {
        static const std::map<std::string, PentodeModel> m {
            { "6L6GC", { 8.7, 1.35, 1460, 4500, 48, 12, 14e-12, 0.85e-12, 12e-12 } },
            { "6550", { 7.9, 1.35, 890, 4800, 60, 24, 14e-12, 0.85e-12, 12e-12 } },
            { "KT88", { 8.8, 1.35, 730, 4200, 32, 16, 14e-12, 0.85e-12, 12e-12 } },
            { "EL34", { 11, 1.35, 650, 4200, 60, 24, 15e-12, 1.1e-12, 8e-12 } },
        };
        return m;
    }
    inline const std::map<std::string, OTAModel>& otas()
    {
        static const std::map<std::string, OTAModel> m {
            { "LM13700", { 7.6e-14, 2, 2e-3 } },
            { "CA3080", { 7.6e-14, 2, 2e-3 } },
        };
        return m;
    }
    inline const std::map<std::string, VactrolModel>& vactrols()
    {
        static const std::map<std::string, VactrolModel> m {
            { "VTL5C3", { 1.5e3, 0.75, 10e6, 2.5e-3, 35e-3 } },
            { "VTL5C1", { 600, 0.9, 50e6, 2.5e-3, 80e-3 } },
            { "NSL-32", { 400, 0.85, 500e3, 5e-3, 10e-3 } },
        };
        return m;
    }
    inline const std::map<std::string, BBDModel>& bbds()
    {
        static const std::map<std::string, BBDModel> m {
            { "MN3207 (1024 stages)", { 1024, 1e-4 } },
            { "MN3007 (1024 stages)", { 1024, 0.8e-4 } },
            { "MN3008 (2048 stages)", { 2048, 0.8e-4 } },
            { "MN3005 (4096 stages)", { 4096, 0.8e-4 } },
        };
        return m;
    }

    template <typename M>
    const typename M::mapped_type& pick (const M& m, const std::string& name, const std::string& fallback)
    {
        auto it = m.find (name);
        return it != m.end() ? it->second : m.at (fallback);
    }

    inline DiodeModel diode (const std::string& name, bool led)
    {
        return led ? pick (leds(), name, "Red LED") : pick (diodes(), name, "1N4148");
    }
    inline BJTModel bjt (const std::string& name, bool pnp)
    {
        auto it = bjts().find (name);
        if (it != bjts().end() && it->second.pnp == pnp) return it->second;
        return bjts().at (pnp ? "2N3906" : "2N3904");
    }
    inline JFETModel jfet (const std::string& name, bool pch = false)
    {
        auto it = jfets().find (name);
        if (it != jfets().end() && it->second.pch == pch) return it->second;
        return jfets().at (pch ? "2N5460" : "J201");
    }
    inline DiodeModel zener (const std::string& name)       { return pick (zeners(), name, "5.1 V (1N4733A)"); }
    inline MOSFETModel mosfet (const std::string& name, bool pmos)
    {
        auto it = mosfets().find (name);
        if (it != mosfets().end() && it->second.pmos == pmos) return it->second;
        return mosfets().at (pmos ? "BS250" : "2N7000");
    }
    inline OpAmpModel opamp (const std::string& name)       { return pick (opamps(), name, "TL072"); }
    inline TriodeModel triode (const std::string& name)     { return pick (triodes(), name, "12AX7"); }
    inline PentodeModel pentode (const std::string& name)   { return pick (pentodes(), name, "6L6GC"); }
    inline OTAModel ota (const std::string& name)           { return pick (otas(), name, "LM13700"); }
    inline VactrolModel vactrol (const std::string& name)   { return pick (vactrols(), name, "VTL5C3"); }
    inline BBDModel bbd (const std::string& name)           { return pick (bbds(), name, "MN3207 (1024 stages)"); }

    /// Taper by index (0 = B linear, 1 = A audio, 2 = C reverse audio).
    inline double taper (int index, double pos)
    {
        const double p = std::fmin (std::fmax (pos, 0.0), 1.0);
        const double k = 4.394449;   // 2·ln 9: 10 % at mid travel
        switch (index)
        {
            case 1:  return (std::exp (k * p) - 1) / (std::exp (k) - 1);
            case 2:  return 1 - (std::exp (k * (1 - p)) - 1) / (std::exp (k) - 1);
            default: return p;
        }
    }
    inline int taperIndex (const std::string& kind) { return kind == "A" ? 1 : (kind == "C" ? 2 : 0); }
} // namespace DeviceLibrary
} // namespace lutherie
