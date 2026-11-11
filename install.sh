#!/bin/bash
# Install the input method. Prefers the system-wide location because recent
# macOS versions only scan /Library/Input Methods for third-party IMEs.
set -euo pipefail
cd "$(dirname "$0")"

./build.sh

APP="build/ElevenInput.app"
USE_SYSTEM=0
if [ "${1:-}" = "--system" ]; then
  USE_SYSTEM=1
fi

if spctl -a "$APP" >/dev/null 2>&1; then
  echo "==> Gatekeeper: accepted"
else
  cat <<'EOF'
==> 警告：这个包没有通过 Gatekeeper（不是 Developer ID + 公证的包）。
    macOS 26/27 很可能不会把它加入系统输入法列表。
    可以先跑 Demo 体验：open build/ElevenDemo.app
    正式安装需要 Developer ID：./sign.sh "Developer ID Application: ..."
EOF
fi

if [ "$USE_SYSTEM" = "1" ] || [ ! -w "$HOME/Library/Input Methods" ]; then
  DEST="/Library/Input Methods/ElevenInput.app"
  if [ "$(id -u)" != "0" ]; then
    echo "==> 需要管理员权限写入 /Library/Input Methods"
    sudo rm -rf "/Library/Input Methods/ElevenInput.app"
    sudo cp -R "$APP" "/Library/Input Methods/"
    sudo chown -R root:wheel "/Library/Input Methods/ElevenInput.app"
  else
    rm -rf "$DEST"
    cp -R "$APP" "/Library/Input Methods/"
  fi
else
  DEST="$HOME/Library/Input Methods/ElevenInput.app"
  mkdir -p "$HOME/Library/Input Methods"
  rm -rf "$DEST"
  cp -R "$APP" "$DEST"
fi

killall ElevenInput 2>/dev/null || true
pkill -f "Input Methods/ElevenInput.app" 2>/dev/null || true

LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
if [ -x "$LSREGISTER" ]; then
  "$LSREGISTER" -f "$DEST" >/dev/null 2>&1 || true
fi

open "$DEST" || true
open "x-apple.systempreferences:com.apple.Keyboard-Settings.extension?TextInput" 2>/dev/null || \
  open "x-apple.systempreferences:com.apple.preference.keyboard" || true

cat <<EOF

安装位置：$DEST

接下来：
  1. 注销并重新登录（输入法列表在登录时扫描）
  2. 系统设置 → 键盘 → 输入法 → 编辑 → “+” → 简体中文 → 拾文拼音
  3. 第一次切换过去会请求「辅助功能」权限，允许后就能读取窗口文字
  4. 打开一个有中文内容的窗口，输入 goujian 试试

没有开发者账号、列表里看不到它？先试 Demo：
  open build/ElevenDemo.app       # ⌃⌥Space 唤起
EOF
