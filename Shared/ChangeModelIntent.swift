import AppIntents
import Foundation

/// Siri・ショートカット・アクションボタンから、既存の Claude Code セッションの
/// モデルを切り替える App Intent。実体は Claude Code 自身の `/model` スラッシュ
/// コマンドを対象セッションに送るだけ（SendPromptIntent と同じキー入力方式）
struct ChangeModelIntent: AppIntent {
    static var title: LocalizedStringResource = "Claude のモデルを変更"
    static var description = IntentDescription("選んだ Claude Code セッションのモデルを切り替えます")
    static var openAppWhenRun: Bool = false

    /// 対象セッション。text より先に宣言することで、こちらを先に尋ねさせる
    @Parameter(title: "セッション", requestValueDialog: "どのセッションのモデルを変更しますか？")
    var session: ClaudeSessionEntity

    @Parameter(title: "モデル", requestValueDialog: "どのモデルにしますか？")
    var model: ClaudeModelChoice

    static var parameterSummary: some ParameterSummary {
        Summary("\(\.$session) のモデルを \(\.$model) に変更する")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        // 操作モードがオフなら実行しない（Mac 上の Claude Code を動かす機能のため）
        guard isControlModeEnabled else {
            return .result(dialog: "\(controlModeDisabledMessage)")
        }
        let ok = await Self.changeModel(sessionId: session.id, model: model.rawValue)
        return .result(dialog: ok ? "\(model.label) に変更しました" : "Mac に届きませんでした")
    }

    /// Mac デーモンの /changemodel へモデル変更を送る（内部は /model <id> の
    /// 送信と同じ）。SessionDetailView のモデル変更メニューからも共有する
    static func changeModel(sessionId: String, model: String) async -> Bool {
        let payload: [String: Any] = ["sessionId": sessionId, "model": model]
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return false }
        return await daemonRequestOK(path: "/changemodel", body: body)
    }
}
