import ActivityKit
import SwiftUI
import UIKit
import WidgetKit

/// ツール名に対応する SF Symbol 名。
/// デーモン側のツールログ（"SFSymbol名|本文"）と同じ対応表にしてある
func toolSymbolName(_ tool: String) -> String {
    switch tool {
    case "Bash":                        return "terminal"
    case "Read":                        return "doc.text"
    case "Edit", "Write", "NotebookEdit": return "pencil"
    case "Grep", "Glob":                return "magnifyingglass"
    case "Task", "Agent":               return "rectangle.stack.fill"
    case "WebFetch", "WebSearch":       return "globe"
    default:                            return "wrench.and.screwdriver"
    }
}

/// 実行中ツールのアイコン。Task/Agent（サブエージェント）はカスタムシンボル
/// （Assets.xcassets の ClaudeTaskRunning）、それ以外は toolSymbolName の SF Symbol
@ViewBuilder
func toolRunningIcon(_ tool: String) -> some View {
    if tool == "Task" || tool == "Agent" {
        Image("ClaudeTaskRunning")
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
    } else {
        Image(systemName: toolSymbolName(tool))
            .resizable()
            .scaledToFit()
    }
}

/// 完了時、直近に使ったツールのチェックマーク付きカスタムシンボル名。
/// Assets.xcassets に "Claude<ツール名>Checkmark" という名前の .symbolset を
/// 追加すれば自動的に使われる（例: ClaudeBashCheckmark）。
/// まだ用意していないツールは nil を返し、呼び出し側は共通の
/// ClaudeBadgeCheckmark にフォールバックする
func toolCheckmarkSymbolName(_ tool: String) -> String? {
    // toolSymbolName と同じグループ分けで、似たツールは1つのシンボルを共有する
    let group: String
    switch tool {
    case "Bash":                          group = "Bash"
    case "Read":                          group = "Read"
    case "Edit", "Write", "NotebookEdit": group = "Edit"
    case "Grep", "Glob":                  group = "Grep"
    case "Task", "Agent":                 group = "Task"
    case "WebFetch", "WebSearch":         group = "WebFetch"
    default:                              return nil
    }
    let name = "Claude\(group)Checkmark"
    return UIImage(named: name) != nil ? name : nil
}

