#!/bin/bash
# ClaudeLive Mac 側セットアップ
#   1. デーモンをビルドして ~/.claudelive/ に配置
#   2. launchd に登録して常駐化
#   3. Claude Code の hooks を設定
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
BASE="$HOME/.claudelive"
PLIST="$HOME/Library/LaunchAgents/com.tento.claudelive.plist"
UID_NUM="$(id -u)"

mkdir -p "$BASE"

echo "==> デーモンをビルド"
swiftc -O -o "$BASE/claudelive-daemon" "$DIR/ClaudeLiveDaemon.swift"

echo "==> launchd に登録"
mkdir -p "$HOME/Library/LaunchAgents"
sed "s|__HOME__|$HOME|g" "$DIR/com.tento.claudelive.plist" > "$PLIST"
launchctl bootout "gui/$UID_NUM/com.tento.claudelive" 2>/dev/null || true
launchctl bootstrap "gui/$UID_NUM" "$PLIST"
launchctl kickstart -k "gui/$UID_NUM/com.tento.claudelive"

echo "==> Claude Code hooks を設定"
python3 "$DIR/install_hooks.py"

echo ""
echo "セットアップ完了。残りの手順:"
echo "  1. ~/.claudelive/config.json に APNs キー ID を設定"
echo "  2. .p8 キーを ~/.claudelive/AuthKey.p8 に配置"
echo "  3. iPhone で ClaudeLive アプリを開いてトークンを登録"
echo "状態確認: curl -s http://127.0.0.1:53536/status | python3 -m json.tool"
echo "ログ:     tail -f ~/.claudelive/daemon.log"
