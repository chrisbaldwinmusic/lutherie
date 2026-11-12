#pragma once

// Everything saved with a session or plugin state, in the same JSON as the Swift app's PedalDocument (version 2),
// so sessions move between the two.

#include "Core/Cabinets.h"
#include "Core/Circuit.h"
#include "Core/Rig.h"

#include <juce_core/juce_core.h>

#include <map>
#include <optional>

namespace lutherie
{
struct BoardPedal
{
    std::string id = newPartID();
    int slot = 0;
    Circuit circuit;
};

struct Session
{
    int version = 2;
    std::vector<BoardPedal> pedals;       // in signal order
    Circuit amp;
    std::map<int, float> params;
    int quality = 4;
    std::optional<std::string> irName;
    std::optional<std::vector<float>> irSamples;
    std::optional<CabinetChoice> cabinet;

    juce::String toJSON() const;
    static std::optional<Session> fromJSON (const juce::String&);
};

/// The starter circuits shipped with the plugin.
namespace Library
{
    const std::vector<Circuit>& pedals();
    const std::vector<Circuit>& amps();
    std::optional<Circuit> pedal (const std::string& name);
    std::optional<Circuit> amp (const std::string& name);
}
} // namespace lutherie
