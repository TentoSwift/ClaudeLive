import Foundation
import Network
import Observation

/// visionOS 版の単一データソース。
/// 2 秒間隔で `GET /sessions` をポーリングし、全ウィンドウ（ダッシュボード・
/// タイル）がこれを購読する。ウィンドウが何枚あってもポーリングは 1 本。
@Observable
@MainActor
final class VisionAppModel {

    /// デーモンの /sessions が返す 1 セッションぶん。
    /// iPhone 版 AppModel.RemoteSession と同じフィールド構成
    struct Session: Identifiable {
        let id: String        // sessionId
        var name: String
        var title: String
        var project: String
        var status: String
        var detail: String
        var currentTool: String
        var toolCount: Int
        var startedAt: Date
        var lastPrompt: String
        var lastResponse: String
        var question: String
        var options: [String]
        var questions: [QuestionItem]
        var model: String
    }

    struct QuestionItem {
        var question: String
        var options: [String]
        var multiSelect: Bool
    }

    struct Message: Identifiable {
        let id: Int
        var role: String
        var text: String
    }

    private(set) var sessions: [Session] = []
    /// 直近のポーリングが成功したか。3 回連続で失敗すると false になり、
    /// 画面は「接続断」表示に切り替わる
    private(set) var isConnected = false
    private(set) var lastError: String?

    /// ポーリングを希望しているビューの数（ダッシュボード・タイルの .task が増減させる）。
    /// 0 → 1 で開始、1 → 0 で停止。scenePhase の管理を各ビューに散らさずに済む
    private var pollingSubscribers = 0
    private var pollingTask: Task<Void, Never>?
    private var consecutiveFailures = 0

    // MARK: - ポーリング

    func beginPolling() {
        pollingSubscribers += 1
        guard pollingTask == nil else { return }
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshSessions()
                // 失敗が続いたら指数バックオフ（最大 30 秒）で叩きすぎない
                let failures = self?.consecutiveFailures ?? 0
                let interval: Duration = failures >= 3
                    ? .seconds(min(30, 2 << min(failures, 4)))
                    : .seconds(2)
                try? await Task.sleep(for: interval)
            }
        }
    }

    func endPolling() {
        pollingSubscribers = max(0, pollingSubscribers - 1)
        if pollingSubscribers == 0 {
            pollingTask?.cancel()
            pollingTask = nil
        }
    }

    func refreshSessions() async {
        guard let data = await daemonRequest(path: "/sessions"),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let entries = object["sessions"] as? [[String: Any]] else {
            consecutiveFailures += 1
            if consecutiveFailures >= 3 {
                isConnected = false
                lastError = "Mac に接続できません"
            }
            return
        }
        consecutiveFailures = 0
        isConnected = true
        lastError = nil
        sessions = entries.compactMap { entry in
            guard let sessionId = entry["sessionId"] as? String else { return nil }
            return Session(
                id: sessionId,
                name: entry["name"] as? String ?? "",
                title: entry["title"] as? String ?? "",
                project: entry["project"] as? String ?? "",
                status: entry["status"] as? String ?? "idle",
                detail: entry["detail"] as? String ?? "",
                currentTool: entry["currentTool"] as? String ?? "",
                toolCount: entry["toolCount"] as? Int ?? 0,
                startedAt: Date(timeIntervalSince1970:
                    TimeInterval(entry["startedAt"] as? Int ?? Int(Date().timeIntervalSince1970))),
                lastPrompt: entry["lastPrompt"] as? String ?? "",
                lastResponse: entry["lastResponse"] as? String ?? "",
                question: entry["question"] as? String ?? "",
                options: entry["options"] as? [String] ?? [],
                questions: (entry["questions"] as? [[String: Any]] ?? []).map { q in
                    QuestionItem(
                        question: q["question"] as? String ?? "",
                        options: q["options"] as? [String] ?? [],
                        multiSelect: q["multiSelect"] as? Bool ?? false)
                },
                model: entry["model"] as? String ?? "")
        }
    }

    func session(id: String) -> Session? {
        sessions.first { $0.id == id }
    }

    // MARK: - 会話

    func fetchMessages(sessionId: String, limit: Int = 30) async -> [Message] {
        guard let data = await daemonRequest(path: "/messages?session=\(sessionId)&limit=\(limit)"),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let entries = object["messages"] as? [[String: Any]] else { return [] }
        return entries.enumerated().map { index, entry in
            Message(id: index,
                    role: entry["role"] as? String ?? "",
                    text: entry["text"] as? String ?? "")
        }
    }

    // MARK: - 操作（操作モード ON のときだけ UI から呼ばれる）

    func sendPrompt(sessionId: String, text: String) async -> Bool {
        let payload: [String: Any] = ["sessionId": sessionId, "text": text]
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return false }
        return await daemonRequestOK(path: "/prompt", body: body)
    }

    func answer(sessionId: String, answers: [[String]], pass: Bool = false) async -> Bool {
        let payload: [String: Any] = ["sessionId": sessionId, "answers": answers, "pass": pass]
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return false }
        return await daemonRequestOK(path: "/answer", body: body)
    }

    func sendCommand(sessionId: String, command: String) async -> Bool {
        let payload: [String: Any] = ["sessionId": sessionId, "command": command]
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return false }
        return await daemonRequestOK(path: "/command", body: body)
    }

    func changeModel(sessionId: String, model: String) async -> Bool {
        let payload: [String: Any] = ["sessionId": sessionId, "model": model]
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return false }
        return await daemonRequestOK(path: "/changemodel", body: body)
    }

    // MARK: - Bonjour 発見

    /// _claudelive._tcp をブラウズして、見つけたサービス名を lastServiceName に保存する。
    /// daemonRequest はこの保存値を経路のひとつとして使う（IP に依存しない）。
    /// tailscaleOnly の Mac は Bonjour を広告しないので、その場合は
    /// 設定画面の手動指定（manualHost）だけが経路になる
    private var browser: NWBrowser?

    func startBrowsing() {
        guard browser == nil else { return }
        let browser = NWBrowser(
            for: .bonjour(type: "_claudelive._tcp", domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { results, _ in
            guard case .service(let name, _, _, _)? = results.first?.endpoint else { return }
            DispatchQueue.main.async {
                UserDefaults.standard.set(name, forKey: "lastServiceName")
            }
        }
        browser.start(queue: .main)
        self.browser = browser
    }
}
