#!/bin/sh
# Builds the JUCE version of Lutherie (AU, VST3, Standalone), checks the engine against the Swift reference, installs
# the plugins into ~/Library/Audio/Plug-Ins and validates them. Needs cmake + ninja (pip3 install --user cmake ninja).
#
#   ./build.sh            build, check, install, validate (pluginval strictness 10 on both formats, then auval)
#   ./build.sh --quick    skip validation
#
# JUCE is not stored in the repository: the script uses ../../JUCE (~/Developer/JUCE) or clones the pinned tag there.
# The build folder lives in ~/Library/Caches, outside any synced folder.
set -e
cd "$(dirname "$0")"
export PATH="$HOME/Library/Python/3.9/bin:$PATH"
BUILD="$HOME/Library/Caches/Lutherie-build"
JUCE="$(cd .. && cd .. && pwd)/JUCE"
JUCE_TAG="9.0.5"
PLUGINVAL_TAG="v1.0.4"
[ -f "$JUCE/CMakeLists.txt" ] || git clone --depth 1 --branch "$JUCE_TAG" https://github.com/juce-framework/JUCE.git "$JUCE"

cmake -S . -B "$BUILD" -G Ninja -DCMAKE_BUILD_TYPE=Release -DLUTHERIE_JUCE_DIR="$JUCE"
cmake --build "$BUILD" --target LutherieTests
"$BUILD/LutherieTests_artefacts/Release/LutherieTests" Tests/reference
cmake --build "$BUILD"
echo "Standalone app: $BUILD/LutherieJUCE_artefacts/Release/Standalone/Lutherie JUCE.app"
[ "${1:-}" = "--quick" ] && exit 0

PV_DIR="$HOME/Library/Caches/pluginval-$PLUGINVAL_TAG"
PV="$PV_DIR/pluginval.app/Contents/MacOS/pluginval"
if [ ! -x "$PV" ]; then
    mkdir -p "$PV_DIR"
    curl -fsSL -o "$PV_DIR/pluginval.zip" "https://github.com/Tracktion/pluginval/releases/download/$PLUGINVAL_TAG/pluginval_macOS.zip"
    unzip -q -o "$PV_DIR/pluginval.zip" -d "$PV_DIR" && rm "$PV_DIR/pluginval.zip"
fi
LOGS="$BUILD/validation"; mkdir -p "$LOGS"
for f in "VST3/Lutherie JUCE.vst3" "Components/Lutherie JUCE.component"; do
    killall -9 AudioComponentRegistrar 2>/dev/null || true
    echo "pluginval (strictness 10): $f"
    "$PV" --strictness-level 10 --timeout-ms 600000 --validate "$HOME/Library/Audio/Plug-Ins/$f" > "$LOGS/pluginval.txt" 2>&1 \
        || { tail -40 "$LOGS/pluginval.txt"; echo "pluginval FAILED for $f"; exit 1; }
done
auval -v aufx Ltjc Chnl > "$LOGS/auval.txt" 2>&1 || { tail -40 "$LOGS/auval.txt"; echo "auval FAILED"; exit 1; }
echo "all validation passed"
