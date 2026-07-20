import ActivityKit
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @AppStorage("manualHost") private var manualHost = ""

    var body: some View {
        NavigationStack {
            Form {
                mirrorSection
                statusSection
                SessionsSection()
                serverSection
                tokenSection
                activitiesSection
                testSection
            }
            .navigationTitle("ClaudeLive")
            .navigationDestination(for: String.self) { sessionId in
                SessionDetailView(sessionId: sessionId)
            }
            .refreshable {
                model.refresh()
                model.registerToServer()
            }
            .task {
                await model.loadRemoteSessions()
            }
        }
    }

    @ViewBuilder
    private var mirrorSection: some View {
        if let attributes = model.mirrorAttributes, let state = model.mirrorState {
            Section("ライブアクティビティ") {
                LiveActivityMirrorView(attributes: attributes, state: state)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
            }
        }
    }

    private var statusSection: some View {
        Section("状態") {
            LabeledContent("ライブアクティビティ") {
                if model.activitiesEnabled {
                    Label("有効", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    Label("無効（設定で許可してください）", systemImage: "xmark.circle.fill")
                        .foregroundStyle(.red)
                }
            }
            if let error = model.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    private var serverSection: some View {
        Section {
            if model.discoveredServers.isEmpty {
                Label("Mac を探しています…", systemImage: "magnifyingglass")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.discoveredServers, id: \.self) { name in
                    Label(name, systemImage: "desktopcomputer")
                }
            }
            TextField("手動指定 例: 192.168.1.10:53536", text: $manualHost)
                .keyboardType(.URL)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            LabeledContent("最終登録", value: model.lastRegistration)
            Button("いま登録する") {
                model.registerToServer()
            }
        } header: {
            Text("Mac との接続")
        } footer: {
            Text("同じ Wi-Fi 上の Mac（claudelive-daemon）を Bonjour で自動発見し、プッシュ用トークンを登録します。見つからないときは Mac の IP アドレスを手動指定してください。")
        }
    }

    private var tokenSection: some View {
        Section {
            if let token = model.pushToStartToken {
                VStack(alignment: .leading, spacing: 4) {
                    Text("push-to-start トークン")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(token)
                        .font(.caption2.monospaced())
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
            } else {
                Label("push-to-start トークン取得待ち…", systemImage: "hourglass")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("トークン")
        } footer: {
            Text("このトークンが Mac に登録されると、アプリを開いていなくても Claude Code の開始と同時にライブアクティビティが立ち上がります。")
        }
    }

    private var activitiesSection: some View {
        Section("実行中のライブアクティビティ") {
            if model.activities.isEmpty {
                Text("なし")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.activities) { info in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(info.projectName)
                                .font(.headline)
                            Spacer()
                            Text(info.stateDescription)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        HStack(spacing: 6) {
                            Text(info.sessionId)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Image(systemName: info.hasPushToken ? "key.fill" : "key.slash")
                                .font(.caption2)
                                .foregroundStyle(info.hasPushToken ? .green : .orange)
                        }
                    }
                }
            }
        }
    }

    private var testSection: some View {
        Section {
            Button("テスト用アクティビティを開始") {
                model.startTestActivity()
            }
            Button("テストの状態を切り替え") {
                model.cycleTestActivity()
            }
            Button("マーキーテスト（質問文）") {
                model.testMarqueeQuestion()
            }
            Button("マーキーテスト（入力）") {
                model.testMarqueePrompt()
            }
            Button("マーキーテスト（返答）") {
                model.testMarqueeResponse()
            }
            Button("テストを終了", role: .destructive) {
                model.endTestActivities()
            }
        } header: {
            Text("ローカルテスト")
        } footer: {
            Text("APNs を使わずにライブアクティビティの見た目を確認できます。マーキーテストは push-to-start budget や AskUserQuestion の hooks 保留を一切使わないので、何度でも試せます。")
        }
    }
}
