#!/bin/bash
# Double-click to install Lutherie on this Mac:
#   Lutherie.app  -> ~/Applications       (the standalone app; it also carries the Audio Unit)
#   Lutherie.vst3 -> ~/Library/Audio/Plug-Ins/VST3
# These builds are signed for this Mac only (not notarized by Apple), so the script also clears
# the "downloaded from the internet" flag that makes macOS show "Apple could not verify…".
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
SRC="$HERE"
[ -d "$HERE/build/Lutherie.app" ] && SRC="$HERE/build"

mkdir -p "$HOME/Applications" "$HOME/Library/Audio/Plug-Ins/VST3"
for item in "$HOME/Applications/Lutherie.app" "$HOME/Library/Audio/Plug-Ins/VST3/Lutherie.vst3"; do
  [ -e "$item" ] && mv "$item" "$item.old-$$" && rm -rf "$item.old-$$"
done
ditto "$SRC/Lutherie.app" "$HOME/Applications/Lutherie.app"
ditto "$SRC/Lutherie.vst3" "$HOME/Library/Audio/Plug-Ins/VST3/Lutherie.vst3"
xattr -dr com.apple.quarantine "$HOME/Applications/Lutherie.app" 2>/dev/null || true
xattr -dr com.apple.quarantine "$HOME/Library/Audio/Plug-Ins/VST3/Lutherie.vst3" 2>/dev/null || true

# Register the Audio Unit that lives inside the app.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$HOME/Applications/Lutherie.app"
pluginkit -a "$HOME/Applications/Lutherie.app/Contents/PlugIns/LutherieAU.appex" 2>/dev/null || true
killall -9 AudioComponentRegistrar 2>/dev/null || true

echo
echo "Lutherie is installed."
echo "  App:         ~/Applications/Lutherie.app"
echo "  Audio Unit:  appears as Channel Audio > Lutherie in Logic, GarageBand, MainStage and other AU hosts"
echo "  VST3:        ~/Library/Audio/Plug-Ins/VST3/Lutherie.vst3 (rescan plugins in your DAW)"
echo
echo "Open Lutherie once from ~/Applications so macOS knows about the Audio Unit."
open "$HOME/Applications/Lutherie.app"
