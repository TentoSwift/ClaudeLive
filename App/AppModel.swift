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

    /// AskUserQuestion の 1 問分（multiSelect なら複数選択できる）
    struct QuestionItem: Identifiable {
        let id = UUID()
        var question: String
        var options: [String]
        var multiSelect: Bool
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
        var question: String
        var options: [String]
        /// 質問がすべて入る（1回の AskUserQuestion に複数問あることがある）。
        /// question/options は互換用に先頭1問を反映したもの
        var questions: [QuestionItem]
    }

    struct ChatMessage: Identifiable {
        let id: Int           // 配列内の連番
        var role: String      // user / assistant
        var text: String
        var timestamp: String
    }

    @Published var pushToStartToken: String?
    @Published var activities: [ActivityInfo] = []
    /// DI コンパクトの作業中アイコンをコマ送りアニメーションにするか。
    /// 過去にこれが原因でライブアクティビティが強制終了される不具合を
    /// 起こしたため、検証用に設定画面からオン/オフできるようにした
    @Published var compactAnimated: Bool = UserDefaults.standard.bool(forKey: "compactAnimated") {
        didSet {
            UserDefaults.standard.set(compactAnimated, forKey: "compactAnimated")
            registerToServer()
        }
    }
    /// ライブアクティビティの見た目をアプリ内でそのまま再現するプレビュー用。
    /// 複数アクティビティがあっても直近に観測した1つだけを表示する
    @Published var mirrorAttributes: ClaudeActivityAttributes?
    @Published var mirrorState: ClaudeActivityAttributes.ContentState?
    @Published var remoteSessions: [RemoteSession] = []
    @Published var discoveredServers: [String] = []
    @Published var lastRegistration = "未登録"
    @Published var lastError: String?
    @Published var activitiesEnabled = ActivityAuthorizationInfo().areActivitiesEnabled
    /// ライブアクティビティのタップ（claudelive://session/<id>）で指定されたセッション。
    /// ContentView がこれを見て該当セッションの詳細画面へ遷移する
    @Published var focusSessionId: String?

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
        mirrorAttributes = activity.attributes
        mirrorState = activity.content.state
        guard !observedActivityIds.contains(activity.id) else { return }
        observedActivityIds.insert(activity.id)

        // アプリ内プレビュー用に、このアクティビティの状態変化をそのまま反映する
        Task {
            for await content in activity.contentUpdates {
                await MainActor.run {
                    self.mirrorAttributes = activity.attributes
                    self.mirrorState = content.state
                }
            }
        }
        Task {
            for await state in activity.activityStateUpdates where state == .dismissed || state == .ended {
                await MainActor.run {
                    if self.mirrorAttributes?.sessionId == activity.attributes.sessionId {
                        self.mirrorAttributes = nil
                        self.mirrorState = nil
                    }
                }
            }
        }

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
        checkPendingFocusSession()
    }

    /// ライブアクティビティの「開いて回答」ボタン（OpenSessionIntent）が
    /// UserDefaults に書いたセッション ID を拾う。App Intent はウィジェット拡張の
    /// プロセスで動くため、直接 focusSessionId を書き込めずこの経由で受け渡す
    private func checkPendingFocusSession() {
        let defaults = UserDefaults.standard
        guard let sessionId = defaults.string(forKey: "pendingFocusSessionId"), !sessionId.isEmpty else { return }
        defaults.removeObject(forKey: "pendingFocusSessionId")
        focusSessionId = sessionId
    }

    // MARK: - セッション一覧・会話（閲覧専用）

    /// GET を発見済み Bonjour エンドポイント・手動指定に同時に投げて、最初に
    /// 成功したものを返す。以前は順番に1つずつタイムアウトを待っていたため、
    /// Wi-Fi を切っていると（＝ Bonjour エンドポイントは必ずタイムアウトする）
    /// 手動指定（Tailscale の IP など）が生きていても、その順番待ちで
    /// 全体がタイムアウトしてしまっていた
    private func fetchData(path: String) async -> Data? {
        await withTaskGroup(of: Data?.self) { group in
            for endpoint in discoveredEndpoints {
                group.addTask {
                    guard let response = await self.httpRequest(
                        method: "GET", path: path, body: nil, to: endpoint) else { return nil }
                    return Self.httpResponseBody(response)
                }
            }
            if let url = manualURL(path: path) {
                group.addTask {
                    var request = URLRequest(url: url, timeoutInterval: 5)
                    if !daemonAuthToken.isEmpty {
                        request.setValue("Bearer \(daemonAuthToken)",
                                         forHTTPHeaderField: "Authorization")
                    }
                    // ステータスコードを見ないと 401 の本文を「成功」として返してしまい、
                    // 並行して走っている正しい経路の結果を打ち消してしまう
                    guard let (data, response) = try? await URLSession.shared.data(for: request),
                          (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
                    return data
                }
            }
            for await result in group {
                if let result {
                    group.cancelAll()
                    return result
                }
            }
            return nil
        }
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
                lastResponse: entry["lastResponse"] as? String ?? "",
                question: entry["question"] as? String ?? "",
                options: entry["options"] as? [String] ?? [],
                questions: (entry["questions"] as? [[String: Any]] ?? []).map { q in
                    QuestionItem(
                        question: q["question"] as? String ?? "",
                        options: q["options"] as? [String] ?? [],
                        multiSelect: q["multiSelect"] as? Bool ?? false)
                })
        }
    }

    /// AskUserQuestion への回答（単一質問・単一選択のときの簡易版。
    /// 選択肢ボタン・自由入力のどちらからも使う）
    func answer(sessionId: String, answer: String) async {
        await self.answer(sessionId: sessionId, answers: [[answer]])
    }

    /// 質問ごとの選択結果をまとめて回答する（複数質問・複数選択(multiSelect)対応）。
    /// answers は questions と同じ並びで、multiSelect の質問は複数要素になる
    func answer(sessionId: String, answers: [[String]]) async {
        let payload: [String: Any] = ["sessionId": sessionId, "answers": answers]
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return }
        _ = await relayRequest(path: "/answer", method: "POST", bodyData: body)
        await loadRemoteSessions()
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

    // MARK: - 新規セッション開始

    @Published var projects: [(path: String, name: String)] = []

    /// 新規セッションを開始できるプロジェクト（過去に使った cwd）一覧を取得する
    func loadProjects() async {
        guard let data = await fetchData(path: "/projects"),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let list = object["projects"] as? [[String: Any]] else { return }
        projects = list.compactMap { entry in
            guard let path = entry["path"] as? String,
                  let name = entry["name"] as? String else { return nil }
            return (path, name)
        }
    }

    /// 新規 Claude Code セッションを開始する（cwd で `claude -p`、--resume なし）。
    /// model 省略時は CLI の既定モデルを使う
    func startNewSession(cwd: String, text: String, model: String = "") async {
        var payload: [String: Any] = ["cwd": cwd, "text": text]
        if !model.isEmpty { payload["model"] = model }
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return }
        _ = await relayRequest(path: "/newsession", method: "POST", bodyData: body)
        // 開始直後は SessionStart → push まで少し待ってから取得
        try? await Task.sleep(for: .seconds(2))
        await loadRemoteSessions()
    }

    // MARK: - Apple Watch からの中継（WatchLink 経由）

    /// Watch から WatchConnectivity で届いたリクエストを Mac デーモンへ中継する。
    /// Watch は Mac と直接通信せず、必ずこの iPhone アプリを経由する
    func relayRequest(path: String, method: String, bodyData: Data?) async -> Data? {
        if method == "GET" {
            return await fetchData(path: path)
        }
        return await withTaskGroup(of: Data?.self) { group in
            for endpoint in discoveredEndpoints {
                group.addTask {
                    guard let response = await self.httpRequest(
                        method: method, path: path, body: bodyData, to: endpoint) else { return nil }
                    return Self.httpResponseBody(response)
                }
            }
            if let url = manualURL(path: path) {
                group.addTask {
                    var request = URLRequest(url: url, timeoutInterval: 8)
                    request.httpMethod = method
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    if !daemonAuthToken.isEmpty {
                        request.setValue("Bearer \(daemonAuthToken)", forHTTPHeaderField: "Authorization")
                    }
                    request.httpBody = bodyData
                    guard let (data, response) = try? await URLSession.shared.data(for: request),
                          (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
                    return data
                }
            }
            for await result in group {
                if let result {
                    group.cancelAll()
                    return result
                }
            }
            return nil
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
                  // Mac 側は「入力待ち」をライブアクティビティに残さない設計
                  // （Notification フックで pushEnd 済み）。ここで拾い直して
                  // 復活させると意図が崩れるので、waiting も対象外にする
                  status != "done", status != "idle", status != "waiting" else { continue }
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
                options: [],
                textSettled: false,
                model: "",
                compactAnimated: compactAnimated,
                lastTool: "")
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

    /// 直列化された登録が実行中か。実行中に来た呼び出しは早期リターンし、
    /// pendingRegistration を立てるだけにする
    private var isRegistering = false
    /// 実行中に追加の registerToServer() 呼び出しがあったか
    private var pendingRegistration = false

    /// activityTokens のスナップショットを Mac へ送る。
    ///
    /// 呼び出しごとに Task { await performRegistration() } と fire-and-forget して
    /// いた頃は、複数の登録が同時に飛べてしまっていた。performRegistration は
    /// 呼ばれた瞬間の activityTokens を捕まえてから非同期にネットワーク送信する
    /// ため、「トークンがまだ揃っていない古いスナップショット」の送信が、
    /// 「トークンが揃った新しいスナップショット」の送信より後にサーバへ届く
    /// ことがあった。デーモン側は「送られてきたスナップショットに無いセッションは
    /// ユーザーが消した」と解釈するため、揃っているはずのセッションが誤って
    /// 「ユーザーが消した」扱いになり、以後ライブアクティビティが二度と
    /// 自動再表示されなくなる不具合があった
    /// （push-to-start 直後の pushTokenUpdates 到着と、他のイベントからの
    /// registerToServer() 呼び出しが競合しやすかった）。
    ///
    /// 実行中は新規送信をせず、完了後に「実行中にもう一度呼ばれたか」だけを見て
    /// 最新のスナップショットで 1 回だけ送り直す。常に「直前の送信が完了してから
    /// 次を送る」順序になるので、古いスナップショットが新しいものを追い越して
    /// 届くことがなくなる
    func registerToServer() {
        guard !isRegistering else {
            pendingRegistration = true
            return
        }
        isRegistering = true
        Task {
            await performRegistration()
            isRegistering = false
            if pendingRegistration {
                pendingRegistration = false
                registerToServer()
            }
        }
    }

    private func performRegistration() async {
        var payload: [String: Any] = ["device": UIDevice.current.name]
        payload["compactAnimated"] = compactAnimated
        if let token = pushToStartToken { payload["pushToStartToken"] = token }
        // 質問プッシュ通知（返信アクション付き）用のリモート通知トークン
        if let remoteToken = UserDefaults.standard.string(forKey: "remoteDeviceToken") {
            payload["remoteDeviceToken"] = remoteToken
        }
        // 「いま生きているアクティビティ」のスナップショットとして常に送る（空でも）。
        // Mac 側はここに無いセッションのトークンを破棄して再開始可能に戻す
        payload["activityTokens"] = activityTokens
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return }

        // 発見済みエンドポイント・手動指定すべてに同時に登録を投げる（生きている
        // Mac 全部に届けたいので、こちらは先着1つで打ち切らず全部の結果を待つ）。
        // 順番に1つずつタイムアウトを待つと、Wi-Fi を切っているときに
        // 手動指定（Tailscale の IP など）が生きていても届くのが遅れていた
        let success = await withTaskGroup(of: Bool.self) { group -> Bool in
            for endpoint in discoveredEndpoints {
                group.addTask { await self.postOverConnection(body: body, to: endpoint) }
            }
            if let url = manualURL() {
                group.addTask {
                    let ok = await self.postOverURLSession(body: body, url: url)
                    // 手動指定（Tailscale の IP など）で届いた場合も、その URL を
                    // 回答ボタンや Watch が使えるように保存する
                    if ok, let scheme = url.scheme, let host = url.host, let port = url.port {
                        UserDefaults.standard.set("\(scheme)://\(host):\(port)", forKey: "lastDaemonURL")
                    }
                    return ok
                }
            }
            var anySuccess = false
            for await ok in group where ok {
                anySuccess = true
            }
            return anySuccess
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
        return URL(string: "http://\(normalizedManualHostPort(host))\(path)")
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
                        // NWEndpoint.Host の文字列化は IPv4 でも "%en0" のような
                        // スコープ ID が付くことがある。URL に使えないので落とす
                        let hostText = "\(host)".components(separatedBy: "%").first ?? "\(host)"
                        if !hostText.contains(":") {  // IPv6（スコープ付き）は URL にしにくいので除外
                            UserDefaults.standard.set(
                                "http://\(hostText):\(port)", forKey: "lastDaemonURL")
                        }
                    }
                    var request = Data(
                        "\(method) \(path) HTTP/1.1\r\nHost: claudelive\r\nConnection: close\r\n".utf8)
                    // デーモンは LAN / Tailscale からのリクエストに共有シークレットを要求する
                    let token = daemonAuthToken
                    if !token.isEmpty {
                        request.append(Data("Authorization: Bearer \(token)\r\n".utf8))
                    }
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

    private nonisolated static func httpResponseBody(_ response: Data) -> Data? {
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
        if !daemonAuthToken.isEmpty {
            request.setValue("Bearer \(daemonAuthToken)", forHTTPHeaderField: "Authorization")
        }
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
                "terminal|Bash: xcodebuild test -scheme BomberMP",
                "pencil|Edit: Simulation.swift",
                "doc.text|Read: GameState.swift",
            ],
            startedAt: Date(),
            toolCount: 12,
            lastPrompt: "決定性のリプレイテストを追加して、CI で毎回回るようにして",
            lastResponse: "",
            sessionName: "claud-test",
            sessionTitle: "決定性のリプレイテストを追加して、CI で毎回回るようにして",
            question: "",
            options: [],
            textSettled: false,
            model: "",
            compactAnimated: compactAnimated,
                lastTool: "")
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
                state.textSettled = false
                await activity.update(.init(state: state, staleDate: nil))
            }
        }
        settleAfterDelay()
    }

    /// マーキー（横スクロール）の見た目だけを確認するための専用テスト。
    /// Mac / APNs を一切経由しないので、push-to-start budget の枯渇や
    /// AskUserQuestion の hooks 保留とは無関係に何度でも試せる。
    /// 質問文と返答は同時に表示されない（質問優先）ので、2 パターンに分ける
    /// マーキーが1周流れたら静止表示に切り替わる挙動を、Mac のデーモンなしで
    /// ローカル再現する（実機のデーモンと同じ 2.6 秒後に textSettled を立てる）
    private func settleAfterDelay() {
        Task {
            try? await Task.sleep(for: .seconds(2.6))
            for activity in Activity<ClaudeActivityAttributes>.activities
            where activity.attributes.sessionId == "test" {
                var state = activity.content.state
                state.textSettled = true
                await activity.update(.init(state: state, staleDate: nil))
            }
        }
    }

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
                state.textSettled = false
                await activity.update(.init(state: state, staleDate: nil))
            }
        }
        settleAfterDelay()
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
                state.textSettled = false
                await activity.update(.init(state: state, staleDate: nil))
            }
        }
        settleAfterDelay()
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
                state.textSettled = false
                await activity.update(.init(state: state, staleDate: nil))
            }
        }
        settleAfterDelay()
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
