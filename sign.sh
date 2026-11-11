#!/bin/bash
# Sign and notarize the input method with an Apple Developer ID.
#
#   ./sign.sh "Developer ID Application: Your Name (TEAMID)"
#
# Requires a paid Apple Developer account. Without a Developer ID, macOS 26/27
# will not list the input method in System Settings (ad-hoc signatures are
# silently ignored), which is why the demo app exists.
set -euo pipefail
cd "$(dirname "$0")"

IDENTITY="${1:-${ELEVEN_SIGN_IDENTITY:-}}"
if [ -z "$IDENTITY" ]; then
  echo "usage: ./sign.sh \"Developer ID Application: Your Name (TEAMID)\""
  exit 1
fi

./build.sh
APP="build/ElevenInput.app"

echo "==> signing with $IDENTITY"
xattr -cr "$APP"
codesign --force --deep --options runtime --timestamp \
  --sign "$IDENTITY" --identifier com.eleven.inputmethod "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

echo "==> gatekeeper"
spctl -a -vv "$APP" || true

echo ""
echo "签名完成。下一步是公证："
echo "  ditto -c -k --keepParent \"$APP\" build/ElevenInput.zip"
echo "  xcrun notarytool submit build/ElevenInput.zip --keychain-profile <profile> --wait"
echo "  xcrun stapler staple \"$APP\""
echo ""
echo "公证并 staple 之后安装："
echo "  sudo rm -rf \"/Library/Input Methods/ElevenInput.app\""
echo "  sudo cp -R \"$APP\" \"/Library/Input Methods/\""
echo "  注销并重新登录，再到 系统设置 → 键盘 → 输入法 中添加「拾文拼音」"
