# ClaudeLive Vision — 空間版 仕様書（ドラフト）

Mac で作業しながら Vision Pro を装着しているとき、Claude Code のセッション状態を
**空間に常駐するパネル**として視界の端に置いておくための visionOS アプリ。

> 位置づけ: ClaudeLive（iPhone ライブアクティビティ版）の visionOS クライアント。
> Mac 側デーモン（port 53536）と HTTP API はそのまま使い、**デーモン変更なし**で成立させる。

## コンセプト

- iPhone 版が「**外出先で気づく**」ためのアプリなのに対し、Vision 版は
  「**装着したまま Mac 作業しているとき、視界から Claude の状態が消えない**」ためのアプリ。
- Mac Virtual Display の隣・上・横に、セッションごとの小さなステータスタイルを浮かべる。
- 許可待ち・質問・完了は**色と音**で気づけて、質問にはその場で（視線+タップで）答えられる。

## iPhone 版との根本的な違い（設計判断）

| | iPhone 版 | Vision 版 |
|---|---|---|
| 配送 | APNs push（外出先でも届く） | **HTTP ポーリング**（装着中=同一LAN前提） |
| 表示 | ライブアクティビティ（OSが管理） | 自前のウィンドウ（空間に永続配置） |
| push-to-start | あり | なし（アプリを開いておく前提） |
| 通知 | APNs アラート | アプリ内の音+表示変化（＋ローカル通知） |

visionOS にはライブアクティビティ相当がなく、バックグラウンド実行も当てにできない。
しかし想定ユースケースは「装着して作業中＝アプリはずっと前面にある」なので、
**フォアグラウンドポーリングだけで成立する**。APNs・トークン登録・push-to-start の
複雑さを全部落とせるのが Vision 版の利点。デーモンの `/register` 系は使わない。

## 再利用するもの

- `Shared/DaemonURL.swift` — Bonjour/LAN/Tailscale 並行接続の `daemonRequest()`。
  Foundation + Network のみなのでそのまま visionOS ターゲットに追加できる
- `Shared/MarkdownText.swift` / `MarkdownTable.swift` — 会話の Markdown 描画
- `Shared/ClaudeModel.swift` / `ClaudeBrandColor.swift`
- デーモンの既存エンドポイント（変更なし）:
  - `GET /sessions` — 2秒間隔でポーリングする主データ源。
    `sessionId / name / title / project / status / detail / currentTool / toolCount /
    startedAt / lastPrompt / lastResponse / question / options / questions / model`
  - `GET /messages?session=&limit=` — 会話ビュー
  - `POST /prompt` `/answer` `/command` `/changemodel` `/newsession` `GET /projects` — 操作モード
- App Intents（`Shared/*Intent.swift`）は visionOS では使わず、直接 `daemonRequest` を呼ぶ

## 使わないもの・注意

- `Widget/`（ライブアクティビティ）一式、APNs まわり、`/register` `/question` の保留機構
- 質問回答は iPhone と同じ `POST /answer`（`{sessionId, answers: [[String]], pass}`）。
  デーモンが保留した AskUserQuestion に対して有効。iPhone と Vision の両方から答えた場合は
  早い者勝ち（デーモン側は最初の回答で解決する。競合しても壊れない）
- 認証はアプリ設定で `authToken` を入力（iPhone 版と同じ `daemonAuthToken` の仕組み）。
  操作モードも iPhone 版と同じく**既定オフ**

## 画面構成

### 1. ダッシュボード（メインウィンドウ、WindowGroup "dashboard"）

- セッション一覧。各行: 状態色・プロジェクト名・セッション名・状態（作業中/許可待ち/入力待ち/完了）・
  実行中ツール・経過時間・直近プロンプト1行
- 行タップ → セッション詳細を同ウィンドウ内で push（NavigationStack）
- ツールバー/オーナメント: 接続先表示、新規セッション、設定
- 接続不能時は再接続 UI（手動ホスト入力は `normalizedManualHostPort` を再利用）

### 2. セッション詳細

- 会話ビュー（`GET /messages`、Markdown 描画、下端固定スクロール）
- 質問が来ているときは選択肢ボタンを最上部にカード表示 → `POST /answer`
- 操作モードON時のみ: プロンプト入力欄、スラッシュコマンド、モデル変更メニュー
- 「タイルとして取り出す」ボタン → そのセッションのミニタイルを openWindow

### 3. ミニタイル（WindowGroup "tile", for: String.self = sessionId）★本命

- 1セッション = 1ウィンドウの小型パネル（目安 360×200pt、`.windowResizability(.contentSize)`）
- 表示: 状態色の帯・プロジェクト名・状態・現在ツール・経過時間・
  直近の説明文/返答を 2〜3 行（マーキー不要。visionOS は領域を広げれば済む）
- 質問到着時はタイル内に選択肢ボタンがそのまま出る（視線+タップで即答）
- ユーザーが Mac Virtual Display の周囲に好きなだけ並べて置く。
  visionOS のウィンドウ位置永続化により、再起動後も置いた場所に復元される
- タイルは自分の sessionId のデータだけ AppModel から購読する。
  セッションが終了（done→一覧から消滅）したら「完了」表示に固定し、閉じるボタンを出す
