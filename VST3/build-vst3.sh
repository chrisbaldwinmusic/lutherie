#!/bin/bash
# Builds build/Lutherie.vst3: the C++ VST3 shell plus the shared Swift engine and editor.
set -euo pipefail
cd "$(dirname "$0")/.."
SDK=ThirdParty/vst3sdk
OUT=build
OBJ=build/vst3-obj
mkdir -p "$OBJ"

swift build -c release --product PedalVSTBridge
BIN=$(swift build -c release --show-bin-path)

SRCS=(
  $SDK/pluginterfaces/base/conststringtable.cpp $SDK/pluginterfaces/base/coreiids.cpp
  $SDK/pluginterfaces/base/funknown.cpp $SDK/pluginterfaces/base/ustring.cpp
  $SDK/base/source/baseiids.cpp $SDK/base/source/fbuffer.cpp $SDK/base/source/fdebug.cpp
  $SDK/base/source/fobject.cpp $SDK/base/source/fstreamer.cpp $SDK/base/source/fstring.cpp
  $SDK/base/source/timer.cpp $SDK/base/source/updatehandler.cpp
  $SDK/base/thread/source/fcondition.cpp $SDK/base/thread/source/flock.cpp
  $SDK/public.sdk/source/common/commoniids.cpp $SDK/public.sdk/source/common/pluginview.cpp
  $SDK/public.sdk/source/main/pluginfactory.cpp $SDK/public.sdk/source/main/macmain.cpp
  $SDK/public.sdk/source/main/moduleinit.cpp
  $SDK/public.sdk/source/vst/vstsinglecomponenteffect.cpp $SDK/public.sdk/source/vst/vstbus.cpp
  $SDK/public.sdk/source/vst/vstparameters.cpp $SDK/public.sdk/source/vst/vstcomponentbase.cpp
  $SDK/public.sdk/source/vst/vstinitiids.cpp
  VST3/lutherie_vst3.cpp
)
FLAGS="-std=c++17 -O2 -DNDEBUG -DRELEASE=1 -fvisibility=hidden -mmacosx-version-min=14.0 -I$SDK"
OBJS=()
for s in "${SRCS[@]}"; do
  o="$OBJ/$(echo "$s" | tr '/' '_').o"
  if [ ! -f "$o" ] || [ "$s" -nt "$o" ]; then clang++ $FLAGS -c "$s" -o "$o"; fi
  OBJS+=("$o")
done

B="$OUT/Lutherie.vst3"
if [ -d "$B" ]; then mv "$B" "$OUT/.oldvst-$$" && rm -rf "$OUT/.oldvst-$$"; fi
mkdir -p "$B/Contents/MacOS" "$B/Contents/Frameworks" "$B/Contents/Resources"
cp "$BIN/libPedalVSTBridge.dylib" "$B/Contents/Frameworks/"
clang++ -bundle -mmacosx-version-min=14.0 "${OBJS[@]}" -o "$B/Contents/MacOS/Lutherie" \
  -L"$BIN" -lPedalVSTBridge -Wl,-rpath,@loader_path/../Frameworks \
  -Wl,-exported_symbols_list,$SDK/public.sdk/source/main/macexport.exp \
  -framework CoreFoundation -framework Foundation -framework AppKit
printf 'BNDL????' > "$B/Contents/PkgInfo"
cat > "$B/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleExecutable</key><string>Lutherie</string>
  <key>CFBundleIdentifier</key><string>audio.channel.lutherie.vst3</string>
  <key>CFBundleName</key><string>Lutherie</string>
  <key>CFBundlePackageType</key><string>BNDL</string>
  <key>CFBundleSignature</key><string>????</string>
  <key>CFBundleShortVersionString</key><string>1.0.0</string>
  <key>CFBundleVersion</key><string>1</string>
</dict></plist>
PLIST
# The linker already signed both binaries for this Mac. Re-signing them with codesign makes
# recent macOS refuse to load the library into a host, so they are left as linked.
echo "Built $(pwd)/$B"
