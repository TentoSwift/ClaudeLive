import SwiftUI

/// ライブアクティビティ（ロック画面）の見た目をアプリ内でそのまま再現する
/// プレビュー。Widget/ClaudeLiveActivityWidget.swift の LockScreenView.fullBody と
/// 同じコンポーネント（StatusIconView・MarqueeText・QuestionView 等）を再利用する。
/// ActivityViewContext はアプリ側からは作れないため、ContentState と
/// attributes を直接受け取る形に分けている
struct LiveActivityMirrorView: View {
    let attributes: ClaudeActivityAttributes
    let state: ClaudeActivityAttributes.ContentState

    private var status: ClaudeStatus { ClaudeStatus(state.status) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !state.question.isEmpty {
                QuestionView(sessionId: attributes.sessionId,
                             question: state.question,
                             options: state.options,
                             tint: status.color,
                             compact: false,
                             isSettled: state.textSettled)
            } else {
                // ヘッダ: 状態アイコン（作業中はアニメーション）・状態ラベル・
                // 実行中ツール・モデル名・経過時間
                HStack(spacing: 6) {
                    StatusIconView(status: status, size: 26)
                    Text(status.label)
                        .font(.headline)
                        .foregroundStyle(status.needsAttention ? status.color : .primary)
                    if !state.currentTool.isEmpty {
                        Text(state.currentTool)
                            .font(.subheadline.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    HStack(spacing: 3) {
                        if !state.model.isEmpty {
                            Text(shortModelName(state.model))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        ElapsedTimerText(startedAt: state.startedAt)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }

                if !state.detail.isEmpty {
                    HStack(spacing: 8) {
                        Color.clear.frame(width: 26, height: 0)
                        Text(state.detail)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                        Spacer(minLength: 0)
                    }
                }

                let expandResponse = status == .done && state.lastResponse.count >= 100
                if expandResponse {
                    if !state.lastPrompt.isEmpty {
                        HStack(alignment: .center, spacing: 6) {
                            PromptIcon(size: 26, color: .secondary)
                            MarqueeText(
                                text: state.lastPrompt,
                                font: .footnote, uiFontSize: 13, uiFontWeight: .regular,
                                color: .secondary, lineHeight: 16,
                                isSettled: state.textSettled)
                        }
                    }
                    HStack(alignment: .top, spacing: 6) {
                        ReplyIcon(size: 22, color: Color.claudeBrand, status: status, changeTrigger: state.lastResponse)
                        Text(styledMarkdown(state.lastResponse))
                            .font(.footnote)
                            .foregroundStyle(.primary)
                            .lineLimit(10)
                    }
                } else {
                    if !state.lastPrompt.isEmpty {
                        HStack(alignment: .center, spacing: 6) {
                            PromptIcon(size: 26, color: .secondary)
                            MarqueeText(
                                text: state.lastPrompt,
                                font: .footnote, uiFontSize: 13, uiFontWeight: .regular,
                                color: .secondary, lineHeight: 16,
                                isSettled: state.textSettled)
                        }
                    }
                    if !state.lastResponse.isEmpty {
                        if status == .done && state.lastResponse.count >= 16 {
                            // 完了時、16文字以上の返答はマーキーにせず2行まで折り返す
                            HStack(alignment: .top, spacing: 6) {
                                ReplyIcon(size: 22, color: Color.claudeBrand, status: status, changeTrigger: state.lastResponse)
                                Text(styledMarkdown(state.lastResponse))
                                    .font(.footnote)
                                    .foregroundStyle(.primary)
                                    .lineLimit(2)
                            }
                        } else {
                            HStack(alignment: .center, spacing: 6) {
                                ReplyIcon(size: 26, color: Color.claudeBrand, status: status, changeTrigger: state.lastResponse)
                                MarqueeText(
                                    text: state.lastResponse,
                                    font: .footnote, uiFontSize: 13, uiFontWeight: .regular,
                                    color: .primary, lineHeight: 16,
                                    isSettled: state.textSettled)
                            }
                        }
                    }

                    LogLinesView(logs: state.recentLogs, maxLines: 2)

                    if state.toolCount > 0 {
                        Text("ツール実行 \(state.toolCount) 回")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .padding(12)
        .background(Color.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 20))
    }
}
