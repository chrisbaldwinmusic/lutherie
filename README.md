# Lutherie (Mac)

Circuit-level guitar pedal and amp simulator: a standalone app, an Audio Unit (inside the app) and a VST3.

## Layout
- `Sources/PedalCore`: the simulation engine (nodal circuit solver, device models, Neural Amp Modeler player, cabinet, signal chain), SPICE export, self-tests. Pure Swift, no UI.
- `Sources/PedalUI`: the SwiftUI editor, learn mode and the Audio Unit.
- `Sources/Lutherie`: the standalone app (installs the plugins on first launch).
- `Sources/LutherieAU`: the Audio Unit extension.
- `Sources/PedalVSTBridge` and `VST3/`: a C interface to the engine plus the VST3 shell (Steinberg VST3 SDK 3.8.1, MIT, in `ThirdParty/`).

`./build.sh` builds everything into `build/` (`./build.sh register` also validates the Audio Unit with `auval`).

## Would JUCE be better?
JUCE would mainly buy two things: Windows (and Linux) builds, and an AAX build for Pro Tools from one C++ codebase.
- Pro Tools still needs Avid's developer account, the AAX SDK and PACE code signing, with or without JUCE.
- The editor would have to be rewritten in C++/JUCE graphics; Swift UI only runs on Apple platforms. A Mac-only hybrid (JUCE wrappers hosting this SwiftUI editor) is possible, but then the Windows benefit is lost.
- JUCE is licensed under AGPLv3 or a paid commercial licence (with a free tier for small revenue); check the current terms before release.
- The engine in PedalCore is self-contained, so a JUCE version would port it (about 1,500 lines of maths) to C++ and keep the same circuits, presets and `.nam` support.

Recommendation: stay native while the product is Mac-only. Move to JUCE when Windows or Pro Tools support becomes a priority.

## Amp captures
Lutherie can browse and load Neural Amp Modeler captures from your own TONE3000 account. Powered by [TONE3000](https://www.tone3000.com).
