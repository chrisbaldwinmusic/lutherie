#pragma once

// Circuits to and from the JSON that the Swift version writes (its Codable form), so presets and sessions are shared.

#include "Circuit.h"

#include <juce_core/juce_core.h>

namespace lutherie
{
Circuit circuitFromVar (const juce::var&);
juce::var circuitToVar (const Circuit&);
std::vector<Circuit> circuitsFromJSON (const juce::String&);
juce::String circuitsToJSON (const std::vector<Circuit>&);
} // namespace lutherie
