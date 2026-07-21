import Foundation
import WatchConnectivity

/// Watch 側の状態管理。
/// - iPhone から WatchConnectivity の applicationContext でデーモン URL を受け取る
/// - Mac デーモン（claudelive-daemon）へ直接 HTTP でアクセスして
///   セッション一覧・会話全文の取得と、質問への回答を行う
@MainActor
final class WatchModel: NSObject, ObservableObject {
    static let shared = WatchModel()

    struct Session: Identifiable {
        let id: String        // sessionId
        var name: String
        var title: String
        var project: String
        var status: String
        var detail: String
        var currentTool: String
        var toolCount: Int
        var lastPrompt: String
        var lastResponse: String
        var question: String
        var options: [String]
        var model: String
    }

    struct Message: Identifiable {
        let id: Int
        var role: String
        var text: String
    }

    @Published var sessions: [Session] = []
    @Published var daemonURL: String = UserDefaults.standard.string(forKey: "daemonURL") ?? ""
    @Published var lastError: String?
    /// 直近の取得結果の診断表示（例 "OK 523B 12:34:56" / "解析失敗"）
    @Published var lastFetchInfo: String = "未取得"
    /// ライブアクティビティのタップで指定されたセッション（起動時に自動で開く）
    @Published var focusSessionId: String?

    private override init() {
        super.init()
        if WCSession.isSupported() {
            WCSession.default.delegate = self
            WCSession.default.activate()
        }
    }

    // MARK: - HTTP

    private func request(path: String, method: String = "GET", body: Data? = nil) async -> Data? {
        guard !daemonURL.isEmpty, let url = URL(string: daemonURL + path) else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 8)
        request.httpMethod = method
        request.httpBody = body
        if body != nil {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            let stamp = Date().formatted(date: .omitted, time: .standard)
            await MainActor.run {
                self.lastError = nil
                self.lastFetchInfo = "HTTP \(statusCode) \(data.count)B \(stamp)"
            }
            return data
        } catch {
            await MainActor.run { self.lastError = error.localizedDescription }
            return nil
        }
    }

    func refresh() async {
        guard let data = await request(path: "/sessions") else { return }
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let entries = object["sessions"] as? [[String: Any]] else {
            lastFetchInfo += " 解析失敗: " + (String(data: data.prefix(60), encoding: .utf8) ?? "?")
            return
        }
        sessions = entries.compactMap { entry in
            guard let id = entry["sessionId"] as? String else { return nil }
            return Session(
                id: id,
                name: entry["name"] as? String ?? "",
                title: entry["title"] as? String ?? "",
                project: entry["project"] as? String ?? "",
                status: entry["status"] as? String ?? "idle",
                detail: entry["detail"] as? String ?? "",
                currentTool: entry["currentTool"] as? String ?? "",
                toolCount: entry["toolCount"] as? Int ?? 0,
                lastPrompt: entry["lastPrompt"] as? String ?? "",
                lastResponse: entry["lastResponse"] as? String ?? "",
                question: entry["question"] as? String ?? "",
                options: entry["options"] as? [String] ?? [],
                model: entry["model"] as? String ?? "")
        }
    }

    func fetchMessages(sessionId: String) async -> [Message] {
        let encoded = sessionId.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)
            ?? sessionId
        guard let data = await request(path: "/messages?session=\(encoded)&limit=30"),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let entries = object["messages"] as? [[String: Any]] else { return [] }
        return entries.enumerated().map { index, entry in
            Message(id: index,
                    role: entry["role"] as? String ?? "",
                    text: entry["text"] as? String ?? "")
        }
    }

    /// AskUserQuestion への回答。iPhone の AnswerQuestionIntent と同じ /answer を叩く
    func answer(sessionId: String, answer: String) async {
        let payload: [String: Any] = ["sessionId": sessionId, "answer": answer]
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return }
        _ = await request(path: "/answer", method: "POST", body: body)
        await refresh()
    }

    /// プロンプト送信（音声ディクテーション/テキスト入力）。
    /// デーモンが claude -p --resume で該当セッションに注入する
    func sendPrompt(sessionId: String, text: String) async {
        let payload: [String: Any] = ["sessionId": sessionId, "text": text]
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return }
        _ = await request(path: "/prompt", method: "POST", body: body)
        await refresh()
    }

    @Published var projects: [(path: String, name: String)] = []

    /// 新規セッションを開始できるプロジェクト一覧を取得する
    func loadProjects() async {
        guard let data = await request(path: "/projects"),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let list = object["projects"] as? [[String: Any]] else { return }
        projects = list.compactMap { entry in
            guard let path = entry["path"] as? String,
                  let name = entry["name"] as? String else { return nil }
            return (path, name)
        }
    }

    /// 新規 Claude Code セッションを開始する（cwd で claude -p、--resume なし）
    func newSession(cwd: String, text: String) async {
        let payload: [String: Any] = ["cwd": cwd, "text": text]
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return }
        _ = await request(path: "/newsession", method: "POST", body: body)
        // 開始直後は SessionStart→push まで少し待ってから取得
        try? await Task.sleep(for: .seconds(2))
        await refresh()
    }
}

// MARK: - WatchConnectivity（iPhone からデーモン URL を受け取る）

extension WatchModel: WCSessionDelegate {
    nonisolated func session(_ session: WCSession,
                             activationDidCompleteWith activationState: WCSessionActivationState,
                             error: Error?) {
        // アクティベート済みの applicationContext があれば反映する
        let context = session.receivedApplicationContext
        Task { @MainActor in self.apply(context) }
    }

    nonisolated func session(_ session: WCSession,
                             didReceiveApplicationContext applicationContext: [String: Any]) {
        Task { @MainActor in self.apply(applicationContext) }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        Task { @MainActor in self.apply(message) }
    }

    nonisolated func session(_ session: WCSession,
                             didReceiveUserInfo userInfo: [String: Any] = [:]) {
        Task { @MainActor in self.apply(userInfo) }
    }

    /// 画面表示時などに、受信済みの applicationContext を改めて確認する
    /// （アクティベート完了より先に UI が出るケースの取りこぼし対策）
    func recheckContext() {
        guard WCSession.isSupported() else { return }
        apply(WCSession.default.receivedApplicationContext)
    }

    /// Watch 単体での手動設定（"100.x.x.x:53536" のような IP:ポート。
    /// スキーム・ポート省略可）。iPhone からの自動同期より優先される
    func setManualURL(_ input: String) {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if !text.hasPrefix("http://") && !text.hasPrefix("https://") {
            text = "http://" + text
        }
        if URL(string: text)?.port == nil {
            text += ":53536"
        }
        daemonURL = text
        UserDefaults.standard.set(text, forKey: "daemonURL")
        Task { await refresh() }
    }

    private func apply(_ context: [String: Any]) {
        guard var url = context["daemonURL"] as? String, !url.isEmpty else { return }
        // 過去に "%en0" のようなスコープ ID 付きで同期された値を修復する
        if url.contains("%"), let range = url.range(of: "%"),
           let colon = url[range.upperBound...].firstIndex(of: ":") {
            url = String(url[..<range.lowerBound]) + String(url[colon...])
        }
        if url != daemonURL {
            daemonURL = url
            UserDefaults.standard.set(url, forKey: "daemonURL")
            Task { await refresh() }
        }
    }
}
