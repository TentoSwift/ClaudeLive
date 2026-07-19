import SwiftUI

/// 使用量セクション（ContentView に埋め込む）
struct UsageSection: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Section {
            if let error = model.usageError, model.usageLimits.isEmpty {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            } else if model.usageLimits.isEmpty {
                Text("読み込み中…")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.usageLimits.sorted { $0.sortOrder < $1.sortOrder }) { limit in
                    UsageRow(limit: limit)
                }
                if let fetchedAt = model.usageFetchedAt {
                    Text("更新: \(fetchedAt.formatted(date: .omitted, time: .shortened))")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        } header: {
            Text("Claude の使用量")
        }
    }
}

private struct UsageRow: View {
    let limit: AppModel.UsageLimit

    private var color: Color {
        switch limit.severity {
        case "critical": return .red
        case "warning": return .orange
        default: return .accentColor
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(limit.title)
                    .font(.subheadline)
                if limit.isActive {
                    Text("直近使用中")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(Int(limit.percent.rounded()))%")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(color)
            }
            ProgressView(value: min(max(limit.percent, 0), 100), total: 100)
                .tint(color)
            if let resetsAt = limit.resetsAt {
                Text("リセット: \(resetsAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
    }
}

/// セッション一覧のセクション（ContentView に埋め込む）
struct SessionsSection: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Section("Mac のセッション") {
            if model.remoteSessions.isEmpty {
                Text("セッションなし（Mac に接続できているか確認）")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.remoteSessions) { session in
                    NavigationLink(value: session.id) {
                        SessionRow(session: session)
                    }
                }
            }
        }
    }
}

private struct SessionRow: View {
    let session: AppModel.RemoteSession

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(session.name.isEmpty ? session.project : session.name)
                    .font(.headline)
                Spacer()
                let status = ClaudeStatus(session.status)
                Label(session.status == "idle" ? "待機" : status.label,
                      systemImage: session.status == "idle" ? "moon.zzz" : status.icon)
                    .font(.caption)
                    .foregroundStyle(session.status == "idle" ? Color.secondary : status.color)
            }
            HStack(spacing: 6) {
                Text(session.project)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if session.toolCount > 0 {
                    Text("ツール \(session.toolCount) 回")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            if !session.lastPrompt.isEmpty {
                Text(session.lastPrompt)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}

/// セッション詳細：会話の閲覧（読み取り専用）
struct SessionDetailView: View {
    @EnvironmentObject private var model: AppModel
    let sessionId: String

    @State private var messages: [AppModel.ChatMessage] = []
    @State private var loaded = false

    private var session: AppModel.RemoteSession? {
        model.remoteSessions.first { $0.id == sessionId }
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if !loaded {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .padding()
                    } else if messages.isEmpty {
                        Text("会話履歴を読み込めませんでした")
                            .foregroundStyle(.secondary)
                            .padding()
                    }
                    ForEach(messages) { message in
                        MessageBubble(message: message)
                            .id(message.id)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .onChange(of: messages.count) { _, _ in
                if let last = messages.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
        .navigationTitle(session.map { $0.name.isEmpty ? $0.project : $0.name } ?? "セッション")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await reload()
            loaded = true
            // 表示中は数秒おきに更新（閲覧専用なので Mac 側への書き込みは発生しない）
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(4))
                await reload()
            }
        }
    }

    private func reload() async {
        if let fetched = await model.fetchMessages(sessionId: sessionId) {
            messages = fetched
        }
        await model.loadRemoteSessions()
    }
}

private struct MessageBubble: View {
    let message: AppModel.ChatMessage

    var body: some View {
        HStack {
            if message.role == "user" { Spacer(minLength: 40) }
            Group {
                if message.role == "user" {
                    Text(message.text)
                        .font(.subheadline)
                        .foregroundStyle(.white)
                } else {
                    // Claude の返答は Markdown レンダリング
                    MarkdownText(text: message.text)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                message.role == "user"
                    ? Color.accentColor.opacity(0.85)
                    : Color(.secondarySystemBackground),
                in: RoundedRectangle(cornerRadius: 14))
            .textSelection(.enabled)
            if message.role != "user" { Spacer(minLength: 40) }
        }
    }
}
