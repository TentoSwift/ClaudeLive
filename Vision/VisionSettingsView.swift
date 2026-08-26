import SwiftUI

/// 接続先・認証トークン・操作モードの設定。
/// UserDefaults のキーは iPhone 版と同じ（manualHost / daemonAuthToken /
/// controlModeEnabled）なので、Shared/DaemonURL.swift の daemonRequest が
/// そのまま読んでくれる
struct VisionSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("manualHost") private var manualHost = ""
    @AppStorage(daemonAuthTokenKey) private var daemonToken = ""
    @AppStorage(controlModeKey) private var controlMode = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Mac のアドレス（例 100.x.x.x）", text: $manualHost)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                } header: {
                    Text("接続先")
                } footer: {
                    Text("同一 Wi-Fi なら Bonjour で自動発見されるため空欄でよい。" +
                         "Mac が Tailscale 限定モードのときは Tailscale の IP を入れる")
                }

                Section {
                    SecureField("接続トークン", text: $daemonToken)
                } header: {
                    Text("認証")
                } footer: {
                    Text("Mac の ~/.claudelive/config.json の authToken と同じ値。" +
                         "空のままだとデーモンに 401 で拒否される（シミュレータの " +
                         "loopback 接続だけは免除）")
                }

                Section {
                    Toggle("操作モード", isOn: $controlMode)
                } footer: {
                    Text("指示の送信・質問への回答・コマンド送信を有効にする。" +
                         "Mac 上の Claude Code を実際に動かす機能のため既定はオフ")
                }
            }
            .navigationTitle("設定")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完了") {
                        manualHost = manualHost.isEmpty
                            ? "" : normalizedManualHostPort(manualHost)
                        dismiss()
                    }
                }
            }
        }
        .frame(minWidth: 480, minHeight: 420)
    }
}
