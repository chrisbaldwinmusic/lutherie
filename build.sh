#!/bin/bash
# Builds Lutherie.app (standalone) with the Audio Unit v3 plugin inside it, signed for this Mac.
#   ./build.sh            build into ./build/Lutherie.app
#   ./build.sh register   also register the plugin with macOS and validate it with auval
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release --product Lutherie
swift build -c release --product LutherieAU
BIN=$(swift build -c release --show-bin-path)

OUT=build
# Assemble and sign outside iCloud-synced folders: File Provider tags bundles with Finder metadata,
# which codesign refuses. The finished app is copied into build/ at the end.
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/lutherie.XXXXXX")"
APP="$STAGE/Lutherie.app"
FINAL="$OUT/Lutherie.app"
APPEX="$APP/Contents/PlugIns/LutherieAU.appex"
mkdir -p "$OUT"
# start from a fresh bundle each time
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APPEX/Contents/MacOS"

cp "$BIN/Lutherie" "$APP/Contents/MacOS/Lutherie"
cp "$BIN/LutherieAU" "$APPEX/Contents/MacOS/LutherieAU"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

VERSION=1.0.0
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Lutherie</string>
  <key>CFBundleDisplayName</key><string>Lutherie</string>
  <key>CFBundleIdentifier</key><string>audio.channel.lutherie</string>
  <key>CFBundleExecutable</key><string>Lutherie</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>CFBundleURLTypes</key><array><dict>
    <key>CFBundleURLName</key><string>audio.channel.lutherie.open</string>
    <key>CFBundleURLSchemes</key><array><string>lutherie</string></array>
  </dict></array>
  <key>NSMicrophoneUsageDescription</key><string>Lutherie plays your guitar through the simulated circuits when you choose Live input.</string>
</dict></plist>
PLIST

cat > "$APPEX/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>LutherieAU</string>
  <key>CFBundleDisplayName</key><string>Lutherie</string>
  <key>CFBundleIdentifier</key><string>audio.channel.lutherie.AU</string>
  <key>CFBundleExecutable</key><string>LutherieAU</string>
  <key>CFBundlePackageType</key><string>XPC!</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSExtension</key><dict>
    <key>NSExtensionPointIdentifier</key><string>com.apple.AudioUnit-UI</string>
    <key>NSExtensionPrincipalClass</key><string>LutherieViewController</string>
    <key>NSExtensionAttributes</key><dict>
      <key>AudioComponents</key><array><dict>
        <key>description</key><string>Circuit-level pedal and amp simulator</string>
        <key>manufacturer</key><string>Chnl</string>
        <key>name</key><string>Channel Audio: Lutherie</string>
        <key>sandboxSafe</key><true/>
        <key>subtype</key><string>Luth</string>
        <key>tags</key><array><string>Effects</string><string>Distortion</string></array>
        <key>type</key><string>aufx</string>
        <key>version</key><integer>65536</integer>
      </dict></array>
    </dict>
  </dict>
</dict></plist>
PLIST

cat > "$OUT/au.entitlements" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>com.apple.security.app-sandbox</key><true/>
  <key>com.apple.security.files.user-selected.read-write</key><true/>
</dict></plist>
PLIST

# The VST3 plugin travels inside the app (as a zip, so it stays exactly as linked) and the app
# installs it on first launch: no separate installer script for macOS to block.
VST3/build-vst3.sh
ditto -c -k --keepParent "$OUT/Lutherie.vst3" "$APP/Contents/Resources/Lutherie-vst3.zip"

xattr -cr "$APP" 2>/dev/null || true
codesign --force --sign - --entitlements "$OUT/au.entitlements" "$APPEX"
codesign --force --sign - "$APP"
codesign --verify --strict "$APP"
if [ -d "$FINAL" ]; then mv "$FINAL" "$OUT/.old-$$" && rm -rf "$OUT/.old-$$"; fi
ditto "$APP" "$FINAL"
rm -rf "$STAGE"
APP="$FINAL"
APPEX="$APP/Contents/PlugIns/LutherieAU.appex"
echo "Built $(pwd)/$APP"
cp "Install Lutherie.command" "$OUT/Install Lutherie.command"

if [ "${1:-}" = "register" ]; then
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP"
  pluginkit -a "$APPEX" || true
  sleep 2
  auval -v aufx Luth Chnl
fi
