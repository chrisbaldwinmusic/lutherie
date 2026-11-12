#pragma once

#include "Session.h"

#include <juce_audio_processors/juce_audio_processors.h>

#include <map>
#include <memory>

namespace lutherie
{
/// The plugin: the rig on the audio thread, and the board (which circuits sit where) on the message thread.
/// Circuits are simulated into engines on a background thread and handed to the rig when ready.
class LutherieProcessor : public juce::AudioProcessor, public juce::ChangeBroadcaster
{
public:
    LutherieProcessor();
    ~LutherieProcessor() override;

    // juce::AudioProcessor
    void prepareToPlay (double sampleRate, int samplesPerBlock) override;
    void releaseResources() override {}
    bool isBusesLayoutSupported (const BusesLayout&) const override;
    void processBlock (juce::AudioBuffer<float>&, juce::MidiBuffer&) override;
    juce::AudioProcessorEditor* createEditor() override;
    bool hasEditor() const override { return true; }
    const juce::String getName() const override { return JucePlugin_Name; }
    bool acceptsMidi() const override { return false; }
    bool producesMidi() const override { return false; }
    double getTailLengthSeconds() const override { return 1.0; }
    int getNumPrograms() override { return 1; }
    int getCurrentProgram() override { return 0; }
    void setCurrentProgram (int) override {}
    const juce::String getProgramName (int) override { return {}; }
    void changeProgramName (int, const juce::String&) override {}
    void getStateInformation (juce::MemoryBlock&) override;
    void setStateInformation (const void*, int) override;

    // parameters, by rig id
    juce::RangedAudioParameter* param (int id) const;
    float value (int id) const;
    void setValue (int id, float v);

    // the board (message thread)
    const std::vector<BoardPedal>& board() const { return pedals; }
    const Circuit& ampCircuit() const { return amp; }
    int quality() const { return oversampling; }
    void setQuality (int q);
    std::optional<CabinetChoice> cabinetChoice() const { return cabinet; }
    void chooseCabinet (const CabinetChoice&);
    /// Puts a circuit in the first free slot at the end of the board; false when the board is full.
    bool addPedal (const Circuit&);
    void replacePedal (const std::string& id, const Circuit&);
    void removePedal (const std::string& id);
    void movePedal (int from, int to);
    void setAmp (const Circuit&);
    /// Labels of the knobs of a pedal slot or the amp (empty slot: none).
    std::vector<std::string> knobLabels (const Circuit&) const;

    Session session() const;
    void apply (const Session&);

    Rig& getRig() { return *rig; }

private:
    std::unique_ptr<Rig> rig;
    std::map<int, juce::RangedAudioParameter*> params;
    std::vector<BoardPedal> pedals;
    Circuit amp;
    int oversampling = 4;
    std::optional<CabinetChoice> cabinet;
    std::optional<std::vector<float>> irSamples;
    std::optional<std::string> irName;
    double preparedRate = 0;
    std::map<int, int> generation;   // per slot (-1 is the amp): builds that finish late are dropped
    juce::ThreadPool builder { 2 };

    void rebuildSlot (int slot);
    void rebuildAmp();
    void rebuildAll();
    void build (int key, const Circuit&, std::function<void (std::shared_ptr<CircuitStage>)> install);
    void pushOrder();
    void pushKnobs (int slot, const Circuit&);
    void updateLatency();

    JUCE_DECLARE_NON_COPYABLE_WITH_LEAK_DETECTOR (LutherieProcessor)
};
} // namespace lutherie
