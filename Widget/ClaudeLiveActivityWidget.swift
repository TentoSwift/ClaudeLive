import ActivityKit
import SwiftUI
import WidgetKit

struct ClaudeLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: ClaudeActivityAttributes.self) { context in
            // ロック画面 / 通知バナー
            LockScreenView(context: context)
                .activityBackgroundTint(Color.black.opacity(0.65))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            let status = ClaudeStatus(context.state.status)
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: status.icon)
                        .font(.title2)
                        .foregroundStyle(status.color)
                        .symbolEffect(.pulse, isActive: status == .working)
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    ElapsedTimerText(startedAt: context.state.startedAt)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: 60)
                        .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(spacing: 2) {
                        Text(context.state.sessionName.isEmpty
                             ? context.attributes.projectName
                             : "\(context.attributes.projectName) · \(context.state.sessionName)")
                            .font(.caption.bold())
                            .lineLimit(1)
                        HStack(spacing: 4) {
                            Text(status.label)
                                .font(.caption2)
                                .foregroundStyle(status.color)
                            if !context.state.currentTool.isEmpty {
                                Text(context.state.currentTool)
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 3) {
                        if !context.state.lastResponse.isEmpty {
                            ConversationLine(icon: "sparkle", iconColor: status.color,
                                            text: context.state.lastResponse, maxLines: 2)
                        } else if !context.state.lastPrompt.isEmpty {
                            ConversationLine(icon: "person.fill", iconColor: .secondary,
                                            text: context.state.lastPrompt, maxLines: 2)
                        } else if !context.state.detail.isEmpty {
                            Text(context.state.detail)
                                .font(.footnote)
                                .lineLimit(2)
                                .contentTransition(.opacity)
                        }
                        LogLinesView(logs: context.state.recentLogs, maxLines: 1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
                }
            } compactLeading: {
                Image(systemName: "sparkle")
                    .foregroundStyle(status.color)
            } compactTrailing: {
                Image(systemName: status.icon)
                    .foregroundStyle(status.color)
                    .symbolEffect(.pulse, isActive: status.needsAttention)
            } minimal: {
                Image(systemName: status.icon)
                    .foregroundStyle(status.color)
            }
            .keylineTint(status.color)
        }
    }
}

/// ロック画面・バナーの表示
private struct LockScreenView: View {
    let context: ActivityViewContext<ClaudeActivityAttributes>

    private var status: ClaudeStatus { ClaudeStatus(context.state.status) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // ヘッダ: プロジェクト名・Mac 名・経過時間
            HStack(spacing: 6) {
                Image(systemName: "sparkle")
                    .font(.caption)
                    .foregroundStyle(status.color)
                Text(context.attributes.projectName)
                    .font(.caption.bold())
                    .lineLimit(1)
                Text(context.state.sessionName.isEmpty
                     ? context.attributes.hostName
                     : context.state.sessionName)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                ElapsedTimerText(startedAt: context.state.startedAt)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            // メイン: 状態 + 実行中ツール
            HStack(spacing: 8) {
                Image(systemName: status.icon)
                    .font(.title3)
                    .foregroundStyle(status.color)
                    .symbolEffect(.pulse, isActive: status == .working || status.needsAttention)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(status.label)
                            .font(.headline)
                            .foregroundStyle(status.needsAttention ? status.color : .primary)
                        if !context.state.currentTool.isEmpty {
                            Text(context.state.currentTool)
                                .font(.subheadline.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    if !context.state.detail.isEmpty {
                        Text(context.state.detail)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .contentTransition(.opacity)
                    }
                }
                Spacer(minLength: 0)
            }

            // 直近のやり取り: ユーザー入力 → Claude の返答
            if !context.state.lastPrompt.isEmpty {
                ConversationLine(icon: "person.fill", iconColor: .secondary,
                                text: context.state.lastPrompt, maxLines: 2)
            }
            if !context.state.lastResponse.isEmpty {
                ConversationLine(icon: "sparkle", iconColor: status.color,
                                text: context.state.lastResponse, maxLines: 3)
            }

            // 直近のツールログ
            LogLinesView(logs: context.state.recentLogs, maxLines: 2)

            // フッタ: ツール実行数
            if context.state.toolCount > 0 {
                Text("ツール実行 \(context.state.toolCount) 回")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(12)
        .opacity(context.isStale ? 0.5 : 1.0)
        .overlay(alignment: .topTrailing) {
            if context.isStale {
                Label("接続が途切れています", systemImage: "wifi.slash")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .padding(8)
            }
        }
    }
}

/// ユーザー入力 / Claude の返答を1行で表示する共通ビュー
private struct ConversationLine: View {
    let icon: String
    let iconColor: Color
    let text: String
    let maxLines: Int

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: icon)
                .font(.caption2)
                .foregroundStyle(iconColor)
            Text(text)
                .font(.footnote)
                .lineLimit(maxLines)
                .contentTransition(.opacity)
        }
    }
}

/// 直近ツールログの共通表示
private struct LogLinesView: View {
    let logs: [String]
    let maxLines: Int

    var body: some View {
        if !logs.isEmpty {
            VStack(alignment: .leading, spacing: 1) {
                ForEach(Array(logs.prefix(maxLines).enumerated()), id: \.offset) { index, line in
                    Text(line)
                        .font(.caption2.monospaced())
                        .foregroundStyle(index == 0 ? .secondary : .tertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
        }
    }
}

/// 経過時間タイマー（システム側で毎秒更新されるのでプッシュ不要）
private struct ElapsedTimerText: View {
    let startedAt: Date

    var body: some View {
        Text(timerInterval: startedAt...Date(timeIntervalSinceNow: 60 * 60 * 24),
             countsDown: false)
            .multilineTextAlignment(.trailing)
    }
}
