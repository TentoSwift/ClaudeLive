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
                    // 質問中は経過時間よりも質問カードの横幅を優先する
                    if status != .question {
                        ElapsedTimerText(startedAt: context.state.startedAt)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: 60)
                            .padding(.trailing, 4)
                    }
                }
                DynamicIslandExpandedRegion(.center) {
                    if status == .question {
                        // 質問中はプロジェクト名・セッション名・「質問」ラベルも省き、
                        // 質問カードに最大限スペースを譲る（ボタンで質問中だと分かるため冗長）
                        EmptyView()
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
                                HStack(alignment: .top, spacing: 6) {
                                    Image(systemName: "sparkle")
                                        .font(.caption2)
                                        .foregroundStyle(status.color)
                                    MarqueeText(
                                        text: context.state.lastResponse,
                                        font: .footnote, uiFontSize: 13, uiFontWeight: .regular,
                                        color: .primary, lineHeight: 14)
                                }
                            } else if !context.state.lastPrompt.isEmpty {
                                HStack(alignment: .top, spacing: 6) {
                                    Image(systemName: "person.fill")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                    MarqueeText(
                                        text: context.state.lastPrompt,
                                        font: .footnote, uiFontSize: 13, uiFontWeight: .regular,
                                        color: .secondary, lineHeight: 14)
                                }
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
        // watchOS 11+ の Smart Stack にも表示する（WWDC24 "Bring your Live
        // Activity to Apple Watch"）。対応ファミリーは .small のみ。
        // 新規の watch ターゲットは不要 — 既存の LockScreenView が
        // activityFamily 環境値で分岐して描画する
        .supplementalActivityFamilies([.small])
    }
}

/// ロック画面・バナーの表示
private struct LockScreenView: View {
    let context: ActivityViewContext<ClaudeActivityAttributes>

    // watchOS の Smart Stack から描画されるときだけ .small になる。
    // iOS のロック画面 / バナーでは常に nil（＝ .small 以外の扱い）
    @Environment(\.activityFamily) private var activityFamily

    private var status: ClaudeStatus { ClaudeStatus(context.state.status) }

    var body: some View {
        if activityFamily == .small {
            WatchSmallView(context: context, status: status)
        } else {
            fullBody
        }
    }

