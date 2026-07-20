import SwiftUI

/// セッション一覧（ルート画面）
struct WatchContentView: View {
    @EnvironmentObject private var model: WatchModel
    @State private var path: [String] = []

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if model.sessions.isEmpty {
                    if model.daemonURL.isEmpty {
                        Text("iPhone の ClaudeLive アプリを一度開くと、Mac の接続先が自動で同期されます")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("セッションなし")
                            .foregroundStyle(.secondary)
                    }
                }
                ForEach(model.sessions) { session in
                    NavigationLink(value: session.id) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(session.name.isEmpty ? session.project : session.name)
                                .font(.headline)
                                .lineLimit(1)
                            Text(statusLabel(session.status))
                                .font(.caption2)
                                .foregroundStyle(statusColor(session.status))
                        }
                    }
                }
                if let error = model.lastError {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            }
            .navigationTitle("ClaudeLive")
            .navigationDestination(for: String.self) { sessionId in
                WatchSessionDetailView(sessionId: sessionId)
            }
        }
        .task {
            model.recheckContext()
            await model.refresh()
            // ライブアクティビティのタップで起動された場合は該当セッションを開く
            if let id = model.focusSessionId {
                model.focusSessionId = nil
                path = [id]
            }
        }
        .onChange(of: model.focusSessionId) { _, id in
            if let id {
                model.focusSessionId = nil
                path = [id]
            }
        }
    }
}

/// セッション詳細。全文のプロンプト・返答・会話と、質問への回答ボタン
struct WatchSessionDetailView: View {
    @EnvironmentObject private var model: WatchModel
    let sessionId: String
    @State private var messages: [WatchModel.Message] = []

    private var session: WatchModel.Session? {
        model.sessions.first { $0.id == sessionId }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                if let session {
                    // 状態行
                    HStack(spacing: 4) {
                        Text(statusLabel(session.status))
                            .font(.headline)
                            .foregroundStyle(statusColor(session.status))
                        if !session.currentTool.isEmpty {
                            Text(session.currentTool)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }

                    // 質問 + 回答ボタン
                    if !session.question.isEmpty {
                        Text(session.question)
                            .font(.footnote)
                        ForEach(session.options, id: \.self) { option in
                            Button {
                                Task { await model.answer(sessionId: sessionId, answer: option) }
                            } label: {
                                Text(option)
                                    .font(.footnote.bold())
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(Color(red: 0.85, green: 0.47, blue: 0.34))
                        }
                    }

                    // 直近のやり取り（省略なしの全文）
                    if !session.lastPrompt.isEmpty {
                        label("入力")
                        Text(session.lastPrompt).font(.footnote)
                    }
                    if !session.lastResponse.isEmpty {
                        label("返答")
                        Text(session.lastResponse).font(.footnote)
                    }
                }

                // 会話履歴
                if !messages.isEmpty {
                    label("会話")
                    ForEach(messages) { message in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(message.role == "user" ? "あなた" : "Claude")
                                .font(.caption2.bold())
                                .foregroundStyle(.secondary)
                            Text(message.text)
                                .font(.footnote)
                        }
                        .padding(.bottom, 3)
                    }
                }
            }
        }
        .navigationTitle(session?.name ?? "セッション")
        .task {
            await model.refresh()
            messages = await model.fetchMessages(sessionId: sessionId)
        }
        .refreshable {
            await model.refresh()
            messages = await model.fetchMessages(sessionId: sessionId)
        }
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(.caption2.bold())
            .foregroundStyle(.secondary)
            .padding(.top, 4)
    }
}

// MARK: - 状態表示（Shared の ClaudeStatus は ActivityKit 依存のため使わず自前で持つ）

func statusLabel(_ status: String) -> String {
    switch status {
    case "working":    return "作業中"
    case "permission": return "許可待ち"
    case "waiting":    return "入力待ち"
    case "question":   return "質問"
    case "done":       return "完了"
    case "error":      return "エラー"
    case "compacting": return "圧縮中"
    default:           return status
    }
}

func statusColor(_ status: String) -> Color {
    switch status {
    case "working", "done": return Color(red: 0.85, green: 0.47, blue: 0.34)
    case "permission":      return .yellow
    case "waiting":         return .cyan
    case "question":        return .indigo
    case "error":           return .red
    case "compacting":      return .purple
    default:                return .secondary
    }
}
