import SwiftUI
import UIKit

/// 通信を一切使わずに初回登録（ペアリング）を行うための画面。
///
/// 通常は iPhone が Bonjour / Tailscale 経由で `POST /register` を叩いて
/// プッシュ用トークンを Mac に渡すが、それには「iPhone から Mac に到達できる」
/// ことが前提になる。Tailscale をまだ入れていない・LAN も使いたくない場合、
/// この画面が生成するコマンドを **Mac 側で実行**すれば同じ登録ができる。
///
/// デーモンの `/register` は loopback からなら認証を免除されるので、
/// Mac のターミナルに貼って実行するだけでよい（ネットワーク越しの通信は発生しない）。
struct ManualPairingView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    /// Mac のターミナルにそのまま貼れる 1 行コマンド
    private var command: String {
        var payload: [String: Any] = ["device": UIDevice.current.name]
        if let token = model.pushToStartToken { payload["pushToStartToken"] = token }
        if let remote = UserDefaults.standard.string(forKey: "remoteDeviceToken") {
            payload["remoteDeviceToken"] = remote
        }
        let json = (try? JSONSerialization.data(withJSONObject: payload))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        // シングルクォートで囲むので、JSON 側の ' はエスケープしておく
        let escaped = json.replacingOccurrences(of: "'", with: #"'\''"#)
        return "curl -sX POST http://127.0.0.1:53536/register -H 'Content-Type: application/json' -d '\(escaped)'"
    }

    private var isReady: Bool { model.pushToStartToken != nil }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("""
                        Tailscale も同一 Wi-Fi も使わずに、この iPhone を Mac に登録できます。\
                        下のコマンドをコピーして、**Mac のターミナルで実行**してください。

                        同じ Apple ID なら、iPhone でコピーしたものを Mac でそのまま貼り付けられます\
                        （ユニバーサルクリップボード）。
                        """)
                    .font(.footnote)
                }

                if isReady {
                    Section("Mac で実行するコマンド") {
                        Text(command)
                            .font(.caption2.monospaced())
                            .textSelection(.enabled)
                        Button {
                            UIPasteboard.general.string = command
                            copied = true
                        } label: {
                            Label(copied ? "コピーしました" : "コマンドをコピー",
                                  systemImage: copied ? "checkmark" : "doc.on.doc")
                        }
                    }
                } else {
                    Section {
                        Label("プッシュトークンの取得を待っています…", systemImage: "hourglass")
                            .foregroundStyle(.secondary)
                        Text("""
                            ライブアクティビティの許可が必要です。設定 → ClaudeLive で\
                            「ライブアクティビティ」がオンになっているか確認してください。\
                            オンにした直後は発行まで少しかかることがあります。
                            """)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                }

                Section("登録されるもの") {
                    LabeledContent("デバイス名", value: UIDevice.current.name)
                    LabeledContent("push-to-start") {
                        Text(model.pushToStartToken.map { String($0.prefix(12)) + "…" } ?? "未取得")
                            .font(.caption.monospaced())
                    }
                    LabeledContent("通知トークン") {
                        Text(UserDefaults.standard.string(forKey: "remoteDeviceToken")
                            .map { String($0.prefix(12)) + "…" } ?? "未取得")
                            .font(.caption.monospaced())
                    }
                }

                Section {
                    Text("""
                        登録できると、Claude Code の開始と同時にライブアクティビティが出るようになります\
                        （更新は APNs 経由なので、以降は Mac に到達できなくても届きます）。

                        指示の送信など**操作**を行いたい場合は、別途「操作モード」の設定が必要です。
                        """)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("手動で登録")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完了") { dismiss() }
                }
            }
        }
    }
}
