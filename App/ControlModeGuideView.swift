import SwiftUI

/// 操作モードの機能紹介と設定手順。
/// 「何ができるようになるのか」「なぜ既定でオフなのか」「どう設定するのか」を
/// アプリ内だけで理解できるようにする（README を読まなくても設定できるように）
struct ControlModeGuideView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("できるようになること") {
                    row("paperplane", "指示を送る",
                        "セッションに文章を送る。音声入力も使える")
                    row("questionmark.bubble", "質問に答える",
                        "Claude からの質問（AskUserQuestion）に iPhone から回答する")
                    row("terminal", "コマンドを送る",
                        "/compact や /clear などのスラッシュコマンド")
                    row("cpu", "モデルを変える",
                        "Opus / Sonnet / Haiku / Fable を切り替える")
                    row("plus.circle", "新しく始める",
                        "プロジェクトを選んで新規セッションを開始する")
                }

                Section {
                    Label {
                        Text("""
                            これは **Mac 上の Claude Code を実際に動かす**機能です。\
                            Claude Code は設定によってファイルの書き換えやコマンド実行も行うため、\
                            この機能に到達できる相手は、その Mac でほぼ何でもできると考えてください。

                            そのため既定はオフで、下の設定を済ませたときだけ有効になります。
                            """)
                    } icon: {
                        Image(systemName: "exclamationmark.shield")
                            .foregroundStyle(.orange)
                    }
                    .font(.footnote)
                } header: {
                    Text("なぜ既定でオフなのか")
                }

                Section("設定のしかた") {
                    step(1, "Mac で接続トークンを調べる", """
                        Mac のターミナルで次を実行し、表示された値を控えます。

                        python3 -c "import json;print(json.load(open('~/.claudelive/config.json'.replace('~','$HOME')))['authToken'])"
                        """)
                    step(2, "Tailscale を入れる（推奨）", """
                        Mac と iPhone の両方に Tailscale を入れ、同じアカウントでログインします。\
                        Mac 側の設定で「Allow incoming connections」をオンにしてください。

                        同一 Wi-Fi だけで使う場合はこの手順を飛ばせますが、\
                        通信が暗号化されないため、信頼できるネットワークでのみ使ってください。
                        """)
                    step(3, "接続先を入れる", """
                        Mac の Tailscale IP（100. で始まるアドレス）を「接続先」に入力します。\
                        Mac のターミナルで次を実行すると分かります。

                        /Applications/Tailscale.app/Contents/MacOS/Tailscale ip -4
                        """)
                    step(4, "トークンを入れて、操作モードをオンにする", """
                        手順 1 で控えた値を「接続トークン」に貼り付け、\
                        操作モードのスイッチをオンにします。
                        """)
                }

                Section {
                    Text("""
                        Mac 側で `tailscaleOnly` を有効にしている場合は、Tailscale 経由でしか繋がりません\
                        （同一 Wi-Fi でも拒否されます）。手順 2・3 が必須になります。
                        """)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                } header: {
                    Text("補足")
                }
            }
            .navigationTitle("操作モード")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("閉じる") { dismiss() }
                }
            }
        }
    }

    private func row(_ icon: String, _ title: String, _ detail: String) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: icon).foregroundStyle(Color.claudeBrand)
        }
    }

    private func step(_ n: Int, _ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: "\(n).circle.fill")
                .font(.subheadline.bold())
            Text(body)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
        .padding(.vertical, 2)
    }
}
