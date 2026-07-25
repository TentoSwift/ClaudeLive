import AppIntents
import Foundation

/// よく使うスラッシュコマンドのプリセット。ここに無いものは自由入力で送れるため、
/// あくまでよく使うものだけ選びやすく並べてある
enum ClaudeQuickCommand: String, AppEnum, CaseIterable, Identifiable {
    case compact = "/compact"
    case clear = "/clear"
    case cost = "/cost"
    case permissions = "/permissions"
    case agents = "/agents"
    case review = "/review"

    var id: String { rawValue }

    /// メニュー表示用の短い名前
    var label: String {
        switch self {
        case .compact: return "会話を圧縮 (/compact)"
        case .clear: return "会話をクリア (/clear)"
        case .cost: return "コストを表示 (/cost)"
        case .permissions: return "権限設定 (/permissions)"
        case .agents: return "エージェント一覧 (/agents)"
        case .review: return "レビュー (/review)"
        }
    }

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "コマンド"
    static var caseDisplayRepresentations: [ClaudeQuickCommand: DisplayRepresentation] = [
        .compact: "会話を圧縮 (/compact)",
        .clear: "会話をクリア (/clear)",
        .cost: "コストを表示 (/cost)",
        .permissions: "権限設定 (/permissions)",
        .agents: "エージェント一覧 (/agents)",
        .review: "レビュー (/review)",
    ]
}

/// Siri・ショートカット・アクションボタンから、既存の Claude Code セッションに
/// スラッシュコマンドを送る App Intent。実体は SendPromptIntent と同じ
/// キー入力方式で「/コマンド」をそのまま該当セッションに送るだけ
struct SendCommandIntent: AppIntent {
    static var title: LocalizedStringResource = "Claude にコマンドを送る"
    static var description = IntentDescription("選んだ Claude Code セッションにスラッシュコマンドを送ります")
    static var openAppWhenRun: Bool = false

    /// 対象セッション。command より先に宣言することで、こちらを先に尋ねさせる
    @Parameter(title: "セッション", requestValueDialog: "どのセッションに送りますか？")
    var session: ClaudeSessionEntity

    /// プリセットに無いコマンドも自由入力で送れるよう、固定の enum ではなく
    /// 文字列にする（先頭の "/" は省略しても daemon 側で補う）
    @Parameter(title: "コマンド", requestValueDialog: "どのコマンドを送りますか？（例: /compact）")
    var command: String

    static var parameterSummary: some ParameterSummary {
        Summary("\(\.$session) に \(\.$command) を送る")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        // 操作モードがオフなら実行しない（Mac 上の Claude Code を動かす機能のため）
        guard isControlModeEnabled else {
            return .result(dialog: "\(controlModeDisabledMessage)")
        }
        if command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw $command.needsValueError("送るコマンドを入力してください")
        }
        let ok = await Self.sendCommand(sessionId: session.id, command: command)
        return .result(dialog: ok ? "送りました" : "Mac に届きませんでした")
    }

    /// Mac デーモンの /command へコマンドを送る。SessionDetailView の
    /// クイックコマンドボタンからも共有する
    static func sendCommand(sessionId: String, command: String) async -> Bool {
        let payload: [String: Any] = ["sessionId": sessionId, "command": command]
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return false }
        return await daemonRequestOK(path: "/command", body: body)
    }
}
