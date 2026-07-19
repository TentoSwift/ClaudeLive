# ClaudeLive

Mac で動いている **Claude Code の状態を iPhone のライブアクティビティ**（Dynamic Island / ロック画面）に表示するアプリ。

```
┌─ Mac ──────────────────────────────┐      ┌─ Apple ─┐      ┌─ iPhone ────────────┐
│ Claude Code                        │      │         │      │ ClaudeLive.app      │
│   └ hooks ─curl→ claudelive-daemon ─┼─────→│  APNs   │─────→│   └ ライブアクティビティ │
│              (port 53536, launchd) │      │         │      │     (Dynamic Island) │
└────────────────────────────────────┘      └─────────┘      └─────────────────────┘
                 ↑ トークン登録（同一 Wi-Fi / Bonjour: _claudelive._tcp）│
                 └──────────────────────────────────────────────────────┘
```

- **配送は APNs プッシュ**なので、ライブアクティビティの更新自体は外出先でも届く
- **push-to-start**（iOS 17.2+）対応：iPhone でアプリを開いていなくても、Claude Code のセッション開始と同時にライブアクティビティが立ち上がる
- 表示内容: 状態（作業中／許可待ち／入力待ち／完了）・プロジェクト名・セッション名・実行中ツール・経過時間・直近の入力と返答・直近ツールログ・ツール実行数。複数セッションはそれぞれ別のアクティビティになる
- 許可待ち・入力待ち・完了時はアラート付きプッシュ（サウンドあり）
- **接続断の自動検知**: `working`/`compacting` のまま 15 分フックが届かなければ（Mac のスリープ・ネットワーク断・Claude Code のクラッシュ等）、Mac 側から能動的にライブアクティビティを終了させる。長時間のビルド等を誤検知しないよう余裕を持たせている
- アプリ内の会話表示は **Markdown レンダリング**対応（見出し・箇条書き・番号リスト・コードブロック・引用・強調・インラインコード。表は非対応で段落として表示）
- アプリから **セッション一覧・会話の閲覧（読み取り専用）・使用量（5時間/週間制限）** を確認できる（同一 Wi-Fi 時のみ）。
  セッションへの自由な返信・書き込みはできない（安全のため意図的に非搭載）
- **Claude からの質問（AskUserQuestion）に iPhone から回答できる**：
  質問が来ると選択肢ボタンがライブアクティビティに表示され、タップで回答が Mac へ届く。
  仕組みは hooks の公式 decision 機構のみ — AskUserQuestion の PreToolUse フックをデーモンが
  最大 `questionHoldSeconds`（既定 60 秒）保留し、iPhone のボタン（App Intent）からの回答を
  `permissionDecision: deny` + 理由として返すと、Claude はそれを回答として続行する。
  タイムアウトか「Macで回答する」ボタンで即座に通常の Mac 表示に戻る。
  ⚠️ 保留中は Mac 側に質問が出ない（最大でその秒数待たされる）trade-off がある

### デーモンのエンドポイント

| エンドポイント | 役割 |
|---|---|
| `POST /hook` | Claude Code hooks からのイベント受信 |
| `POST /register` | iPhone からのトークン登録（生存アクティビティのスナップショット） |
| `GET /sessions` | 対話セッション一覧（`~/.claude/sessions` レジストリ + フック状態のマージ） |
| `GET /messages?session=<id>&limit=N` | transcript JSONL から会話テキストを抽出（読み取り専用） |
| `GET /usage` | Claude Code の使用量（5時間/週間制限）。60秒キャッシュ |
| `POST /question` | AskUserQuestion の PreToolUse フック専用。iPhone 回答待ちで保留 |
| `POST /answer` | iPhone の回答ボタン（App Intent）からの `{sessionId, answer, pass}` |
| `POST /reset` | トークン・開始フラグを全クリア（表示が壊れたときの脱出口） |
| `GET /status` | デバッグ用状態 |

## 構成

| パス | 役割 |
|---|---|
| `App/` | iOS アプリ本体。トークン監視と Mac への登録、ローカルテスト UI |
| `Widget/` | ライブアクティビティの表示（ロック画面 + Dynamic Island） |
| `Shared/ClaudeActivityAttributes.swift` | ContentState 定義。**デーモンの content-state と対応。変えたら両方更新** |
| `mac/ClaudeLiveDaemon.swift` | Mac 側デーモン。hooks 受信 → APNs 送信。依存ライブラリなし |
| `mac/install.sh` | デーモンのビルド・launchd 常駐化・hooks 設定を一括実行 |

