#pragma once

// The whole signal chain: input level → gate → pedalboard (up to six circuits, in any order) → amp (tube circuit
// or profile) → power stage → cabinet → output. Port of PedalCore/Rig.swift; parameter ids are the same, so host
// automation and saved sessions carry over.

#include "DSP.h"
#include "Engine.h"

#include <array>
#include <atomic>
#include <memory>
#include <mutex>
#include <optional>
#include <string>
#include <vector>

namespace lutherie
{
namespace RigParam
{
    enum : int { inputLevel = 0, outputLevel = 1, pedalOn0 = 2, ampMode = 3, cabMode = 4, powerDrive = 5, presence = 6, gate = 7, mix = 8,
                 pedalKnob1 = 10, ampKnob1 = 20 };
    constexpr int pedalSlots = 6;
    constexpr int knobsPerCircuit = 8;
    constexpr int count = 32 + (pedalSlots - 1) * 10;

    constexpr int pedalOn (int slot)               { return slot == 0 ? 2 : 32 + (slot - 1) * 10; }
    constexpr int pedalKnob (int slot, int index)  { return slot == 0 ? 10 + index : 33 + (slot - 1) * 10 + index; }
    constexpr int ampKnob (int index)              { return 20 + index; }

    /// Every id the host sees, in order.
    std::vector<int> all();
    bool isValid (int id);
    std::optional<int> pedalOnSlot (int id);
    std::optional<std::pair<int, int>> pedalKnobOf (int id);   // (slot, index)
    std::optional<int> ampKnobOf (int id);
    std::string name (int id);
    float minValue (int id);
    float maxValue (int id);
    float defaultValue (int id);
    std::string unit (int id);
    bool isIndexed (int id);
    std::vector<std::string> valueNames (int id);
}

/// One circuit running at an oversampled rate; the amp's stand-in power stage runs here too.
class CircuitStage
{
public:
    CircuitStage (const Circuit&, double hostRate, int factor);
    CircuitEngine engine;
    const int factor;
    int latency() const { return os.latency(); }

    bool powerOn = false;
    double powerDrive = 1, powerMakeup = 1;
    DCBlocker powerDC, chainDC;

    double power (double v);
    void setPower (const float* pd);
    void process (float* x, int frames, const float* knobs, const float* powerDrive = nullptr);
    void checkHealth();

private:
    Oversampler os;
    std::vector<double> buf;
    float run (float x);
};

/// An amp profile (a neural capture) run by the rig in amp mode 2. Filled in when the profile player lands.
class ProfileStage
{
public:
    virtual ~ProfileStage() = default;
    virtual int latency() const = 0;
    virtual void process (float* x, int frames) = 0;
};

class Rig
{
public:
    static constexpr int maxPedals = RigParam::pedalSlots;

    explicit Rig (double sampleRate, int maxFrames = 4096);

    /// Parameter storage, indexed by id; the host writes, the audio thread reads.
    std::array<std::atomic<float>, RigParam::count> params;
    float get (int id) const { return params[(size_t) id].load (std::memory_order_relaxed); }
    void set (int id, float v);

    double getSampleRate() const { return sampleRate; }
    /// Resets filters for a new host sample rate. Call from the message thread, then reinstall circuits.
    void setSampleRate (double sr);

    // Installing (message thread). The audio thread picks the new objects up at its next block.
    void installPedal (std::shared_ptr<CircuitStage>, int slot);
    void setOrder (const std::vector<int>& slots);
    void installAmp (std::shared_ptr<CircuitStage>);
    void installProfile (std::shared_ptr<ProfileStage>);
    void installImpulse (std::optional<std::vector<float>>);

    /// What latency will be once the audio thread has picked up everything installed.
    int expectedLatency();

    /// Mono processing, in place allowed.
    void process (const float* input, float* output, int frames);

    // meters and timing (read by the UI)
    std::atomic<float> inputPeak { 0 }, outputPeak { 0 };
    std::atomic<double> load { 0 };
    std::atomic<int> latencySamples { 0 };

    /// Engines currently running (for the editor's analysis; may change after the next block).
    CircuitEngine* pedalEngine (int slot) { return pedals[(size_t) slot] ? &pedals[(size_t) slot]->engine : nullptr; }
    CircuitEngine* ampEngine() { return amp ? &amp->engine : nullptr; }

private:
    double sampleRate;
    const int maxFrames;

    // what the audio thread runs
    std::array<std::shared_ptr<CircuitStage>, maxPedals> pedals {};
    std::array<int, maxPedals> order {};
    int orderCount = maxPedals;
    std::shared_ptr<CircuitStage> amp;
    std::shared_ptr<ProfileStage> profile;
    std::shared_ptr<Convolver> ir;
    std::shared_ptr<Oversampler> chainOS;

    // waiting to be picked up
    std::mutex lock;
    std::array<std::optional<std::shared_ptr<CircuitStage>>, maxPedals> pendingPedals {};
    std::array<int, maxPedals> pendingOrder {};
    std::optional<int> pendingOrderCount;
    std::optional<std::shared_ptr<CircuitStage>> pendingAmp;
    std::optional<std::shared_ptr<ProfileStage>> pendingProfile;
    std::optional<std::shared_ptr<Convolver>> pendingIR;
    std::optional<std::shared_ptr<Oversampler>> pendingOS;
    /// Objects the audio thread has let go of; freed on the message thread at the next install, never on audio.
    std::vector<std::shared_ptr<void>> retired, trash;

    CabinetSim cab;
    Biquad presenceFilter;
    float presenceDB = 0;
    DCBlocker dcPedal;
    float gateEnv = 0, gateGain = 1;
    bool gateOpen = false;
    int gateHold = 0;
    float gateEnvDecay = 0, gateAttack = 0, gateRelease = 0;
    int gateHoldSamples = 0;
    DelayLine dryDelay, bypassDelay;
    std::vector<float> dry, scratch;
    std::array<double, 16> chainBuf {};
    std::array<CircuitStage*, maxPedals> active {};
    std::array<int, maxPedals> activeSlots {};
    int activeCount = 0;

    void setGateTiming();
    template <typename F> void swapIn (F&& body);
    void prepareOversampler (const std::shared_ptr<CircuitStage>&);
    int latencyFor (int circuits, CircuitStage* a, ProfileStage* pr) const;
    int boardLatency() const;
    void processChunk (const float* input, float* out, int n);
    void runChain (float* x, int n, CircuitStage* a, Oversampler* os);
    double tickChain (double v, CircuitStage* a);
};
} // namespace lutherie
