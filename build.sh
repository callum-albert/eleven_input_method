#!/bin/bash
# Build the input method and wrap it in a .app bundle.
set -euo pipefail
cd "$(dirname "$0")"

if [ ! -f Resources/pinyin.bin ]; then
  echo "==> building dictionary"
  python3 tools/build_dict.py
fi

echo "==> compiling"
swift build -c release --product ElevenInput
swift build -c release --product eleven-probe
swift build -c release --product ElevenSelfTest

BIN_DIR="$(swift build -c release --show-bin-path)"
APP="build/ElevenInput.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/ElevenInput" "$APP/Contents/MacOS/ElevenInput"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/pinyin.bin "$APP/Contents/Resources/pinyin.bin"
cp -R Resources/zh-Hans.lproj "$APP/Contents/Resources/zh-Hans.lproj"
cp -R Resources/en.lproj "$APP/Contents/Resources/en.lproj"
swift tools/make_icon.swift "$APP/Contents/Resources/menu_icon.pdf" >/dev/null

ICONSET="$(mktemp -d)/AppIcon.iconset"
swift tools/make_appicon.swift "$ICONSET" >/dev/null
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$(dirname "$ICONSET")"

# Ad-hoc signature: enough for local use. Rebuilding changes the signature, so
# macOS may ask for Accessibility permission again after a rebuild.
xattr -cr "$APP"
IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | sed -n 's/.*"\(.*\)"/\1/p' | grep -m1 "Eleven Local Code Signing" || true)"
if [ -n "$IDENTITY" ]; then
  codesign --force --deep --options runtime --sign "$IDENTITY" --identifier com.eleven.inputmethod "$APP" >/dev/null 2>&1 || true
  echo "    signed with: $IDENTITY"
else
  codesign --force --deep --sign - --identifier com.eleven.inputmethod "$APP" >/dev/null 2>&1 || true
  echo "    signed ad-hoc"
fi

if ! spctl -a "$APP" >/dev/null 2>&1; then
  echo "    note: not notarized — macOS 26/27 may refuse to list it as an input method"
fi
echo "==> built $APP"

# Standalone demo app (no input-source registration required).
swift build -c release --product ElevenDemo
DEMO="build/ElevenDemo.app"
rm -rf "$DEMO"
mkdir -p "$DEMO/Contents/MacOS" "$DEMO/Contents/Resources"
cp "$BIN_DIR/ElevenDemo" "$DEMO/Contents/MacOS/ElevenDemo"
cp Resources/Demo-Info.plist "$DEMO/Contents/Info.plist"
cp Resources/pinyin.bin "$DEMO/Contents/Resources/pinyin.bin"
cp "$APP/Contents/Resources/AppIcon.icns" "$DEMO/Contents/Resources/AppIcon.icns"
xattr -cr "$DEMO"
if [ -n "$IDENTITY" ]; then
  codesign --force --deep --options runtime --sign "$IDENTITY" --identifier com.eleven.demo "$DEMO" >/dev/null 2>&1 || true
else
  codesign --force --deep --sign - --identifier com.eleven.demo "$DEMO" >/dev/null 2>&1 || true
fi
echo "==> built $DEMO"
echo "    probe:  $BIN_DIR/eleven-probe goujian --context-file /tmp/screen.txt"
