# ClaudeLive セットアップ指示書（Claude Code 用）

このファイルは **Claude Code に読ませてセットアップを代行させる**ためのものです。
人間向けの説明は [README.md](README.md) にあります。

使い方: このリポジトリを clone し、そのディレクトリで Claude Code を起動して

```
SETUP_WITH_CLAUDE.md の手順でセットアップして
```

と伝えてください。

---

# ここから下は Claude Code への指示

あなたはこのリポジトリ（ClaudeLive）のセットアップを代行します。
以下を**順番に**実行してください。

## 全体像

ClaudeLive は 3 つの部品からなります。

1. **Mac デーモン** — Claude Code の hooks を受け、APNs にプッシュを送る（あなたが構築できる）
2. **iOS / watchOS アプリ** — Xcode で実機にインストールする（**人間にしかできない**）
3. **APNs 認証キー** — Apple Developer で発行する（**人間にしかできない**）

**あなたができるのは 1 だけです。** 2 と 3 は人間に依頼してください。
勝手に代替手段を探したり、できないことを「やった」と報告したりしないこと。

## 重要な原則

- **各ステップで検証してから次へ進む。** 「実行した」ではなく「動いていることを確認した」を報告する
- **失敗したら止まって報告する。** 勝手に別の方法を試して深追いしない
- **人間の判断が要る箇所では必ず尋ねる。** 特にセキュリティ設定（後述）は独断で決めない
- **秘密情報を出力しない。** `authToken` や `.p8` の中身をチャットに書かない。
  ユーザーに伝える必要があるときは「取得コマンド」を案内する

---

## ステップ 0: 前提の確認

以下を確認し、足りないものがあれば報告して止まってください。

```bash
sw_vers -productVersion          # macOS のバージョン
swift --version                  # デーモンのビルドに必要
python3 --version                # hooks 設定スクリプトに必要
ls ~/.claude/settings.json       # Claude Code が設定済みか
```

`~/.claude/settings.json` が無い場合、Claude Code のフック設定先が無いということです。
Claude Code を一度起動してもらってください。

## ステップ 1: Mac デーモンを構築する

```bash
cd mac && ./install.sh
```

これは次を行います。

- デーモンをビルドして `~/.claudelive/claudelive-daemon` に配置
- コード署名（後述の注意あり）
- launchd に登録して常駐化
- `~/.claude/settings.json` に hooks を追記（`settings.json.claudelive.bak` にバックアップを取る）

**検証**: 次が JSON を返せば成功です。

```bash
curl -s http://127.0.0.1:53536/status | python3 -m json.tool
```

返らない場合は `tail -30 ~/.claudelive/daemon.log` を見て原因を報告してください。
（`daemon.stdout.log` ではなく **`daemon.log`** を見ること。前者は launchd 経由で
バッファされ、書き込みが遅れます）

## ステップ 2: コード署名の確認（任意・人間の作業）

指示の送信・質問への回答はすべて `claude -p --resume` のヘッドレス実行で行うため、
アクセシビリティ権限は不要です。ただし ad-hoc 署名は再ビルドのたびにハッシュが
変わるため、通知など他の OS 権限がバイナリに紐づく場合に再付与が必要になることが
あります。安定させたい場合、人間に次を依頼してください（必須ではありません）。

> キーチェーンアクセス → 証明書アシスタント → 自分に証明書を作成
> 　名前: `ClaudeLive Daemon Signing` / 証明書のタイプ: コード署名
> を作成後、`cd mac && ./install.sh` を再実行してください。

`ClaudeLive Daemon Signing` が使われた旨が出ていれば、この手順は不要です。

## ステップ 3: セキュリティ設定（必ず人間に確認する）

**このデーモンは Mac 上の Claude Code を操作できる API を持ちます。**
Claude Code はファイル書き込みやシェル実行を行うため、**この API に到達できる
＝その Mac でほぼ任意の操作ができる**と考えてください。

`authToken` は初回起動時に自動生成され、loopback 以外からのアクセスに要求されます。
加えて `tailscaleOnly` を有効にすると、loopback と Tailscale 以外の接続を
トークン検証より前に切断します（LAN 側の攻撃面が無くなる）。

**独断で決めず、人間に次を尋ねてください。**

> `tailscaleOnly` を有効にしますか？
> - 有効（推奨）: LAN からは一切繋がらなくなる。iPhone から使うには Tailscale が必要
> - 無効: 同一 Wi-Fi なら Bonjour で繋がる。ただし通信は平文 HTTP で、
>   トークンを知られると Mac を操作されうる

有効にする場合:

```bash
python3 - <<'PY'
import json, os
p = os.path.expanduser("~/.claudelive/config.json")
c = json.load(open(p))
c["tailscaleOnly"] = True
json.dump(c, open(p, "w"), indent=2, ensure_ascii=False)
print("tailscaleOnly = true にしました")
PY
launchctl kickstart -k "gui/$(id -u)/com.tento.claudelive"
```

