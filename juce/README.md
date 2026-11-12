# Lutherie (JUCE)

The C++/JUCE version of Lutherie, replacing the Swift app in the folder above in stages. Until it does, it installs
beside it as **Lutherie JUCE** (AU `aufx Ltjc Chnl`, VST3, standalone).

`./build.sh` builds, checks and installs everything (see the script for options). JUCE lives outside the repository,
in `~/Developer/JUCE`.

## Layout
- `Source/Core`: the engine in plain C++ (no JUCE): circuit model and netlist, device models, the nodal solver,
  oversampler and filters, built-in cabinets, and the rig (six pedal slots, amp, power stage, cabinet, mix).
  `CircuitJSON` reads and writes circuits in the Swift app's JSON.
- `Source/Plugin`: the processor (same parameter ids as the Swift plugin; sessions in the same JSON, so they move
  between the two), and the editor (pedalboard, amp, cabinet).
- `Resources`: the starter circuits as JSON.
- `Tests`: runs every starter circuit and a whole board through the C++ engine and compares the samples with the
  Swift engine's (`Tests/reference`, written by `REF_DIR=… PedalCheck` in the Swift package). Everything matches to
  better than −130 dB.

## Still to port
- Neural amp profiles (amp mode 2): planned on NeuralAmpModelerCore; TONE3000 sign-in.
- The schematic editor, part palette, analysis (response, scope, harmonics, bias) and learn mode.
- Loading impulse-response files; session files from the standalone app.
