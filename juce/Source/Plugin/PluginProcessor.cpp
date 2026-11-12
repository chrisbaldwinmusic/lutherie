#include "PluginProcessor.h"
#include "PluginEditor.h"

#include <set>

namespace lutherie
{
namespace
{
juce::String paramID (int id) { return "p" + juce::String (id); }

std::unique_ptr<juce::RangedAudioParameter> makeParam (int id)
{
    const juce::ParameterID pid (paramID (id), 1);
    const auto name = juce::String (RigParam::name (id));
    if (RigParam::isIndexed (id))
    {
        juce::StringArray names;
        for (auto& n : RigParam::valueNames (id)) names.add (n);
        return std::make_unique<juce::AudioParameterChoice> (pid, name, names, (int) RigParam::defaultValue (id));
    }
    const auto unit = juce::String (RigParam::unit (id));
    return std::make_unique<juce::AudioParameterFloat> (
        pid, name, juce::NormalisableRange<float> (RigParam::minValue (id), RigParam::maxValue (id)), RigParam::defaultValue (id),
        juce::AudioParameterFloatAttributes().withLabel (unit).withStringFromValueFunction ([unit] (float v, int) {
            return unit.isEmpty() ? juce::String (v, 2) : juce::String (v, 1) + " " + unit;
        }));
}
} // namespace

LutherieProcessor::LutherieProcessor()
    : juce::AudioProcessor (BusesProperties().withInput ("Input", juce::AudioChannelSet::stereo(), true)
                                             .withOutput ("Output", juce::AudioChannelSet::stereo(), true))
{
    rig = std::make_unique<Rig> (48'000.0);
    for (int id : RigParam::all())
    {
        auto p = makeParam (id);
        params[id] = p.get();
        addParameter (p.release());
    }
    // a board to start from: one overdrive into the two-stage tube preamp
    if (auto c = Library::pedal ("Diode Overdrive")) pedals.push_back ({ newPartID(), 0, *c });
    if (auto a = Library::amp ("Two-Stage Tube Preamp")) amp = *a;
    for (auto& p : pedals) pushKnobs (p.slot, p.circuit);
    pushKnobs (-1, amp);
}

LutherieProcessor::~LutherieProcessor()
{
    builder.removeAllJobs (true, 10'000);
}

bool LutherieProcessor::isBusesLayoutSupported (const BusesLayout& l) const
{
    auto ok = [] (const juce::AudioChannelSet& s) { return s == juce::AudioChannelSet::mono() || s == juce::AudioChannelSet::stereo(); };
    return ok (l.getMainInputChannelSet()) && ok (l.getMainOutputChannelSet());
}

juce::RangedAudioParameter* LutherieProcessor::param (int id) const
{
    auto it = params.find (id);
    return it != params.end() ? it->second : nullptr;
}

float LutherieProcessor::value (int id) const
{
    auto* p = param (id);
    return p ? p->convertFrom0to1 (p->getValue()) : 0.0f;
}

void LutherieProcessor::setValue (int id, float v)
{
    if (auto* p = param (id)) p->setValueNotifyingHost (p->convertTo0to1 (v));
}

void LutherieProcessor::prepareToPlay (double sampleRate, int)
{
    if (sampleRate != preparedRate)
    {
        preparedRate = sampleRate;
        rig->setSampleRate (sampleRate);
        if (cabinet)
            if (auto s = CabinetLibrary::impulse (*cabinet, sampleRate)) { irSamples = s; rig->installImpulse (s); }
        rebuildAll();
    }
    setLatencySamples (rig->expectedLatency());
}

void LutherieProcessor::processBlock (juce::AudioBuffer<float>& buffer, juce::MidiBuffer&)
{
    juce::ScopedNoDenormals noDenormals;
    for (auto& [id, p] : params) rig->set (id, p->convertFrom0to1 (p->getValue()));

    const int n = buffer.getNumSamples();
    const int ins = getTotalNumInputChannels(), outs = getTotalNumOutputChannels();
    if (n == 0 || outs == 0) return;
    float* mono = buffer.getWritePointer (0);
    // a guitar on a stereo track: both sides, averaged
    if (ins >= 2) { const float* r = buffer.getReadPointer (1); for (int i = 0; i < n; ++i) mono[i] = 0.5f * (mono[i] + r[i]); }
    else if (ins == 0) buffer.clear();
    rig->process (mono, mono, n);
    for (int ch = 1; ch < outs; ++ch) buffer.copyFrom (ch, 0, mono, n);
}

// MARK: Board

std::vector<std::string> LutherieProcessor::knobLabels (const Circuit& c) const
{
    std::vector<std::string> out;
    for (auto& k : c.knobs()) out.push_back (k.text.empty() ? k.name : k.text);
    if (out.size() > RigParam::knobsPerCircuit) out.resize (RigParam::knobsPerCircuit);
    return out;
}

void LutherieProcessor::pushKnobs (int slot, const Circuit& c)
{
    auto knobs = c.knobs();
    for (size_t i = 0; i < knobs.size() && i < RigParam::knobsPerCircuit; ++i)
        setValue (slot < 0 ? RigParam::ampKnob ((int) i) : RigParam::pedalKnob (slot, (int) i), (float) knobs[i].get ("position"));
}

void LutherieProcessor::build (int key, const Circuit& c, std::function<void (std::shared_ptr<CircuitStage>)> install)
{
    const int gen = ++generation[key];
    const double sr = preparedRate > 0 ? preparedRate : 48'000;
    const int q = oversampling;
    builder.addJob ([this, key, gen, c, sr, q, install] {
        std::shared_ptr<CircuitStage> stage;
        try { stage = std::make_shared<CircuitStage> (c, sr, q); } catch (const std::exception&) {}
        juce::MessageManager::callAsync ([this, key, gen, stage, install] {
            if (generation[key] != gen) return;   // superseded by a later change
            install (stage);
            updateLatency();
            sendChangeMessage();
        });
    });
}

void LutherieProcessor::rebuildSlot (int slot)
{
    for (auto& p : pedals)
        if (p.slot == slot) { build (slot, p.circuit, [this, slot] (auto s) { rig->installPedal (s, slot); }); return; }
    ++generation[slot];
    rig->installPedal (nullptr, slot);
}

void LutherieProcessor::rebuildAmp() { build (-1, amp, [this] (auto s) { rig->installAmp (s); }); }

void LutherieProcessor::rebuildAll()
{
    for (int s = 0; s < Rig::maxPedals; ++s) rebuildSlot (s);
    rebuildAmp();
    pushOrder();
}

void LutherieProcessor::pushOrder()
{
    std::vector<int> order;
    for (auto& p : pedals) order.push_back (p.slot);
    rig->setOrder (order);
}

void LutherieProcessor::updateLatency() { setLatencySamples (rig->expectedLatency()); }

bool LutherieProcessor::addPedal (const Circuit& c)
{
    for (int s = 0; s < Rig::maxPedals; ++s)
    {
        bool used = false;
        for (auto& p : pedals) used |= p.slot == s;
        if (used) continue;
        pedals.push_back ({ newPartID(), s, c });
        setValue (RigParam::pedalOn (s), 1);
        pushKnobs (s, c);
        rebuildSlot (s);
        pushOrder();
        sendChangeMessage();
        return true;
    }
    return false;
}

void LutherieProcessor::replacePedal (const std::string& id, const Circuit& c)
{
    for (auto& p : pedals)
        if (p.id == id)
        {
            p.circuit = c;
            pushKnobs (p.slot, c);
            rebuildSlot (p.slot);
            sendChangeMessage();
        }
}

void LutherieProcessor::removePedal (const std::string& id)
{
    for (auto it = pedals.begin(); it != pedals.end(); ++it)
        if (it->id == id)
        {
            const int slot = it->slot;
            pedals.erase (it);
            rebuildSlot (slot);
            pushOrder();
            updateLatency();
            sendChangeMessage();
            return;
        }
}

void LutherieProcessor::movePedal (int from, int to)
{
    if (from < 0 || from >= (int) pedals.size() || to < 0 || to >= (int) pedals.size() || from == to) return;
    auto p = pedals[(size_t) from];
    pedals.erase (pedals.begin() + from);
    pedals.insert (pedals.begin() + to, p);
    pushOrder();
    sendChangeMessage();
}

void LutherieProcessor::setAmp (const Circuit& c)
{
    amp = c;
    pushKnobs (-1, c);
    rebuildAmp();
    sendChangeMessage();
}

void LutherieProcessor::setQuality (int q)
{
    q = juce::jlimit (1, 8, q);
    if (q == oversampling) return;
    oversampling = q;
    rebuildAll();
    sendChangeMessage();
}

void LutherieProcessor::chooseCabinet (const CabinetChoice& c)
{
    auto s = CabinetLibrary::impulse (c, preparedRate > 0 ? preparedRate : 48'000);
    if (! s) return;
    cabinet = c;
    irSamples = s;
    irName = c.cabinet;
    rig->installImpulse (s);
    sendChangeMessage();
}

// MARK: State

Session LutherieProcessor::session() const
{
    Session s;
    s.pedals = pedals;
    // knob positions live in the host parameters; write them back into the drawings
    for (auto& p : s.pedals)
    {
        auto knobs = p.circuit.knobs();
        for (size_t i = 0; i < knobs.size() && i < RigParam::knobsPerCircuit; ++i)
            for (int idx : p.circuit.partIndices ((int) i)) p.circuit.parts[(size_t) idx].set ("position", value (RigParam::pedalKnob (p.slot, (int) i)));
    }
    s.amp = amp;
    for (size_t i = 0; i < s.amp.knobs().size() && i < RigParam::knobsPerCircuit; ++i)
        for (int idx : s.amp.partIndices ((int) i)) s.amp.parts[(size_t) idx].set ("position", value (RigParam::ampKnob ((int) i)));
    for (int id : RigParam::all()) s.params[id] = value (id);
    s.quality = oversampling;
    s.cabinet = cabinet;
    s.irName = irName;
    s.irSamples = irSamples;
    return s;
}

void LutherieProcessor::apply (const Session& s)
{
    oversampling = juce::jlimit (1, 8, s.quality);
    pedals.clear();
    std::set<int> used;
    for (auto& p : s.pedals) if (p.slot >= 0 && p.slot < Rig::maxPedals && used.insert (p.slot).second) pedals.push_back (p);
    amp = s.amp;
    for (auto& p : pedals) pushKnobs (p.slot, p.circuit);
    pushKnobs (-1, amp);
    // knob positions come from the drawings; everything else from the saved values
    for (auto& [id, v] : s.params)
        if (RigParam::isValid (id) && ! RigParam::pedalKnobOf (id) && ! RigParam::ampKnobOf (id)) setValue (id, v);
    cabinet.reset(); irSamples.reset(); irName.reset();
    if (s.cabinet && CabinetLibrary::contains (*s.cabinet)) chooseCabinet (*s.cabinet);
    else if (s.irSamples) { irSamples = s.irSamples; irName = s.irName; rig->installImpulse (irSamples); }
    else rig->installImpulse (std::nullopt);
    rebuildAll();
    sendChangeMessage();
}

void LutherieProcessor::getStateInformation (juce::MemoryBlock& dest)
{
    const auto json = session().toJSON();
    dest.append (json.toRawUTF8(), json.getNumBytesAsUTF8());
}

void LutherieProcessor::setStateInformation (const void* data, int size)
{
    if (auto s = Session::fromJSON (juce::String::fromUTF8 (static_cast<const char*> (data), size)))
        apply (*s);
}

juce::AudioProcessorEditor* LutherieProcessor::createEditor() { return new LutherieEditor (*this); }
} // namespace lutherie

juce::AudioProcessor* JUCE_CALLTYPE createPluginFilter() { return new lutherie::LutherieProcessor(); }
