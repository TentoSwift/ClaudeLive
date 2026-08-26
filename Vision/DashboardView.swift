import SwiftUI

/// メインウィンドウ: セッション一覧 → 詳細（NavigationStack）
struct DashboardView: View {
    @Environment(VisionAppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            List {
                if !model.isConnected {
                    Section {
                        Label(model.lastError ?? "Mac に接続できません",
                              systemImage: "wifi.exclamationmark")
                            .foregroundStyle(.orange)
                        Text("同一ネットワークで Mac のデーモンが動いているか、" +
                             "設定の接続先（Tailscale の IP など）を確認してください")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                Section("Mac のセッション") {
                    if model.sessions.isEmpty && model.isConnected {
                        Text("セッションなし")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(model.sessions) { session in
                        NavigationLink(value: session.id) {
                            SessionRow(session: session)
                        }
                    }
                }
            }
            .navigationTitle("ClaudeLive")
            .navigationDestination(for: String.self) { sessionId in
                VisionSessionDetailView(sessionId: sessionId)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                }
            }
            .sheet(isPresented: $showSettings) {
                VisionSettingsView()
            }
        }
        .task {
            model.startBrowsing()
            model.beginPolling()
            // シミュレータ検証用: 起動引数でタイルを直接開く
            // （visionOS シミュレータは CLI から UI 操作できないため）
            if let index = ProcessInfo.processInfo.arguments.firstIndex(of: "-openTile"),
               index + 1 < ProcessInfo.processInfo.arguments.count {
                openWindow(id: "tile", value: ProcessInfo.processInfo.arguments[index + 1])
            }
        }
        .onDisappear { model.endPolling() }
    }
}

/// 一覧の 1 行。iPhone 版と同じく、ランダムな内部名より会話の中身
/// （直近プロンプト > 最初の指示）を見出しにする
private struct SessionRow: View {
    let session: VisionAppModel.Session

    private var headline: String {
        if !session.lastPrompt.isEmpty { return session.lastPrompt }
        if !session.title.isEmpty { return session.title }
        return session.name.isEmpty ? session.project : session.name
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(headline)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                let status = ClaudeStatus(session.status)
                Label(session.status == "idle" ? "待機" : status.label,
                      systemImage: session.status == "idle" ? "moon.zzz" : status.icon)
                    .font(.caption)
                    .foregroundStyle(session.status == "idle" ? Color.secondary : status.color)
            }
            HStack(spacing: 8) {
                Text(session.project)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !session.currentTool.isEmpty {
                    Text(session.currentTool)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                }
                if session.toolCount > 0 {
                    Text("ツール \(session.toolCount) 回")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                Text(session.startedAt, style: .relative)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
    }
}
