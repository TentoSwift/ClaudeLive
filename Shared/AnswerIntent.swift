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
        guard let body = try? JSONSerialization.data(withJSONObject: [
            "sessionId": sessionId,
            "answer": answer,
            "pass": pass,
        ] as [String: Any]) else { return .result() }

        // 直近の接続で確認できたデーモン URL → 手動指定の順に試す
        let defaults = UserDefaults.standard
        var urls: [URL] = []
        if let saved = defaults.string(forKey: "lastDaemonURL"),
           let url = URL(string: saved + "/answer") {
            urls.append(url)
        }
        if let manual = defaults.string(forKey: "manualHost"), !manual.isEmpty {
            let hostPort = manual.contains(":") ? manual : "\(manual):53536"
            if let url = URL(string: "http://\(hostPort)/answer") {
                urls.append(url)
            }
        }
        for url in urls {
            var request = URLRequest(url: url, timeoutInterval: 5)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = body
            if let (_, response) = try? await URLSession.shared.data(for: request),
               (response as? HTTPURLResponse)?.statusCode == 200 {
                break
            }
        }
        return .result()
    }
}
