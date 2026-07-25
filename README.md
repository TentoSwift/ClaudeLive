# ClaudeLive

Mac で動いている **Claude Code の状態を iPhone のライブアクティビティ**（Dynamic Island / ロック画面）に表示するアプリ。

```
┌─ Mac ──────────────────────────────┐      ┌─ Apple ─┐      ┌─ iPhone ────────────┐
│ Claude Code                        │      │         │      │ ClaudeLive.app      │
│   └ hooks ─curl→ claudelive-daemon ─┼─────→│  APNs   │─────→│   └ ライブアクティビティ │
│              (port 53536, launchd) │      │         │      │     (Dynamic Island) │
└────────────────────────────────────┘      └─────────┘      └─────────────────────┘
                 ↑ トークン登録・操作（同一 Wi-Fi の Bonjour、または Tailscale）│
                 └──────────────────────────────────────────────────────┘
```

- **配送は APNs プッシュ**なので、ライブアクティビティの更新自体は外出先でも届く
- **push-to-start**（iOS 17.2+）対応：iPhone でアプリを開いていなくても、Claude Code のセッション開始と同時にライブアクティビティが立ち上がる
- 表示内容: 状態（作業中／許可待ち／入力待ち／完了）・プロジェクト名・セッション名・実行中ツール・経過時間・直近の入力と返答・直近ツールログ・ツール実行数。複数セッションはそれぞれ別のアクティビティになる
- **途中経過のテキストも表示**: Claude がツールを呼ぶ前に書いた説明文を `PreToolUse` のたびに transcript から拾い、最終回答（`Stop` イベント）を待たずに随時ライブアクティビティへ反映する。
  ⚠️ transcript は非同期書き込みのため、表示が1手遅れる（直前の発言になる）ことがある。Claude Code hooks には「テキストを書いた瞬間」を伝える専用イベントが無いための現実的な妥協
