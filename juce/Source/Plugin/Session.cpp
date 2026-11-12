#include "Session.h"
#include "Core/CircuitJSON.h"

#include <BinaryData.h>

namespace lutherie
{
namespace
{
juce::var floatsToArray (const std::vector<float>& v)
{
    // Swift encodes [Float] as a plain array of numbers
    juce::Array<juce::var> arr;
    arr.ensureStorageAllocated ((int) v.size());
    for (float f : v) arr.add ((double) f);
    return arr;
}
} // namespace

juce::String Session::toJSON() const
{
    auto* o = new juce::DynamicObject();
    o->setProperty ("version", version);
    o->setProperty ("pedal", pedals.empty() ? circuitToVar (Circuit { "Empty pedal", {}, {}, {} }) : circuitToVar (pedals.front().circuit));
    juce::Array<juce::var> board;
    for (auto& p : pedals)
    {
        auto* po = new juce::DynamicObject();
        po->setProperty ("id", juce::String (p.id));
        po->setProperty ("slot", p.slot);
        po->setProperty ("circuit", circuitToVar (p.circuit));
        board.add (juce::var (po));
    }
    o->setProperty ("pedals", board);
    o->setProperty ("amp", circuitToVar (amp));
    // Swift writes a dictionary with integer keys as one flat array: key, value, key, value…
    juce::Array<juce::var> flat;
    for (auto& [k, v] : params) { flat.add (k); flat.add ((double) v); }
    o->setProperty ("params", flat);
    o->setProperty ("quality", quality);
    if (irName) o->setProperty ("irName", juce::String (*irName));
    if (irSamples && ! cabinet) o->setProperty ("irSamples", floatsToArray (*irSamples));
    if (cabinet)
    {
        auto* c = new juce::DynamicObject();
        c->setProperty ("cabinet", juce::String (cabinet->cabinet));
        c->setProperty ("mic", juce::String (cabinet->mic));
        c->setProperty ("position", juce::String (cabinet->position));
        o->setProperty ("cabinet", juce::var (c));
    }
    return juce::JSON::toString (juce::var (o), true);
}

std::optional<Session> Session::fromJSON (const juce::String& text)
{
    auto v = juce::JSON::parse (text);
    if (! v.isObject() || ! v.hasProperty ("amp")) return std::nullopt;
    Session s;
    s.version = (int) v.getProperty ("version", 1);
    if (auto* arr = v["pedals"].getArray())
        for (auto& pv : *arr)
        {
            BoardPedal p;
            if (pv["id"].isString()) p.id = pv["id"].toString().toStdString();
            p.slot = (int) pv["slot"];
            p.circuit = circuitFromVar (pv["circuit"]);
            s.pedals.push_back (p);
        }
    else if (v.hasProperty ("pedal"))
        s.pedals.push_back ({ newPartID(), 0, circuitFromVar (v["pedal"]) });   // a session from before the pedalboard
    s.amp = circuitFromVar (v["amp"]);
    if (auto* flat = v["params"].getArray())
        for (int i = 0; i + 1 < flat->size(); i += 2) s.params[(int) (*flat)[i]] = (float) (double) (*flat)[i + 1];
    else if (auto* obj = v["params"].getDynamicObject())
        for (auto& p : obj->getProperties()) s.params[p.name.toString().getIntValue()] = (float) (double) p.value;
    s.quality = (int) v.getProperty ("quality", 4);
    if (v["irName"].isString()) s.irName = v["irName"].toString().toStdString();
    if (auto* ir = v["irSamples"].getArray())
    {
        std::vector<float> samples;
        for (auto& x : *ir) samples.push_back ((float) (double) x);
        s.irSamples = samples;
    }
    if (v["cabinet"].isObject())
        s.cabinet = CabinetChoice { v["cabinet"]["cabinet"].toString().toStdString(), v["cabinet"]["mic"].toString().toStdString(),
                                    v["cabinet"]["position"].toString().toStdString() };
    return s;
}

namespace Library
{
const std::vector<Circuit>& pedals()
{
    static const std::vector<Circuit> list = circuitsFromJSON (juce::String::fromUTF8 (BinaryData::pedals_json, BinaryData::pedals_jsonSize));
    return list;
}
const std::vector<Circuit>& amps()
{
    static const std::vector<Circuit> list = circuitsFromJSON (juce::String::fromUTF8 (BinaryData::amps_json, BinaryData::amps_jsonSize));
    return list;
}
static std::optional<Circuit> named (const std::vector<Circuit>& list, const std::string& n)
{
    for (auto& c : list) if (c.name == n) return c;
    return std::nullopt;
}
std::optional<Circuit> pedal (const std::string& n) { return named (pedals(), n); }
std::optional<Circuit> amp (const std::string& n) { return named (amps(), n); }
} // namespace Library
} // namespace lutherie