- **3D の Claude マーク**: タイルの一角（目安 80×80pt）に、スターバースト型の
  Claude マークを立体化したもの（円柱スポーク 12 本 + 中心ハブ、RealityKit）を
  表示し、状態を動きで表現する:
    - `working` / `compacting` → **小さく ⇔ 大きくの脈動**（鼓動、1.2 秒周期）
    - `waiting`（入力待ち）/ `idle` → ごくゆっくり回転
    - `permission` / `question` → 速く強い脈動 + 吹き出し
      （吹き出しは質問文の先頭 1 行。v1 は 2D オーバーレイ、
      3D attachment 化は本格モデル差し替えと同じタイミングで検討）
    - `done` → 静止
  - 見た目とロジックは `CharacterPoseView` に閉じており、表現を変えるときは
    このファイルだけ直せばよい
  - アニメーションは RealityKit の FromToByAnimation（autoReverse リピート）で、
    CPU 側のタイマーを使わない。タイルを閉じている間は描画されない

### 4. ステータスオーブ（volumetric、任意 / M4）

- 手のひらサイズの球体オブジェクト。**全セッションを集約した1個**を空間に置く:
  - 全て作業中 → オレンジでゆっくり脈動
  - どれかが許可待ち/質問 → 赤で速く点滅
  - 全て完了/アイドル → 緑で静止
- タップでダッシュボードを開く
- カタチでの知見を適用: **ボリュメトリックシーンは Info.plist のシーンロール指定必須**、
  **複数の `.gesture()` は最初の1つしか効かない**（1つの gesture に統合する）

## 状態と通知

- `status` は iPhone 版と同じ語彙: `working / permission / waiting(入力待ち) / question / done / compacting / idle`
  （実値はデーモンの `SessionState.status` に従う。実装時に突き合わせて確定し、本表を更新）
- 状態遷移の検知はクライアント側の差分比較（前回ポーリング結果と比較）
- 音: 許可待ち・質問・完了への遷移時に短い効果音（AVFoundation、音種は状態別）
- アプリが非アクティブになる場合に備え、遷移時に**ローカル通知**も発行
  （scenePhase が background の間はポーリングが止まるので「最後に見えた状態」までしか出せない、
  という制約は README に明記する）

## ポーリング設計

- `AppModel`（@Observable、単一ソース）が 2 秒間隔で `GET /sessions` を叩き、全ウィンドウが購読
- ウィンドウが何枚あってもポーリングは 1 本（タイルごとに叩かない）
- 会話ビューを開いている間だけ、そのセッションの `GET /messages` を 3 秒間隔で追加ポーリング
- 失敗が 3 回続いたら「接続断」表示に切り替え、指数バックオフ（最大 30 秒）で再試行
- scenePhase == .active の間だけタイマーを動かす

## プロジェクト構成

新規リポジトリにはせず、**ClaudeLive.xcodeproj に visionOS ターゲットを追加**する
（Shared/ の再利用が理由。バンドル ID: `com.tento.ClaudeLive.Vision`）。

```
ClaudeLive/
  Vision/                      # 新規
    ClaudeLiveVisionApp.swift  # WindowGroup: dashboard / tile(for: String) / orb(volumetric)
    VisionAppModel.swift       # ポーリング、セッション配列、状態遷移検知、効果音
    DashboardView.swift
    SessionDetailView.swift
    TileView.swift
    CharacterPoseView.swift   # タイル内キャラクター。v1 はプレースホルダー形状
    OrbView.swift              # M4
    VisionSettingsView.swift   # 接続先・authToken・操作モード
    Info.plist                 # シーンロール（volumetric 用）
```

ターゲット: visionOS 2.0+（ウィンドウ位置永続化と広い空間配置の恩恵を受けるなら 26 推奨。
実機の OS バージョンを確認して決める）。

## マイルストーン

- **M1: 閲覧** — ターゲット追加、`DaemonURL` 再利用で `/sessions` ポーリング、
  ダッシュボード+詳細（読み取り専用）。シミュレータ+実 Mac デーモンで検証可能
- **M2: タイル** — ミニタイル WindowGroup、状態遷移の色/音、ウィンドウ復元確認、
  `CharacterPoseView`（プレースホルダー形状）で状態別ポーズの切り替えを実装
- **M3: 操作** — 操作モード設定、プロンプト送信・質問回答・コマンド・モデル変更・新規セッション
- **M4: オーブ** — volumetric ステータスオーブ（任意）
- **M5: 磨き** — 接続断 UX、Tailscale 手動指定、README 追記

## 検証

- visionOS シミュレータは同一 Mac の loopback でデーモンに届く（`127.0.0.1:53536` は
  認証免除なのでシミュレータからは Bearer 不要で試せる。※実機は LAN 経由なので要トークン）
- 実機 Vision Pro + Mac の実運用検証（Bonjour で見つかること、装着作業しながらの視認性）
- デーモンをモックするより実デーモンに実セッションを立てて検証する方が早い
  （このリポジトリ自体で Claude Code を走らせれば /sessions に現れる）

## やらないこと（v1）

- APNs / push-to-start / バックグラウンド更新
- 複数 Mac の同時接続（接続先は1台。将来の拡張余地としてコードでは host をキーに持つ）
- iPhone の ライブアクティビティミラー表示（visionOS 側では自前 UI に一本化）
