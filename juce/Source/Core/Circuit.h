#pragma once

// The circuit model: parts on a grid, wires, and the netlist built from them. Plain C++ (no JUCE), so the
// engine can be tested and reused on its own. A line-for-line port of PedalCore/Circuit.swift.

#include <cstdint>
#include <map>
#include <optional>
#include <string>
#include <vector>

namespace lutherie
{
struct GridPoint
{
    int x = 0, y = 0;
    GridPoint() = default;
    GridPoint (int x_, int y_) : x (x_), y (y_) {}
    GridPoint operator+ (GridPoint o) const { return { x + o.x, y + o.y }; }
    GridPoint operator- (GridPoint o) const { return { x - o.x, y - o.y }; }
    bool operator== (GridPoint o) const { return x == o.x && y == o.y; }
    bool operator!= (GridPoint o) const { return ! (*this == o); }
    bool operator< (GridPoint o) const { return x != o.x ? x < o.x : y < o.y; }
};

enum class PartKind
{
    resistor, capacitor, inductor, pot, diode, led, zener,
    npn, pnp, njfet, pjfet, nmos, pmos, opamp, triode, pentode, transformer,
    ota, vactrol, bbd, lfo,
    spst, spdt,
    ground, supply, input, output, label
};

const std::vector<PartKind>& allPartKinds();
std::string toString (PartKind);
std::optional<PartKind> partKindFromString (const std::string&);
std::string displayName (PartKind);
std::string prefix (PartKind);
std::vector<GridPoint> localPins (PartKind);
std::vector<std::string> pinNames (PartKind);
std::map<std::string, double> defaultProps (PartKind);
std::string defaultModel (PartKind);
std::vector<std::string> models (PartKind);

/// A UUID kept as its text form (as Swift writes it), which is all the engine needs.
using PartID = std::string;
PartID newPartID();

struct Part
{
    PartID id;
    PartKind kind = PartKind::resistor;
    std::string name;
    GridPoint position;
    int rotation = 0;       // quarter turns clockwise
    bool flipped = false;   // mirrored left-right before rotation
    std::map<std::string, double> props;
    std::string model;
    std::string text;       // knob caption for pots, net name for labels

    Part() = default;
    Part (PartKind k, std::string name, GridPoint at, int rotation = 0, bool flipped = false,
          const std::map<std::string, double>& props = {}, std::optional<std::string> model = {}, std::string text = {});

    GridPoint transform (GridPoint p) const;
    std::vector<GridPoint> pins() const;
    GridPoint pin (int i) const { return pins()[(size_t) i]; }
    int gang() const;
    int switchState() const;
    std::string switchStateName() const;
    double get (const std::string& key) const;
    double operator[] (const std::string& key) const { return get (key); }
    void set (const std::string& key, double v) { props[key] = v; }
};

struct Wire
{
    PartID id;
    GridPoint a, b;
    Wire() = default;
    Wire (GridPoint a_, GridPoint b_);
    bool passesThrough (GridPoint p) const;
};

struct Circuit
{
    std::string name;
    std::vector<Part> parts;
    std::vector<Wire> wires;
    std::string notes;

    std::vector<Part> pots() const;
    bool hasPowerStage() const;
    std::vector<Part> knobs() const;
    std::optional<int> knobIndex (const Part& p) const;
    std::vector<int> partIndices (int knob) const;
    std::string nextName (PartKind) const;
    void addWire (GridPoint a, GridPoint b);
    void connect (GridPoint a, GridPoint b, bool verticalFirst = false);
    const Part* find (const std::string& partName) const;
};

/// Natural ordering of names ("VR2" before "VR10"), as Swift's localizedStandardCompare.
bool naturalLess (const std::string& a, const std::string& b);

/// Which node every pin of every part is on. Node 0 is ground.
struct Netlist
{
    int nodeCount = 1;
    std::map<PartID, std::vector<int>> pinNodes;
    std::map<int, std::string> nodeNames;
    std::vector<std::string> problems;

    static Netlist build (const Circuit&);
    std::string nameOf (int node) const;
};

/// Engineering notation: "4.7k", "100n".
namespace Eng
{
    std::string format (double v, const std::string& unit = {});
    std::optional<double> parse (const std::string&);
}
} // namespace lutherie
