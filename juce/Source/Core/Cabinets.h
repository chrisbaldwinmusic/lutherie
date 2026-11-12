#pragma once

// Speaker cabinets built into the app, computed as impulse responses from a model of the speaker, the box, the
// neighbouring speakers and the microphone (port of PedalCore/CabinetLibrary.swift). Designed voicings of the
// familiar cabinet types, not measurements of particular cabinets.

#include "DSP.h"

#include <optional>
#include <string>
#include <vector>

namespace lutherie
{
struct CabinetChoice
{
    std::string cabinet, mic = "Dynamic", position = "Cap edge";
    std::string title() const { return cabinet + " \xc2\xb7 " + mic + " \xc2\xb7 " + position; }
};

namespace CabinetLibrary
{
    std::vector<std::string> cabinets();
    const std::vector<std::string>& mics();
    const std::vector<std::string>& positions();
    std::string notes (const std::string& cabinet);
    bool contains (const CabinetChoice&);
    std::optional<std::vector<float>> impulse (const CabinetChoice&, double sampleRate);
}
} // namespace lutherie
