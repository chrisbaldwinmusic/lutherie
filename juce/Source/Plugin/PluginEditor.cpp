#include "PluginEditor.h"

namespace lutherie
{
/// Text from the engine is UTF-8 (×, ·, µ, Ω); juce::String would otherwise read a plain char* as Latin-1.
static juce::String u8 (const std::string& s) { return juce::String (juce::CharPointer_UTF8 (s.c_str())); }
static juce::String u8 (const char* s) { return juce::String (juce::CharPointer_UTF8 (s)); }

// MARK: Look and feel

LutherieLookAndFeel::LutherieLookAndFeel()
{
    setColour (juce::ResizableWindow::backgroundColourId, Theme::bg());
    setColour (juce::ComboBox::backgroundColourId, Theme::well());
    setColour (juce::ComboBox::textColourId, Theme::text());
    setColour (juce::ComboBox::outlineColourId, Theme::line());
    setColour (juce::ComboBox::arrowColourId, Theme::dim());
    setColour (juce::PopupMenu::backgroundColourId, Theme::panel());
    setColour (juce::PopupMenu::textColourId, Theme::text());
    setColour (juce::PopupMenu::highlightedBackgroundColourId, Theme::red());
    setColour (juce::PopupMenu::headerTextColourId, Theme::gold());
    setColour (juce::TextButton::textColourOffId, Theme::text());
    setColour (juce::TextButton::textColourOnId, Theme::text());
    setColour (juce::Slider::textBoxTextColourId, Theme::text());
    setColour (juce::Slider::textBoxOutlineColourId, juce::Colours::transparentBlack);
    setColour (juce::Label::textColourId, Theme::text());
}

void LutherieLookAndFeel::drawRotarySlider (juce::Graphics& g, int x, int y, int w, int h, float pos, float start, float end, juce::Slider&)
{
    const auto bounds = juce::Rectangle<float> ((float) x, (float) y, (float) w, (float) h).reduced (3);
    const float r = std::min (bounds.getWidth(), bounds.getHeight()) / 2;
    const auto c = bounds.getCentre();
    // tick marks round the skirt
    g.setColour (knobInk.withAlpha (0.45f));
    for (int i = 0; i <= 10; ++i)
    {
        const float a = start + (end - start) * (float) i / 10.0f;
        const auto p1 = c.getPointOnCircumference (r, a), p2 = c.getPointOnCircumference (r * 0.86f, a);
        g.drawLine ({ p1, p2 }, 1.0f);
    }
    // the knob: a shadow, a skirted cap, a highlight
    const float kr = r * 0.78f;
    g.setColour (juce::Colours::black.withAlpha (0.35f));
    g.fillEllipse (c.x - kr, c.y - kr + 2, kr * 2, kr * 2);
    juce::ColourGradient grad (knobCap.brighter (0.35f), c.x, c.y - kr, knobCap.darker (0.4f), c.x, c.y + kr, false);
    g.setGradientFill (grad);
    g.fillEllipse (c.x - kr, c.y - kr, kr * 2, kr * 2);
    g.setColour (juce::Colours::black.withAlpha (0.5f));
    g.drawEllipse (c.x - kr, c.y - kr, kr * 2, kr * 2, 1.0f);
    // pointer
    const float a = start + pos * (end - start);
    g.setColour (knobInk);
    g.drawLine ({ c.getPointOnCircumference (kr * 0.25f, a), c.getPointOnCircumference (kr * 0.92f, a) }, 2.2f);
}

void LutherieLookAndFeel::drawComboBox (juce::Graphics& g, int w, int h, bool, int, int, int, int, juce::ComboBox& box)
{
    const auto r = juce::Rectangle<float> (0, 0, (float) w, (float) h).reduced (0.5f);
    g.setColour (box.findColour (juce::ComboBox::backgroundColourId));
    g.fillRoundedRectangle (r, 4);
    g.setColour (box.findColour (juce::ComboBox::outlineColourId));
    g.drawRoundedRectangle (r, 4, 1);
    juce::Path arrow;
    const float ax = (float) w - 12, ay = (float) h / 2;
    arrow.addTriangle (ax - 4, ay - 2, ax + 4, ay - 2, ax, ay + 3);
    g.setColour (Theme::dim());
    g.fillPath (arrow);
}

void LutherieLookAndFeel::drawButtonBackground (juce::Graphics& g, juce::Button& b, const juce::Colour&, bool over, bool down)
{
    const auto r = b.getLocalBounds().toFloat().reduced (0.5f);
    g.setColour ((b.getToggleState() ? Theme::red() : Theme::panelHi()).brighter (down ? 0.2f : (over ? 0.08f : 0.0f)));
    g.fillRoundedRectangle (r, 4);
    g.setColour (Theme::line());
    g.drawRoundedRectangle (r, 4, 1);
}

// MARK: Knob

Knob::Knob (juce::RangedAudioParameter& p, const juce::String& cap, juce::Colour inkColour)
    : caption (cap), ink (inkColour), attachment (p, slider)
{
    slider.setSliderStyle (juce::Slider::RotaryHorizontalVerticalDrag);
    slider.setTextBoxStyle (juce::Slider::NoTextBox, false, 0, 0);
    slider.setRotaryParameters (juce::degreesToRadians (225.0f), juce::degreesToRadians (495.0f), true);
    slider.setPopupDisplayEnabled (true, true, nullptr);
    slider.setDoubleClickReturnValue (true, p.convertFrom0to1 (p.getDefaultValue()));
    addAndMakeVisible (slider);
}

void Knob::resized() { slider.setBounds (getLocalBounds().withTrimmedBottom (14)); }

void Knob::paint (juce::Graphics& g)
{
    g.setColour (ink);
    g.setFont (juce::FontOptions (10.0f, juce::Font::bold));
    g.drawFittedText (caption.toUpperCase(), getLocalBounds().removeFromBottom (14), juce::Justification::centred, 1, 0.8f);
}

// MARK: Pedal card

PedalCard::Finish PedalCard::finishFor (const std::string& n)
{
    static const std::map<std::string, Finish> table {
        { "JFET Clean Boost", { 0xece4cf, 0xcfc5ab, 0x2a2224, false, 0x3d9cff } },
        { "Single-Transistor Boost", { 0x9fb8a2, 0x7e9a82, 0x1b2420, false, 0xff3b30 } },
        { "MOSFET Boost", { 0xd9d4cb, 0xa9a49a, 0x1c1b1d, false, 0x3d9cff } },
        { "Germanium Treble Booster", { 0xc7cbd0, 0x8e9399, 0x161719, false, 0xff3b30 } },
        { "Diode Overdrive", { 0xc4473f, 0x8f2a27, 0xf3ead6, true, 0xff3b30 } },
        { "Cascaded JFET Overdrive", { 0x2f7470, 0x1e4d4a, 0xf0e8d2, true, 0xff3b30 } },
        { "Selectable-Clip Overdrive", { 0xd8a83c, 0xa87a1f, 0x1d1709, false, 0xff3b30 } },
        { "Hard-Clip Distortion", { 0x2a2a2d, 0x121214, 0xf08a3c, false, 0xff8a1f } },
        { "Slew-Limited Distortion", { 0x47607d, 0x2c3e55, 0xf0e8d2, true, 0xff3b30 } },
        { "Two-Transistor Fuzz", { 0x6c4c8e, 0x43305c, 0xf1e9d6, false, 0xff3b30 } },
        { "Germanium Fuzz", { 0xb4683b, 0x7a3f22, 0xf6eedb, false, 0xff3b30 } },
        { "Four-Stage Sustain Fuzz", { 0x66724a, 0x414b2d, 0xf1ead4, true, 0xff3b30 } },
        { "Bass Blend Overdrive", { 0x2c406a, 0x1a2744, 0xe9dfc6, false, 0x3d9cff } },
        { "Four-Stage Phaser", { 0xe8772e, 0xb5531a, 0x1d140c, false, 0xff3b30 } },
        { "Opto Tremolo", { 0x3f6b5a, 0x274538, 0xf1e8d2, true, 0xffb347 } },
        { "Bucket-Brigade Chorus", { 0x6fa6c9, 0x4a7fa3, 0x0f1a24, false, 0x3d9cff } },
        { "Bucket-Brigade Delay", { 0x4b6b3a, 0x2f4724, 0xf2ead2, true, 0xff3b30 } },
    };
    if (auto it = table.find (n); it != table.end()) return it->second;
    // a circuit of the player's own: a steady colour from its name
    static const Finish palette[] = { { 0x7b2f3b, 0x4f1c26, 0xf1e8d2, true, 0xff3b30 }, { 0x3b5f4a, 0x24402f, 0xf1e8d2, true, 0xff3b30 },
                                      { 0x5a5560, 0x37333b, 0xf1e8d2, true, 0xff3b30 }, { 0xc9b48a, 0x9e8a62, 0x221c14, false, 0xff3b30 },
                                      { 0x2f5873, 0x1c384c, 0xf1e8d2, true, 0xff3b30 } };
    juce::uint32 h = 2166136261u;
    for (unsigned char b : n) h = (h ^ b) * 16777619u;
    return palette[h % 5];
}

PedalCard::PedalCard (LutherieProcessor& p, BoardView& b, const BoardPedal& bp)
    : id (bp.id), slot (bp.slot), proc (p), board (b), name (bp.circuit.name), finish (finishFor (bp.circuit.name)),
      onAttachment (*p.param (RigParam::pedalOn (bp.slot)), footswitch)
{
    const auto labels = proc.knobLabels (bp.circuit);
    for (size_t i = 0; i < labels.size(); ++i)
        addAndMakeVisible (knobs.add (new Knob (*proc.param (RigParam::pedalKnob (slot, (int) i)), u8 (labels[i]), Theme::hex (finish.ink))));
    footswitch.setClickingTogglesState (true);
    footswitch.setTooltip ("On / bypassed");
    addAndMakeVisible (footswitch);
}

void PedalCard::paint (juce::Graphics& g)
{
    auto r = getLocalBounds().toFloat().reduced (2);
    g.setColour (juce::Colours::black.withAlpha (0.45f));
    g.fillRoundedRectangle (r.translated (0, 3), 9);
    g.setGradientFill (juce::ColourGradient (Theme::hex (finish.top), r.getX(), r.getY(), Theme::hex (finish.bottom), r.getX(), r.getBottom(), false));
    g.fillRoundedRectangle (r, 9);
    g.setColour (juce::Colours::white.withAlpha (0.18f));
    g.drawRoundedRectangle (r.reduced (0.5f), 9, 1);
    // corner screws
    for (auto pt : { r.getTopLeft() + juce::Point<float> (9, 9), r.getTopRight() + juce::Point<float> (-9, 9),
                     r.getBottomLeft() + juce::Point<float> (9, -9), r.getBottomRight() + juce::Point<float> (-9, -9) })
    {
        g.setColour (juce::Colours::black.withAlpha (0.35f));
        g.fillEllipse (pt.x - 3, pt.y - 3, 6, 6);
    }
    // LED
    const bool on = proc.value (RigParam::pedalOn (slot)) > 0.5f;
    const auto led = juce::Point<float> (r.getCentreX(), r.getBottom() - 92);
    if (on)
    {
        g.setColour (Theme::hex (finish.led, 0.35f));
        g.fillEllipse (led.x - 9, led.y - 9, 18, 18);
    }
    g.setColour (on ? Theme::hex (finish.led) : juce::Colours::black.withAlpha (0.5f));
    g.fillEllipse (led.x - 4, led.y - 4, 8, 8);
    // name, lettered on the lower panel
    g.setColour (Theme::hex (finish.ink));
    g.setFont (juce::FontOptions (12.5f, juce::Font::bold));
    g.drawFittedText (u8 (name).toUpperCase(), juce::Rectangle<int> (10, getHeight() - 82, getWidth() - 20, 32),
                      juce::Justification::centred, 2, 0.75f);
    if (dragging) { g.setColour (juce::Colours::white.withAlpha (0.12f)); g.fillRoundedRectangle (r, 9); }
}

void PedalCard::resized()
{
    const int n = knobs.size();
    const int cols = n <= 2 ? n : (n <= 4 ? 2 : 3);
    const int rows = cols == 0 ? 0 : (n + cols - 1) / cols;
    const int kw = 44, kh = 58;
    const int top = 18;
    for (int i = 0; i < n; ++i)
    {
        const int row = i / cols, col = i % cols;
        const int inRow = std::min (cols, n - row * cols);
        const int x0 = (getWidth() - inRow * kw - (inRow - 1) * 4) / 2;
        knobs[i]->setBounds (x0 + col * (kw + 4), top + row * (kh + 2), kw, kh);
    }
    juce::ignoreUnused (rows);
    footswitch.setBounds (getWidth() / 2 - 17, getHeight() - 44, 34, 30);
}

void PedalCard::showMenu()
{
    juce::PopupMenu menu, swap;
    int i = 1;
    for (auto& c : Library::pedals()) if (c.name.rfind ("Empty", 0) != 0) swap.addItem (i++, u8 (c.name));
    menu.addSubMenu ("Change circuit", swap);
    menu.addSeparator();
    menu.addItem (1000, "Take off the board");
    menu.showMenuAsync (juce::PopupMenu::Options().withTargetComponent (this), [p = &proc, pid = id] (int r) {
        if (r == 1000) { p->removePedal (pid); return; }
        if (r <= 0) return;
        int k = 1;
        for (auto& c : Library::pedals())
            if (c.name.rfind ("Empty", 0) != 0 && k++ == r) { p->replacePedal (pid, c); return; }
    });
}

void PedalCard::mouseDown (const juce::MouseEvent& e)
{
    dragStart = getPosition();
    dragging = false;
    if (e.mods.isPopupMenu() || e.y > getHeight() - 90) showMenu();
}

void PedalCard::mouseDrag (const juce::MouseEvent& e)
{
    if (e.y > getHeight() - 90 && ! dragging) return;
    if (! dragging && e.getDistanceFromDragStart() < 4) return;
    dragging = true;
    toFront (false);
    setTopLeftPosition (dragStart.x + e.getDistanceFromDragStartX(), dragStart.y);
    repaint();
}

void PedalCard::mouseUp (const juce::MouseEvent&)
{
    if (! dragging) return;
    dragging = false;
    board.dropped (*this, getBounds().getCentreX());
}

// MARK: Board

BoardView::BoardView (LutherieProcessor& p) : proc (p)
{
    add.setTextWhenNothingSelected ("+ Add a pedal");
    add.onChange = [this] {
        const auto name = add.getText().toStdString();
        add.setSelectedId (0, juce::dontSendNotification);
        if (auto c = Library::pedal (name)) proc.addPedal (*c);
    };
    addAndMakeVisible (add);
    rebuild();
}

void BoardView::rebuild()
{
    cards.clear();
    for (auto& bp : proc.board()) addAndMakeVisible (cards.add (new PedalCard (proc, *this, bp)));
    add.clear (juce::dontSendNotification);
    int i = 1;
    for (auto& c : Library::pedals()) add.addItem (u8 (c.name), i++);
    add.setVisible ((int) proc.board().size() < Rig::maxPedals);
    const int wanted = gap + ((int) cards.size() + 1) * (cardW + gap);
    setSize (std::max (wanted, getParentWidth() > 0 ? getParentWidth() : 400), cardH + 2 * gap);
    resized();
}

void BoardView::resized()
{
    int x = gap;
    for (auto* c : cards) { c->setBounds (x, gap, cardW, cardH); x += cardW + gap; }
    add.setBounds (x, gap + cardH / 2 - 14, cardW, 28);
}

void BoardView::paint (juce::Graphics& g)
{
    // the board itself, and the cable that runs along it
    g.setColour (Theme::well());
    g.fillRoundedRectangle (getLocalBounds().toFloat().reduced (4), 8);
    g.setColour (Theme::panelHi());
    g.drawLine (0, (float) gap + cardH / 2.0f, (float) getWidth(), (float) gap + cardH / 2.0f, 3);
}

void BoardView::dropped (PedalCard& card, int x)
{
    int from = cards.indexOf (&card);
    int to = juce::jlimit (0, (int) cards.size() - 1, (x - gap / 2) / (cardW + gap));
    if (from == to) { resized(); return; }
    proc.movePedal (from, to);
}

// MARK: Editor

LutherieEditor::LutherieEditor (LutherieProcessor& p) : juce::AudioProcessorEditor (p), proc (p), board (p)
{
    setLookAndFeel (&laf);
    boardViewport.setViewedComponent (&board, false);
    boardViewport.setScrollBarsShown (false, true);
    addAndMakeVisible (boardViewport);

    const std::pair<int, const char*> globals[] = { { RigParam::inputLevel, "Input" }, { RigParam::gate, "Gate" },
                                                    { RigParam::mix, "Mix" }, { RigParam::outputLevel, "Output" } };
    for (auto& [id, cap] : globals) addAndMakeVisible (globalKnobs.add (new Knob (*proc.param (id), cap, Theme::text())));

    auto setupCombo = [this] (juce::ComboBox& c) { addAndMakeVisible (c); };
    for (auto* c : { &ampMode, &ampPreset, &cabMode, &cabinet, &mic, &position, &quality }) setupCombo (*c);
    ampMode.addItemList ({ "Amp off", "Tube circuit", "Amp profile" }, 1);
    ampModeAttachment = std::make_unique<juce::ComboBoxParameterAttachment> (*proc.param (RigParam::ampMode), ampMode);
    cabMode.addItemList ({ "Cabinet off", "Built-in voicing", "Impulse response" }, 1);
    cabModeAttachment = std::make_unique<juce::ComboBoxParameterAttachment> (*proc.param (RigParam::cabMode), cabMode);
    {
        int i = 1;
        for (auto& c : Library::amps()) ampPreset.addItem (u8 (c.name), i++);
        ampPreset.onChange = [this] { if (auto a = Library::amp (ampPreset.getText().toStdString())) if (a->name != proc.ampCircuit().name) proc.setAmp (*a); };
    }
    {
        int i = 1;
        for (auto& c : CabinetLibrary::cabinets()) cabinet.addItem (u8 (c), i++);
        i = 1; for (auto& m : CabinetLibrary::mics()) mic.addItem (m, i++);
        i = 1; for (auto& m : CabinetLibrary::positions()) position.addItem (m, i++);
        auto choose = [this] {
            if (cabinet.getSelectedId() == 0) return;
            proc.chooseCabinet ({ cabinet.getText().toStdString(), mic.getText().toStdString(), position.getText().toStdString() });
            proc.setValue (RigParam::cabMode, 2);
        };
        cabinet.onChange = choose; mic.onChange = choose; position.onChange = choose;
        cabinet.setTextWhenNothingSelected ("Choose a cabinet");
    }
    for (int f : { 1, 2, 4, 8 }) quality.addItem (juce::String (f) + u8 ("\xc3\x97 oversampling"), (int) std::log2 (f) + 1);
    quality.onChange = [this] { proc.setQuality (1 << (quality.getSelectedId() - 1)); };

    proc.addChangeListener (this);
    refresh();
    setResizable (true, true);
    setResizeLimits (900, 640, 2400, 1400);
    setSize (1180, 700);
    startTimerHz (20);

    // Testing aid: LUTHERIE_SNAPSHOT=/path/out.png draws the editor to a picture once things have built, then quits
    // (standalone only).
    if (auto path = juce::SystemStats::getEnvironmentVariable ("LUTHERIE_SNAPSHOT", {}); path.isNotEmpty()
        && juce::JUCEApplicationBase::isStandaloneApp())
        juce::Timer::callAfterDelay (2500, [safe = juce::Component::SafePointer<LutherieEditor> (this), path] {
            if (! safe) return;
            juce::FileOutputStream out { juce::File (path) };
            if (out.openedOk()) { out.setPosition (0); out.truncate(); juce::PNGImageFormat().writeImageToStream (safe->createComponentSnapshot (safe->getLocalBounds(), true, 2.0f), out); }
            juce::JUCEApplicationBase::quit();
        });
}

LutherieEditor::~LutherieEditor()
{
    proc.removeChangeListener (this);
    setLookAndFeel (nullptr);
}

void LutherieEditor::changeListenerCallback (juce::ChangeBroadcaster*) { refresh(); }

void LutherieEditor::refresh()
{
    board.rebuild();
    ampKnobs.clear();
    const auto labels = proc.knobLabels (proc.ampCircuit());
    for (size_t i = 0; i < labels.size(); ++i)
        addAndMakeVisible (ampKnobs.add (new Knob (*proc.param (RigParam::ampKnob ((int) i)), u8 (labels[i]), Theme::text())));
    addAndMakeVisible (ampKnobs.add (new Knob (*proc.param (RigParam::powerDrive), "Power", Theme::gold())));
    addAndMakeVisible (ampKnobs.add (new Knob (*proc.param (RigParam::presence), "Presence", Theme::gold())));
    int i = 1;
    for (auto& c : Library::amps()) { if (c.name == proc.ampCircuit().name) ampPreset.setSelectedId (i, juce::dontSendNotification); ++i; }
    if (auto c = proc.cabinetChoice())
    {
        auto pick = [] (juce::ComboBox& box, const std::string& s) {
            for (int k = 0; k < box.getNumItems(); ++k) if (box.getItemText (k) == u8 (s)) box.setSelectedItemIndex (k, juce::dontSendNotification);
        };
        pick (cabinet, c->cabinet); pick (mic, c->mic); pick (position, c->position);
    }
    else
    {
        mic.setSelectedItemIndex (0, juce::dontSendNotification);
        position.setSelectedItemIndex (1, juce::dontSendNotification);
    }
    quality.setSelectedId ((int) std::log2 (proc.quality()) + 1, juce::dontSendNotification);
    resized();
}

void LutherieEditor::timerCallback()
{
    auto& rig = proc.getRig();
    inMeter = rig.inputPeak.load();
    outMeter = rig.outputPeak.load();
    status = juce::String (juce::roundToInt (rig.load.load() * 100)) + u8 ("% CPU   \xc2\xb7   latency ") + juce::String (rig.latencySamples.load()) + " samples";
    for (auto* c : board.getChildren()) c->repaint();   // LEDs follow the footswitches and automation
    repaint (0, 0, getWidth(), 56);
}

void LutherieEditor::paint (juce::Graphics& g)
{
    g.fillAll (Theme::bg());
    // title
    g.setColour (Theme::text());
    g.setFont (juce::FontOptions (22.0f, juce::Font::bold));
    g.drawText ("L U T H E R I E", 20, 12, 260, 30, juce::Justification::centredLeft);
    g.setColour (Theme::dim());
    g.setFont (juce::FontOptions (11.0f));
    g.drawText ("CHANNEL AUDIO", 22, 38, 200, 14, juce::Justification::centredLeft);
    g.drawText (status, getWidth() - 560, 18, 280, 20, juce::Justification::centredRight);
    // meters
    auto meter = [&g] (juce::Rectangle<float> r, float v) {
        g.setColour (Theme::well()); g.fillRoundedRectangle (r, 2);
        const float db = juce::jlimit (-60.0f, 6.0f, juce::Decibels::gainToDecibels (v, -60.0f));
        auto f = r.withWidth (r.getWidth() * (db + 60) / 66);
        g.setColour (db > -1 ? Theme::red() : Theme::gold()); g.fillRoundedRectangle (f, 2);
    };
    meter ({ (float) getWidth() - 240, 20, 100, 6 }, inMeter);
    meter ({ (float) getWidth() - 240, 32, 100, 6 }, outMeter);
    g.setFont (juce::FontOptions (9.0f));
    g.drawText ("IN", getWidth() - 262, 16, 18, 12, juce::Justification::centredRight);
    g.drawText ("OUT", getWidth() - 262, 28, 18, 12, juce::Justification::centredRight);

    // section panels
    auto section = [&g] (juce::Rectangle<int> r, const juce::String& title) {
        g.setColour (Theme::panel()); g.fillRoundedRectangle (r.toFloat(), 8);
        g.setColour (Theme::line()); g.drawRoundedRectangle (r.toFloat().reduced (0.5f), 8, 1);
        g.setColour (Theme::gold()); g.setFont (juce::FontOptions (10.5f, juce::Font::bold));
        g.drawText (title, r.getX() + 12, r.getY() + 8, 200, 14, juce::Justification::centredLeft);
    };
    const int lowerY = getHeight() - 236;
    section ({ 16, lowerY, getWidth() - 32 - 300, 220 }, "A M P");
    section ({ getWidth() - 316, lowerY, 300, 220 }, "C A B I N E T");
}

void LutherieEditor::layoutAmpKnobs()
{
    const int lowerY = getHeight() - 236;
    const int ampW = getWidth() - 32 - 300;
    ampMode.setBounds (28, lowerY + 30, 150, 26);
    ampPreset.setBounds (186, lowerY + 30, 240, 26);
    quality.setBounds (434, lowerY + 30, 170, 26);
    const int kw = 62, kh = 80;
    int x = 28;
    for (auto* k : ampKnobs)
    {
        if (x + kw > 16 + ampW - 8) break;
        k->setBounds (x, lowerY + 80, kw, kh);
        x += kw + 6;
    }
}

void LutherieEditor::resized()
{
    int x = getWidth() - 540 - 260;
    for (auto* k : globalKnobs) { k->setBounds (x, 6, 56, 50); x += 62; }
    const int lowerY = getHeight() - 236;
    boardViewport.setBounds (12, 64, getWidth() - 24, lowerY - 72);
    board.rebuild();
    layoutAmpKnobs();
    const int cx = getWidth() - 304;
    cabMode.setBounds (cx, lowerY + 30, 276, 26);
    cabinet.setBounds (cx, lowerY + 66, 276, 26);
    mic.setBounds (cx, lowerY + 102, 134, 26);
    position.setBounds (cx + 142, lowerY + 102, 134, 26);
}
} // namespace lutherie
