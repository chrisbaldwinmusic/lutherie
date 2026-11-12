#include "CircuitJSON.h"

namespace lutherie
{
static GridPoint pointFrom (const juce::var& v) { return { (int) v["x"], (int) v["y"] }; }
static juce::var pointTo (GridPoint p)
{
    auto* o = new juce::DynamicObject();
    o->setProperty ("x", p.x);
    o->setProperty ("y", p.y);
    return juce::var (o);
}

Circuit circuitFromVar (const juce::var& v)
{
    Circuit c;
    c.name = v["name"].toString().toStdString();
    c.notes = v["notes"].toString().toStdString();
    if (auto* parts = v["parts"].getArray())
        for (auto& pv : *parts)
        {
            auto kind = partKindFromString (pv["kind"].toString().toStdString());
            if (! kind) continue;
            Part p;
            p.id = pv["id"].toString().toStdString();
            if (p.id.empty()) p.id = newPartID();
            p.kind = *kind;
            p.name = pv["name"].toString().toStdString();
            p.position = pointFrom (pv["position"]);
            p.rotation = ((int) pv["rotation"] % 4 + 4) % 4;
            p.flipped = (bool) pv["flipped"];
            p.model = pv["model"].toString().toStdString();
            p.text = pv["text"].toString().toStdString();
            if (auto* obj = pv["props"].getDynamicObject())
                for (auto& prop : obj->getProperties()) p.props[prop.name.toString().toStdString()] = (double) prop.value;
            c.parts.push_back (std::move (p));
        }
    if (auto* wires = v["wires"].getArray())
        for (auto& wv : *wires)
        {
            Wire w (pointFrom (wv["a"]), pointFrom (wv["b"]));
            if (wv["id"].isString()) w.id = wv["id"].toString().toStdString();
            c.wires.push_back (w);
        }
    return c;
}

juce::var circuitToVar (const Circuit& c)
{
    auto* o = new juce::DynamicObject();
    o->setProperty ("name", juce::String (c.name));
    o->setProperty ("notes", juce::String (c.notes));
    juce::Array<juce::var> parts, wires;
    for (auto& p : c.parts)
    {
        auto* po = new juce::DynamicObject();
        po->setProperty ("id", juce::String (p.id));
        po->setProperty ("kind", juce::String (toString (p.kind)));
        po->setProperty ("name", juce::String (p.name));
        po->setProperty ("position", pointTo (p.position));
        po->setProperty ("rotation", p.rotation);
        po->setProperty ("flipped", p.flipped);
        po->setProperty ("model", juce::String (p.model));
        po->setProperty ("text", juce::String (p.text));
        auto* props = new juce::DynamicObject();
        for (auto& [k, val] : p.props) props->setProperty (juce::Identifier (juce::String (k)), val);
        po->setProperty ("props", juce::var (props));
        parts.add (juce::var (po));
    }
    for (auto& w : c.wires)
    {
        auto* wo = new juce::DynamicObject();
        wo->setProperty ("id", juce::String (w.id));
        wo->setProperty ("a", pointTo (w.a));
        wo->setProperty ("b", pointTo (w.b));
        wires.add (juce::var (wo));
    }
    o->setProperty ("parts", parts);
    o->setProperty ("wires", wires);
    return juce::var (o);
}

std::vector<Circuit> circuitsFromJSON (const juce::String& text)
{
    std::vector<Circuit> out;
    auto v = juce::JSON::parse (text);
    if (auto* arr = v.getArray()) for (auto& c : *arr) out.push_back (circuitFromVar (c));
    else if (v.isObject()) out.push_back (circuitFromVar (v));
    return out;
}

juce::String circuitsToJSON (const std::vector<Circuit>& cs)
{
    juce::Array<juce::var> arr;
    for (auto& c : cs) arr.add (circuitToVar (c));
    return juce::JSON::toString (juce::var (arr));
}
} // namespace lutherie
