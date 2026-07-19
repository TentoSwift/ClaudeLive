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
                    if status == .question {
                        // 質問中はプロジェクト名・セッション名を省いて、
                        // 「質問」ラベルと下の質問カードにスペースを譲る
                        Text(status.label)
                            .font(.caption.bold())
                            .foregroundStyle(status.color)
                    } else {
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
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 3) {
                        if !context.state.question.isEmpty {
                            QuestionView(sessionId: context.attributes.sessionId,
                                         question: context.state.question,
                                         options: context.state.options,
                                         tint: status.color,
                                         compact: true)
                        } else {
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

            // セッションのタイトル（最初の入力から生成）。質問中は選択肢に譲って隠す
            if !context.state.sessionTitle.isEmpty, status != .question {
                Text(context.state.sessionTitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
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

            if !context.state.question.isEmpty {
                // 質問中は選択肢ボタンを優先表示（スペース確保のため会話・ログは隠す）
                QuestionView(sessionId: context.attributes.sessionId,
                             question: context.state.question,
                             options: context.state.options,
                             tint: status.color,
                             compact: false)
            } else {
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
            }

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

/// Claude からの質問と選択肢ボタン。
/// タップすると AnswerQuestionIntent（アプリ本体プロセスで実行）が
/// Mac デーモンの /answer に回答を POST し、保留中の PreToolUse フックが
/// decision JSON で解決されて Claude が続行する
private struct QuestionView: View {
    let sessionId: String
    let question: String
    let options: [String]
    let tint: Color
    let compact: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 5 : 8) {
            Text(question)
                .font(compact ? .caption2 : .subheadline.weight(.semibold))
                // 選択肢を 1 行横並びにしたことで縦に余裕ができたので、
                // Dynamic Island でも 2 行までは見せる（全文はロック画面で 4 行表示）
                .lineLimit(compact ? 2 : 4)
                .fixedSize(horizontal: false, vertical: true)

            let items = Array(options.prefix(4))
            if compact {
                // Dynamic Island: 見切れ防止のため 1 行に横並び
                HStack(spacing: 5) {
                    ForEach(Array(items.enumerated()), id: \.offset) { _, label in
                        answerButton(label)
                    }
                }
            } else {
                // ロック画面: 2 列グリッド。最後の 1 個は横幅いっぱい
                ForEach(0..<((items.count + 1) / 2), id: \.self) { row in
                    HStack(spacing: 6) {
                        ForEach(0..<2, id: \.self) { column in
                            let index = row * 2 + column
                            if index < items.count {
                                answerButton(items[index])
                            }
                        }
                    }
                }
                Button(intent: AnswerQuestionIntent(sessionId: sessionId, answer: "", pass: true)) {
                    Label("Macで回答する", systemImage: "desktopcomputer")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .padding(.top, 1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func answerButton(_ label: String) -> some View {
        Button(intent: AnswerQuestionIntent(sessionId: sessionId, answer: label)) {
            Text(label)
                .font(compact ? .caption2.bold() : .subheadline.bold())
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, compact ? 6 : 10)
                .padding(.horizontal, 4)
                .background(tint, in: RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
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
