import ActivityKit
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @AppStorage("manualHost") private var manualHost = ""
    /// Mac デーモンが要求する共有シークレット（config.json の authToken）
    @AppStorage(daemonAuthTokenKey) private var daemonToken = ""
    @State private var path: [String] = []

    // ライブアクティビティのタップから開いた質問への回答。
    // アプリの画面へ遷移させず、ショートカットの「入力を要求」のような
    // システムのアラート（テキストフィールド付き）でその場で答えられるようにする
    @State private var showAnswerAlert = false
    @State private var alertSessionId: String?
    @State private var alertQuestion = ""
    @State private var alertOptions: [String] = []
    @State private var alertAnswerText = ""

    var body: some View {
        NavigationStack(path: $path) {
            Form {
                mirrorSection
                statusSection
                SessionsSection()
                serverSection
                experimentalSection
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
        .onChange(of: model.focusSessionId) { _, sessionId in
            guard let sessionId else { return }
            model.focusSessionId = nil
            Task {
                await model.loadRemoteSessions()
                if let session = model.remoteSessions.first(where: { $0.id == sessionId }),
                   !session.question.isEmpty {
                    alertSessionId = sessionId
                    alertQuestion = session.question
                    alertOptions = session.options
                    alertAnswerText = ""
                    showAnswerAlert = true
                } else {
                    // 質問中でなければ通常どおり会話の詳細画面を開く
                    path = [sessionId]
                }
            }
        }
        .alert(alertQuestion, isPresented: $showAnswerAlert) {
            ForEach(alertOptions, id: \.self) { option in
                Button(option) {
                    Task { await model.answer(sessionId: alertSessionId ?? "", answer: option) }
                }
            }
            TextField("自由入力で回答…", text: $alertAnswerText)
            Button("送信する") {
                guard !alertAnswerText.isEmpty else { return }
                Task { await model.answer(sessionId: alertSessionId ?? "", answer: alertAnswerText) }
            }
            Button("キャンセル", role: .cancel) {}
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
            SecureField("接続トークン", text: $daemonToken)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            LabeledContent("最終登録", value: model.lastRegistration)
            Button("いま登録する") {
                model.registerToServer()
            }
        } header: {
            Text("Mac との接続")
        } footer: {
            Text("""
                同じ Wi-Fi 上の Mac（claudelive-daemon）を Bonjour で自動発見し、プッシュ用トークンを登録します。\
                見つからないときは Mac の IP アドレスを手動指定してください。

                接続トークンは Mac の `~/.claudelive/config.json` の `authToken` の値です。\
                デーモンはこのトークンが一致しないリクエストを拒否します\
                （同じネットワークの第三者に会話を読まれたり、操作されるのを防ぐため）。
                """)
        }
    }

    private var experimentalSection: some View {
        Section {
            Toggle("DI コンパクトのコマ送りアニメーション", isOn: $model.compactAnimated)
        } header: {
            Text("実験的機能")
        } footer: {
            Text("過去にこのアニメーションがライブアクティビティの強制終了を引き起こした不具合があるため、検証用にオン/オフできるようにしています。オフが既定・安定です。切り替えると Mac に即座に伝わり、表示中のライブアクティビティにも反映されます。")
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
            Button("回答アラートのテスト") {
                alertSessionId = "test"
                alertQuestion = "テスト用の質問です。選択肢または自由入力で回答してください"
                alertOptions = ["はい", "いいえ", "保留"]
                alertAnswerText = ""
                showAnswerAlert = true
            }
        } header: {
            Text("ローカルテスト")
        } footer: {
            Text("APNs を使わずにライブアクティビティの見た目を確認できます。マーキーテストは push-to-start budget や AskUserQuestion の hooks 保留を一切使わないので、何度でも試せます。回答アラートのテストは URL スキームやライブアクティビティのタップを介さず、アラート UI 自体だけを直接確認できます。")
        }
    }
}
