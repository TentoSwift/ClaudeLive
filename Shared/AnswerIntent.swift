import AppIntents
import Foundation
import Network

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

        let defaults = UserDefaults.standard

        // 1. Bonjour サービス名へ直接接続（IP アドレスに依存しない最も確実な経路）
        if let serviceName = defaults.string(forKey: "lastServiceName"),
           await Self.postOverService(name: serviceName, body: body) {
            return .result()
        }

        // 2. 保存済み URL / 手動指定へのフォールバック
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

    /// Bonjour サービスエンドポイントへ TCP 接続して素の HTTP/1.1 で POST する
    /// （アプリ本体のトークン登録と同じ方式。名前解決は Network.framework 任せ）
    private static func postOverService(name: String, body: Data) async -> Bool {
        let endpoint = NWEndpoint.service(
            name: name, type: "_claudelive._tcp", domain: "local", interface: nil)
        return await withCheckedContinuation { continuation in
            let queue = DispatchQueue(label: "claudelive.answer")
            let connection = NWConnection(to: endpoint, using: .tcp)
            var finished = false
            let finish: (Bool) -> Void = { ok in
                queue.async {
                    guard !finished else { return }
                    finished = true
                    connection.cancel()
                    continuation.resume(returning: ok)
                }
            }
            queue.asyncAfter(deadline: .now() + 6) { finish(false) }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    var request = Data(
                        "POST /answer HTTP/1.1\r\nHost: claudelive\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
                    request.append(body)
                    connection.send(content: request, completion: .contentProcessed { error in
                        guard error == nil else { finish(false); return }
                        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) {
                            data, _, _, _ in
                            let head = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                            finish(head.contains(" 200 "))
                        }
                    })
                case .failed:
                    finish(false)
                default:
                    break
                }
            }
            connection.start(queue: queue)
        }
    }
}
