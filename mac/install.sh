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

# コード署名。ad-hoc 署名（--sign -）だと「アクセシビリティ」の許可が
# バイナリのハッシュに紐づくため、再ビルドはもちろん Mac の再起動でも
# 許可が失効してしまう。自己署名のコード署名証明書があればそれで署名すると、
# 許可が「証明書」に紐づくので、再ビルド・再起動しても許可が保持され、
# アクセシビリティの再付与が二度と要らなくなる。
#
# 証明書は一度だけ作る（キーチェーンに永続）:
#   キーチェーンアクセス → 証明書アシスタント → 自分に証明書を作成
#     名前: ClaudeLive Daemon Signing / 証明書のタイプ: コード署名
#   （Apple Development 証明書は provisioning が要り CLI ツールでは実行不可なので使わない）
SIGN_CERT="ClaudeLive Daemon Signing"
if security find-certificate -c "$SIGN_CERT" >/dev/null 2>&1; then
    echo "==> コード署名（自己署名証明書 '$SIGN_CERT'。再起動・再ビルドで許可が切れない）"
    codesign --force --sign "$SIGN_CERT" --identifier com.tento.claudelive.daemon "$BASE/claudelive-daemon"
else
    echo "==> コード署名（ad-hoc。証明書 '$SIGN_CERT' が無いため。再起動でアクセシビリティ許可が切れる場合あり）"
    codesign --force --sign - --identifier com.tento.claudelive.daemon "$BASE/claudelive-daemon"
fi

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