- **長いテキストはマーキー表示**（質問文・入力・返答）：1行に収まらない場合、公開 API のみで実現した独自のフォントマスク方式コマ送りアニメで横スクロールする
  （[Kyome22/AnimationLimitBreaker](https://github.com/Kyome22/AnimationLimitBreaker) を移植。原理は `Widget/Animation/FrameAnimation.swift` のコメント参照）。
  **1周流したら静止表示に切り替わり**、新しいテキストが来ると再び1周流れる。
  ウィジェット側は時間経過を自力監視できないため、この切り替え判断は Mac 側デーモンがタイマー（`marqueeSettleDelay`, 既定2.6秒）で行い、専用の軽い push で伝える
- 許可待ち・入力待ち・完了時はアラート付きプッシュ（サウンドあり）。
  **入力待ちはライブアクティビティを残さない**——通知だけ送って終了し、次に実際のやり取り
  （UserPromptSubmit）があるまで再表示しない（許可待ちは引き続き表示され続ける）
- **接続断の自動検知**: `working`/`compacting` のまま 15 分フックが届かなければ（ネットワーク断・Claude Code のクラッシュ等）、Mac 側から能動的にライブアクティビティを終了させる。長時間のビルド等を誤検知しないよう余裕を持たせている
- **スリープ・シャットダウンの即時検知**: 上記の 15 分待ちとは別に、`NSWorkspace` の `willSleepNotification`/`willPowerOffNotification` を監視し、**Mac がスリープ／シャットダウンする瞬間**に全セッションのライブアクティビティを即座に終了させる（`done` 以外の状態が対象）
- アプリ内の会話表示は **Markdown レンダリング**対応（見出し・箇条書き・番号リスト・コードブロック・引用・強調・インラインコード。表は非対応で段落として表示）
- アプリから **セッション一覧・会話の閲覧**ができる（同一 Wi-Fi、または Tailscale 経由で外出先からも）
- **iPhone / Apple Watch からセッションを操作できる**：指示の送信、スラッシュコマンド送信、
  モデル変更、新規セッションの開始。⚠️ これは Mac 上の Claude Code に任意の指示を実行させる機能なので、
  必ず[セキュリティ](#セキュリティ)を読んでから使うこと
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
| `POST /question` | AskUserQuestion の PreToolUse フック専用。iPhone 回答待ちで保留 |
| `POST /answer` | iPhone の回答ボタン（App Intent）からの `{sessionId, answers, pass}` |
| `POST /prompt` | **セッションに指示を送る**（画面ロック中は `claude -p --resume`、通常は Claude アプリへキー入力） |
| `POST /command` | **スラッシュコマンドを送る**（`/compact` など） |
| `POST /changemodel` | **モデルを変更**（`/model <id>` の送信） |
| `POST /newsession` | **新規セッションを開始**（指定 cwd で `claude -p`） |
| `GET /projects` | 新規セッションを開始できるプロジェクト（過去に使った cwd）一覧 |
| `POST /reset` | トークン・開始フラグを全クリア（表示が壊れたときの脱出口） |
| `GET /status` | デバッグ用状態 |

`/hook` `/question` を除く全エンドポイントは、**loopback 以外からのアクセスに
`Authorization: Bearer <authToken>` を要求**する（[セキュリティ](#セキュリティ)参照）。

## 構成

| パス | 役割 |
|---|---|
| `App/` | iOS アプリ本体。トークン監視と Mac への登録、ローカルテスト UI |
| `Widget/` | ライブアクティビティの表示（ロック画面 + Dynamic Island） |
| `Shared/ClaudeActivityAttributes.swift` | ContentState 定義。**デーモンの content-state と対応。変えたら両方更新** |
| `mac/ClaudeLiveDaemon.swift` | Mac 側デーモン。hooks 受信 → APNs 送信。依存ライブラリなし |
| `mac/install.sh` | デーモンのビルド・launchd 常駐化・hooks 設定を一括実行 |

## 事前準備（fork する場合）

自分の環境用に以下を書き換えてください：

- `ClaudeLive.xcodeproj` の **DEVELOPMENT_TEAM** → 自分の Team ID
- バンドル ID **`com.tento.ClaudeLive`** / **`com.tento.ClaudeLive.Widget`** → 自分のものに
- `mac/com.tento.claudelive.plist` の launchd ラベルはそのままでも動くが、変えるなら
  `install.sh` 内の参照も合わせる

### Apple Developer Program に登録していない場合

**ライブアクティビティの自動表示だけは使えませんが、それ以外はすべて使えます。**

APNs キー（`.p8`）の作成には**有料の Apple Developer Program（年 $99）が必須**で、
無料の Apple ID（Personal Team）では Push Notifications の capability を
プロビジョニングできません。ただしこのアプリの機能のうち、Mac との通信は
すべて素の HTTP なので **APNs とは独立して動きます**。

| 機能 | 無料アカウント |
|---|---|
| セッション一覧・会話の閲覧 | ✅ 使える |
| 指示・スラッシュコマンドの送信、モデル変更、新規セッション | ✅ 使える |
| Apple Watch アプリ | ✅ 使える |
| ライブアクティビティ（アプリを開いている間） | ⚠️ アプリから手動で開始する形なら可 |
| **push-to-start**（Claude Code の開始と同時に自動で出る） | ❌ 使えない |
| **バックグラウンド更新**（アプリを閉じていても更新され続ける） | ❌ 使えない |

無料アカウントで使う場合の変更点：

1. `App/ClaudeLive.entitlements` から `aps-environment` を削除する
   （残したままだと Xcode がプロビジョニングに失敗する）
2. `~/.claudelive/config.json` の `keyId` / `teamId` / `p8Path` は未設定のままでよい。
   デーモンは APNs の送信に失敗してもログに残すだけで動き続ける（HTTP API は正常）
3. Xcode の Signing で **Personal Team** を選ぶ。無料プロビジョニングは
   **7 日で失効する**ため、週に一度 Xcode から入れ直す必要がある

> 「Claude Code が止まったのに気づける」という本アプリの主目的は push-to-start と
> バックグラウンド更新に依存しているため、無料アカウントでは
> 「iPhone から Mac の Claude Code を見る・操作するリモコン」として使う形になります。

## セットアップ

### 1. APNs 認証キー（.p8）を用意

> ライブアクティビティを自動表示・自動更新するために必要。
> 有料の Apple Developer Program が要る（無料アカウントの場合は
> 「Apple Developer Program に登録していない場合」を参照し、この手順は飛ばす）。

1. [Apple Developer → Keys](https://developer.apple.com/account/resources/authkeys/list) で **Apple Push Notifications service (APNs)** を有効にしたキーを作成
2. `.p8` をダウンロードして `~/.claudelive/AuthKey.p8` に置く
3. **Key ID**（10 桁）を控える

### 2. Mac 側

```bash
cd ClaudeLive/mac && ./install.sh
```

その後 `~/.claudelive/config.json` の `teamId` / `keyId` を実際の値に書き換え、デーモンを再起動：

```bash
launchctl kickstart -k gui/$(id -u)/com.tento.claudelive
```

`authToken` は初回起動時に自動生成される。次の手順で使うので控えておく：

```bash
python3 -c "import json;print(json.load(open('$HOME/.claudelive/config.json'))['authToken'])"
```

### 3. iPhone 側

`ClaudeLive.xcodeproj` を Xcode で開く（`xed ClaudeLive.xcodeproj`）。
実機を選んで Run（自動署名。App ID の Push Notifications capability は entitlements から自動で付く）。

アプリの「Mac との接続」で、**接続トークン**に上で控えた `authToken` を入力する
（これが無いとデーモンに 401 で弾かれる）。
Bonjour で Mac を自動発見してトークンを登録する（「登録成功」表示を確認）。
見つからない場合は Mac の IP を手動指定。

### 4. 動作確認

Claude Code で何か作業を始めると、iPhone にライブアクティビティが出る。

```bash
# デーモンの状態
curl -s http://127.0.0.1:53536/status | python3 -m json.tool
# ログ
tail -f ~/.claudelive/daemon.log
```

### 5. （任意）Tailscale で外出先・モバイル回線から使う

Bonjour は同一 LAN でしか効かないため、Wi-Fi を離れると Mac に到達できず
セッション一覧の取得や指示の送信ができなくなる（**ライブアクティビティの更新自体は
APNs 経由なので外出先でも届く** — 届かないのは iPhone → Mac の操作系）。

[Tailscale](https://tailscale.com/) で Mac と iPhone を同じ tailnet に入れると、
モバイル回線からでも操作できるようになる。

1. Mac と iPhone の両方に Tailscale を入れ、**同じアカウントでログイン**する
2. Mac 側の設定で **「Allow incoming connections」を有効**にする
   （オフだと tailnet 内からの接続が全て拒否され、繋がらない）
3. Mac の Tailscale IP（`100.x.x.x`）を調べる

   ```bash
   /Applications/Tailscale.app/Contents/MacOS/Tailscale ip -4
   ```

4. iPhone アプリの「Mac との接続 → 手動指定」にその IP を入力する
   （ポートは省略可。`100.x.x.x` だけでよい）

アプリは Bonjour・直近の LAN IP・手動指定の3経路を**同時に**試して最初に成功したものを使うので、
自宅 Wi-Fi では Bonjour、外ではこの手動指定が自動的に効く（切り替え操作は不要）。

⚠️ Tailscale 経由でも**通信は平文 HTTP** のままなので、[セキュリティ](#セキュリティ)も読むこと。

## 仕組みのメモ

- hooks（SessionStart / UserPromptSubmit / PreToolUse / PostToolUse / Notification / Stop / PreCompact / SessionEnd）が
  イベント JSON を `curl` で `127.0.0.1:53536/hook` に転送する（`install_hooks.py` が `~/.claude/settings.json` に追記）
- デーモンはセッションごとに状態を持ち、push-to-start → update → end を APNs に送る。
  PreToolUse の連打は 1 秒間隔にまとめる
- content-state の `Date` は ActivityKit のデフォルト JSONDecoder 仕様に合わせて
  **2001-01-01 基準の秒数**で送る（`timeIntervalSinceReferenceDate`）
- `apnsEnvironment` は Xcode から入れたビルドなら `development`（サンドボックス）、
  TestFlight / App Store 配布なら `production`。**環境が合わないと `BadDeviceToken` になる**

## セキュリティ

このデーモンは **Mac 上の Claude Code を操作できる API** を持つ。Claude Code は設定次第で
ファイル書き込みやシェル実行を行うため、**この API に到達できる＝その Mac でほぼ任意の操作ができる**
と考えて扱うこと。

### 認証

`~/.claudelive/config.json` の `authToken`（初回起動時に自動生成、`chmod 600`）による
共有シークレット認証がある。

- **loopback (127.0.0.1) は免除** — Claude Code の hooks が `curl` で叩くため
- **それ以外（LAN / Tailscale）はトークン必須** — 無い・違う場合は `401 Unauthorized`
- iPhone 側はアプリの「Mac との接続 → 接続トークン」に同じ値を入力する

トークンを変えたいときは `config.json` の `authToken` を書き換えて
`launchctl kickstart -k gui/$(id -u)/com.tento.claudelive` で再起動する。

### Tailscale 限定モード（推奨）

`config.json` に `"tailscaleOnly": true` を入れて再起動すると、
**loopback と Tailscale (100.64.0.0/10) 以外からの接続を、トークン検証より前に切断**する。
あわせて Bonjour の広告も止める（LAN 専用の仕組みなのでこのモードでは無意味なため）。

```jsonc
// ~/.claudelive/config.json
{ "tailscaleOnly": true }
```

正しいトークンを持っていても LAN 側からは一切繋がらなくなるので、
信頼できない Wi-Fi（カフェ・学内など）に繋ぐ端末ではこちらを推奨。

**前提**: iPhone アプリの「手動指定」に Mac の Tailscale IP が入っていること。
Bonjour が止まるため、これが未設定だとアプリから到達できなくなる。

### 残っている弱点

- **通信は平文 HTTP**（TLS なし）。APNs への送信だけが HTTPS。
  同一ネットワークで通信を傍受できる相手には、会話の内容とトークンが見える。
  Tailscale 経由なら WireGuard で暗号化されるため、上記の限定モードを使うとこの弱点も緩和される
- `tailscaleOnly` が false のときは**全インターフェースで待ち受け**、さらに Bonjour で
  `_claudelive._tcp` として自分の存在を LAN に広告している
- `.p8` 秘密鍵と APNs トークンは `~/.claudelive/` に平文で置かれる

### デーモンが Mac 上で行う操作

- `osascript` でクリップボードの読み書き、Claude アプリの前面化、⌘V / Enter のキー入力
  （そのためアクセシビリティ権限が必要）
- `claude -p` / `claude -p --resume` のプロセス起動
- `~/.claude/` 配下の transcript / セッションレジストリの読み取り

## 制約・注意

- **per-activity トークンの登録に iPhone ⇔ Mac の疎通が必要**。
  アクティビティが push-to-start で立ち上がった直後、iOS がアプリをバックグラウンド起動して
  更新用トークンを発行する。これを Mac に届けられないと更新が送れないので、
  セッション開始の時点で **iPhone が Mac に到達できる**必要がある
  （同一 Wi-Fi、またはセットアップ手順 5 の Tailscale が繋がっていること。
  その後の update / end は APNs 経由なのでどこにいても届く）
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
