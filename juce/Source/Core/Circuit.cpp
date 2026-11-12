#include "Circuit.h"
#include "Devices.h"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <functional>
#include <random>
#include <set>

namespace lutherie
{
using K = PartKind;

const std::vector<PartKind>& allPartKinds()
{
    static const std::vector<PartKind> all {
        K::resistor, K::capacitor, K::inductor, K::pot, K::diode, K::led, K::zener,
        K::npn, K::pnp, K::njfet, K::pjfet, K::nmos, K::pmos, K::opamp, K::triode, K::pentode, K::transformer,
        K::ota, K::vactrol, K::bbd, K::lfo, K::spst, K::spdt, K::ground, K::supply, K::input, K::output, K::label
    };
    return all;
}

std::string toString (PartKind k)
{
    switch (k)
    {
        case K::resistor: return "resistor";   case K::capacitor: return "capacitor"; case K::inductor: return "inductor";
        case K::pot: return "pot";             case K::diode: return "diode";         case K::led: return "led";
        case K::zener: return "zener";         case K::npn: return "npn";             case K::pnp: return "pnp";
        case K::njfet: return "njfet";         case K::pjfet: return "pjfet";         case K::nmos: return "nmos";
        case K::pmos: return "pmos";           case K::opamp: return "opamp";         case K::triode: return "triode";
        case K::pentode: return "pentode";     case K::transformer: return "transformer";
        case K::ota: return "ota";             case K::vactrol: return "vactrol";     case K::bbd: return "bbd";
        case K::lfo: return "lfo";             case K::spst: return "spst";           case K::spdt: return "spdt";
        case K::ground: return "ground";       case K::supply: return "supply";       case K::input: return "input";
        case K::output: return "output";       case K::label: return "label";
    }
    return "resistor";
}

std::optional<PartKind> partKindFromString (const std::string& s)
{
    for (auto k : allPartKinds()) if (toString (k) == s) return k;
    return std::nullopt;
}

std::string displayName (PartKind k)
{
    switch (k)
    {
        case K::resistor: return "Resistor";            case K::capacitor: return "Capacitor";
        case K::inductor: return "Inductor";            case K::pot: return "Potentiometer";
        case K::diode: return "Diode";                  case K::led: return "LED";
        case K::zener: return "Zener diode";            case K::pjfet: return "P-JFET";
        case K::npn: return "NPN transistor";           case K::pnp: return "PNP transistor";
        case K::njfet: return "N-JFET";                 case K::nmos: return "N-MOSFET";
        case K::pmos: return "P-MOSFET";                case K::spst: return "Switch";
        case K::spdt: return "Selector switch";         case K::opamp: return "Op-amp";
        case K::triode: return "Triode (tube)";         case K::pentode: return "Power tube";
        case K::transformer: return "Output transformer";
        case K::ota: return "OTA";                      case K::vactrol: return "Vactrol (LED + LDR)";
        case K::bbd: return "Bucket-brigade delay";     case K::lfo: return "LFO";
        case K::ground: return "Ground";                case K::supply: return "Supply";
        case K::input: return "Guitar in";              case K::output: return "Output";
        case K::label: return "Net label";
    }
    return {};
}

std::string prefix (PartKind k)
{
    switch (k)
    {
        case K::resistor: return "R";   case K::capacitor: return "C";  case K::inductor: return "L";
        case K::pot: return "VR";       case K::diode: case K::led: case K::zener: return "D";
        case K::npn: case K::pnp: return "Q";
        case K::njfet: case K::pjfet: return "J";
        case K::nmos: case K::pmos: return "M";
        case K::spst: case K::spdt: return "SW";
        case K::opamp: return "U";      case K::triode: case K::pentode: return "V";
        case K::transformer: return "T";
        case K::ota: return "U";        case K::vactrol: return "OC";   case K::bbd: return "IC";   case K::lfo: return "LFO";
        case K::ground: return "GND";   case K::supply: return "VCC";   case K::input: return "IN";
        case K::output: return "OUT";   case K::label: return "NET";
    }
    return "X";
}

std::vector<GridPoint> localPins (PartKind k)
{
    switch (k)
    {
        case K::resistor: case K::capacitor: case K::inductor: case K::diode: case K::led: case K::zener: case K::spst:
            return { { -2, 0 }, { 2, 0 } };
        case K::spdt:   return { { -2, 0 }, { 2, -1 }, { 2, 1 } };
        case K::pot:    return { { -2, 0 }, { 2, 0 }, { 0, -2 } };
        case K::npn: case K::pnp: case K::njfet: case K::pjfet: case K::nmos: case K::pmos: case K::triode:
            return { { 1, -2 }, { -2, 0 }, { 1, 2 } };
        case K::opamp:  return { { -2, 1 }, { -2, -1 }, { 2, 0 } };
        case K::pentode: return { { 1, -2 }, { -2, 0 }, { 1, 2 }, { 3, 0 } };
        case K::transformer: return { { -2, -2 }, { -2, 0 }, { -2, 2 }, { 2, -2 }, { 2, 2 } };
        case K::ota:    return { { -2, 1 }, { -2, -1 }, { 2, 0 }, { 0, 2 } };
        case K::vactrol: return { { -2, -1 }, { -2, 1 }, { 2, -1 }, { 2, 1 } };
        case K::bbd:    return { { -2, 0 }, { 2, 0 }, { 0, 2 } };
        case K::lfo:    return { { -2, 0 }, { 2, 0 } };
        case K::ground: case K::supply: case K::input: case K::output: case K::label:
            return { { 0, 0 } };
    }
    return {};
}

std::vector<std::string> pinNames (PartKind k)
{
    switch (k)
    {
        case K::resistor: case K::capacitor: case K::inductor: return { "1", "2" };
        case K::diode: case K::led: case K::zener: return { "Anode", "Cathode" };
        case K::pot: return { "End 1", "End 3", "Wiper" };
        case K::npn: case K::pnp: return { "Collector", "Base", "Emitter" };
        case K::njfet: case K::pjfet: case K::nmos: case K::pmos: return { "Drain", "Gate", "Source" };
        case K::spst: return { "1", "2" };
        case K::spdt: return { "Common", "A", "B" };
        case K::triode: return { "Plate", "Grid", "Cathode" };
        case K::pentode: return { "Plate", "Grid", "Cathode", "Screen" };
        case K::transformer: return { "Primary 1", "Centre tap", "Primary 2", "Secondary 1", "Secondary 2" };
        case K::opamp: return { "+ In", "\xe2\x88\x92 In", "Out" };
        case K::ota: return { "+ In", "\xe2\x88\x92 In", "Out", "Bias (Iabc)" };
        case K::vactrol: return { "LED anode", "LED cathode", "Cell 1", "Cell 2" };
        case K::bbd: return { "In", "Out", "Clock CV" };
        case K::lfo: return { "Rate CV", "Out" };
        default: return { "Pin" };
    }
}

std::map<std::string, double> defaultProps (PartKind k)
{
    switch (k)
    {
        case K::resistor: return { { "r", 10'000 } };
        case K::capacitor: return { { "c", 100e-9 } };
        case K::inductor: return { { "l", 0.5 }, { "rs", 50 } };
        case K::pot: return { { "r", 100'000 }, { "position", 0.5 } };
        case K::supply: return { { "v", 9 }, { "rs", 0.01 } };
        case K::transformer: return { { "zpp", 6600 }, { "zs", 8 }, { "lp", 40 }, { "k", 0.9985 }, { "rp", 150 }, { "rsec", 0.5 } };
        case K::spst: return { { "state", 1 } };
        case K::spdt: return { { "state", 0 } };
        case K::input: return { { "rs", 1'000 }, { "scale", 1 } };
        case K::output: return { { "rl", 1'000'000 }, { "scale", 1 } };
        case K::bbd: return { { "fmin", 10'000 }, { "fmax", 100'000 }, { "vref", 9 } };
        case K::lfo: return { { "fmin", 0.1 }, { "fmax", 10 }, { "vref", 9 }, { "mid", 4.5 }, { "amp", 2 }, { "wave", 0 } };
        default: return {};
    }
}

std::string defaultModel (PartKind k)
{
    switch (k)
    {
        case K::diode: return "1N4148";         case K::led: return "Red LED";
        case K::zener: return "5.1 V (1N4733A)"; case K::pjfet: return "2N5460";
        case K::npn: return "2N3904";           case K::pnp: return "2N3906";
        case K::njfet: return "J201";           case K::nmos: return "2N7000";
        case K::pmos: return "BS250";           case K::opamp: return "TL072";
        case K::triode: return "12AX7";         case K::pentode: return "6L6GC";
        case K::pot: return "B";                case K::ota: return "LM13700";
        case K::vactrol: return "VTL5C3";       case K::bbd: return "MN3207 (1024 stages)";
        default: return {};
    }
}

std::vector<std::string> models (PartKind k)
{
    using namespace DeviceLibrary;
    std::vector<std::string> out;
    auto keys = [&out] (const auto& m, auto keep) { for (auto& [n, v] : m) if (keep (v)) out.push_back (n); };
    auto all = [] (const auto&) { return true; };
    switch (k)
    {
        case K::diode: keys (diodes(), all); break;
        case K::led: keys (leds(), all); break;
        case K::zener:
            keys (zeners(), all);
            std::sort (out.begin(), out.end(), [] (auto& a, auto& b) { return zeners().at (a).bv < zeners().at (b).bv; });
            break;
        case K::npn: keys (bjts(), [] (const BJTModel& m) { return ! m.pnp; }); break;
        case K::pnp: keys (bjts(), [] (const BJTModel& m) { return m.pnp; }); break;
        case K::njfet: keys (jfets(), [] (const JFETModel& m) { return ! m.pch; }); break;
        case K::pjfet: keys (jfets(), [] (const JFETModel& m) { return m.pch; }); break;
        case K::nmos: keys (mosfets(), [] (const MOSFETModel& m) { return ! m.pmos; }); break;
        case K::pmos: keys (mosfets(), [] (const MOSFETModel& m) { return m.pmos; }); break;
        case K::opamp: keys (opamps(), all); break;
        case K::triode: keys (triodes(), all); break;
        case K::pentode: keys (pentodes(), all); break;
        case K::ota: keys (otas(), all); break;
        case K::vactrol: keys (vactrols(), all); break;
        case K::bbd:
            keys (bbds(), all);
            std::sort (out.begin(), out.end(), [] (auto& a, auto& b) { return bbds().at (a).stages < bbds().at (b).stages; });
            break;
        case K::pot: out = { "A", "B", "C" }; break;
        default: break;
    }
    return out;
}

PartID newPartID()
{
    static std::mt19937_64 rng { std::random_device {}() };
    const uint64_t a = rng(), b = rng();
    char buf[40];
    std::snprintf (buf, sizeof (buf), "%08X-%04X-4%03X-%04X-%012llX",
                   (unsigned) (a >> 32), (unsigned) ((a >> 16) & 0xffff), (unsigned) (a & 0xfff),
                   (unsigned) (0x8000 | ((b >> 48) & 0x3fff)), (unsigned long long) (b & 0xffffffffffffULL));
    return buf;
}

// MARK: Part

Part::Part (PartKind k, std::string n, GridPoint at, int rot, bool flip, const std::map<std::string, double>& p,
            std::optional<std::string> m, std::string t)
    : id (newPartID()), kind (k), name (std::move (n)), position (at), rotation (((rot % 4) + 4) % 4), flipped (flip),
      props (defaultProps (k)), model (m ? *m : defaultModel (k)), text (std::move (t))
{
    for (auto& [key, v] : p) props[key] = v;
}

GridPoint Part::transform (GridPoint p) const
{
    GridPoint q = p;
    if (flipped) q = { -q.x, q.y };
    switch (rotation)
    {
        case 1: q = { -q.y, q.x }; break;
        case 2: q = { -q.x, -q.y }; break;
        case 3: q = { q.y, -q.x }; break;
        default: break;
    }
    return q;
}

std::vector<GridPoint> Part::pins() const
{
    std::vector<GridPoint> out;
    for (auto p : localPins (kind)) out.push_back (position + transform (p));
    return out;
}

double Part::get (const std::string& key) const
{
    if (auto it = props.find (key); it != props.end()) return it->second;
    auto d = defaultProps (kind);
    if (auto it = d.find (key); it != d.end()) return it->second;
    return 0;
}

int Part::gang() const          { return kind == K::pot ? (int) std::lround (get ("gang")) : 0; }
int Part::switchState() const   { return (int) std::lround (get ("state")); }
std::string Part::switchStateName() const
{
    if (kind == K::spst) return switchState() == 0 ? "off" : "on";
    static const char* names[] = { "A", "B", "off" };
    return names[std::clamp (switchState(), 0, 2)];
}

// MARK: Wire

Wire::Wire (GridPoint a_, GridPoint b_) : id (newPartID()), a (a_), b (b_) {}

bool Wire::passesThrough (GridPoint p) const
{
    if (p == a || p == b) return false;
    if (a.x == b.x && p.x == a.x) return p.y > std::min (a.y, b.y) && p.y < std::max (a.y, b.y);
    if (a.y == b.y && p.y == a.y) return p.x > std::min (a.x, b.x) && p.x < std::max (a.x, b.x);
    return false;
}

// MARK: Circuit

bool naturalLess (const std::string& a, const std::string& b)
{
    size_t i = 0, j = 0;
    while (i < a.size() && j < b.size())
    {
        if (std::isdigit ((unsigned char) a[i]) && std::isdigit ((unsigned char) b[j]))
        {
            size_t i2 = i, j2 = j;
            while (i2 < a.size() && std::isdigit ((unsigned char) a[i2])) ++i2;
            while (j2 < b.size() && std::isdigit ((unsigned char) b[j2])) ++j2;
            const auto na = std::stoull (a.substr (i, i2 - i)), nb = std::stoull (b.substr (j, j2 - j));
            if (na != nb) return na < nb;
            i = i2; j = j2;
            continue;
        }
        const int ca = std::tolower ((unsigned char) a[i]), cb = std::tolower ((unsigned char) b[j]);
        if (ca != cb) return ca < cb;
        ++i; ++j;
    }
    return a.size() - i < b.size() - j;
}

std::vector<Part> Circuit::pots() const
{
    std::vector<Part> out;
    for (auto& p : parts) if (p.kind == K::pot) out.push_back (p);
    std::stable_sort (out.begin(), out.end(), [] (const Part& x, const Part& y) { return naturalLess (x.name, y.name); });
    return out;
}

bool Circuit::hasPowerStage() const
{
    return std::any_of (parts.begin(), parts.end(), [] (const Part& p) { return p.kind == K::pentode || p.kind == K::transformer; });
}

std::vector<Part> Circuit::knobs() const
{
    std::set<int> seen;
    std::vector<Part> out;
    for (auto& p : pots()) if (p.gang() == 0 || seen.insert (p.gang()).second) out.push_back (p);
    return out;
}

std::optional<int> Circuit::knobIndex (const Part& p) const
{
    auto k = knobs();
    for (size_t i = 0; i < k.size(); ++i)
        if (k[i].id == p.id || (p.gang() != 0 && k[i].gang() == p.gang())) return (int) i;
    return std::nullopt;
}

std::vector<int> Circuit::partIndices (int knob) const
{
    auto k = knobs();
    if (knob < 0 || knob >= (int) k.size()) return {};
    const Part& lead = k[(size_t) knob];
    std::vector<int> out;
    for (size_t i = 0; i < parts.size(); ++i) if (parts[i].id == lead.id) out.push_back ((int) i);
    for (size_t i = 0; i < parts.size(); ++i)
        if (parts[i].kind == K::pot && parts[i].id != lead.id && lead.gang() != 0 && parts[i].gang() == lead.gang())
            out.push_back ((int) i);
    return out;
}

std::string Circuit::nextName (PartKind k) const
{
    std::set<std::string> used;
    for (auto& p : parts) used.insert (p.name);
    for (int i = 1;; ++i)
        if (! used.count (prefix (k) + std::to_string (i))) return prefix (k) + std::to_string (i);
}

void Circuit::addWire (GridPoint a, GridPoint b)
{
    if (a == b) return;
    for (auto end : { a, b })
    {
        auto it = std::find_if (wires.begin(), wires.end(), [end] (const Wire& w) { return w.passesThrough (end); });
        if (it != wires.end())
        {
            Wire w = *it;
            wires.erase (it);
            wires.emplace_back (w.a, end);
            wires.emplace_back (end, w.b);
        }
    }
    wires.emplace_back (a, b);
}

void Circuit::connect (GridPoint a, GridPoint b, bool verticalFirst)
{
    if (a.x == b.x || a.y == b.y) { addWire (a, b); return; }
    const GridPoint corner = verticalFirst ? GridPoint (a.x, b.y) : GridPoint (b.x, a.y);
    addWire (a, corner);
    addWire (corner, b);
}

const Part* Circuit::find (const std::string& n) const
{
    for (auto& p : parts) if (p.name == n) return &p;
    return nullptr;
}

// MARK: Netlist

static std::string trimLower (std::string s)
{
    auto ws = [] (unsigned char c) { return std::isspace (c); };
    while (! s.empty() && ws (s.back())) s.pop_back();
    size_t i = 0;
    while (i < s.size() && ws (s[i])) ++i;
    s = s.substr (i);
    for (auto& c : s) c = (char) std::tolower ((unsigned char) c);
    return s;
}

static std::string fmtG (const char* f, double v)
{
    char buf[64];
    std::snprintf (buf, sizeof (buf), f, v);
    return buf;
}

Netlist Netlist::build (const Circuit& c)
{
    std::map<GridPoint, GridPoint> parent;
    std::function<GridPoint (GridPoint)> find = [&] (GridPoint p)
    {
        GridPoint r = p;
        for (auto it = parent.find (r); it != parent.end() && it->second != r; it = parent.find (r)) r = it->second;
        GridPoint cur = p;
        for (auto it = parent.find (cur); it != parent.end() && it->second != r; it = parent.find (cur))
        {
            GridPoint next = it->second;
            it->second = r;
            cur = next;
        }
        return r;
    };
    auto touch = [&] (GridPoint p) { if (! parent.count (p)) parent[p] = p; };
    auto unite = [&] (GridPoint a, GridPoint b)
    {
        touch (a); touch (b);
        auto ra = find (a), rb = find (b);
        if (ra != rb) parent[ra] = rb;
    };
    for (auto& w : c.wires) unite (w.a, w.b);
    for (auto& p : c.parts) for (auto pin : p.pins()) touch (pin);
    for (auto& w : c.wires)
        for (auto end : { w.a, w.b })
            for (auto& other : c.wires) if (other.passesThrough (end)) unite (end, other.a);
    for (auto& p : c.parts)
        for (auto pin : p.pins())
            for (auto& w : c.wires) if (w.passesThrough (pin)) unite (pin, w.a);
    std::map<std::string, GridPoint> labelAnchor;
    for (auto& p : c.parts)
    {
        if (p.kind != K::label && p.kind != K::supply) continue;
        const std::string key = p.kind == K::label ? "L:" + trimLower (p.text) : "S:" + fmtG ("%.6g", p.get ("v"));
        if (auto it = labelAnchor.find (key); it != labelAnchor.end()) unite (it->second, p.pin (0));
        else labelAnchor[key] = p.pin (0);
    }
    std::set<GridPoint> groundRoots;
    for (auto& p : c.parts) if (p.kind == K::ground) groundRoots.insert (find (p.pin (0)));

    Netlist net;
    std::map<GridPoint, int> nodeOf;
    int count = 1;
    net.nodeNames[0] = "0";
    auto node = [&] (GridPoint p)
    {
        auto r = find (p);
        if (groundRoots.count (r)) return 0;
        if (auto it = nodeOf.find (r); it != nodeOf.end()) return it->second;
        nodeOf[r] = count++;
        return count - 1;
    };
    for (auto& p : c.parts)
    {
        std::vector<int> nodes;
        for (auto pin : p.pins()) nodes.push_back (node (pin));
        net.pinNodes[p.id] = nodes;
    }
    for (auto& p : c.parts)
    {
        auto& nodes = net.pinNodes[p.id];
        if (nodes.empty() || nodes[0] == 0) continue;
        const int n = nodes[0];
        switch (p.kind)
        {
            case K::label: if (! p.text.empty()) net.nodeNames[n] = p.text; break;
            case K::supply:
                if (! net.nodeNames.count (n))
                {
                    auto s = fmtG ("VCC_%gV", p.get ("v"));
                    std::replace (s.begin(), s.end(), '.', 'p');
                    net.nodeNames[n] = s;
                }
                break;
            case K::input: if (! net.nodeNames.count (n)) net.nodeNames[n] = "IN"; break;
            case K::output: if (! net.nodeNames.count (n)) net.nodeNames[n] = "OUT"; break;
            default: break;
        }
    }
    auto has = [&] (PartKind k) { return std::any_of (c.parts.begin(), c.parts.end(), [k] (const Part& p) { return p.kind == k; }); };
    if (! has (K::input)) net.problems.push_back ("Add a Guitar in.");
    if (! has (K::output)) net.problems.push_back ("Add an Output.");
    if (! has (K::ground)) net.problems.push_back ("Add a Ground.");
    std::map<int, int> pinsPerNode;
    for (auto& p : c.parts) for (int n : net.pinNodes[p.id]) pinsPerNode[n]++;
    std::vector<std::string> dangling;
    for (auto& p : c.parts)
    {
        if (p.kind == K::label || p.kind == K::ground || p.kind == K::supply) continue;
        for (int n : net.pinNodes[p.id])
            if (n != 0 && pinsPerNode[n] < 2) { dangling.push_back (p.name); break; }
    }
    if (! dangling.empty())
    {
        std::string s = "Not connected: ";
        for (size_t i = 0; i < std::min<size_t> (6, dangling.size()); ++i) s += (i ? ", " : "") + dangling[i];
        if (dangling.size() > 6) s += "\xe2\x80\xa6";
        net.problems.push_back (s);
    }
    net.nodeCount = count;
    return net;
}

std::string Netlist::nameOf (int node) const
{
    if (auto it = nodeNames.find (node); it != nodeNames.end()) return it->second;
    return "N" + std::to_string (node);
}

// MARK: Engineering notation

namespace Eng
{
std::string format (double v, const std::string& unit)
{
    if (v == 0) return "0" + unit;
    static const std::pair<const char*, double> prefixes[] = {
        { "T", 1e12 }, { "G", 1e9 }, { "M", 1e6 }, { "k", 1e3 }, { "", 1 },
        { "m", 1e-3 }, { "\xc2\xb5", 1e-6 }, { "n", 1e-9 }, { "p", 1e-12 }
    };
    const double a = std::abs (v);
    for (auto& [p, m] : prefixes)
    {
        if (a < m * 0.9999) continue;
        std::string t = fmtG (v / m >= 100 ? "%.0f" : "%.3g", v / m);
        if (t.find ('.') != std::string::npos)
        {
            while (! t.empty() && t.back() == '0') t.pop_back();
            if (! t.empty() && t.back() == '.') t.pop_back();
        }
        return t + p + unit;
    }
    return fmtG ("%.3g", v) + unit;
}

std::optional<double> parse (const std::string& text)
{
    std::string s = text;
    auto trim = [] (std::string& x)
    {
        while (! x.empty() && std::isspace ((unsigned char) x.back())) x.pop_back();
        size_t i = 0;
        while (i < x.size() && std::isspace ((unsigned char) x[i])) ++i;
        x = x.substr (i);
    };
    trim (s);
    for (const char* unit : { "\xce\xa9", "ohm", "Ohm", "F", "H", "V", "Hz" })
    {
        const std::string u = unit;
        if (s.size() > u.size() && s.compare (s.size() - u.size(), u.size(), u) == 0) { s = s.substr (0, s.size() - u.size()); trim (s); }
    }
    auto number = [] (const std::string& x) -> std::optional<double>
    {
        if (x.empty()) return std::nullopt;
        char* end = nullptr;
        const double v = std::strtod (x.c_str(), &end);
        if (end != x.c_str() + x.size()) return std::nullopt;
        return v;
    };
    if (auto v = number (s)) return v;
    static const std::map<std::string, double> mult {
        { "T", 1e12 }, { "G", 1e9 }, { "M", 1e6 }, { "k", 1e3 }, { "K", 1e3 }, { "R", 1 }, { "m", 1e-3 },
        { "u", 1e-6 }, { "\xc2\xb5", 1e-6 }, { "n", 1e-9 }, { "p", 1e-12 }
    };
    for (auto& [sym, m] : mult)
    {
        auto at = s.find (sym);
        if (at == std::string::npos) continue;
        const std::string head = s.substr (0, at), tail = s.substr (at + sym.size());
        auto h = number (head);
        if (! h) continue;
        if (tail.empty()) return *h * m;
        if (tail.find ('.') == std::string::npos)
            if (auto t = number ("0." + tail)) return (*h + *t) * m;
    }
    return std::nullopt;
}
} // namespace Eng
} // namespace lutherie