/// インライン Markdown（**強調**・`コード` など）を解釈する
func styledMarkdown(_ text: String) -> AttributedString {
    (try? AttributedString(
        markdown: text,
        options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
        ?? AttributedString(text)
}

struct ClaudeLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: ClaudeActivityAttributes.self) { context in
            // ロック画面 / 通知バナー
            // watchOS の Smart Stack はカード側が背景を持つため、ここでは
            // 黒背景を付けず LockScreenView 側で iOS のときだけ付ける
            LockScreenView(context: context)
                .activitySystemActionForegroundColor(.white)
                // タップでアプリを開き、セッション詳細へ直接遷移させる。
                // ライブアクティビティは Button(intent:)・Link・widgetURL の
                // いずれを使っても自アプリ以外は開けない（実機で確認済み）ため、
                // 外部アプリ（ショートカット）への直接遷移は諦め、
                // 確実に動く「アプリを開く」方式に統一する
                .widgetURL(URL(string: "claudelive://session/\(context.attributes.sessionId)"))
        } dynamicIsland: { context in
            let status = ClaudeStatus(context.state.status)
            // 完了時、返答が長くて場所を取るなら他の情報（プロジェクト名・状態ラベル等）は省く
            let expandResponse = status == .done && context.state.lastResponse.count >= 100
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    StatusIconView(status: status, size: 24)
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    // 質問中は経過時間よりも質問カードの横幅を優先する。
                    // DI では経過時間は表示しない（ロック画面側にはある）
                    if status != .question, !context.state.model.isEmpty {
                        Text(shortModelName(context.state.model))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .frame(maxWidth: 100)
                            .padding(.trailing, 4)
                    }
                }
                DynamicIslandExpandedRegion(.center) {
                    if status == .question || status == .done {
                        // 質問中、または完了時はプロジェクト名・セッション名・状態ラベルも省き、
                        // 内容の表示に最大限スペースを譲る
                        EmptyView()
                    } else {
                        // DI では何のセッションかを示す行（プロジェクト名 "Claud" や
                        // "claud-9b" のような自動生成のセッション名）を出さない。
                        // 狭い幅を食うわりに読み取れる情報が少ないため、
                        // 状態と実行中ツールだけにする（識別はロック画面側にある）
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
                        if !context.state.question.isEmpty {
                            QuestionView(sessionId: context.attributes.sessionId,
                                         question: context.state.question,
                                         options: context.state.options,
                                         tint: status.color,
                                         compact: true,
                                         isSettled: context.state.textSettled,
                              questionCount: context.state.questionCount)
                        } else {
                            // 完了時、返答が長くて場所を取るならツールログ・実行回数は省いて
                            // 返答を複数行で優先表示する（マーキーは1行しか流せないため）
                            if expandResponse {
                                if !context.state.lastPrompt.isEmpty {
                                    HStack(alignment: .center, spacing: 6) {
                                        PromptIcon(size: 24, color: .secondary)
                                        MarqueeText(
                                            text: context.state.lastPrompt,
                                            font: .footnote, uiFontSize: 13, uiFontWeight: .regular,
                                            color: .secondary, lineHeight: 14,
                                            isSettled: context.state.textSettled)
                                    }
                                }
                                HStack(alignment: .top, spacing: 6) {
                                    ReplyIcon(size: 24, color: Color.claudeBrand, status: status, changeTrigger: context.state.lastResponse)
                                    ResponseBodyView(text: context.state.lastResponse, lineLimit: 10)
                                        .foregroundStyle(.primary)
                                }
                            } else {
                                // プロンプトと返答、両方あれば両方表示する（完了時も入力を残す）
                                if !context.state.lastPrompt.isEmpty {
                                    HStack(alignment: .center, spacing: 6) {
                                        PromptIcon(size: 24, color: .secondary)
                                        MarqueeText(
                                            text: context.state.lastPrompt,
                                            font: .footnote, uiFontSize: 13, uiFontWeight: .regular,
                                            color: .secondary, lineHeight: 14,
                                            isSettled: context.state.textSettled)
                                    }
                                }
                                if !context.state.lastResponse.isEmpty {
                                    if status == .done && context.state.lastResponse.count >= 16 {
                                        // 完了時、16文字以上の返答はマーキーにせず2行まで折り返す
                                        HStack(alignment: .top, spacing: 6) {
                                            ReplyIcon(size: 24, color: Color.claudeBrand, status: status, changeTrigger: context.state.lastResponse)
                                            ResponseBodyView(text: context.state.lastResponse, lineLimit: 2)
                                                .foregroundStyle(.primary)
                                        }
                                    } else {
                                        // マーキーは 1 行なのでアイコンは中央揃え（.top だと浮く）
                                        HStack(alignment: .center, spacing: 6) {
                                            ReplyIcon(size: 24, color: Color.claudeBrand, status: status, changeTrigger: context.state.lastResponse)
                                            MarqueeText(
                                                text: context.state.lastResponse,
                                                font: .footnote, uiFontSize: 13, uiFontWeight: .regular,
                                                color: .primary, lineHeight: 14,
                                                isSettled: context.state.textSettled)
                                        }
                                    }
                                }
                                if context.state.lastPrompt.isEmpty, context.state.lastResponse.isEmpty,
                                   !context.state.detail.isEmpty {
                                    Text(context.state.detail)
                                        .font(.footnote)
                                        .lineLimit(2)
                                        .contentTransition(.opacity)
                                }
                                LogLinesView(logs: context.state.recentLogs, maxLines: 1)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
                    .ignoresSafeArea(.container, edges: .bottom)
                }
            } compactLeading: {
                CompactStatusIcon(status: status, size: 20,
                                  startedAt: context.state.startedAt,
                                  animated: context.state.compactAnimated,
                                  changeTrigger: context.state.toolCount)
            } compactTrailing: {
                // 実行中のツール、または完了時は直近ツールのチェックマーク付き
                // アイコン。どちらも無いときは透明なプレースホルダを置く
                // （空にすると幅が詰まって Dynamic Island の大きさが変わるため）。
                // タップでこのセッションの詳細（回答 UI 込み）を開く
                Link(destination: URL(string: "claudelive://session/\(context.attributes.sessionId)")!) {
                    Group {
                        if status == .question {
                            Image(systemName: "questionmark")
                                .resizable()
                                .scaledToFit()
                                .foregroundStyle(status.color)
                        } else if !context.state.currentTool.isEmpty {
                            toolRunningIcon(context.state.currentTool)
                                .foregroundStyle(status.color)
                        } else if let name = toolCheckmarkSymbolName(context.state.lastTool) {
                            // ツール実行が終わったら（完了時に限らず作業中の合間も）
                            // 直近ツールのチェックマーク付きアイコンを出す。
                            // バッジ付きは横長なので正方形に fit させると本体が
                            // 縮んで左に寄る → 高さ基準で合わせ、幅はみ出しは許容
                            Image(name)
                                .renderingMode(.template)
                                .resizable()
                                .scaledToFit()
                                .foregroundStyle(Color.claudeBrand)
                                // ターミナル（Bash）だけ大きめに見せる
                                .frame(height: context.state.lastTool == "Bash" ? 20 * 1.4 * 1.5 * 1.5 : 20)
                        } else {
                            Color.clear
                        }
                    }
                    .frame(width: 20, height: 20)
                }
            } minimal: {
                // 他のライブアクティビティと同居して1つしか出せないとき。
                // ツール実行中はそのツールのアイコン、それ以外は状態アイコン
                // （完了なら Claude の完了マーク）
                if !context.state.currentTool.isEmpty {
                    toolRunningIcon(context.state.currentTool)
                        .frame(width: 18, height: 18)
                        .foregroundStyle(status.color)
                } else {
                    StatusIconView(status: status, size: 18, animateWhenWorking: false)
                }
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

/// Claude のマーク。[[claude-usage-bar-app]] と同じ ClaudeSpark.png を使う。
/// 元画像に Claude カラーが付いているので tint はかけずそのまま表示し、
/// 読み込みに失敗した場合だけ SF Symbols にフォールバックする
struct ClaudeMarkIcon: View {
    let size: CGFloat
    var color: Color = .primary

    var body: some View {
        if let image = FrameAnimation.bundledImage("ClaudeSpark") {
            image
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
        } else {
            Image(systemName: "sparkle")
                .font(.system(size: size))
                .foregroundStyle(color)
                .frame(width: size, height: size)
        }
    }
}

/// SF Symbols を実寸指定で描く小アイコン。
/// `.font()` 指定だとシンボルごとに見た目の大きさがまちまちになるため、
/// ClaudeMarkIcon（PNG）と縦横のサイズ基準を揃える目的で使う
struct SmallSymbolIcon: View {
    let name: String
    let size: CGFloat
    var color: Color = .secondary

    var body: some View {
        Image(systemName: name)
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .foregroundStyle(color)
    }
}

/// プロンプト（ユーザー入力）行のアイコン。カスタム SF Symbol
/// （person.bubble.right.fill のカスタム版）を使う
struct PromptIcon: View {
    let size: CGFloat
    var color: Color = .secondary

    var body: some View {
        Image("ClaudePersonBubble")
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .foregroundStyle(color)
    }
}

/// Claude の返答行のアイコン。カスタム SF Symbol
/// （bubble.left.fill のカスタム版）を使う
struct ReplyIcon: View {
    let size: CGFloat
    var color: Color = .primary
    var status: ClaudeStatus? = nil
    /// この値が変わるたびに一度だけ揺れる（新しい返答が来たときのフィードバック用）
    var changeTrigger: String = ""

    private var symbolName: String {
        status == .done ? "ClaudeBubbleReplyDone" : "ClaudeBubbleReply"
    }

    var body: some View {
        Image(symbolName)
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .foregroundStyle(color)
            .symbolEffect(.wiggle, value: changeTrigger)
    }
}

/// 状態アイコン。
/// - 作業中（.working）: Claude ブランドのモーフィングアニメ
/// - 完了（.done）/ 質問（.question）: 専用のカスタムシンボル（Claude カラー）
/// - それ以外: 通常の SF Symbols アイコン
///
/// 見た目の大きさが揃うよう、SF Symbols とカスタムシンボルはどちらも
/// 同じ実寸（size）を基準に描画する
/// Dynamic Island のコンパクト領域専用の状態アイコン。
/// フォントマスク方式のコマ送り（SpinnerProofView）はコンパクト領域では
/// マスクのタイミングが噛み合わず塗り潰し矩形が出てしまうため、ここでは
/// カスタムシンボル + symbolEffect というネイティブの手段でアニメーションさせる
struct CompactStatusIcon: View {
    let status: ClaudeStatus
    let size: CGFloat
    /// DigitFrameSpinnerView のタイマー起点（ライブアクティビティの startedAt）
    let startedAt: Date
    /// true でコマ送り版（CompactSpinnerView）を使う。過去にこれが原因で
    /// ライブアクティビティが強制終了される不具合を起こしたため、既定は false
    /// （静止版）にし、アプリの設定画面から検証用にオン/オフできるようにした
    var animated: Bool = false
    /// この値が変わるたびに一度だけバウンドする（ツール切り替わりのフィード
    /// バック用）。symbolEffect の .repeating はコンパクト領域では連続再生
    /// されない（実機で確認）ため、value トリガー方式に変更した
    var changeTrigger: Int = 0

    private var symbolName: String {
        switch status {
        case .done:     return "ClaudeBadgeCheckmark"
        case .question: return "ClaudeBadgeQuestionmark"
        default:        return ""
        }
    }

    var body: some View {
        Group {
            if status == .working && animated {
                CompactSpinnerView(size: size)
            } else if status == .working {
                Image("ClaudeMark")
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(status.color)
                    .symbolEffect(.bounce, value: changeTrigger)
            } else if symbolName.isEmpty {
                Image(systemName: status.icon)
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(status.color)
                    .symbolEffect(.pulse, options: .repeating, isActive: status.needsAttention)
            } else {
                Image(symbolName)
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    // 完了はブランドカラー固定、質問は状態色（インディゴ）にする
                    .foregroundStyle(status == .question ? status.color : Color.claudeBrand)
                    .symbolEffect(.pulse, options: .repeating,
                                  isActive: status == .question)
            }
        }
        .frame(width: size, height: size)
    }
}

struct StatusIconView: View {
    let status: ClaudeStatus
    let size: CGFloat
    var animateWhenWorking: Bool = true

    /// Claude マークにバッジを付けたカスタムシンボル（Assets.xcassets）
    private var customSymbolName: String? {
        switch status {
        case .done:     return "ClaudeBadgeCheckmark"
        case .question: return "ClaudeBadgeQuestionmark"
        default:        return nil
        }
    }

    var body: some View {
        Group {
            if status == .working && animateWhenWorking {
                SpinnerProofView(size: size, color: status.color)
            } else if status == .working {
                // アニメーションを使わない場所（DI minimal・watch AOD 中）は
                // 金槌マークではなく Claude マークの静止版で表す
                ClaudeMarkIcon(size: size, color: status.color)
            } else if let name = customSymbolName {
                Image(name)
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    // 完了はブランドカラー固定、質問は状態色（インディゴ）にする
                    .foregroundStyle(status == .question ? status.color : Color.claudeBrand)
            } else {
                Image(systemName: status.icon)
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(status.color)
                    .symbolEffect(.pulse, isActive: status.needsAttention)
                    .symbolEffect(.bounce.byLayer, options: .repeating, isActive: status == .compacting)
            }
        }
        .frame(width: size, height: size)
    }
}

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
                .activityBackgroundTint(Color.black.opacity(0.65))
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
                             compact: false,
                             isSettled: context.state.textSettled,
                              questionCount: context.state.questionCount)
            } else {
                // ヘッダ: 状態アイコン（作業中はアニメーション）・状態ラベル・経過時間
                HStack(spacing: 6) {
                    StatusIconView(status: status, size: 26)
                    Text(status.label)
                        .font(.headline)
                        .foregroundStyle(status.needsAttention ? status.color : .primary)
                    if !context.state.currentTool.isEmpty {
                        Text(context.state.currentTool)
                            .font(.subheadline.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    if !context.state.model.isEmpty {
                        Text(shortModelName(context.state.model))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    ElapsedTimerText(startedAt: context.state.startedAt)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        // Text(timerInterval:) は「表示しうる最大幅」を先に確保するため、
                        // 放置するとモデル名との間に大きな余白ができる。実測に近い幅で固定する。
                        // 1時間以上だと "H:MM:SS" になり幅が増えるので、58pt では折り返して
                        // 2行になっていた。3桁分の余裕を見て広げる
                        .frame(width: 74, alignment: .trailing)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                // 詳細
                if !context.state.detail.isEmpty {
                    HStack(spacing: 8) {
                        Color.clear.frame(width: 26, height: 0)
                        Text(context.state.detail)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .contentTransition(.opacity)
                        Spacer(minLength: 0)
                    }
                }

                // 完了時、返答が長くて場所を取るならツールログ・実行回数は省いて
                // 返答を複数行で優先表示する（マーキーは1行しか流せないため）
                let expandResponse = status == .done && context.state.lastResponse.count >= 100
                if expandResponse {
                    if !context.state.lastPrompt.isEmpty {
                        HStack(alignment: .center, spacing: 6) {
                            PromptIcon(size: 26, color: .secondary)
                            MarqueeText(
                                text: context.state.lastPrompt,
                                font: .footnote, uiFontSize: 13, uiFontWeight: .regular,
                                color: .secondary, lineHeight: 16,
                                isSettled: context.state.textSettled)
                        }
                    }
                    HStack(alignment: .top, spacing: 6) {
                        ReplyIcon(size: 26, color: Color.claudeBrand, status: status, changeTrigger: context.state.lastResponse)
                        ResponseBodyView(text: context.state.lastResponse, lineLimit: 10)
                            .foregroundStyle(.primary)
                    }
                } else {
                    // 直近のやり取り: ユーザー入力 → Claude の返答
                    if !context.state.lastPrompt.isEmpty {
                        // マーキーは 1 行なのでアイコンは中央揃え（.top だと浮く）
                        HStack(alignment: .center, spacing: 6) {
                            PromptIcon(size: 26, color: .secondary)
                            MarqueeText(
                                text: context.state.lastPrompt,
                                font: .footnote, uiFontSize: 13, uiFontWeight: .regular,
                                color: .secondary, lineHeight: 16,
                                isSettled: context.state.textSettled)
                        }
                    }
                    if !context.state.lastResponse.isEmpty {
                        if status == .done && context.state.lastResponse.count >= 16 {
                            // 完了時、16文字以上の返答はマーキーにせず2行まで折り返す
                            HStack(alignment: .top, spacing: 6) {
                                ReplyIcon(size: 26, color: Color.claudeBrand, status: status, changeTrigger: context.state.lastResponse)
                                ResponseBodyView(text: context.state.lastResponse, lineLimit: 2)
                                    .foregroundStyle(.primary)
                            }
                        } else {
                            HStack(alignment: .center, spacing: 6) {
                                ReplyIcon(size: 26, color: Color.claudeBrand, status: status, changeTrigger: context.state.lastResponse)
                                MarqueeText(
                                    text: context.state.lastResponse,
                                    font: .footnote, uiFontSize: 13, uiFontWeight: .regular,
                                    color: .primary, lineHeight: 16,
                                    isSettled: context.state.textSettled)
                            }
                        }
                    }

                    LogLinesView(logs: context.state.recentLogs, maxLines: 2)

                    // フッタ: ツール実行数
                    if context.state.toolCount > 0 {
                        Text("ツール実行 \(context.state.toolCount) 回")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
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

    /// インライン Markdown（**強調**・`コード` など）を解釈する
    private func styled(_ text: String) -> AttributedString {
        (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }

    var body: some View {
        // Link・.widgetURL・openAppWhenRun 付き AppIntent をすべて試したが、
        // いずれも実機で期待通り動かなかった（前者2つは無反応、Intent 版は
        // ウィジェット拡張機能が属する iOS 側のアプリを開いてしまい、
        // Watch アプリを開けなかった）。誤動作より無反応の方がましなので、
        // タップを乗っ取らない素のコンテンツに戻す
        content
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .top, spacing: 5) {
                // 常時表示(AOD)中はアニメを止めて静止アイコンに（輝度を落とす必要があり、
                // このアイコン画像は固定色のため tint を効かせられないため）
                StatusIconView(status: status, size: 22, animateWhenWorking: !isLuminanceReduced)
                Text(context.state.sessionName.isEmpty
                     ? context.attributes.projectName
                     : context.state.sessionName)
                    .font(.caption2.bold())
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .layoutPriority(-1)
                // 状態ラベル（「作業中」など）はセッション名の隣に置く
                Text(status.label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .layoutPriority(-1)
                Spacer(minLength: 0)
                // 実行中ツール、または直近ツールのチェックマーク付きアイコン。
                // DI コンパクトの右端と同じ考え方で 1 行目の右端に置く
                Group {
                    if !context.state.currentTool.isEmpty {
                        toolRunningIcon(context.state.currentTool)
                            // 常時表示(AOD)中も色を変えない（他のアイコンは輝度を落とすが、
                            // これは要望によりそのままにする）
                            .foregroundStyle(status.color)
                    } else if let name = toolCheckmarkSymbolName(context.state.lastTool) {
                        Image(name)
                            .renderingMode(.template)
                            .resizable()
                            .scaledToFit()
                            .foregroundStyle(status.color)
                            // ターミナル（Bash）だけ大きめに見せるが、行の高さ（22pt）を
                            // 超えると Smart Stack のカードからはみ出すので上限を設ける
                            .frame(height: context.state.lastTool == "Bash" ? 22 : 16)
                    } else {
                        Color.clear
                    }
                }
                // 行の先頭アイコン（22pt）と同じ高さの枠に収め、上端で揃える
                .frame(width: 16, height: 22, alignment: .top)
                .clipped()
            }

            if !context.state.question.isEmpty {
                let count = context.state.questionCount ?? 1
                // Smart Stack は行数が限られるので質問文そのものは出さず、
                // 「質問が来ている」ことだけをアイコンと短い見出しで示して、
                // 空いた行を選択肢ボタンに回す（全文はアプリで読める）
                HStack(spacing: 4) {
                    Image(systemName: "questionmark.circle.fill")
                        .foregroundStyle(Color.claudeBrand)
                    Text(count > 1 ? "質問 \(count)件" : "質問")
                        .font(.caption2.bold())
                }
                // Smart Stack では単一質問でも選択肢を出さない。
                // カードのタップで Watch アプリが開き、そこで回答する
                // （選択肢の全文や自由入力はアプリでしか扱えないため、
                // 狭いカードに切り詰めたボタンを並べるより一貫していて誤答も防げる）
                Text("アプリで回答してください")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                if !context.state.currentTool.isEmpty {
                    Text(context.state.currentTool)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                // 状態の一言だけでなく、Claude が実際に何を言った/何を頼まれたかを
                // 一番情報量の多い内容として表示する（返答 > 入力 > detail の優先順）
                if !context.state.lastResponse.isEmpty {
                    // Smart Stack は 3 行しかないので表は描かない。ただし表を含む
                    // 返答は改行付きで届くため、素のまま出すとパイプ記法が
                    // 表示行を埋めてしまう。「（表）」に畳んで文章にスペースを譲る
                    Text(styled(MarkdownTable.flattenedWithoutTables(context.state.lastResponse)))
                        .font(.caption2)
                        .lineLimit(3)
                } else if !context.state.lastPrompt.isEmpty {
                    Text(styled(context.state.lastPrompt))
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
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }
}

/// Claude からの質問と選択肢ボタン。
/// タップすると AnswerQuestionIntent（アプリ本体プロセスで実行）が
/// Mac デーモンの /answer に回答を POST し、保留中の PreToolUse フックが
/// decision JSON で解決されて Claude が続行する
struct QuestionView: View {
    let sessionId: String
    let question: String
    let options: [String]
    let tint: Color
    let compact: Bool
    var isSettled: Bool = false
    /// AskUserQuestion に含まれる質問の総数（nil / 1 は単一質問）
    var questionCount: Int? = nil

    /// 2 問以上あるか。ライブアクティビティは 1 問目しか描けないので、
    /// このときは選択肢を出さずアプリへ誘導する
    private var isMultiQuestion: Bool { (questionCount ?? 1) > 1 }

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
                lineHeight: compact ? 14 : 18,
                // 質問文は回答されるまで表示され続けるので、1周で静止させず
                // ずっと流し続ける（isSettled を無視する）
                isSettled: false)

            let items = isMultiQuestion ? [] : Array(options.prefix(4))
            if isMultiQuestion {
                // 選択肢を出すと 1 問目だけ答えて残りが未回答のまま
                // Claude に返ってしまうため、アプリで答えてもらう
                Link(destination: URL(string: "claudelive://session/\(sessionId)")!) {
                    HStack(spacing: 5) {
                        Image(systemName: "list.bullet.rectangle")
                        Text("\(questionCount ?? 0)件の質問 — アプリで回答")
                            .font(compact ? .caption2.weight(.semibold) : .footnote.weight(.semibold))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, compact ? 5 : 7)
                    .background(tint.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 4)
            } else if compact && items.count <= 3 {
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

            // 選択肢にない答えはアプリを開いて自由入力する（システムアラート）
            Button(intent: OpenSessionIntent(sessionId: sessionId)) {
                Text("他の答えを入力…")
                    .font(compact ? .caption2 : .caption)
                    .foregroundStyle(tint)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, compact ? 6 : 0)
            .padding(.bottom, compact ? 4 : 0)
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
struct LogLinesView: View {
    let logs: [String]
    let maxLines: Int

    /// デーモンは "SFSymbol名|本文" 形式で送ってくる（絵文字は使わない）。
    /// 区切りが無い古い形式は本文のみとして扱い、汎用アイコンを添える
    private func split(_ line: String) -> (symbol: String, text: String) {
        guard let index = line.firstIndex(of: "|") else {
            return ("wrench.and.screwdriver", line)
        }
        return (String(line[line.startIndex..<index]),
                String(line[line.index(after: index)...]))
    }

    var body: some View {
        if !logs.isEmpty {
            VStack(alignment: .leading, spacing: 1) {
                ForEach(Array(logs.prefix(maxLines).enumerated()), id: \.offset) { index, line in
                    let parsed = split(line)
                    HStack(alignment: .center, spacing: 5) {
                        SmallSymbolIcon(name: parsed.symbol, size: 10,
                                        color: index == 0 ? .secondary : .secondary.opacity(0.6))
                        Text(parsed.text)
                            .font(.caption2.monospaced())
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    .foregroundStyle(index == 0 ? .secondary : .tertiary)
                }
            }
        }
    }
}

/// 経過時間タイマー（システム側で毎秒更新されるのでプッシュ不要）
struct ElapsedTimerText: View {
    let startedAt: Date

    var body: some View {
        Text(timerInterval: startedAt...Date(timeIntervalSinceNow: 60 * 60 * 24),
             countsDown: false)
            .multilineTextAlignment(.trailing)
    }
}
