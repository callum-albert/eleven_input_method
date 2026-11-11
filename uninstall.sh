#!/bin/bash
set -euo pipefail
DEST="$HOME/Library/Input Methods/ElevenInput.app"
killall ElevenInput 2>/dev/null || true
pkill -f "Input Methods/ElevenInput.app" 2>/dev/null || true
rm -rf "$DEST"
echo "已删除 $DEST"
echo "如果它还在输入法列表里，去 系统设置 → 键盘 → 输入法 中手动移除。"
echo "本地学习数据位于 ~/Library/Application Support/ElevenInput/"
