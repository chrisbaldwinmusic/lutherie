#pragma once

// Modified nodal analysis solver for one circuit: Newton–Raphson on every sample, trapezoidal integration for
// capacitors and inductors, physical device models. Port of PedalCore/Engine.swift; comments there explain the
// models in more depth. Nothing on the audio path allocates.

#include "Circuit.h"

#include <cstdint>
#include <stdexcept>
#include <string>
#include <utility>
#include <vector>

namespace lutherie
{
struct CircuitError : std::runtime_error { using std::runtime_error::runtime_error; };

class CircuitEngine
{
public:
    CircuitEngine (const Circuit& circuit, double sampleRate);

    const Circuit circuit;
    const double sampleRate, dt;
    /// Samples that needed cutting into shorter steps to converge (for checks and the CPU readout).
    int cutbacks = 0;
    int n = 0;
    Netlist netlist;
    std::vector<std::string> potNames, potLabels, warnings;
    std::vector<PartID> potIDs;
    int nonConverged = 0;
    int knobCount = 0;
    int nl = 0, ns = 0;

    bool earlyExit = true;
    bool predictor = true;
    double tolerance = 1e-6;
    bool useFullSolver = false;
    int maxIterations = 40;
    bool traceNewton = false;     // debugging: print every Newton iteration
    bool cutBackEnabled = true;   // testing aid: off, a sample that won't converge is taken as it stands
    int64_t iterationCount = 0, factorCount = 0;

    /// Advances one sample with input u (in input units) and returns the output in output units.
    double tick (double u);
    /// Sets a knob (0…1). Safe on the audio thread; applied gradually by applyKnobs().
    void setKnob (int i, double pos);
    double knob (int i) const;
    /// Moves knobs a step toward their targets (call every 32 samples or so).
    void applyKnobs();
    void process (const float* input, float* output, int frames);

    bool isHealthy() const;
    void recover();

    std::vector<std::pair<std::string, double>> operatingPoint() const;
    std::string nameOfIndex (int idx) const;
    std::vector<double> frequencyResponse (const std::vector<double>& freqs);

private:
    struct ResistorEl { int a, b; double g; };
    struct PotEl { int a, b, w; double r; int taper; double pos, target; int knob; };
    struct CapEl { int a, b; double c, geq = 0, vPrev = 0, iPrev = 0; };
    struct IndEl { int m, b; double l, geq = 0, vPrev = 0, iPrev = 0; };
    struct SupplyEl { int a; double v, g; };
    struct DiodeEl { int a, c; double Is, nvt, vcrit, vOld; double bv = 0, bvt = 1, bcrit = 0, ibv = 5e-3; };
    struct BJTEl { int c, b, e; double pol, Is, bf, br, va, vt, vcrit, vbeOld, vbcOld; };
    struct JFETEl { int d, g, s; double beta, vto, lambda, pol = 1; };
    struct MOSEl { int d, g, s; double pol, beta, vto, lambda, a; };
    struct TriodeEl { int p, g, k; double mu, ex, kg1, kp, kvb, vgkOld, vpkOld; };
    struct PentodeEl { int p, g, k, s; double mu, ex, kg1, kg2, kp, kvb, vgOld, vpOld, vsOld; };
    struct XfmrEl
    {
        int a[3], b[3];
        double gamma[9];
        double iPrev[3] {}, vPrev[3] {};
        double gm (int i, int j) const { return gamma[i * 3 + j]; }
    };
    struct OpAmpEl { int inP, inN, m, out; double gm, iMax, mid, half, gout, vClamp; };
    struct OTAEl { int p, n, out, abc, di; double iMax; };
    struct VactrolEl { int di, r1, r2; double gDark, g10, gamma, kOn, kOff, light, g; };
    struct BBDEl
    {
        int inp, out, cv, half;
        double fmin, fmax, vref, g, smear;
        std::vector<double> ring;
        int mask, w;
        double phase, held, vinPrev, bias, biasCoef;
        uint32_t seed;
    };
    struct LFOEl
    {
        int cv, out;
        double g, fmin, fmax, vref, mid, amp;
        int wave;
        double phase;
        double value() const;
    };

