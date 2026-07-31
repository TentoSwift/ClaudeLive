import Foundation
import WatchConnectivity

/// Watch 側の状態管理。
/// Mac デーモンとは直接通信せず、WatchConnectivity で iPhone アプリ（WatchLink）に
/// リクエストを送り、iPhone が Mac デーモンへ中継した結果を受け取る
@MainActor
final class WatchModel: NSObject, ObservableObject {
    static let shared = WatchModel()

    /// AskUserQuestion の 1 問分（multiSelect なら複数選択できる）
    struct QuestionItem: Identifiable {
        let id = UUID()
        var question: String
        var options: [String]
        var multiSelect: Bool
    }

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
        /// 質問がすべて入る（1回の AskUserQuestion に複数問あることがある）
        var questions: [QuestionItem]
    }

    struct Message: Identifiable {
        let id: Int
        var role: String
        var text: String
    }

    @Published var sessions: [Session] = []
    @Published var lastError: String?
    /// 直近の取得結果の診断表示（例 "OK 523B 12:34:56" / "解析失敗"）
    @Published var lastFetchInfo: String = "未取得"
    /// iPhone アプリ（WatchLink）に到達できているか
    @Published var isReachable: Bool = false
    /// ライブアクティビティのタップで指定されたセッション（起動時に自動で開く）
    @Published var focusSessionId: String?

    private override init() {
        super.init()
        if WCSession.isSupported() {
            WCSession.default.delegate = self
            WCSession.default.activate()
        }
    }

    // MARK: - iPhone 経由のリクエスト

    /// iPhone アプリ（WatchLink）へ WatchConnectivity のメッセージで送り、
    /// iPhone が Mac デーモンへ中継した結果を受け取る
    private func request(path: String, method: String = "GET", body: Data? = nil) async -> Data? {
        guard WCSession.default.activationState == .activated else {
            await MainActor.run { self.lastError = "iPhone未接続" }
            return nil
        }
        guard WCSession.default.isReachable else {
            await MainActor.run { self.lastError = "iPhone に到達できません（アプリを開いてください）" }
            return nil
        }
        var message: [String: Any] = ["path": path, "method": method]
        if let body { message["body"] = String(data: body, encoding: .utf8) ?? "" }
        return await withCheckedContinuation { continuation in
            WCSession.default.sendMessage(message, replyHandler: { reply in
                Task { @MainActor in
                    // iPhone 側の操作モードを UserDefaults へ書き戻す。
                    // Watch の @AppStorage(controlModeKey) はこれで自動更新され、
                    // 質問回答・送信系 UI の表示が iPhone の設定に追従する
                    if let mode = reply["controlMode"] as? Bool {
                        UserDefaults.standard.set(mode, forKey: controlModeKey)
                    }
                    let stamp = Date().formatted(date: .omitted, time: .standard)
                    if let text = reply["data"] as? String {
                        self.lastError = nil
                        self.lastFetchInfo = "OK \(text.utf8.count)B \(stamp)"
                        continuation.resume(returning: text.data(using: .utf8))
                    } else {
                        self.lastError = reply["error"] as? String ?? "不明なエラー"
                        continuation.resume(returning: nil)
                    }
                }
            }, errorHandler: { error in
                Task { @MainActor in
                    self.lastError = error.localizedDescription
                    continuation.resume(returning: nil)
                }
            })
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
                model: entry["model"] as? String ?? "",
                questions: (entry["questions"] as? [[String: Any]] ?? []).map { q in
                    QuestionItem(
                        question: q["question"] as? String ?? "",
                        options: q["options"] as? [String] ?? [],
                        multiSelect: q["multiSelect"] as? Bool ?? false)
                })
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

    /// AskUserQuestion への回答（単一質問・単一選択の簡易版）。
    /// iPhone の AnswerQuestionIntent と同じ /answer を叩く
    func answer(sessionId: String, answer: String) async {
        await self.answer(sessionId: sessionId, answers: [[answer]])
    }

    /// 質問ごとの選択結果をまとめて回答する（複数質問・複数選択(multiSelect)対応）
    func answer(sessionId: String, answers: [[String]]) async {
        let payload: [String: Any] = ["sessionId": sessionId, "answers": answers]
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

    /// 新規 Claude Code セッションを開始する（cwd で claude -p、--resume なし）。
    /// model 省略時は CLI の既定モデルを使う
    func newSession(cwd: String, text: String, model: String = "") async {
        var payload: [String: Any] = ["cwd": cwd, "text": text]
        if !model.isEmpty { payload["model"] = model }
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return }
        _ = await request(path: "/newsession", method: "POST", body: body)
        // 開始直後は SessionStart→push まで少し待ってから取得
        try? await Task.sleep(for: .seconds(2))
        await refresh()
    }

    /// 既存セッションのモデルを変更する（実体は /model <id> の送信）
    func changeModel(sessionId: String, model: String) async {
        let payload: [String: Any] = ["sessionId": sessionId, "model": model]
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return }
        _ = await request(path: "/changemodel", method: "POST", body: body)
    }

    /// 既存セッションにスラッシュコマンドを送る（例 /compact）
    func sendCommand(sessionId: String, command: String) async {
        let payload: [String: Any] = ["sessionId": sessionId, "command": command]
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return }
        _ = await request(path: "/command", method: "POST", body: body)
    }
}

// MARK: - WatchConnectivity（iPhone アプリとの接続状態）

extension WatchModel: WCSessionDelegate {
    nonisolated func session(_ session: WCSession,
                             activationDidCompleteWith activationState: WCSessionActivationState,
                             error: Error?) {
        Task { @MainActor in
            self.isReachable = session.isReachable
            if session.isReachable { await self.refresh() }
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor in
            self.isReachable = session.isReachable
            if session.isReachable { await self.refresh() }
        }
    }

    /// 画面表示時などに、現在の到達性を改めて確認する
    /// （アクティベート完了より先に UI が出るケースの取りこぼし対策）
    func recheckContext() {
        guard WCSession.isSupported() else { return }
        isReachable = WCSession.default.isReachable
    }
}