    private var fullBody: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !context.state.question.isEmpty {
                // 質問中は質問文と選択肢ボタンだけを表示する
                // （ヘッダー・経過時間・状態行・会話・ツール数はすべて省く）
                QuestionView(sessionId: context.attributes.sessionId,
                             question: context.state.question,
                             options: context.state.options,
                             tint: status.color,
                             compact: false)
            } else {
                // ヘッダ: プロジェクト名・Mac 名・経過時間
                HStack(spacing: 6) {
                    // 【検証中】コマ送りアニメが Live Activity 内で動くかの実証。
                    // 動けば本命のテキストマーキー実装に進む。動かなければ削除する
                    SpinnerProofView(size: 16, color: status.color)
                        .frame(width: 16, height: 16)
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

                // セッションのタイトル（最初の入力から生成）
                if !context.state.sessionTitle.isEmpty {
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

                // 直近のやり取り: ユーザー入力 → Claude の返答
                if !context.state.lastPrompt.isEmpty {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "person.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        MarqueeText(
                            text: context.state.lastPrompt,
                            font: .footnote, uiFontSize: 13, uiFontWeight: .regular,
                            color: .secondary, lineHeight: 16)
                    }
                }
                if !context.state.lastResponse.isEmpty {
                    HStack(alignment: .top, spacing: 6) {
                        Image(systemName: "sparkle")
                            .font(.caption)
                            .foregroundStyle(status.color)
                        MarqueeText(
                            text: context.state.lastResponse,
                            font: .footnote, uiFontSize: 13, uiFontWeight: .regular,
                            color: .primary, lineHeight: 16)
                    }
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

/// watchOS の Smart Stack（.small ファミリーのみ対応）向けの表示。
/// スペースが極小なのでテキスト中心・要素は最小限にする。
/// 質問中もボタンは出さず文字で知らせるだけ（回答は iPhone 側で行う）
private struct WatchSmallView: View {
    let context: ActivityViewContext<ClaudeActivityAttributes>
    let status: ClaudeStatus

    // 常時表示（Always On Display）中は輝度を落として表示される。
    // 色をそのまま使うと明るすぎるので、暗めの表現に切り替える
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced

    private var tint: Color { isLuminanceReduced ? .white.opacity(0.6) : status.color }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Image(systemName: status.icon)
                    .foregroundStyle(tint)
                Text(context.state.sessionName.isEmpty
                     ? context.attributes.projectName
                     : context.state.sessionName)
                    .font(.caption2.bold())
                    .lineLimit(1)
                Spacer(minLength: 0)
            }

            if !context.state.question.isEmpty {
                // 質問中は質問文を短く表示するだけ（回答ボタンは iPhone 側）
                Text(context.state.question)
                    .font(.caption2)
                    .lineLimit(2)
            } else {
                Text(status.label
                     + (context.state.currentTool.isEmpty ? "" : " · \(context.state.currentTool)"))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                // 状態の一言だけでなく、Claude が実際に何を言った/何を頼まれたかを
                // 一番情報量の多い内容として表示する（返答 > 入力 > detail の優先順）
                if !context.state.lastResponse.isEmpty {
                    Text(context.state.lastResponse)
                        .font(.caption2)
                        .lineLimit(3)
                } else if !context.state.lastPrompt.isEmpty {
                    Text(context.state.lastPrompt)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                } else if !context.state.detail.isEmpty {
                    Text(context.state.detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
            // 質問文はフォントマスク方式のコマ送りアニメで横スクロール表示する
            // （公開 API のみで実現。Kyome22/AnimationLimitBreaker を移植）
            MarqueeText(
                text: question,
                font: compact ? .caption2 : .footnote.weight(.semibold),
                uiFontSize: compact ? 11 : 13,
                uiFontWeight: compact ? .regular : .semibold,
                color: .primary,
                lineHeight: compact ? 14 : 18)

            let items = Array(options.prefix(4))
            if compact && items.count <= 3 {
                // Dynamic Island・選択肢 3 個以下: 1 行に横並び。
                // 3 個までは横幅に余裕があり折り返さない（4 個だけが問題になる）
                HStack(spacing: 5) {
                    ForEach(Array(items.enumerated()), id: \.offset) { _, label in
                        answerButton(label)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 4)
            } else {
                // ロック画面、および DI で選択肢 4 個: 2 列グリッド。
                // 1 行 4 個だと横幅が狭すぎて長い単語が折り返し、DI の高さ上限を
                // 超えて下端が切れる事故があったため、2 列にして横幅を確保する
                let grid = ForEach(0..<((items.count + 1) / 2), id: \.self) { row in
                    HStack(spacing: 6) {
                        ForEach(0..<2, id: \.self) { column in
                            let index = row * 2 + column
                            if index < items.count {
                                answerButton(items[index])
                            }
                        }
                    }
                }
                if compact {
                    grid.padding(.horizontal, 6).padding(.bottom, 4)
                } else {
                    grid
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func answerButton(_ label: String) -> some View {
        Button(intent: AnswerQuestionIntent(sessionId: sessionId, answer: label)) {
            Text(label)
                .font(compact ? .caption2.bold() : .subheadline.bold())
                // 1 行に収まらない選択肢ラベルは、縮小だけでなく折り返しでも読めるようにする
                // （選択肢の文言が読めないまま押させるのを避ける）
                .lineLimit(2)
                .minimumScaleFactor(0.55)
                .multilineTextAlignment(.center)
                .foregroundStyle(.white)
                // 1 行のラベルと 2 行のラベルが同じ行内に並んでも高さが揃うよう、
                // 常に 2 行ぶんの高さを確保する（短いラベルは上下中央に収まる）
                .frame(maxWidth: .infinity, minHeight: compact ? 24 : 32)
                .padding(.vertical, compact ? 6 : 10)
                .padding(.horizontal, compact ? 8 : 6)
                .background(tint, in: Capsule())
        }
        .buttonStyle(.plain)
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