## ステップ 4: APNs キー（人間の作業・ライブアクティビティに必須）

ライブアクティビティの自動表示・更新には **有料の Apple Developer Program** が要ります。

**無料アカウントの場合はこのステップを飛ばしてください。**
セッションの閲覧と操作は使えますが、ライブアクティビティは動きません
（詳細は README の「Apple Developer Program に登録していない場合」）。

人間に次を依頼してください。

1. [Apple Developer → Keys](https://developer.apple.com/account/resources/authkeys/list) で
   **APNs** を有効にしたキーを作成
2. `.p8` を `~/.claudelive/AuthKey.p8` に配置
3. **Key ID**（10 桁）と **Team ID**（10 桁）を教えてもらう

受け取ったら設定します。`<KEY_ID>` / `<TEAM_ID>` を実際の値に置き換えて実行してください
（あなたの実行環境は非対話なので、`input()` を使うスクリプトは `EOFError` で失敗します。
必ずこの引数渡しの形にすること）。

```bash
python3 - "<KEY_ID>" "<TEAM_ID>" <<'PY'
import json, os, sys
p = os.path.expanduser("~/.claudelive/config.json")
c = json.load(open(p))
c["keyId"], c["teamId"] = sys.argv[1], sys.argv[2]
json.dump(c, open(p, "w"), indent=2, ensure_ascii=False)
print("設定しました:", {k: c[k] for k in ("keyId", "teamId")})
PY
launchctl kickstart -k "gui/$(id -u)/com.tento.claudelive"
```

**検証**: `ls -la ~/.claudelive/AuthKey.p8` でキーが存在すること。

## ステップ 5: iOS アプリ（人間の作業）

**あなたにはできません。** 人間に依頼してください。

> 1. `xed ClaudeLive.xcodeproj` で Xcode を開く
> 2. 各ターゲットの **Signing & Capabilities** で自分の Team を選ぶ
>    （fork した場合はバンドル ID も `com.tento.*` から自分のものへ変更）
> 3. iPhone を繋いで Run

ビルドが通るかだけは、あなたも確認できます（署名は別問題なので失敗しても切り分けること）。

```bash
xcodebuild build -scheme ClaudeLive -destination 'generic/platform=iOS' 2>&1 | tail -5
```

## ステップ 6: 登録

アプリを開くと Bonjour で Mac を自動発見して登録します。

`tailscaleOnly` を有効にした場合や同じ Wi-Fi に繋げない場合は、
アプリの「**通信を使わずに登録する**」を使うよう案内してください。
表示されたコマンドを Mac のターミナルで実行するだけで登録できます
（`/register` は loopback からなら認証不要なため）。

**検証**:

```bash
curl -s http://127.0.0.1:53536/status | python3 -c "import json,sys; d=json.load(sys.stdin); print('登録端末:', d.get('devices')); print('push-to-start:', d.get('hasPushToStartToken'))"
```

`hasPushToStartToken` が `true` なら成功です。

## ステップ 7: 動作確認

Claude Code で何か作業をしてもらい、iPhone にライブアクティビティが出れば完了です。

```bash
tail -20 ~/.claudelive/daemon.log
```

出ない場合の切り分け:

| 症状 | 見るところ |
|---|---|
| フックが届いていない | `~/.claude/settings.json` の hooks 設定と `daemon.log` |
| `APNs 403 InvalidProviderToken` | `config.json` の `teamId` / `keyId` と `.p8` の組 |
| `APNs 400 BadDeviceToken` | `apnsEnvironment`（Xcode から入れたなら `development`） |
| 「認証されていないリクエストを拒否」 | アプリ側の接続トークン。理由がログに併記される |
| 「許可されない接続元を切断」 | `tailscaleOnly` が有効。Tailscale 経由で繋ぐ |

## 最後に報告すること

完了したら、次を**事実に基づいて**報告してください。推測で埋めないこと。

- 各ステップの結果（成功／失敗／スキップ）と、その根拠になった確認コマンドの出力
- 人間の作業として残っているもの
- `tailscaleOnly` をどちらにしたか
- ライブアクティビティが実際に出たかどうか（未確認なら「未確認」と書く）

## 任意: 操作モードについて案内する

iPhone から指示を送る・質問に答える機能は **既定でオフ**です。
使いたい場合は、アプリの「操作モード」をオンにし、接続先と接続トークンを
入力する必要があると案内してください。

接続トークンの取得コマンド（**出力をチャットに貼らず、人間に直接実行してもらう**）:

```bash
python3 -c "import json,os;print(json.load(open(os.path.expanduser('~/.claudelive/config.json')))['authToken'])"
```
