import AppIntents
import Foundation

/// ライブアクティビティの回答ボタンから実行される App Intent。
/// LiveActivityIntent はアプリ本体のプロセスで実行されるため、
/// アプリが UserDefaults に保存した Mac デーモンの URL をそのまま使える。
/// （型自体は Button(intent:) を描画する Widget ターゲットにもコンパイルされる）
struct AnswerQuestionIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Claude の質問に回答"
    static var isDiscoverable: Bool = false

    @Parameter(title: "Session ID")
    var sessionId: String

    @Parameter(title: "Answer")
    var answer: String

    /// true = 回答せず Mac 側に質問を出す（保留の即解除）
    @Parameter(title: "Pass")
    var pass: Bool

    init() {
        sessionId = ""
        answer = ""
        pass = false
    }

    init(sessionId: String, answer: String, pass: Bool = false) {
        self.sessionId = sessionId
        self.answer = answer
        self.pass = pass
    }

    func perform() async throws -> some IntentResult {
        // 質問への回答も Mac 上の Claude Code を進める操作なので、
        // 操作モードがオフのあいだは行わない
        guard isControlModeEnabled else { return .result() }
        _ = await Self.sendAnswer(sessionId: sessionId, answer: answer, pass: pass)
        return .result()
    }

    /// Mac デーモンの /answer へ回答を送る。ライブアクティビティのボタンからも、
    /// ショートカット経由の自由入力（AnswerQuestionFromShortcutIntent）からも共有する。
    /// 経路のフォールバック（Bonjour サービス名 → 直近の LAN IP → 手動指定）は
    /// DaemonURL.swift の daemonRequest に集約している
    static func sendAnswer(sessionId: String, answer: String, pass: Bool) async -> Bool {
        guard let body = try? JSONSerialization.data(withJSONObject: [
            "sessionId": sessionId,
            "answer": answer,
            "pass": pass,
        ] as [String: Any]) else { return false }
        return await daemonRequestOK(path: "/answer", body: body)
    }
}
