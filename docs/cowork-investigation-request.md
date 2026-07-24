# Cowork調査依頼

## 背景

`ClaudeLive`（~/Downloads/Claud/ClaudeLive）は、Claude Code CLIセッションの状態（作業中・許可待ち・完了など）をiPhoneのライブアクティビティ（ロック画面/Dynamic Island）に表示するMacアプリです。

仕組みは、`~/.claude/settings.json`に登録したhooks（`SessionStart`・`UserPromptSubmit`・`PreToolUse`・`Stop`など）が、Claude Code CLIのセッションイベントごとにMac側の常駐デーモン（`http://127.0.0.1:53536/hook`）へPOSTすることで成り立っています。

## やりたいこと

Coworkで実行しているタスクも、同じようにiPhoneのライブアクティビティに状態を出したい。

## 分かっていること

- Coworkは`claude`コマンドのCLIフラグではなく、**Claude DesktopアプリのUIから起動する**機能
- Claude.appのプロセス引数に`cowork-artifact://`・`cowork-file://`という専用URLスキームが登録されている
- 過去に見つかったCowork関連のtranscriptファイル（`~/.claude/projects/**/*.jsonl`）は、通常セッションの形式（`SessionStart`/`UserPromptSubmit`などのhooksが発火する形式）とは異なり、`{"type":"queue-operation","operation":"enqueue",...}`という別フォーマットだった（かなり古いデータなので現状と違う可能性あり）
- 通常のhooks（`~/.claude/settings.json`）がCoworkのタスクに対しても発火するのかは未確認

## 調べてほしいこと

Coworkでタスクを1つ実行しながら、以下を確認してレポートしてください。

1. **プロセス**: `ps aux | grep -i claude` で、通常のセッションと違う起動のされ方（別プロセス名・特別な引数）をしているか
2. **hooksが発火するか**: `~/.claude/settings.json`の`SessionStart`/`UserPromptSubmit`/`PreToolUse`/`Stop`フックが、Coworkのタスク開始・ツール実行・完了のタイミングでちゃんと呼ばれているか（`~/.claudelive/daemon.stdout.log`に「セッション開始」等のログが出るかで確認できる）
3. **ファイル**: タスク実行前後で `~/.claude/` 配下・`~/Library/Application Support/Claude/` 配下に新しく作られる/更新されるファイルがあれば、その一覧とパス
4. **その中身の形式**: 3で見つかったファイルのうち、タスクの進捗（実行中のツール、完了、エラーなど）が読み取れそうなものがあれば、その中身のJSON構造
5. **セッションID的なもの**: Coworkのタスクを一意に識別できるID（sessionIdに相当するもの）がどこかに存在するか

## 期待する結果

上記が分かれば、「Coworkのタスクが今どういう状態か」をMac側のデーモンが検知できるようになり、既存のライブアクティビティの仕組みにそのまま乗せられます。hooksが素直に発火するなら一番簡単（設定を足すだけ）。発火しない場合は、3・4で見つけたファイルを監視する専用の仕組みを新たに作ることになります。