    std::vector<ResistorEl> resistors;
    std::vector<PotEl> pots;
    std::vector<CapEl> caps;
    std::vector<IndEl> inds;
    std::vector<SupplyEl> supplies;
    std::vector<DiodeEl> diodes;
    std::vector<BJTEl> bjts;
    std::vector<JFETEl> jfets;
    std::vector<MOSEl> mosfets;
    std::vector<PentodeEl> pentodes;
    std::vector<XfmrEl> xfmrs;
    std::vector<TriodeEl> triodes;
    std::vector<OpAmpEl> opamps;
    std::vector<OTAEl> otas;
    std::vector<VactrolEl> vactrols;
    std::vector<BBDEl> bbds;
    std::vector<LFOEl> lfos;
    // copies of the stepping state, for a sample that has to be crossed again in finer steps
    std::vector<CapEl> capsSave;
    std::vector<IndEl> indsSave;
    std::vector<XfmrEl> xfmrsSave;
    std::vector<VactrolEl> vactrolsSave;
    std::vector<BBDEl> bbdsSave;
    std::vector<LFOEl> lfosSave;

    int inputNode = -1, outputNode = -1;
    double inputG = 1e-3, inputScale = 1, outputScale = 1, outputG = 1e-6;
    static constexpr double gmin = 1e-12;

    std::vector<double> G0, A, rhs0, rhs, x;
    std::vector<int> perm;
    bool linear = false;
    std::vector<int> nodeMap;
    std::vector<double> K, As, rS, bS, Minv, Y, zL, LLw, xPrev, xSave, xPrevSave;
    double h;           // the step being taken: dt, or a fraction of it while cutting back
    double uPrev = 0;   // last sample's input, to interpolate across a cut-back sample
    std::vector<int> permS, permL;
    bool reducedValid = false;

    double* sA = nullptr;
    double* sR = nullptr;
    int sStride = 0, sOff = 0;
    bool luValid = false, dcMode = false;
    double sourceScale = 1, dvLimit = 1e9, maxSupply = 9;
    bool potsDirty = false;

    double v (int i) const { return i >= 0 ? x[(size_t) i] : 0; }
    void addG (std::vector<double>& m, int i, int j, double g) { if (i >= 0 && j >= 0) m[(size_t) (i * n + j)] += g; }
    void conductance (std::vector<double>& m, int a, int b, double g) { addG (m, a, a, g); addG (m, b, b, g); addG (m, a, b, -g); addG (m, b, a, -g); }
    void inject (int i, double cur) { if (i >= 0) sR[i - sOff] += cur; }
    void nlG (int i, int j, double g) { if (i >= 0 && j >= 0) sA[(i - sOff) * sStride + (j - sOff)] += g; }
    void nlConductance (int a, int b, double g) { nlG (a, a, g); nlG (b, b, g); nlG (a, b, -g); nlG (b, a, -g); }
    void targetFull()    { sA = A.data(); sR = rhs.data(); sStride = n; sOff = 0; }
    void targetReduced() { sA = As.data(); sR = bS.data(); sStride = ns; sOff = nl; }
    void stamp3 (int t, double i0, double g1, int c1p, int c1n, double v1, double g2, int c2p, int c2n, double v2);

    void stampLinear();
    void reduce();
    void buildRHS (double u);
    void stampNonlinear();
    bool newton (int maxIter, double tol);
    bool newtonReduced (int maxIter, double tol);
    bool iterateReduced (int maxIter, double tol);
    void resetLimiters();
    void acceptStep();
    double diodeCurrent (int i) const;
    void stepVactrol (VactrolEl&);
    void stepBBD (BBDEl&);
    void solveOperatingPoint();

    static bool luFactor (double* M, int n, int* perm);
    static void luSolve (const double* M, int n, const int* perm, double* b);
};
} // namespace lutherie
