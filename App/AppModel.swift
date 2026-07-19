import ActivityKit
import Combine
import Foundation
import Network
import SwiftUI
import UIKit

/// アプリ本体の状態管理。
/// 役割は 3 つ：
/// 1. push-to-start トークンと各アクティビティのプッシュトークンを監視する
/// 2. Bonjour で Mac デーモン（_claudelive._tcp）を発見する
/// 3. トークンをデーモンへ POST /register で登録する
@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    struct ActivityInfo: Identifiable {
        let id: String
        let sessionId: String
        let projectName: String
        var stateDescription: String
        var hasPushToken: Bool
    }

    struct RemoteSession: Identifiable {
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
    }

    struct ChatMessage: Identifiable {
        let id: Int           // 配列内の連番
        var role: String      // user / assistant
        var text: String
        var timestamp: String
    }

    @Published var pushToStartToken: String?
    @Published var activities: [ActivityInfo] = []
    @Published var remoteSessions: [RemoteSession] = []
    @Published var discoveredServers: [String] = []
    @Published var lastRegistration = "未登録"
    @Published var lastError: String?
    @Published var activitiesEnabled = ActivityAuthorizationInfo().areActivitiesEnabled

    /// sessionId -> per-activity push token (hex)
    private var activityTokens: [String: String] = [:]
    private var discoveredEndpoints: [NWEndpoint] = []
    private var browser: NWBrowser?
    private var observedActivityIds = Set<String>()

    private init() {
        startTokenObservation()
        startBrowser()
    }

    // MARK: - トークン監視

    private func startTokenObservation() {
        // push-to-start トークン（アプリ全体で 1 つ）
        Task {
            for await data in Activity<ClaudeActivityAttributes>.pushToStartTokenUpdates {
                let hex = Self.hex(data)
                await MainActor.run { self.pushToStartToken = hex }
                self.registerToServer()
            }
        }
        // 新しく始まったアクティビティ（push-to-start 起動含む）
        Task {
            for await activity in Activity<ClaudeActivityAttributes>.activityUpdates {
                await MainActor.run { self.track(activity) }
            }
        }
        for activity in Activity<ClaudeActivityAttributes>.activities {
            track(activity)
        }
    }

    private func track(_ activity: Activity<ClaudeActivityAttributes>) {
        refreshList()
        guard !observedActivityIds.contains(activity.id) else { return }
        observedActivityIds.insert(activity.id)

        // per-activity トークン。これを Mac に届けないと更新プッシュが送れない
        Task {
            for await tokenData in activity.pushTokenUpdates {
                let hex = Self.hex(tokenData)
                await MainActor.run {
                    self.activityTokens[activity.attributes.sessionId] = hex
                    self.refreshList()
                }
                self.registerToServer()
            }
        }
        Task {
            for await state in activity.activityStateUpdates {
                await MainActor.run {
                    if state == .dismissed || state == .ended {
                        self.activityTokens.removeValue(forKey: activity.attributes.sessionId)
                        // 終了を Mac に伝えて、死んだトークン宛てに送り続けるのを防ぐ
                        self.registerToServer()
                    }
                    self.refreshList()
                }
            }
        }
    }

    func refresh() {
        activitiesEnabled = ActivityAuthorizationInfo().areActivitiesEnabled
        for activity in Activity<ClaudeActivityAttributes>.activities {
            track(activity)
        }
        refreshList()
        adoptSessions()
        Task { await loadRemoteSessions() }
    }

    // MARK: - セッション一覧・会話（閲覧専用）

    /// GET を発見済み Bonjour エンドポイント → 手動指定の順に試して body を返す
    private func fetchData(path: String) async -> Data? {
        for endpoint in discoveredEndpoints {
            if let response = await httpRequest(method: "GET", path: path, body: nil, to: endpoint),
               let body = Self.httpResponseBody(response) {
                return body
            }
        }
        if let url = manualURL(path: path) {
            return try? await URLSession.shared.data(
                for: URLRequest(url: url, timeoutInterval: 5)).0
        }
        return nil
    }

    func loadRemoteSessions() async {
        guard let data = await fetchData(path: "/sessions"),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let entries = object["sessions"] as? [[String: Any]] else { return }
        remoteSessions = entries.compactMap { entry in
            guard let sessionId = entry["sessionId"] as? String else { return nil }
            return RemoteSession(
                id: sessionId,
                name: entry["name"] as? String ?? "",
                title: entry["title"] as? String ?? "",
                project: entry["project"] as? String ?? "",
                status: entry["status"] as? String ?? "idle",
                detail: entry["detail"] as? String ?? "",
                currentTool: entry["currentTool"] as? String ?? "",
                toolCount: entry["toolCount"] as? Int ?? 0,
                lastPrompt: entry["lastPrompt"] as? String ?? "",
                lastResponse: entry["lastResponse"] as? String ?? "")
        }
    }

    func fetchMessages(sessionId: String) async -> [ChatMessage]? {
        let encoded = sessionId.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)
            ?? sessionId
        guard let data = await fetchData(path: "/messages?session=\(encoded)&limit=60"),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let entries = object["messages"] as? [[String: Any]] else { return nil }
        return entries.enumerated().map { index, entry in
            ChatMessage(
                id: index,
                role: entry["role"] as? String ?? "assistant",
                text: entry["text"] as? String ?? "",
                timestamp: entry["timestamp"] as? String ?? "")
        }
    }

    // MARK: - Mac 側セッションの取り込み

    /// Mac の /status を見て、アクティビティが無い実行中セッションをローカルで立ち上げる。
    /// ローカル起動は push-to-start の budget を消費しないので、
    /// 表示が消えてもアプリを開けば復活できる
    func adoptSessions() {
        Task { await performAdoption() }
    }

    private func performAdoption() async {
        guard activitiesEnabled else { return }
        guard let data = await fetchData(path: "/sessions"),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let entries = object["sessions"] as? [[String: Any]] else { return }
        let host = object["host"] as? String ?? "Mac"
        let existing = Set(Activity<ClaudeActivityAttributes>.activities.map(\.attributes.sessionId))

        for entry in entries {
            let status = entry["status"] as? String ?? "idle"
            guard let sessionId = entry["sessionId"] as? String,
                  let project = entry["project"] as? String,
                  !existing.contains(sessionId),
                  status != "done", status != "idle" else { continue }
            let startedAt = (entry["startedAt"] as? Double)
                .map { Date(timeIntervalSince1970: $0) } ?? Date()
            let attributes = ClaudeActivityAttributes(
                sessionId: sessionId, projectName: project, hostName: host)
            let state = ClaudeActivityAttributes.ContentState(
                status: status,
                detail: "",
                currentTool: "",
                recentLogs: [],
                startedAt: startedAt,
                toolCount: 0,
                lastPrompt: "",
                lastResponse: "",
                sessionName: entry["name"] as? String ?? "",
                sessionTitle: entry["title"] as? String ?? "",
                question: "",
                options: [])
            // pushType .token なのでトークンが発行され、track → /register 経由で
            // Mac に渡り、以後の update はプッシュで届く
            if let activity = try? Activity.request(
                attributes: attributes,
                content: .init(state: state, staleDate: nil),
                pushType: .token) {
                track(activity)
            }
        }
    }

    private func refreshList() {
        activities = Activity<ClaudeActivityAttributes>.activities.map { a in
            ActivityInfo(
                id: a.id,
                sessionId: a.attributes.sessionId,
                projectName: a.attributes.projectName,
                stateDescription: ClaudeStatus(a.content.state.status).label,
                hasPushToken: activityTokens[a.attributes.sessionId] != nil
            )
        }
    }

    private static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Bonjour で Mac を発見

    private func startBrowser() {
        let params = NWParameters.tcp
        params.includePeerToPeer = true
        let browser = NWBrowser(for: .bonjour(type: "_claudelive._tcp", domain: nil), using: params)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor in
                guard let self else { return }
                self.discoveredEndpoints = results.map(\.endpoint)
                self.discoveredServers = results.compactMap {
                    if case let .service(name, _, _, _) = $0.endpoint { return name }
                    return nil
                }
                // 回答ボタン（AnswerQuestionIntent）が Bonjour サービス名で
                // 直接接続できるように保存しておく
                if let first = self.discoveredServers.first {
                    UserDefaults.standard.set(first, forKey: "lastServiceName")
                }
                self.registerToServer()
                self.adoptSessions()
            }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    // MARK: - デーモンへの登録

    func registerToServer() {
        Task { await performRegistration() }
    }

    private func performRegistration() async {
        var payload: [String: Any] = ["device": UIDevice.current.name]
        if let token = pushToStartToken { payload["pushToStartToken"] = token }
        // 「いま生きているアクティビティ」のスナップショットとして常に送る（空でも）。
        // Mac 側はここに無いセッションのトークンを破棄して再開始可能に戻す
        payload["activityTokens"] = activityTokens
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return }

        var success = false
        for endpoint in discoveredEndpoints {
            if await postOverConnection(body: body, to: endpoint) { success = true }
        }
        if let url = manualURL() {
            if await postOverURLSession(body: body, url: url) { success = true }
        }
        let stamp = Date().formatted(date: .omitted, time: .standard)
        await MainActor.run {
            self.lastRegistration = success
                ? "登録成功（\(stamp)）"
                : "登録失敗 — Mac に届いていません（\(stamp)）"
        }
    }

    private func manualURL(path: String = "/register") -> URL? {
        let host = UserDefaults.standard.string(forKey: "manualHost") ?? ""
        guard !host.isEmpty else { return nil }
        let hostPort = host.contains(":") ? host : "\(host):53536"
        return URL(string: "http://\(hostPort)\(path)")
    }

    /// Bonjour の service エンドポイントに直接 TCP 接続して素の HTTP/1.1 を話す
    /// （IP 解決を Network.framework に任せられるので確実）。
    /// レスポンス全体（ヘッダ含む）を返す。失敗・タイムアウトは nil
    private func httpRequest(method: String, path: String, body: Data?,
                             to endpoint: NWEndpoint) async -> Data? {
        await withCheckedContinuation { continuation in
            let queue = DispatchQueue(label: "claudelive.http")
            let connection = NWConnection(to: endpoint, using: .tcp)
            var response = Data()
            var finished = false
            let finish: (Data?) -> Void = { data in
                queue.async {
                    guard !finished else { return }
                    finished = true
                    connection.cancel()
                    continuation.resume(returning: data)
                }
            }
            queue.asyncAfter(deadline: .now() + 5) { finish(nil) }
            func receiveLoop() {
                connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) {
                    data, _, isComplete, error in
                    if let data { response.append(data) }
                    if error != nil {
                        finish(nil)
                    } else if isComplete {
                        finish(response)
                    } else {
                        receiveLoop()
                    }
                }
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    // 接続先の実 IP を保存しておく。ライブアクティビティの回答ボタン
                    // （AnswerQuestionIntent）が Bonjour 解決なしで即 POST できるように
                    if case let .hostPort(host, port)? = connection.currentPath?.remoteEndpoint {
                        let hostText = "\(host)"
                        if !hostText.contains(":") {  // IPv6（スコープ付き）は URL にしにくいので除外
                            UserDefaults.standard.set(
                                "http://\(hostText):\(port)", forKey: "lastDaemonURL")
                        }
                    }
                    var request = Data(
                        "\(method) \(path) HTTP/1.1\r\nHost: claudelive\r\nConnection: close\r\n".utf8)
                    if let body {
                        request.append(Data(
                            "Content-Type: application/json\r\nContent-Length: \(body.count)\r\n\r\n".utf8))
                        request.append(body)
                    } else {
                        request.append(Data("\r\n".utf8))
                    }
                    connection.send(content: request, completion: .contentProcessed { error in
                        if error != nil { finish(nil) } else { receiveLoop() }
                    })
                case .failed:
                    finish(nil)
                default:
                    break
                }
            }
            connection.start(queue: queue)
        }
    }

    private static func httpResponseBody(_ response: Data) -> Data? {
        guard let range = response.range(of: Data("\r\n\r\n".utf8)),
              String(data: response.prefix(64), encoding: .utf8)?.contains(" 200 ") == true
        else { return nil }
        return Data(response[range.upperBound...])
    }

    private func postOverConnection(body: Data, to endpoint: NWEndpoint) async -> Bool {
        guard let response = await httpRequest(
            method: "POST", path: "/register", body: body, to: endpoint) else { return false }
        return String(data: response.prefix(64), encoding: .utf8)?.contains(" 200 ") == true
    }

    private func postOverURLSession(body: Data, url: URL) async -> Bool {
        var request = URLRequest(url: url, timeoutInterval: 5)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        guard let (_, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse else { return false }
        return http.statusCode == 200
    }

    // MARK: - ローカルテスト（APNs なしで UI を確認する用）

    private var testStatusIndex = 0

    func startTestActivity() {
        lastError = nil
        let attrs = ClaudeActivityAttributes(
            sessionId: "test",
            projectName: "BomberMP",
            hostName: "ローカルテスト")
        let state = ClaudeActivityAttributes.ContentState(
            status: "working",
            detail: "",
            currentTool: "Bash",
            recentLogs: [
                "⚙️ Bash: xcodebuild test -scheme BomberMP",
                "✏️ Edit: Simulation.swift",
                "📖 Read: GameState.swift",
            ],
            startedAt: Date(),
            toolCount: 12,
            lastPrompt: "決定性のリプレイテストを追加して、CI で毎回回るようにして",
            lastResponse: "",
            sessionName: "claud-test",
            sessionTitle: "決定性のリプレイテストを追加して、CI で毎回回るようにして",
            question: "",
            options: [])
        do {
            let activity = try Activity.request(
                attributes: attrs,
                content: .init(state: state, staleDate: nil),
                pushType: .token)
            track(activity)
            testStatusIndex = 0
        } catch {
            lastError = "テスト開始に失敗: \(error.localizedDescription)"
        }
    }

    func cycleTestActivity() {
        let cycle: [(status: String, detail: String, tool: String, prompt: String,
                     response: String, question: String, options: [String])] = [
            ("permission", "Bash の実行許可を求めています", "", "", "", "", []),
            ("question", "", "", "", "",
             "リプレイテストはどの粒度で追加しますか？",
             ["毎 tick 検証", "最終状態のみ", "両方", "Macで決める"]),
            ("waiting", "", "", "", "", "", []),
            ("done", "", "", "",
             "決定性のリプレイテストを追加しました。同じ seed と入力列を2つの独立した State に流し、最終チェックサムが一致することを assert しています。テストは green です。",
             "", []),
            ("working", "", "Edit", "GameState.swift の Player 構造体を整理して", "", "", []),
        ]
        testStatusIndex = (testStatusIndex + 1) % cycle.count
        let entry = cycle[testStatusIndex]
        Task {
            for activity in Activity<ClaudeActivityAttributes>.activities
            where activity.attributes.sessionId == "test" {
                var state = activity.content.state
                state.status = entry.status
                state.detail = entry.detail
                state.currentTool = entry.tool
                if !entry.prompt.isEmpty { state.lastPrompt = entry.prompt }
                state.lastResponse = entry.response
                state.question = entry.question
                state.options = entry.options
                await activity.update(.init(state: state, staleDate: nil))
            }
        }
    }

    /// マーキー（横スクロール）の見た目だけを確認するための専用テスト。
    /// Mac / APNs を一切経由しないので、push-to-start budget の枯渇や
    /// AskUserQuestion の hooks 保留とは無関係に何度でも試せる。
    /// 質問文と返答は同時に表示されない（質問優先）ので、2 パターンに分ける
    func testMarqueeQuestion() {
        Task {
            for activity in Activity<ClaudeActivityAttributes>.activities
            where activity.attributes.sessionId == "test" {
                var state = activity.content.state
                state.status = "question"
                state.detail = ""
                state.currentTool = ""
                state.question = "マーキーのテストです。この質問文はわざと長く作っていて、1行に収まらないはずです。流れて見えていますか？"
                state.options = ["流れて読める", "流れているが遅い/速い", "流れていない"]
                await activity.update(.init(state: state, staleDate: nil))
            }
        }
    }

    func testMarqueeResponse() {
        Task {
            for activity in Activity<ClaudeActivityAttributes>.activities
            where activity.attributes.sessionId == "test" {
                var state = activity.content.state
                state.status = "working"
                state.detail = ""
                state.currentTool = ""
                state.question = ""
                state.options = []
                state.lastPrompt = ""
                state.lastResponse = "こちらは返答テキストのマーキーテストです。同じくわざと長く作った文章が横に流れるかどうかを、質問カードとは別に確認できます。"
                await activity.update(.init(state: state, staleDate: nil))
            }
        }
    }

    func testMarqueePrompt() {
        Task {
            for activity in Activity<ClaudeActivityAttributes>.activities
            where activity.attributes.sessionId == "test" {
                var state = activity.content.state
                state.status = "working"
                state.detail = ""
                state.currentTool = ""
                state.question = ""
                state.options = []
                state.lastResponse = ""
                state.lastPrompt = "こちらはユーザー入力のマーキーテストです。わざと長く作った文章が横に流れるかどうかを確認できます。"
                await activity.update(.init(state: state, staleDate: nil))
            }
        }
    }

    func endTestActivities() {
        Task {
            for activity in Activity<ClaudeActivityAttributes>.activities
            where activity.attributes.sessionId == "test" {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
            await MainActor.run { self.refreshList() }
        }
    }
}
