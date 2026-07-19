#!/usr/bin/env python3
"""Claude Code の hooks に ClaudeLive デーモンへの中継を追加する。

~/.claude/settings.json に curl による POST を登録する。
既に登録済みのイベントはスキップし、他の hooks 設定には触らない。
実行前に settings.json.claudelive.bak へバックアップを取る。
"""

import json
import os
import shutil

SETTINGS = os.path.expanduser("~/.claude/settings.json")
MARKER = "127.0.0.1:53536/hook"
COMMAND = (
    "curl -sS -m 3 -X POST http://127.0.0.1:53536/hook "
    "-H 'Content-Type: application/json' --data-binary @- "
    ">/dev/null 2>&1 || true"
)
# AskUserQuestion 専用: デーモンが iPhone の回答を待つ間フックを保留するので
# タイムアウトを長くし、stdout（デーモンの decision JSON）は捨てずに返す
QUESTION_MARKER = "127.0.0.1:53536/question"
QUESTION_COMMAND = (
    "curl -sS -m 90 -X POST http://127.0.0.1:53536/question "
    "-H 'Content-Type: application/json' --data-binary @- "
    "2>/dev/null || true"
)
EVENTS = [
    "SessionStart",
    "UserPromptSubmit",
    "PreToolUse",
    "PostToolUse",
    "Notification",
    "Stop",
    "PreCompact",
    "SessionEnd",
]
NEEDS_MATCHER = {"PreToolUse", "PostToolUse", "PreCompact"}


def main():
    settings = {}
    if os.path.exists(SETTINGS):
        with open(SETTINGS) as f:
            settings = json.load(f)
        shutil.copyfile(SETTINGS, SETTINGS + ".claudelive.bak")

    hooks = settings.setdefault("hooks", {})
    added = []
    for event in EVENTS:
        entries = hooks.setdefault(event, [])
        already = any(
            MARKER in hook.get("command", "")
            for entry in entries
            for hook in entry.get("hooks", [])
        )
        if already:
            continue
        entry = {"hooks": [{"type": "command", "command": COMMAND}]}
        if event in NEEDS_MATCHER:
            entry["matcher"] = "*"
        entries.append(entry)
        added.append(event)

    # AskUserQuestion を iPhone から回答するための保留フック
    entries = hooks.setdefault("PreToolUse", [])
    question_installed = any(
        QUESTION_MARKER in hook.get("command", "")
        for entry in entries
        for hook in entry.get("hooks", [])
    )
    if not question_installed:
        entries.append({
            "matcher": "AskUserQuestion",
            "hooks": [{"type": "command", "command": QUESTION_COMMAND, "timeout": 120}],
        })
        added.append("PreToolUse(AskUserQuestion)")

    os.makedirs(os.path.dirname(SETTINGS), exist_ok=True)
    with open(SETTINGS, "w") as f:
        json.dump(settings, f, ensure_ascii=False, indent=2)
        f.write("\n")

    if added:
        print(f"hooks を追加: {', '.join(added)}")
    else:
        print("hooks は登録済みです")


if __name__ == "__main__":
    main()