## 事前準備（fork する場合）

このプロジェクトは Apple Developer アカウント（実機ビルド + APNs 用）が必要です。
自分の環境用に以下を書き換えてください：

- `ClaudeLive.xcodeproj` の **DEVELOPMENT_TEAM**（現状 `LV3H7Q68W6`）→ 自分の Team ID
- バンドル ID **`com.tento.ClaudeLive`** / **`com.tento.ClaudeLive.Widget`** → 自分のものに
- `mac/com.tento.claudelive.plist` の launchd ラベルはそのままでも動くが、変えるなら
  `install.sh` 内の参照も合わせる

> 使用量表示機能は、この Mac にインストール済みの Claude Code が Keychain に保存する
> OAuth 認証情報を読み取って Anthropic の usage API を叩きます。あくまで**自分の
> 認証情報を自分のためにローカルで使う**用途です。

## セットアップ

### 1. APNs 認証キー（.p8）を用意

1. [Apple Developer → Keys](https://developer.apple.com/account/resources/authkeys/list) で **Apple Push Notifications service (APNs)** を有効にしたキーを作成
2. `.p8` をダウンロードして `~/.claudelive/AuthKey.p8` に置く
3. **Key ID**（10 桁）を控える

### 2. Mac 側

```bash
cd ClaudeLive/mac && ./install.sh
```

その後 `~/.claudelive/config.json` の `keyId` を実際の Key ID に書き換え、デーモンを再起動：

```bash
launchctl kickstart -k gui/$(id -u)/com.tento.claudelive
```

### 3. iPhone 側

`ClaudeLive.xcodeproj` を Xcode で開く（`xed ClaudeLive.xcodeproj`）。
実機を選んで Run（自動署名。App ID の Push Notifications capability は entitlements から自動で付く）。
アプリを開くと Bonjour で Mac を自動発見してトークンを登録する（「登録成功」表示を確認）。
見つからない場合は Mac の IP を手動指定。

### 4. 動作確認

Claude Code で何か作業を始めると、iPhone にライブアクティビティが出る。

```bash
# デーモンの状態
curl -s http://127.0.0.1:53536/status | python3 -m json.tool
# ログ
tail -f ~/.claudelive/daemon.log
```

## 仕組みのメモ

- hooks（SessionStart / UserPromptSubmit / PreToolUse / PostToolUse / Notification / Stop / PreCompact / SessionEnd）が
  イベント JSON を `curl` で `127.0.0.1:53536/hook` に転送する（`install_hooks.py` が `~/.claude/settings.json` に追記）
- デーモンはセッションごとに状態を持ち、push-to-start → update → end を APNs に送る。
  PreToolUse の連打は 1 秒間隔にまとめる
- content-state の `Date` は ActivityKit のデフォルト JSONDecoder 仕様に合わせて
  **2001-01-01 基準の秒数**で送る（`timeIntervalSinceReferenceDate`）
- `apnsEnvironment` は Xcode から入れたビルドなら `development`（サンドボックス）、
  TestFlight / App Store 配布なら `production`。**環境が合わないと `BadDeviceToken` になる**

## 制約・注意

- **per-activity トークンの登録に iPhone ⇔ Mac の疎通が必要**。
  アクティビティが push-to-start で立ち上がった直後、iOS がアプリをバックグラウンド起動して
  更新用トークンを発行する。これを Mac に届けられないと更新が送れないので、
  実質「セッション開始時に iPhone が Mac と同じネットワークにいる」ことが前提
  （その後の update / end は APNs 経由なのでどこにいても届く）
- push-to-start には OS 側のレート制限（budget）がある。短時間に大量のセッションを
  作ると開始プッシュが抑制されることがある
- ライブアクティビティは最長 8 時間で OS に終了される

## トラブルシューティング

| 症状 | 確認すること |
|---|---|
| アクティビティが出ない | `/status` で `hasPushToStartToken` が true か。false ならアプリを開いて再登録 |
| `APNs 403 InvalidProviderToken` | `config.json` の `teamId` / `keyId` と .p8 の組が正しいか |
| `APNs 400 BadDeviceToken` | `apnsEnvironment` とアプリの配布経路（Xcode= development）が一致しているか |
| 開始は出るが更新されない | アプリの「実行中のライブアクティビティ」で鍵アイコンが緑か（per-activity トークン登録済みか） |
| hooks が発火していない | `~/.claude/settings.json` の hooks 設定と `daemon.log` を確認 |
