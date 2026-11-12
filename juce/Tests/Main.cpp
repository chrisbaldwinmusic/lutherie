// Offline checks for the C++ engine: every starter circuit, run on the same test signal as the Swift engine
// (PedalCheck REF_DIR), must give the same samples. Usage: LutherieTests <reference folder>

#include "Core/CircuitJSON.h"
#include "Core/Engine.h"
#include "Core/Rig.h"
#include "Core/Cabinets.h"

#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <map>

using namespace lutherie;


int main (int argc, char** argv)
{
    const juce::File dir (argc > 1 ? juce::String (argv[1]) : juce::File::getCurrentWorkingDirectory().getChildFile ("Tests/reference").getFullPathName());
    auto circuits = circuitsFromJSON (dir.getChildFile ("pedals.json").loadFileAsString());
    for (auto& c : circuitsFromJSON (dir.getChildFile ("amps.json").loadFileAsString())) circuits.push_back (c);
    if (circuits.empty()) { std::printf ("no circuits in %s\n", dir.getFullPathName().toRawUTF8()); return 1; }

    std::map<juce::String, int> swiftFirstNC;
    for (auto& line : juce::StringArray::fromLines (dir.getChildFile ("index.txt").loadFileAsString()))
    {
        auto bits = juce::StringArray::fromTokens (line, "\t", "");
        if (bits.size() >= 3) swiftFirstNC[bits[0]] = bits[2].getIntValue();
    }
    int failures = 0;
    // Accuracy of the time-step cutback: the British head driven hard (every knob at 0.8) at 96 kHz, against the same
    // circuit stepped eight times finer all the way through. They must agree closely where the cutback works.
    for (auto& c : circuits)
    {
        if (c.name != "British 50 W Head" && ! (std::getenv ("CAL") && (c.name == "High-Gain Cascade Preamp" || c.name == "Two-Transistor Fuzz" || c.name == "British Stack Preamp"))) continue;
        auto run = [&c] (double rate, int every, int& cut, int& nc) {
            CircuitEngine e (c, rate);
            for (int k = 0; k < e.knobCount; ++k) e.setKnob (k, 0.8);
            std::vector<double> out;
            const int n = (int) (rate * 0.15);
            for (int i = 0; i < n; ++i)
            {
                if (i % 32 == 0) e.applyKnobs();
                const double t = i / rate;
                const double y = e.tick (0.3 * std::sin (2 * M_PI * 220 * t) + 0.1 * std::sin (2 * M_PI * 1250 * t));
                if (i % every == 0) out.push_back (y);
            }
            cut = e.cutbacks; nc = e.nonConverged;
            return out;
        };
        int cut1 = 0, nc1 = 0, cut8 = 0, nc8 = 0;
        const auto a = run (96'000, 1, cut1, nc1), b = run (768'000, 8, cut8, nc8);
        double err = 0, sig = 0;
        for (size_t i = a.size() / 3; i < std::min (a.size(), b.size()); ++i) { err += (a[i] - b[i]) * (a[i] - b[i]); sig += b[i] * b[i]; }
        const double db = 10 * std::log10 (err / std::max (sig, 1e-30));
        const bool ok = nc1 == 0 && db < -20;
        if (! ok) ++failures;
        if (c.name != "British 50 W Head") { std::printf ("     calibration %s: 96 vs 768 kHz error %.1f dB (cut back %d)\n", c.name.c_str(), db, cut1); continue; }
        std::printf ("%s cutback: British head flat out at 96 kHz (cut back %d, failed %d) against 768 kHz (cut back %d): error %.1f dB\n",
                     ok ? "ok  " : "FAIL", cut1, nc1, cut8, db);
    }
    const double rate = 96'000;
    const int n = (int) (rate * 0.25);
    for (auto& c : circuits)
    {
        if (c.name.rfind ("Empty", 0) == 0) continue;
        juce::String slug;
        for (auto ch : juce::String (c.name).toLowerCase()) slug += juce::CharacterFunctions::isLetterOrDigit (ch) ? juce::String::charToString (ch) : "_";
        juce::MemoryBlock ref;
        if (! dir.getChildFile (slug + ".f32").loadFileAsData (ref)) { std::printf ("FAIL %s: no reference\n", c.name.c_str()); ++failures; continue; }
        const auto* want = static_cast<const float*> (ref.getData());
        try
        {
            CircuitEngine e (c, rate);
            if (std::getenv ("FULL")) e.useFullSolver = true;
            if (std::getenv ("NOPRED")) e.predictor = false;
            if (std::getenv ("NOEARLY")) e.earlyExit = false;
            if (auto* t = std::getenv ("TOL")) e.tolerance = std::atof (t);
            if (std::getenv ("FULLOPAMPS")) { e.setOpAmpsLinear (false); e.opAmpsAllowed = false; }
            if (auto* it = std::getenv ("ITER")) e.maxIterations = std::atoi (it);
            if (std::getenv ("OP") && c.name == std::getenv ("OP"))
                for (auto& [name, val] : e.operatingPoint()) std::printf ("  %s = %.4f\n", name.c_str(), val);
            double maxDiff = 0, peak = 1e-12;
            int firstBad = -1, firstNC = -1;
            const auto t0 = std::chrono::steady_clock::now();
            for (int i = 0; i < n; ++i)
            {
                const double t = i / rate;
                if (i == n / 2) for (int k = 0; k < e.knobCount; ++k) e.setKnob (k, 0.8);
                if (i % 32 == 0) e.applyKnobs();
                if (auto* tr = std::getenv ("TRACE")) e.traceNewton = c.name == std::getenv ("OP") && i == std::atoi (tr);
                const double y = e.tick (0.3 * std::sin (2 * M_PI * 220 * t) + 0.1 * std::sin (2 * M_PI * 1250 * t));
                maxDiff = std::max (maxDiff, std::abs ((double) (float) y - want[i]));
                if (firstBad < 0 && std::abs ((double) (float) y - want[i]) > 1e-4) firstBad = i;
                if (firstNC < 0 && e.nonConverged > 0) firstNC = i;
                peak = std::max (peak, (double) std::abs (want[i]));
            }
            const double secs = std::chrono::duration<double> (std::chrono::steady_clock::now() - t0).count();
            const double db = 20 * std::log10 (std::max (maxDiff, 1e-12) / peak);
            // A circuit where the Swift engine's Newton also gives up must give up at the same sample and match until then.
            const int swiftNC = swiftFirstNC.count (slug) ? swiftFirstNC[slug] : -1;
            const bool sharedFailure = swiftNC >= 0 && firstNC == swiftNC && firstBad >= swiftNC;
            // Sub-stepped samples stop at Newton's tolerance by slightly different routes in the two engines, so a
            // circuit that needed them is held to -50 dB rather than -80.
            const bool ok = db < (e.cutbacks > 0 ? -50 : -80) || sharedFailure;
            if (sharedFailure && db >= -80)
                std::printf ("note %s: both engines stop converging at sample %d and drift apart after it\n", c.name.c_str(), swiftNC);
            if (! ok) { ++failures; std::printf ("  first differs at sample %d, first non-converged at %d (Swift %d)\n", firstBad, firstNC, swiftNC); }
            std::printf ("%s %-30s difference %7.1f dB of peak   %5.1fx real time at 96 kHz   non-converged %d  cut back %d  op-amps linear %3.0f%% (%d switches)\n",
                         ok ? "ok  " : "FAIL", c.name.c_str(), db, 0.25 / secs, e.nonConverged, e.cutbacks,
                         100.0 * (double) e.opLinearSamples / n, e.opModeSwitches);
        }
        catch (const std::exception& ex) { std::printf ("FAIL %s: %s\n", c.name.c_str(), ex.what()); ++failures; }
    }
    // The whole rig against the Swift rig (PedalCheck REF_DIR writes rig.f32): the same board, order and settings.
    {
        auto byName = [&circuits] (const std::string& n) -> const Circuit& {
            for (auto& c : circuits) if (c.name == n) return c;
            throw std::runtime_error ("no preset " + n);
        };
        Rig rig (48'000);
        const char* names[] = { "Diode Overdrive", "Four-Stage Phaser", "Bucket-Brigade Delay", "Germanium Fuzz" };
        const int slots[] = { 0, 2, 3, 5 };
        for (int i = 0; i < 4; ++i) rig.installPedal (std::make_shared<CircuitStage> (byName (names[i]), 48'000, 4), slots[i]);
        rig.setOrder ({ 3, 0, 5, 2 });
        rig.installAmp (std::make_shared<CircuitStage> (byName ("Two-Stage Tube Preamp"), 48'000, 4));
        rig.set (RigParam::pedalOn (5), 0);
        rig.set (RigParam::mix, 0.8f);
        const int frames = 48'000 / 4;
        std::vector<float> buf ((size_t) frames);
        for (int i = 0; i < frames; ++i) buf[(size_t) i] = (float) (0.3 * std::sin (2 * M_PI * 220 * i / 48'000.0));
        const auto t0 = std::chrono::steady_clock::now();
        for (int s = 0; s < frames; s += 256) rig.process (buf.data() + s, buf.data() + s, std::min (256, frames - s));
        const double secs = std::chrono::duration<double> (std::chrono::steady_clock::now() - t0).count();
        juce::MemoryBlock ref;
        dir.getChildFile ("rig.f32").loadFileAsData (ref);
        const auto* want = static_cast<const float*> (ref.getData());
        double maxDiff = 0, peak = 1e-12;
        for (int i = 0; i < frames && (size_t) i * 4 < ref.getSize(); ++i)
        {
            maxDiff = std::max (maxDiff, (double) std::abs (buf[(size_t) i] - want[i]));
            peak = std::max (peak, (double) std::abs (want[i]));
        }
        const double db = 20 * std::log10 (std::max (maxDiff, 1e-12) / peak);
        const bool ok = ref.getSize() >= (size_t) frames * 4 && db < -80 && rig.latencySamples.load() == 48;
        if (! ok) ++failures;
        std::printf ("%s rig: 4 pedals + amp at 4x, difference %.1f dB of peak, latency %d, %.0f%% of one core\n",
                     ok ? "ok  " : "FAIL", db, rig.latencySamples.load(), secs / 0.25 * 100);
    }
    // Op-amps switching between the linear treatment and the full model: a level sweeping from quiet to far too loud
    // and back, so the op-amps leave and re-enter their linear range, must match the full model throughout.
    for (const char* name : { "Four-Stage Phaser", "Bucket-Brigade Chorus", "Selectable-Clip Overdrive", "Bass Blend Overdrive" })
    {
        const Circuit* c = nullptr;
        for (auto& cc : circuits) if (cc.name == name) c = &cc;
        if (! c) continue;
        const double rate = 96'000;
        const int n = (int) (rate * 1.0);
        auto run = [&] (bool allowLinear, int& switches, double& linShare) {
            CircuitEngine e (*c, rate);
            if (! allowLinear) { e.setOpAmpsLinear (false); e.opAmpsAllowed = false; }
            std::vector<double> out ((size_t) n);
            for (int i = 0; i < n; ++i)
            {
                if (i % 32 == 0) e.applyKnobs();
                const double t = i / rate;
                const double level = 0.02 + 2.5 * std::pow (std::sin (M_PI * t), 4);   // quiet, very loud, quiet
                out[(size_t) i] = e.tick (level * std::sin (2 * M_PI * 330 * t));
            }
            switches = e.opModeSwitches; linShare = (double) e.opLinearSamples / n;
            return out;
        };
        int sw = 0, sw0 = 0; double share = 0, share0 = 0;
        const auto a = run (true, sw, share), ref = run (false, sw0, share0);
        double maxDiff = 0, peak = 1e-12;
        for (int i = 0; i < n; ++i) { maxDiff = std::max (maxDiff, std::abs (a[(size_t) i] - ref[(size_t) i])); peak = std::max (peak, std::abs (ref[(size_t) i])); }
        const double db = 20 * std::log10 (std::max (maxDiff, 1e-15) / peak);
        const bool ok = db < -80;
        if (! ok) ++failures;
        std::printf ("%s op-amp switching, %s: worst difference from the full model %.1f dB of peak over a level sweep (%d switches, linear %.0f%% of the time)\n",
                     ok ? "ok  " : "FAIL", name, db, sw, share * 100);
    }
    // Built-in cabinets: every combination builds and is normalised like a loaded impulse response.
    {
        int built = 0;
        bool ok = true;
        for (auto& c : CabinetLibrary::cabinets())
            for (auto& m : CabinetLibrary::mics())
                for (auto& p : CabinetLibrary::positions())
                {
                    auto ir = CabinetLibrary::impulse ({ c, m, p }, 48'000);
                    if (! ir) { ok = false; continue; }
                    double e = 0;
                    for (float v : *ir) e += (double) v * v;
                    ok = ok && std::abs (std::sqrt (e) - 0.5) < 1e-4;
                    ++built;
                }
        if (! ok) ++failures;
        std::printf ("%s cabinets: %d impulse responses built\n", ok ? "ok  " : "FAIL", built);
    }
    std::printf (failures == 0 ? "ALL OK\n" : "%d FAILURE(S)\n", failures);
    return failures == 0 ? 0 : 1;
}
