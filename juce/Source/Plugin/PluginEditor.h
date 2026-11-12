#pragma once

#include "PluginProcessor.h"

#include <juce_audio_processors/juce_audio_processors.h>
#include <juce_gui_basics/juce_gui_basics.h>

namespace lutherie
{
/// Colours and drawing shared with the Swift app's look (the Channel Audio house style in Lutherie's red).
struct Theme
{
    static juce::Colour hex (juce::uint32 rgb, float alpha = 1) { return juce::Colour (0xff000000 | rgb).withAlpha (alpha); }
    static juce::Colour bg()       { return hex (0x191516); }
    static juce::Colour panel()    { return hex (0x262022); }
    static juce::Colour panelHi()  { return hex (0x3a3033); }
    static juce::Colour well()     { return hex (0x0e0b0c); }
    static juce::Colour line()     { return hex (0x43383b, 0.55f); }
    static juce::Colour text()     { return hex (0xe9dfc6); }
    static juce::Colour dim()      { return hex (0xa39d8d); }
    static juce::Colour gold()     { return hex (0xc9a25a); }
    static juce::Colour red()      { return hex (0xb8403a); }
    static juce::Colour crimson()  { return hex (0x8f2630); }
};

class LutherieLookAndFeel : public juce::LookAndFeel_V4
{
public:
    LutherieLookAndFeel();
    void drawRotarySlider (juce::Graphics&, int x, int y, int w, int h, float pos, float start, float end, juce::Slider&) override;
    void drawComboBox (juce::Graphics&, int w, int h, bool down, int, int, int, int, juce::ComboBox&) override;
    void drawButtonBackground (juce::Graphics&, juce::Button&, const juce::Colour&, bool over, bool down) override;
    juce::Font getComboBoxFont (juce::ComboBox&) override { return juce::Font (juce::FontOptions (12.0f)); }
    juce::Font getPopupMenuFont() override { return juce::Font (juce::FontOptions (13.0f)); }
    /// Knob colours for the next knobs drawn (set per enclosure).
    juce::Colour knobCap = Theme::hex (0x1b1718), knobInk = Theme::text();
};

/// A knob with its caption under it, bound to a host parameter.
class Knob : public juce::Component
{
public:
    Knob (juce::RangedAudioParameter&, const juce::String& caption, juce::Colour ink);
    void resized() override;
    void paint (juce::Graphics&) override;
    juce::Slider slider;
private:
    juce::String caption;
    juce::Colour ink;
    juce::SliderParameterAttachment attachment;
};

class BoardView;

/// One pedal: its painted enclosure, knobs, footswitch and LED. Drag it by its top to move it along the board;
/// its name opens a menu to swap the circuit or take the pedal off.
class PedalCard : public juce::Component
{
public:
    PedalCard (LutherieProcessor&, BoardView&, const BoardPedal&);
    void paint (juce::Graphics&) override;
    void resized() override;
    void mouseDown (const juce::MouseEvent&) override;
    void mouseDrag (const juce::MouseEvent&) override;
    void mouseUp (const juce::MouseEvent&) override;
    const std::string id;
    const int slot;
private:
    LutherieProcessor& proc;
    BoardView& board;
    std::string name;
    struct Finish { juce::uint32 top, bottom, ink; bool creamKnobs; juce::uint32 led; };
    Finish finish;
    juce::OwnedArray<Knob> knobs;
    juce::TextButton footswitch;
    juce::ButtonParameterAttachment onAttachment;
    juce::Point<int> dragStart;
    bool dragging = false;
    static Finish finishFor (const std::string& name);
    void showMenu();
};

/// The pedals in signal order, and a place to add another.
class BoardView : public juce::Component
{
public:
    explicit BoardView (LutherieProcessor&);
    void rebuild();
    void resized() override;
    void paint (juce::Graphics&) override;
    void dropped (PedalCard&, int x);
    static constexpr int cardW = 150, cardH = 290, gap = 14;
private:
    LutherieProcessor& proc;
    juce::OwnedArray<PedalCard> cards;
    juce::ComboBox add;
};

class LutherieEditor : public juce::AudioProcessorEditor, private juce::ChangeListener, private juce::Timer
{
public:
    explicit LutherieEditor (LutherieProcessor&);
    ~LutherieEditor() override;
    void paint (juce::Graphics&) override;
    void resized() override;

private:
    LutherieProcessor& proc;
    LutherieLookAndFeel laf;
    BoardView board;
    juce::Viewport boardViewport;
    juce::OwnedArray<Knob> globalKnobs, ampKnobs;
    juce::ComboBox ampMode, ampPreset, cabMode, cabinet, mic, position, quality;
    std::unique_ptr<juce::ComboBoxParameterAttachment> ampModeAttachment, cabModeAttachment;
    juce::String status;
    float inMeter = 0, outMeter = 0;

    void changeListenerCallback (juce::ChangeBroadcaster*) override;
    void timerCallback() override;
    void refresh();
    void layoutAmpKnobs();
};
} // namespace lutherie
