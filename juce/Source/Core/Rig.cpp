#include "Rig.h"

#include <chrono>
#include <cmath>
#include <set>

namespace lutherie
{
// MARK: Parameters

namespace RigParam
{
std::vector<int> all()
{
    std::vector<int> ids;
    for (int i = 0; i <= 8; ++i) ids.push_back (i);
    for (int i = 10; i <= 17; ++i) ids.push_back (i);
    for (int i = 20; i <= 27; ++i) ids.push_back (i);
    for (int s = 1; s < pedalSlots; ++s) for (int i = 32 + (s - 1) * 10; i <= 40 + (s - 1) * 10; ++i) ids.push_back (i);
    return ids;
}
bool isValid (int id)
{
    static const std::set<int> valid = [] { auto a = all(); return std::set<int> (a.begin(), a.end()); }();
    return valid.count (id) > 0;
}
std::optional<int> pedalOnSlot (int id)
{
    if (id == 2) return 0;
    if (id < 32) return std::nullopt;
    const int r = id - 32;
    return r % 10 == 0 ? std::optional<int> (r / 10 + 1) : std::nullopt;
}
std::optional<std::pair<int, int>> pedalKnobOf (int id)
{
    if (id >= 10 && id <= 17) return std::make_pair (0, id - 10);
    if (id < 32) return std::nullopt;
    const int r = id - 32;
    if (r % 10 == 0) return std::nullopt;
    return std::make_pair (r / 10 + 1, r % 10 - 1);
}
std::optional<int> ampKnobOf (int id) { return id >= 20 && id <= 27 ? std::optional<int> (id - 20) : std::nullopt; }

std::string name (int id)
{
    switch (id)
    {
        case inputLevel: return "Input Level";   case outputLevel: return "Output Level";
        case ampMode: return "Amp";               case cabMode: return "Cabinet";
        case powerDrive: return "Power Amp Drive"; case presence: return "Presence";
        case gate: return "Noise Gate";           case mix: return "Mix";
        default: break;
    }
    if (auto s = pedalOnSlot (id)) return "Pedal " + std::to_string (*s + 1) + " On";
    if (auto k = pedalKnobOf (id)) return "Pedal " + std::to_string (k->first + 1) + " Knob " + std::to_string (k->second + 1);
    if (auto k = ampKnobOf (id)) return "Amp Knob " + std::to_string (*k + 1);
    return "Parameter " + std::to_string (id);
}
float minValue (int id)
{
    switch (id) { case inputLevel: return -24; case outputLevel: return -48; case presence: return -8; case gate: return -100; default: return 0; }
}
float maxValue (int id)
{
    switch (id) { case inputLevel: return 24; case outputLevel: return 12; case ampMode: case cabMode: return 2; case presence: return 8; case gate: return -30; default: return 1; }
}
float defaultValue (int id)
{
    switch (id)
    {
        case inputLevel: return 0; case outputLevel: return -6; case ampMode: return 1; case cabMode: return 1;
        case powerDrive: return 0.35f; case presence: return 0; case gate: return -100; case mix: return 1;
        default: return pedalOnSlot (id) ? 1.0f : 0.5f;
    }
}
std::string unit (int id)
{
    return id == inputLevel || id == outputLevel || id == presence || id == gate ? "dB" : "";
}
bool isIndexed (int id) { return pedalOnSlot (id).has_value() || id == ampMode || id == cabMode; }
std::vector<std::string> valueNames (int id)
{
    if (pedalOnSlot (id)) return { "Bypassed", "On" };
    if (id == ampMode) return { "Off", "Tube circuit", "Amp profile" };
    if (id == cabMode) return { "Off", "Built-in", "Impulse response" };
    return {};
}
} // namespace RigParam

// MARK: Circuit stage

CircuitStage::CircuitStage (const Circuit& c, double hostRate, int f)
    : engine (c, hostRate * std::max (1, f)), factor (std::max (1, f)),
      powerDC (hostRate * std::max (1, f)), chainDC (hostRate * std::max (1, f)), os (std::max (1, f)), buf ((size_t) std::max (1, f))
{
}

double CircuitStage::power (double v)
{
    const double x = powerDC.run (v) * powerDrive;
    const double y = x >= 0 ? std::tanh (x) : std::tanh (x * 0.92) / 0.92;
    return y * powerMakeup * 0.5;
}

void CircuitStage::setPower (const float* pd)
{
    // a circuit with real power tubes needs no stand-in power stage
    if (pd && ! engine.circuit.hasPowerStage())
    {
        powerOn = true;
        powerDrive = 0.5 + 6 * (double) *pd;
        powerMakeup = 1 / std::tanh (powerDrive * 0.5);
    }
    else powerOn = false;
}

float CircuitStage::run (float x)
{
    if (factor == 1)
    {
        const double y = engine.tick (x);
        return (float) (powerOn ? power (y) : y);
    }
    os.up (x, buf.data());
    for (int k = 0; k < factor; ++k) { const double y = engine.tick (buf[(size_t) k]); buf[(size_t) k] = powerOn ? power (y) : y; }
    const double y = os.down (buf.data());
    return std::isfinite (y) ? (float) y : 0.0f;
}

void CircuitStage::process (float* x, int frames, const float* knobs, const float* pd)
{
    for (int i = 0; i < std::min (engine.knobCount, RigParam::knobsPerCircuit); ++i) engine.setKnob (i, knobs[i]);
    setPower (pd);
    for (int start = 0; start < frames; start += 32)
    {
        const int n = std::min (32, frames - start);
        engine.applyKnobs();
        for (int f = start; f < start + n; ++f) x[f] = run (x[f]);
    }
    checkHealth();
}

void CircuitStage::checkHealth()
{
    if (! engine.isHealthy()) engine.recover();
    powerDC.heal();
    chainDC.heal();
}

// MARK: Rig

Rig::Rig (double sr, int mf)
    : sampleRate (sr), maxFrames (mf), cab (sr), presenceFilter (Biquad::highShelf, 3500, 0.7, 0, sr), dcPedal (sr),
      dry ((size_t) mf), scratch ((size_t) mf)
{
    for (auto& p : params) p.store (0);
    for (int id : RigParam::all()) params[(size_t) id].store (RigParam::defaultValue (id));
    for (int i = 0; i < maxPedals; ++i) { order[(size_t) i] = i; pendingOrder[(size_t) i] = i; }
    retired.reserve (64);
    trash.reserve (64);
    setGateTiming();
}

void Rig::set (int id, float v)
{
    if (id < 0 || id >= RigParam::count) return;
    params[(size_t) id].store (std::clamp (v, RigParam::minValue (id), RigParam::maxValue (id)), std::memory_order_relaxed);
}

void Rig::setGateTiming()
{
    gateEnvDecay = (float) std::exp (-1 / (0.040 * sampleRate));
    gateAttack = (float) (1 - std::exp (-1 / (0.002 * sampleRate)));
    gateRelease = (float) (1 - std::exp (-1 / (0.040 * sampleRate)));
    gateHoldSamples = (int) (0.020 * sampleRate);
}

void Rig::setSampleRate (double sr)
{
    std::lock_guard<std::mutex> g (lock);
    sampleRate = sr;
    cab = CabinetSim (sr);
    presenceFilter = Biquad (Biquad::highShelf, 3500, 0.7, presenceDB, sr);
    dcPedal = DCBlocker (sr);
    setGateTiming();
    dryDelay.reset(); bypassDelay.reset();
}

template <typename F>
void Rig::swapIn (F&& body)
{
    // Objects the audio thread has finished with are freed here, after the lock is released: the lock is only held
    // for a few pointer moves, and the audio thread never waits for it (it tries, and tries again next block).
    {
        std::lock_guard<std::mutex> g (lock);
        std::swap (trash, retired);
        body();
    }
    trash.clear();
}

void Rig::prepareOversampler (const std::shared_ptr<CircuitStage>& s)
{
    if (! s || s->factor <= 1) return;
    const Oversampler* current = pendingOS ? pendingOS->get() : chainOS.get();
    if (! current || current->factor != s->factor) pendingOS = std::make_shared<Oversampler> (s->factor);
}

void Rig::installPedal (std::shared_ptr<CircuitStage> s, int slot)
{
    if (slot < 0 || slot >= maxPedals) return;
    swapIn ([&] { pendingPedals[(size_t) slot] = s; prepareOversampler (s); });
}

void Rig::setOrder (const std::vector<int>& slots)
{
    std::set<int> seen;
    std::vector<int> s;
    for (int v : slots) if (v >= 0 && v < maxPedals && seen.insert (v).second) s.push_back (v);
    swapIn ([&] {
        for (size_t i = 0; i < s.size(); ++i) pendingOrder[i] = s[i];
        pendingOrderCount = (int) s.size();
    });
}

void Rig::installAmp (std::shared_ptr<CircuitStage> s) { swapIn ([&] { pendingAmp = s; prepareOversampler (s); }); }
void Rig::installProfile (std::shared_ptr<ProfileStage> p) { swapIn ([&] { pendingProfile = p; }); }
void Rig::installImpulse (std::optional<std::vector<float>> samples)
{
    std::shared_ptr<Convolver> conv;
    if (samples && ! samples->empty()) conv = std::make_shared<Convolver> (*samples);
    swapIn ([&] { pendingIR = conv; });
}

int Rig::latencyFor (int circuits, CircuitStage* a, ProfileStage* pr) const
{
    // every circuit shares one oversampled pass and bypassed pedals are delayed to match, so switching pedals on
    // and off never shifts timing
    const int mode = (int) std::lround (get (RigParam::ampMode));
    return std::max (circuits, mode == 1 && a ? a->latency() : 0) + (mode == 2 && pr ? pr->latency() : 0);
}

int Rig::expectedLatency()
{
    std::lock_guard<std::mutex> g (lock);
    int circuits = 0;
    const bool pending = pendingOrderCount.has_value();
    for (int j = 0; j < (pending ? *pendingOrderCount : orderCount); ++j)
    {
        const int s = pending ? pendingOrder[(size_t) j] : order[(size_t) j];
        auto* st = pendingPedals[(size_t) s] ? pendingPedals[(size_t) s]->get() : pedals[(size_t) s].get();
        if (st) circuits = std::max (circuits, st->latency());
    }
    auto* a = pendingAmp ? pendingAmp->get() : amp.get();
    auto* pr = pendingProfile ? pendingProfile->get() : profile.get();
    return latencyFor (circuits, a, pr);
}

int Rig::boardLatency() const
{
    int l = 0;
    for (int j = 0; j < orderCount; ++j) if (auto& st = pedals[(size_t) order[(size_t) j]]) l = std::max (l, st->latency());
    return l;
}

void Rig::process (const float* input, float* output, int frames)
{
    const auto t0 = std::chrono::steady_clock::now();
    if (lock.try_lock())
    {
        auto take = [this] (auto& current, auto& pending)
        {
            if (! pending) return;
            if (current) retired.push_back (std::static_pointer_cast<void> (current));
            current = *pending;
            pending.reset();
        };
        for (int s = 0; s < maxPedals; ++s) take (pedals[(size_t) s], pendingPedals[(size_t) s]);
        if (pendingOrderCount)
        {
            for (int i = 0; i < *pendingOrderCount; ++i) order[(size_t) i] = pendingOrder[(size_t) i];
            orderCount = *pendingOrderCount;
            pendingOrderCount.reset();
        }
        take (amp, pendingAmp);
        take (profile, pendingProfile);
        take (ir, pendingIR);
        take (chainOS, pendingOS);
        lock.unlock();
    }
    latencySamples.store (latencyFor (boardLatency(), amp.get(), profile.get()));

    for (int done = 0; done < frames; done += maxFrames)
        processChunk (input + done, output + done, std::min (maxFrames, frames - done));

    const double elapsed = std::chrono::duration<double> (std::chrono::steady_clock::now() - t0).count();
    load.store (load.load() * 0.9 + 0.1 * (elapsed / (frames / sampleRate)));
}

void Rig::processChunk (const float* input, float* out, int n)
{
    const float inGain = std::pow (10.0f, get (RigParam::inputLevel) / 20);
    float peakIn = 0;
    for (int i = 0; i < n; ++i)
    {
        const float v = input[i] * inGain;
        scratch[(size_t) i] = v;
        dry[(size_t) i] = v;
        peakIn = std::max (peakIn, std::abs (v));
    }
    inputPeak.store (std::max (peakIn, inputPeak.load() * 0.9f));

    dryDelay.process (dry.data(), n, latencySamples.load());

    // noise gate before the pedals, like a real one in front: opens at the threshold, closes 6 dB below it
    const float gateDB = get (RigParam::gate);
    if (gateDB > -99)
    {
        const float thr = std::pow (10.0f, gateDB / 20), closeThr = thr * 0.5f;
        for (int i = 0; i < n; ++i)
        {
            const float a = std::abs (scratch[(size_t) i]);
            gateEnv = a > gateEnv ? a : gateEnv * gateEnvDecay;
            if (gateEnv > thr) { gateOpen = true; gateHold = gateHoldSamples; }
            else if (gateEnv < closeThr) { if (gateHold > 0) --gateHold; else gateOpen = false; }
            const float target = gateOpen ? 1.0f : 0.0f;
            gateGain += (target - gateGain) * (target > gateGain ? gateAttack : gateRelease);
            scratch[(size_t) i] *= gateGain;
        }
    }
    else { gateGain = 1; gateOpen = true; }

    const int mode = (int) std::lround (get (RigParam::ampMode));
    CircuitStage* ampStage = mode == 1 ? amp.get() : nullptr;
    int circuitDelay = ampStage ? ampStage->latency() : 0;
    activeCount = 0;
    for (int j = 0; j < orderCount; ++j)
    {
        const int s = order[(size_t) j];
        auto* st = pedals[(size_t) s].get();
        if (! st) continue;
        circuitDelay = std::max (circuitDelay, st->latency());
        if (get (RigParam::pedalOn (s)) > 0.5f) { active[(size_t) activeCount] = st; activeSlots[(size_t) activeCount] = s; ++activeCount; }
    }
    if (activeCount == 0 && ! ampStage)
    {
        if (circuitDelay > 0) bypassDelay.process (scratch.data(), n, circuitDelay);
    }
    else
    {
        if (circuitDelay > 0) bypassDelay.push (scratch.data(), n);
        const int f = ampStage ? ampStage->factor : active[0]->factor;
        bool same = true;
        for (int j = 0; j < activeCount; ++j) if (active[(size_t) j]->factor != f) same = false;
        if (same && (f == 1 || (chainOS && chainOS->factor == f)))
            runChain (scratch.data(), n, ampStage, f > 1 ? chainOS.get() : nullptr);
        else
        {
            // only while circuits rebuilt at a new oversampling factor arrive one by one
            float knobs[RigParam::knobsPerCircuit];
            for (int j = 0; j < activeCount; ++j)
            {
                for (int k = 0; k < RigParam::knobsPerCircuit; ++k) knobs[k] = get (RigParam::pedalKnob (activeSlots[(size_t) j], k));
                active[(size_t) j]->process (scratch.data(), n, knobs);
                for (int i = 0; i < n; ++i) scratch[(size_t) i] = (float) dcPedal.run (scratch[(size_t) i]);
            }
            if (ampStage)
            {
                for (int k = 0; k < RigParam::knobsPerCircuit; ++k) knobs[k] = get (RigParam::ampKnob (k));
                const float pd = get (RigParam::powerDrive);
                ampStage->process (scratch.data(), n, knobs, &pd);
            }
        }
    }
    if (mode == 2 && profile) profile->process (scratch.data(), n);

    const float pres = get (RigParam::presence);
    if (pres != presenceDB)
    {
        presenceDB = pres;
        presenceFilter.set (Biquad::highShelf, 3500, 0.7, pres, sampleRate);
    }
    const int cabMode = (int) std::lround (get (RigParam::cabMode));
    if (cabMode == 2 && ir)
    {
        ir->process (scratch.data(), n);
        for (int i = 0; i < n; ++i) scratch[(size_t) i] = (float) presenceFilter.run (scratch[(size_t) i]);
    }
    else if (cabMode >= 1)
        for (int i = 0; i < n; ++i) scratch[(size_t) i] = (float) presenceFilter.run (cab.run (scratch[(size_t) i]));
    else
        for (int i = 0; i < n; ++i) scratch[(size_t) i] = (float) presenceFilter.run (scratch[(size_t) i]);

    const float outGain = std::pow (10.0f, get (RigParam::outputLevel) / 20);
    const float mixAmt = get (RigParam::mix);
    float peakOut = 0;
    for (int i = 0; i < n; ++i)
    {
        float y = (scratch[(size_t) i] * mixAmt + dry[(size_t) i] * (1 - mixAmt)) * outGain;
        if (! std::isfinite (y)) y = 0;
        y = std::clamp (y, -4.0f, 4.0f);
        out[i] = y;
        peakOut = std::max (peakOut, std::abs (y));
    }
    outputPeak.store (std::max (peakOut, outputPeak.load() * 0.9f));
}

void Rig::runChain (float* x, int n, CircuitStage* a, Oversampler* os)
{
    for (int j = 0; j < activeCount; ++j)
    {
        auto* st = active[(size_t) j];
        for (int i = 0; i < std::min (st->engine.knobCount, RigParam::knobsPerCircuit); ++i)
            st->engine.setKnob (i, get (RigParam::pedalKnob (activeSlots[(size_t) j], i)));
    }
    if (a)
    {
        for (int i = 0; i < std::min (a->engine.knobCount, RigParam::knobsPerCircuit); ++i) a->engine.setKnob (i, get (RigParam::ampKnob (i)));
        const float pd = get (RigParam::powerDrive);
        a->setPower (&pd);
    }
    const int f = os ? os->factor : 1;
    for (int start = 0; start < n; start += 32)
    {
        const int m = std::min (32, n - start);
        for (int j = 0; j < activeCount; ++j) active[(size_t) j]->engine.applyKnobs();
        if (a) a->engine.applyKnobs();
        for (int i = start; i < start + m; ++i)
        {
            double y;
            if (os)
            {
                os->up (x[i], chainBuf.data());
                for (int k = 0; k < f; ++k) chainBuf[(size_t) k] = tickChain (chainBuf[(size_t) k], a);
                y = os->down (chainBuf.data());
            }
            else y = tickChain (x[i], a);
            x[i] = std::isfinite (y) ? (float) y : 0.0f;
        }
    }
    for (int j = 0; j < activeCount; ++j) active[(size_t) j]->checkHealth();
    if (a) a->checkHealth();
}

double Rig::tickChain (double v, CircuitStage* a)
{
    for (int j = 0; j < activeCount; ++j)
    {
        auto* st = active[(size_t) j];
        v = st->chainDC.run (st->engine.tick (v));
    }
    if (a)
    {
        const double y = a->engine.tick (v);
        v = a->powerOn ? a->power (y) : y;
    }
    return v;
}
} // namespace lutherie
