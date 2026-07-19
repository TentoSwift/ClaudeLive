// ClaudeLive デーモン（Mac 側）
//
// Claude Code の hooks から HTTP でイベントを受け取り、
// APNs 経由で iPhone のライブアクティビティを start / update / end する。
// 依存ライブラリなし（Foundation + Network + CryptoKit のみ）。
//
// ビルド: swiftc -O -o claudelive-daemon ClaudeLiveDaemon.swift
// 設定:   ~/.claudelive/config.json（初回起動時にテンプレートを生成）
//
// エンドポイント:
//   POST /hook      Claude Code hooks からのイベント（stdin JSON をそのまま転送）
//   POST /register  iPhone アプリからのトークン登録
//   GET  /sessions  対話セッション一覧
//   GET  /messages  transcript から会話テキストを抽出（閲覧専用。返信はできない）
//   GET  /status    デバッグ用の状態表示
//   POST /reset     トークン・開始フラグを全クリア

import AppKit
import CryptoKit
import Foundation
import Network

// MARK: - パスとログ

let baseDir = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".claudelive", isDirectory: true)
let configPath = baseDir.appendingPathComponent("config.json")
let tokensPath = baseDir.appendingPathComponent("tokens.json")
let logPath = baseDir.appendingPathComponent("daemon.log")

let logFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd HH:mm:ss"
    return f
}()

func log(_ message: String) {
    let line = "[\(logFormatter.string(from: Date()))] \(message)\n"
    print(line, terminator: "")
    if let data = line.data(using: .utf8) {
        if let handle = try? FileHandle(forWritingTo: logPath) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: logPath)
        }
    }
}

// MARK: - 設定

struct Config: Codable {
    var teamId: String
    var keyId: String
    var p8Path: String
    var bundleId: String
    /// "development"（Xcode から入れたビルド）or "production"（TestFlight / App Store）
    var apnsEnvironment: String
    var port: UInt16
    /// AskUserQuestion を iPhone で回答できるよう保留する秒数。
    /// この間 Mac 側には質問が表示されない（タイムアウトで通常表示に戻る）。
    /// 既存 config との互換のため Optional（未設定なら 60 秒）
    var questionHoldSeconds: Int?

    static let template = Config(
        teamId: "LV3H7Q68W6",
        keyId: "APNS_KEY_ID_HERE",
        p8Path: "~/.claudelive/AuthKey.p8",
        bundleId: "com.tento.ClaudeLive",
        apnsEnvironment: "development",
        port: 53536,
        questionHoldSeconds: 60)

    var questionHold: TimeInterval { TimeInterval(questionHoldSeconds ?? 60) }

    static func load() -> Config {
        try? FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: configPath),
           let config = try? JSONDecoder().decode(Config.self, from: data) {
            return config
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? (try? encoder.encode(template))?.write(to: configPath)
        log("config.json が無かったのでテンプレートを作成しました: \(configPath.path)")
        log("APNs キー ID と .p8 のパスを設定してください")
        return template
    }

    var apnsHost: String {
        apnsEnvironment == "production" ? "api.push.apple.com" : "api.sandbox.push.apple.com"
    }

    var expandedP8Path: String {
        (p8Path as NSString).expandingTildeInPath
    }
}

// MARK: - APNs クライアント

final class APNSClient {
    private let config: Config
    private var cachedJWT: (token: String, issuedAt: Date)?
    private let session = URLSession(configuration: .ephemeral)

    init(config: Config) {
        self.config = config
    }

    private func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// ES256 署名の JWT。APNs の要件（20〜60 分ごとに更新）に合わせて 45 分キャッシュ
    private func jwt() throws -> String {
        if let cached = cachedJWT, Date().timeIntervalSince(cached.issuedAt) < 45 * 60 {
            return cached.token
        }
        let pem = try String(contentsOfFile: config.expandedP8Path, encoding: .utf8)
        let key = try P256.Signing.PrivateKey(pemRepresentation: pem)
        let header = base64URL(Data(#"{"alg":"ES256","kid":"\#(config.keyId)"}"#.utf8))
        let claims = base64URL(
            Data(#"{"iss":"\#(config.teamId)","iat":\#(Int(Date().timeIntervalSince1970))}"#.utf8))
        let input = "\(header).\(claims)"
        let signature = try key.signature(for: Data(input.utf8))
        let token = "\(input).\(base64URL(signature.rawRepresentation))"
        cachedJWT = (token, Date())
        return token
    }

    /// Live Activity 用プッシュを送る。completion(成功したか)
    func send(deviceToken: String, payload: [String: Any],
              label: String, completion: @escaping (Bool) -> Void) {
        let token: String
        let body: Data
        do {
            token = try jwt()
            body = try JSONSerialization.data(withJSONObject: payload)
        } catch {
            log("APNs 準備失敗 (\(label)): \(error)")
            completion(false)
            return
        }
        var request = URLRequest(
            url: URL(string: "https://\(config.apnsHost)/3/device/\(deviceToken)")!)
        request.httpMethod = "POST"
        request.setValue("bearer \(token)", forHTTPHeaderField: "authorization")
        request.setValue("\(config.bundleId).push-type.liveactivity",
                         forHTTPHeaderField: "apns-topic")
        request.setValue("liveactivity", forHTTPHeaderField: "apns-push-type")
        request.setValue("10", forHTTPHeaderField: "apns-priority")
        request.setValue("0", forHTTPHeaderField: "apns-expiration")
        request.httpBody = body

        session.dataTask(with: request) { data, response, error in
            if let error {
                log("APNs 送信エラー (\(label)): \(error.localizedDescription)")
                completion(false)
                return
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            if status == 200 {
                log("APNs OK (\(label))")
                completion(true)
            } else {
                let reason = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                log("APNs \(status) (\(label)): \(reason)")
                completion(false)
            }
        }.resume()
    }
}

// MARK: - トークン保存

struct TokenStore: Codable {
    var pushToStartToken: String?
    var activityTokens: [String: String] = [:]  // sessionId -> token
    var deviceName: String?

    static func load() -> TokenStore {
        if let data = try? Data(contentsOf: tokensPath),
           let store = try? JSONDecoder().decode(TokenStore.self, from: data) {
            return store
        }
        return TokenStore()
    }

    func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? (try? encoder.encode(self))?.write(to: tokensPath)
    }
}

// MARK: - セッション状態

final class SessionState {
    let id: String
    var projectName: String
    var hostName: String
    /// セッション名（~/.claude/sessions のレジストリ由来。例 "claud-52"）
    var name = ""
    /// セッションのタイトル。最初のユーザー入力から一度だけ作り、以後変えない
    var title = ""
    var cwd = ""
    var transcriptPath = ""
    var startedAt = Date()
    var status = "waiting"
    var detail = "セッション開始"
    var currentTool = ""
    var logs: [String] = []
    var toolCount = 0
    var lastPrompt = ""
    var lastResponse = ""
    /// AskUserQuestion の質問文と選択肢（iPhone 回答待ちの間だけ入る）
    var question = ""
    var options: [String] = []
    /// UserPromptSubmit か PreToolUse を一度でも観測したか。
    /// SessionStart だけで即終了する内部的・裏側のプロセス（サブエージェント等）を
    /// 通知しないためのゲート
    var hasSubstantiveActivity = false
    /// iPhone 側でアクティビティを消された。次の UserPromptSubmit まで再開始しない
    var dismissedByUser = false
    var startPushSent = false
    var lastPushAt = Date.distantPast
    var updateScheduled = false
    /// 直近でフックを受信した時刻。working/compacting のまま長時間これが
    /// 更新されない場合、Mac のスリープやネットワーク断とみなす
    var lastHookAt = Date()
    /// マーキーを1周流し終えて静止表示にする段階か。question/lastPrompt/
    /// lastResponse が変わるたびに false に戻し、少し待ってから true にする
    var textSettled = false
    var settleTimer: DispatchSourceTimer?

    init(id: String, projectName: String, hostName: String) {
        self.id = id
        self.projectName = projectName
        self.hostName = hostName
    }
}

// MARK: - セッションレジストリ（~/.claude/sessions/<pid>.json）

/// Claude Code が起動中セッションごとに書くレジストリ。
/// セッション名・種別（interactive/headless）・cwd が取れる。
/// PID が生きているファイルだけを有効とみなす
struct RegistryEntry {
    let sessionId: String
    let name: String
    let kind: String
    let cwd: String
}

func loadSessionRegistry() -> [String: RegistryEntry] {
    let dir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/sessions", isDirectory: true)
    var result: [String: RegistryEntry] = [:]
    let files = (try? FileManager.default.contentsOfDirectory(
        at: dir, includingPropertiesForKeys: nil)) ?? []
    for file in files where file.pathExtension == "json" {
        guard let pid = Int32(file.deletingPathExtension().lastPathComponent),
              pid > 0, kill(pid, 0) == 0,
              let data = try? Data(contentsOf: file),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let sessionId = obj["sessionId"] as? String else { continue }
        let entry = RegistryEntry(
            sessionId: sessionId,
            name: obj["name"] as? String ?? "",
            kind: obj["kind"] as? String ?? "",
            cwd: obj["cwd"] as? String ?? "")
        // 同じセッション ID が複数ある場合（-p --resume の並走など）は interactive を優先
        if let existing = result[sessionId], existing.kind == "interactive" { continue }
        result[sessionId] = entry
    }
    return result
}

// MARK: - デーモン本体

final class Daemon {
    private let config: Config
    private let apns: APNSClient
    private let queue = DispatchQueue(label: "claudelive.daemon")
    private var tokens = TokenStore.load()
    private var sessions: [String: SessionState] = [:]
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private let macName = Host.current().localizedName ?? "Mac"

    /// 更新プッシュの最小間隔（PreToolUse の連打をまとめる）
    private let minPushInterval: TimeInterval = 1.0

    /// push-to-start のレート制限（フィルタをすり抜けたノイズがあっても
    /// iPhone を通知で埋め尽くさないための安全弁）
    private var recentStartPushes: [Date] = []
    private let maxStartsPerWindow = 3
    private let startPushWindow: TimeInterval = 120

    private var watchdogTimer: DispatchSourceTimer?

    /// iPhone 回答待ちで保留中の AskUserQuestion フック接続
    private final class PendingQuestion {
        let connection: NWConnection
        var timer: DispatchSourceTimer?
        init(connection: NWConnection) { self.connection = connection }
    }
    private var pendingQuestions: [String: PendingQuestion] = [:]

    init(config: Config) {
        self.config = config
        self.apns = APNSClient(config: config)
    }

    // MARK: HTTP サーバ

    func start() {
        guard let port = NWEndpoint.Port(rawValue: config.port) else {
            log("不正なポート: \(config.port)")
            exit(1)
        }
        let listener: NWListener
        do {
            listener = try NWListener(using: .tcp, on: port)
        } catch {
            log("ポート \(config.port) で待ち受けできません: \(error)")
            exit(1)
        }
        listener.service = NWListener.Service(name: macName, type: "_claudelive._tcp")
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.stateUpdateHandler = { state in
            if case .failed(let error) = state {
                log("リスナー停止: \(error)")
                exit(1)
            }
        }
        listener.start(queue: queue)
        self.listener = listener
        startWatchdog()
        observeSystemPowerEvents()
        log("起動: port \(config.port), APNs \(config.apnsHost), bundle \(config.bundleId)")
        if tokens.pushToStartToken == nil {
            log("push-to-start トークン未登録。iPhone で ClaudeLive アプリを開いて登録してください")
        }
    }

    private func accept(_ connection: NWConnection) {
        let key = ObjectIdentifier(connection)
        connections[key] = connection
        var buffer = Data()

        func receive() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) {
                [weak self] data, _, isComplete, error in
                guard let self else { return }
                if let data { buffer.append(data) }
                if let request = Self.parseHTTP(buffer) {
                    self.route(request, on: connection)
                } else if isComplete || error != nil {
                    self.close(connection)
                } else {
                    receive()
                }
            }
        }
        connection.start(queue: queue)
        receive()
    }

    private func close(_ connection: NWConnection) {
        connection.cancel()
        connections.removeValue(forKey: ObjectIdentifier(connection))
    }

    private struct HTTPRequest {
        var method: String
        var path: String
        var body: Data
    }

    private static func parseHTTP(_ data: Data) -> HTTPRequest? {
        guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        guard let head = String(data: data[..<headerEnd.lowerBound], encoding: .utf8) else {
            return nil
        }
        let lines = head.components(separatedBy: "\r\n")
        let parts = lines[0].components(separatedBy: " ")
        guard parts.count >= 2 else { return nil }
        var contentLength = 0
        for line in lines.dropFirst() {
            let kv = line.split(separator: ":", maxSplits: 1)
            if kv.count == 2, kv[0].lowercased() == "content-length" {
                contentLength = Int(kv[1].trimmingCharacters(in: .whitespaces)) ?? 0
            }
        }
        let body = data[headerEnd.upperBound...]
        guard body.count >= contentLength else { return nil }
        return HTTPRequest(method: parts[0], path: parts[1], body: Data(body.prefix(contentLength)))
    }

    private func respond(_ connection: NWConnection, status: String = "200 OK",
                         json: String = #"{"ok":true}"#) {
        let response = "HTTP/1.1 \(status)\r\nContent-Type: application/json\r\nContent-Length: \(json.utf8.count)\r\nConnection: close\r\n\r\n\(json)"
        connection.send(content: Data(response.utf8), completion: .contentProcessed { [weak self] _ in
            self?.close(connection)
        })
    }

    private func route(_ request: HTTPRequest, on connection: NWConnection) {
        let (path, query) = Self.splitQuery(request.path)
        switch (request.method, path) {
        case ("GET", "/sessions"):
            respond(connection, json: sessionsJSON())
        case ("GET", "/messages"):
            if let sessionId = query["session"] {
                let limit = query["limit"].flatMap(Int.init) ?? 40
                respond(connection, json: messagesJSON(sessionId: sessionId, limit: limit))
            } else {
                respond(connection, status: "400 Bad Request", json: #"{"ok":false}"#)
            }
        case ("POST", "/hook"):
            respond(connection)  // hooks を待たせないよう先に応答
            if let json = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any] {
                handleHook(json)
            }
        case ("POST", "/question"):
            // AskUserQuestion の PreToolUse フック専用。iPhone で回答できるよう
            // 接続を保留する（応答が decision JSON になり、フックの stdout として
            // Claude Code に渡る）
            if let json = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any] {
                handleQuestionHook(json, on: connection)
            } else {
                respond(connection, json: "{}")
            }
        case ("POST", "/answer"):
            // iPhone のライブアクティビティのボタン（AnswerQuestionIntent）から
            if let json = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any],
               let sessionId = json["sessionId"] as? String {
                handleAnswer(
                    sessionId: sessionId,
                    answer: json["answer"] as? String ?? "",
                    pass: json["pass"] as? Bool ?? false)
                respond(connection)
            } else {
                respond(connection, status: "400 Bad Request", json: #"{"ok":false}"#)
            }
        case ("POST", "/register"):
            if let json = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any] {
                handleRegister(json)
                respond(connection)
            } else {
                respond(connection, status: "400 Bad Request", json: #"{"ok":false}"#)
            }
        case ("GET", "/status"):
            respond(connection, json: statusJSON())
        case ("POST", "/reset"):
            // iPhone 側の実態と食い違ったとき（アクティビティを手動で消した等）の脱出口。
            // トークンと開始フラグを捨てて、次のフックから作り直す
            tokens.activityTokens.removeAll()
            tokens.save()
            for session in sessions.values {
                session.startPushSent = false
            }
            recentStartPushes.removeAll()
            log("リセット: アクティビティトークンと開始フラグをクリア")
            respond(connection)
        default:
            respond(connection, status: "404 Not Found", json: #"{"ok":false}"#)
        }
    }

    private func statusJSON() -> String {
        let sessionList = sessions.values.map {
            [
                "sessionId": $0.id, "project": $0.projectName, "status": $0.status,
                "startPushSent": $0.startPushSent,
                "hasActivityToken": tokens.activityTokens[$0.id] != nil,
                "startedAt": Int($0.startedAt.timeIntervalSince1970),
            ] as [String: Any]
        }
        let info: [String: Any] = [
            "ok": true,
            "host": macName,
            "hasPushToStartToken": tokens.pushToStartToken != nil,
            "device": tokens.deviceName ?? "",
            "activityTokenCount": tokens.activityTokens.count,
            "sessions": sessionList,
        ]
        let data = (try? JSONSerialization.data(withJSONObject: info)) ?? Data("{}".utf8)
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    // MARK: セッション一覧・会話・返信

    private static func splitQuery(_ rawPath: String) -> (String, [String: String]) {
        guard let qIndex = rawPath.firstIndex(of: "?") else { return (rawPath, [:]) }
        let path = String(rawPath[..<qIndex])
        var query: [String: String] = [:]
        for pair in rawPath[rawPath.index(after: qIndex)...].components(separatedBy: "&") {
            let kv = pair.components(separatedBy: "=")
            guard kv.count == 2 else { continue }
            query[kv[0]] = kv[1].removingPercentEncoding ?? kv[1]
        }
        return (path, query)
    }

    /// レジストリ（生きている対話セッション）とフックで観測した状態をマージして返す
    private func sessionsJSON() -> String {
        let registry = loadSessionRegistry()
        var list: [[String: Any]] = []
        for (sessionId, entry) in registry where entry.kind == "interactive" {
            let session = sessions[sessionId]
            list.append([
                "sessionId": sessionId,
                "name": entry.name,
                "title": session?.title ?? "",
                "project": (entry.cwd as NSString).lastPathComponent,
                "status": session?.status ?? "idle",
                "detail": session?.detail ?? "",
                "currentTool": session?.currentTool ?? "",
                "toolCount": session?.toolCount ?? 0,
                "startedAt": Int((session?.startedAt ?? Date()).timeIntervalSince1970),
                "hasActivityToken": tokens.activityTokens[sessionId] != nil,
                "lastPrompt": session?.lastPrompt ?? "",
                "lastResponse": session?.lastResponse ?? "",
            ])
        }
        list.sort { ($0["startedAt"] as? Int ?? 0) > ($1["startedAt"] as? Int ?? 0) }
        let data = (try? JSONSerialization.data(withJSONObject: ["ok": true, "host": macName, "sessions": list]))
            ?? Data("{}".utf8)
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    /// transcript JSONL から直近の会話（ユーザー入力と Claude の返答テキスト）を抽出する。
    /// 形式は Claude Code 内部仕様でバージョンにより変わりうる。壊れても空を返すだけにする
    private func messagesJSON(sessionId: String, limit: Int) -> String {
        let path = transcriptPath(for: sessionId)
        var messages: [[String: String]] = []
        if let path, let handle = FileHandle(forReadingAtPath: path) {
            // 長大なファイルは末尾 2MB だけ読む
            let maxBytes: UInt64 = 2 * 1024 * 1024
            let size = (try? handle.seekToEnd()) ?? 0
            let offset = size > maxBytes ? size - maxBytes : 0
            try? handle.seek(toOffset: offset)
            let data = (try? handle.readToEnd()) ?? Data()
            try? handle.close()
            var lines = data.split(separator: UInt8(ascii: "\n"))
            if offset > 0, !lines.isEmpty { lines.removeFirst() }  // 途中から読んだ先頭行は捨てる

            for line in lines {
                guard let obj = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
                      let type = obj["type"] as? String, type == "user" || type == "assistant",
                      obj["isSidechain"] as? Bool != true,
                      obj["isMeta"] as? Bool != true,
                      let message = obj["message"] as? [String: Any] else { continue }
                var text = ""
                if let content = message["content"] as? String {
                    text = content
                } else if let content = message["content"] as? [[String: Any]] {
                    text = content.compactMap { item in
                        (item["type"] as? String) == "text" ? item["text"] as? String : nil
                    }.joined(separator: "\n")
                }
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                // tool_result のみの user 行や、コマンド実行などのシステム的な行は出さない
                guard !trimmed.isEmpty, !trimmed.hasPrefix("<"),
                      !trimmed.hasPrefix("[Request interrupted") else { continue }
                messages.append([
                    "role": type,
                    "text": String(trimmed.prefix(2000)),
                    "timestamp": obj["timestamp"] as? String ?? "",
                ])
            }
        }
        let tail = Array(messages.suffix(limit))
        let data = (try? JSONSerialization.data(withJSONObject: ["ok": true, "messages": tail]))
            ?? Data("{}".utf8)
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    /// PreToolUse のたびに transcript 末尾から直近のアシスタントのテキストを拾い、
    /// ツール実行の合間に書いた説明文をライブアクティビティにも反映する。
    /// transcript は非同期書き込みのため、最新の1手前の発言になることがある
    /// （公式ドキュメントにも明記されている既知の遅延）
    private func latestAssistantText(forSessionId sessionId: String) -> String? {
        guard let path = transcriptPath(for: sessionId),
              let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        // 直近の発言だけが目的なので末尾 64KB で十分
        let maxBytes: UInt64 = 64 * 1024
        let size = (try? handle.seekToEnd()) ?? 0
        let offset = size > maxBytes ? size - maxBytes : 0
        try? handle.seek(toOffset: offset)
        let data = (try? handle.readToEnd()) ?? Data()
        var lines = data.split(separator: UInt8(ascii: "\n"))
        if offset > 0, !lines.isEmpty { lines.removeFirst() }

        for line in lines.reversed() {
            guard let obj = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
                  obj["type"] as? String == "assistant",
                  obj["isSidechain"] as? Bool != true,
                  let message = obj["message"] as? [String: Any],
                  let content = message["content"] as? [[String: Any]] else { continue }
            let text = content.compactMap { item in
                (item["type"] as? String) == "text" ? item["text"] as? String : nil
            }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { return text }
        }
        return nil
    }

    private func transcriptPath(for sessionId: String) -> String? {
        if let session = sessions[sessionId], !session.transcriptPath.isEmpty {
            return session.transcriptPath
        }
        // フック未観測のセッションは cwd から導出する
        // （プロジェクトディレクトリ名は cwd の英数字以外を "-" に置換したもの）
        guard let entry = loadSessionRegistry()[sessionId] else { return nil }
        let munged = entry.cwd.map { ch in
            ch.isLetter || ch.isNumber ? String(ch) : "-"
        }.joined()
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects/\(munged)/\(sessionId).jsonl").path
        return FileManager.default.fileExists(atPath: path) ? path : nil
    }

    // MARK: iPhone からのトークン登録

    private func handleRegister(_ json: [String: Any]) {
        if let device = json["device"] as? String {
            tokens.deviceName = device
        }
        var newStartToken = false
        if let token = json["pushToStartToken"] as? String, token != tokens.pushToStartToken {
            tokens.pushToStartToken = token
            newStartToken = true
            log("push-to-start トークン登録 (\(tokens.deviceName ?? "?"))")
        }
        var newActivitySessions: [String] = []
        if let map = json["activityTokens"] as? [String: String] {
            // iPhone 側の「いま生きているアクティビティ」のスナップショットとして扱う。
            // 消えたトークンは破棄する
            // （アクティビティを手動で消されると、古いトークン宛ての update は
            // APNs 200 のまま黙って捨てられ続けるので、Mac 側からは検知できない）
            for sessionId in tokens.activityTokens.keys where map[sessionId] == nil {
                tokens.activityTokens.removeValue(forKey: sessionId)
                if let session = sessions[sessionId] {
                    // ユーザーが消したアクティビティを勝手に即再作成しない。
                    // （以前は即 pushStart していたが、テストのたびにスワイプで消す →
                    // 数秒後に自動復活、のループで push-to-start budget を食い潰した）
                    // 次の UserPromptSubmit（ユーザーが再びやり取りした時）だけ再開始を許す
                    session.startPushSent = false
                    session.dismissedByUser = true
                }
                log("アクティビティトークン破棄（iPhone 側で終了済み・自動再作成しない）: \(sessionId.prefix(8))")
            }
            for (sessionId, token) in map where tokens.activityTokens[sessionId] != token {
                tokens.activityTokens[sessionId] = token
                if let session = sessions[sessionId] {
                    session.dismissedByUser = false  // アプリからの取り込み等で復活した
                }
                newActivitySessions.append(sessionId)
                log("アクティビティトークン登録: session \(sessionId.prefix(8))")
            }
        }
        tokens.save()

        // 待たされていたプッシュを流す
        if newStartToken {
            for session in sessions.values where !session.startPushSent {
                pushStart(session)
            }
        }
        for sessionId in newActivitySessions {
            if let session = sessions[sessionId] {
                pushUpdate(session)
            }
        }
    }

    // MARK: AskUserQuestion の iPhone 回答

    /// AskUserQuestion の PreToolUse フックを保留し、質問をライブアクティビティへ送る。
    /// 対象外（複数質問・アクティビティ未表示・サブエージェント等）は即座に素通しする
    private func handleQuestionHook(_ json: [String: Any], on connection: NWConnection) {
        guard json["agent_id"] == nil,
              let sessionId = json["session_id"] as? String,
              let toolInput = json["tool_input"] as? [String: Any],
              let questions = toolInput["questions"] as? [[String: Any]],
              questions.count == 1,  // 複数質問はボタンで表現しきれないので Mac に任せる
              let first = questions.first,
              let questionText = first["question"] as? String,
              let rawOptions = first["options"] as? [[String: Any]],
              tokens.activityTokens[sessionId] != nil  // アクティビティが出ていなければ保留する意味がない
        else {
            respond(connection, json: "{}")
            return
        }
        let options = rawOptions.compactMap { $0["label"] as? String }.prefix(4)
        guard !options.isEmpty else {
            respond(connection, json: "{}")
            return
        }

        // 既存の保留が残っていたら素通しで解放（多重質問は起きないはずだが保険）
        releaseQuestion(sessionId: sessionId, answer: nil, notify: false)

        let session = ensureSession(sessionId, json: json)
        session.lastHookAt = Date()
        session.status = "question"
        session.question = Self.truncate(questionText, 200)
        session.options = Array(options)
        session.detail = ""
        session.currentTool = ""
        markTextChanged(session)

        let pending = PendingQuestion(connection: connection)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + config.questionHold)
        timer.setEventHandler { [weak self] in
            // 時間切れ: フックを素通しして Mac 側に質問を出す
            self?.releaseQuestion(sessionId: sessionId, answer: nil, notify: true)
        }
        timer.resume()
        pending.timer = timer
        pendingQuestions[sessionId] = pending

        log("質問を iPhone へ送信: \(session.projectName)「\(Self.truncate(questionText, 40))」")
        pushUpdate(session, alert: [
            "title": "\(session.projectName): 質問",
            "body": Self.truncate(questionText, 100),
            "sound": "default",
        ])
    }

    private func handleAnswer(sessionId: String, answer: String, pass: Bool) {
        if pass || answer.isEmpty {
            log("iPhone から「Macで回答」: session \(sessionId.prefix(8))")
            releaseQuestion(sessionId: sessionId, answer: nil, notify: true)
        } else {
            log("iPhone から回答: session \(sessionId.prefix(8))「\(Self.truncate(answer, 40))」")
            releaseQuestion(sessionId: sessionId, answer: answer, notify: true)
        }
    }

    /// マーキー対象のテキスト（question/lastPrompt/lastResponse）が変わった直後に呼ぶ。
    /// 静止段階を解除して1周分アニメさせ、少し待ってから静止表示に切り替える
    /// push を送る。ウィジェット側は時間経過を自力で監視できないため、
    /// この「いつ静止に切り替えるか」の判断は Mac 側が肩代わりする
    private let marqueeSettleDelay: TimeInterval = 2.6  // ループ長(2秒)より少し長く
    private func markTextChanged(_ session: SessionState) {
        session.textSettled = false
        session.settleTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + marqueeSettleDelay)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            session.textSettled = true
            session.settleTimer = nil
            self.pushUpdate(session)
        }
        timer.resume()
        session.settleTimer = timer
    }

    /// 保留中のフック接続に応答して解放する。
    /// answer あり → deny + 理由（Claude が回答として受け取る）、nil → 素通し
    private func releaseQuestion(sessionId: String, answer: String?, notify: Bool) {
        guard let pending = pendingQuestions.removeValue(forKey: sessionId) else { return }
        pending.timer?.cancel()

        if let answer {
            let reason = "ユーザーは iPhone のライブアクティビティから「\(answer)」を選択しました。"
                + "これをこの質問への回答として扱い、質問を再表示せずに続行してください。"
            let output: [String: Any] = [
                "hookSpecificOutput": [
                    "hookEventName": "PreToolUse",
                    "permissionDecision": "deny",
                    "permissionDecisionReason": reason,
                ]
            ]
            let data = (try? JSONSerialization.data(withJSONObject: output)) ?? Data("{}".utf8)
            respond(pending.connection, json: String(data: data, encoding: .utf8) ?? "{}")
        } else {
            respond(pending.connection, json: "{}")
        }

        guard notify, let session = sessions[sessionId] else { return }
        if let answer {
            session.status = "working"
            session.detail = "回答: \(Self.truncate(answer, 60))"
        } else {
            session.status = "waiting"
            session.detail = "Mac で質問に回答してください"
        }
        session.question = ""
        session.options = []
        pushUpdate(session)
    }

    // MARK: Claude Code hooks の処理

    private func handleHook(_ json: [String: Any]) {
        guard let event = json["hook_event_name"] as? String,
              let sessionId = json["session_id"] as? String else { return }
        // サブエージェント（Agent ツールや内部処理の裏側プロセス）発のフックは対象外。
        // この環境ではユーザーが直接見ているメインセッション以外にも
        // 短命な Claude Code プロセスがフックを発火させることがあるため
        guard json["agent_id"] == nil else { return }

        if event == "SessionEnd" {
            releaseQuestion(sessionId: sessionId, answer: nil, notify: false)
            if let session = sessions[sessionId] {
                session.settleTimer?.cancel()
                pushEnd(session)
                sessions.removeValue(forKey: sessionId)
                tokens.activityTokens.removeValue(forKey: sessionId)
                tokens.save()
            }
            return
        }

        let session = ensureSession(sessionId, json: json)
        session.lastHookAt = Date()
        if let transcript = json["transcript_path"] as? String {
            session.transcriptPath = transcript
        }
        var alert: [String: Any]? = nil

        switch event {
        case "SessionStart":
            session.status = "waiting"
            session.detail = "セッション開始"

        case "UserPromptSubmit":
            session.status = "working"
            session.currentTool = ""
            session.detail = ""
            session.lastResponse = ""  // 新しいターンが始まるので前の返答は消す
            session.question = ""
            session.options = []
            session.hasSubstantiveActivity = true
            session.dismissedByUser = false  // ユーザーが再びやり取りした → 表示再開してよい
            if let prompt = json["prompt"] as? String {
                session.lastPrompt = Self.truncate(prompt, 180)
                if session.title.isEmpty {
                    session.title = Self.truncate(prompt, 60)
                }
                markTextChanged(session)
            }

        case "PreToolUse":
            session.hasSubstantiveActivity = true
            let toolName = json["tool_name"] as? String ?? "?"
            // AskUserQuestion は /question 側（保留フック）が状態を管理するので
            // ここで status を上書きしない
            if toolName == "AskUserQuestion" { return }
            session.status = "working"
            session.question = ""
            session.options = []
            session.currentTool = toolName
            session.toolCount += 1
            let line = Self.toolLogLine(
                name: toolName, input: json["tool_input"] as? [String: Any] ?? [:])
            session.logs.insert(line, at: 0)
            if session.logs.count > 6 { session.logs.removeLast() }

            // ツール呼び出し前に書いた説明文があれば、途中経過としてライブアクティビティにも
            // 反映する（transcript の非同期書き込みにより 1 手遅れになることがある）
            if let text = latestAssistantText(forSessionId: session.id), text != session.lastResponse {
                session.lastResponse = Self.truncate(text, 300)
                markTextChanged(session)
            }

        case "PostToolUse":
            session.currentTool = ""
            // Mac 側で質問に回答された（保留素通し後）ケースの後片付け
            if (json["tool_name"] as? String) == "AskUserQuestion" {
                session.status = "working"
                session.question = ""
                session.options = []
            }

        case "Notification":
            let message = json["message"] as? String ?? ""
            if message.localizedCaseInsensitiveContains("permission") {
                session.status = "permission"
                session.detail = message
                session.currentTool = ""
                alert = [
                    "title": "\(session.projectName): 許可待ち",
                    "body": message,
                    "sound": "default",
                ]
            } else if session.status == "done" {
                // Stop で既に完了・返答表示済みのところに来る「入力待ち」通知は
                // 何もしない。ここで終了させると、表示されたばかりの返答が
                // 読む間もなく消えてしまう（実際に起きた不具合）
                return
            } else {
                // 入力待ちはライブアクティビティに残さない。通知だけ送って終了する
                // （次に実際のやり取り＝UserPromptSubmit があるまで再開しない）
                session.currentTool = ""
                let detail = message.isEmpty ? "入力を待っています" : message
                let waitAlert: [String: Any] = [
                    "title": "\(session.projectName): 入力待ち",
                    "body": detail,
                    "sound": "default",
                ]
                pushEnd(session, status: "waiting", detail: detail, dismissAfter: 30, alert: waitAlert)
                tokens.activityTokens.removeValue(forKey: sessionId)
                tokens.save()
                session.startPushSent = false
                session.dismissedByUser = true
                session.status = "waiting"
                session.detail = detail
                return
            }

        case "Stop":
            session.status = "done"
            session.detail = ""
            session.currentTool = ""
            session.question = ""
            session.options = []
            session.lastResponse = Self.extractLastResponse(json) ?? ""
            markTextChanged(session)
            alert = [
                "title": "\(session.projectName): 完了",
                "body": session.lastResponse.isEmpty
                    ? "Claude Code の応答が完了しました" : session.lastResponse,
                "sound": "default",
            ]

        case "PreCompact":
            session.status = "compacting"
            session.detail = "コンテキストを圧縮しています…"

        default:
            return  // SubagentStop などは表示しない
        }

        sync(session, alert: alert)
    }

    private func ensureSession(_ sessionId: String, json: [String: Any]) -> SessionState {
        if let existing = sessions[sessionId] {
            if existing.name.isEmpty,
               let entry = loadSessionRegistry()[sessionId] {
                existing.name = entry.name
            }
            return existing
        }
        let cwd = json["cwd"] as? String ?? ""
        let projectName = cwd.isEmpty ? "Claude Code" : (cwd as NSString).lastPathComponent
        let session = SessionState(id: sessionId, projectName: projectName, hostName: macName)
        session.cwd = cwd
        if let entry = loadSessionRegistry()[sessionId] {
            session.name = entry.name
        }
        // デーモン再起動でメモリ上のセッションは消えるが、
        // 既に per-activity トークンがあるなら iPhone 側にアクティビティは生きている。
        // push-to-start を再送すると重複したアクティビティができてしまうので、
        // 開始済み扱いにして update から再開する
        if tokens.activityTokens[sessionId] != nil {
            session.startPushSent = true
        }
        sessions[sessionId] = session
        log("セッション開始: \(projectName) (\(sessionId.prefix(8)))")
        return session
    }

    private static func truncate(_ text: String, _ max: Int) -> String {
        let flattened = text.replacingOccurrences(of: "\n", with: " ")
        return flattened.count <= max ? flattened : String(flattened.prefix(max)) + "…"
    }

    /// Stop フックの `last_assistant_message` から返答テキストを取り出す。
    /// ドキュメントに厳密な型の記載がないため、素の文字列と
    /// `{text:...}` / `{content:[{text:...}]}` 形の両方を受け付ける。
    private static func extractLastResponse(_ json: [String: Any]) -> String? {
        guard let raw = json["last_assistant_message"] else { return nil }
        if let text = raw as? String {
            return text.isEmpty ? nil : truncate(text, 300)
        }
        if let obj = raw as? [String: Any] {
            if let text = obj["text"] as? String {
                return truncate(text, 300)
            }
            if let content = obj["content"] as? [[String: Any]] {
                let text = content.compactMap { $0["text"] as? String }.joined(separator: " ")
                return text.isEmpty ? nil : truncate(text, 300)
            }
        }
        return nil
    }

    /// ログ 1 行は "SFSymbol名|本文" 形式で送る。
    /// 絵文字ではなく SF Symbols を使うため、アイコンの識別子だけを渡して
    /// 実際の描画は iOS 側（LogLinesView）に任せる
    private static func toolLogLine(name: String, input: [String: Any]) -> String {
        let symbol: String
        switch name {
        case "Bash": symbol = "terminal"
        case "Read": symbol = "doc.text"
        case "Edit", "Write", "NotebookEdit": symbol = "pencil"
        case "Grep", "Glob": symbol = "magnifyingglass"
        case "Task", "Agent": symbol = "sparkles"
        case "WebFetch", "WebSearch": symbol = "globe"
        default: symbol = "wrench.and.screwdriver"
        }
        var detail = ""
        if let command = input["command"] as? String {
            detail = command
        } else if let path = input["file_path"] as? String {
            detail = (path as NSString).lastPathComponent
        } else if let pattern = input["pattern"] as? String {
            detail = pattern
        } else if let description = input["description"] as? String {
            detail = description
        } else if let prompt = input["prompt"] as? String {
            detail = prompt
        }
        let text = detail.isEmpty ? name : "\(name): \(detail)"
        return "\(symbol)|\(truncate(text, 60))"
    }

    // MARK: プッシュ送信

    /// 状態変化をアクティビティに反映する。
    /// アラート付き（許可待ちなど）は即送信、それ以外は 1 秒間隔でまとめる。
    private func sync(_ session: SessionState, alert: [String: Any]?) {
        if !session.startPushSent {
            pushStart(session)
            return
        }
        guard tokens.activityTokens[session.id] != nil else { return }
        if alert != nil {
            pushUpdate(session, alert: alert)
            return
        }
        let elapsed = Date().timeIntervalSince(session.lastPushAt)
        if elapsed >= minPushInterval {
            pushUpdate(session)
        } else if !session.updateScheduled {
            session.updateScheduled = true
            queue.asyncAfter(deadline: .now() + (minPushInterval - elapsed)) { [weak self] in
                session.updateScheduled = false
                self?.pushUpdate(session)
            }
        }
    }

    private func contentState(for session: SessionState) -> [String: Any] {
        [
            "status": session.status,
            "detail": session.detail,
            "currentTool": session.currentTool,
            "recentLogs": Array(session.logs.prefix(4)),
            // ActivityKit のデフォルト JSONDecoder は Date を
            // 2001-01-01 基準の秒数として読む
            "startedAt": session.startedAt.timeIntervalSinceReferenceDate,
            "toolCount": session.toolCount,
            "lastPrompt": session.lastPrompt,
            "lastResponse": session.lastResponse,
            "sessionName": session.name,
            "sessionTitle": session.title,
            "question": session.question,
            "options": session.options,
            "textSettled": session.textSettled,
        ]
    }

    private func relevance(for session: SessionState) -> Double {
        switch session.status {
        case "permission", "question": return 1.0
        case "waiting": return 0.8
        default: return 0.5
        }
    }

    private func pushStart(_ session: SessionState) {
        guard let token = tokens.pushToStartToken else { return }
        guard !session.startPushSent else { return }
        // アプリ側でローカル起動済み（トークンあり）なら開始プッシュは不要。
        // 送ると同じセッションのアクティビティが二重にできてしまう
        if tokens.activityTokens[session.id] != nil {
            session.startPushSent = true
            pushUpdate(session)
            return
        }
        // プロンプト送信かツール実行が実際にあるまでは通知しない
        // （SessionStart 直後に終わる裏側の短命プロセスを除外する）
        guard session.hasSubstantiveActivity else { return }
        // ユーザーが消したアクティビティは、次のプロンプト送信まで復活させない
        guard !session.dismissedByUser else { return }
        // レジストリで「対話セッション」と確認できたものだけ通知する。
        // サブエージェントや headless 実行はここで確実に落ちる
        guard let entry = loadSessionRegistry()[session.id], entry.kind == "interactive" else {
            return
        }
        if session.name.isEmpty { session.name = entry.name }

        let now = Date()
        recentStartPushes.removeAll { now.timeIntervalSince($0) > startPushWindow }
        guard recentStartPushes.count < maxStartsPerWindow else {
            log("push-to-start をレート制限で抑制: \(session.projectName) (\(session.id.prefix(8)))")
            return
        }
        recentStartPushes.append(now)

        session.startPushSent = true  // 多重送信防止（失敗したら戻す）
        let payload: [String: Any] = [
            "aps": [
                "timestamp": Int(Date().timeIntervalSince1970),
                "event": "start",
                "content-state": contentState(for: session),
                "attributes-type": "ClaudeActivityAttributes",
                "attributes": [
                    "sessionId": session.id,
                    "projectName": session.projectName,
                    "hostName": session.hostName,
                ],
                "alert": [
                    "title": session.projectName,
                    "body": "Claude Code セッション開始",
                ],
                "relevance-score": relevance(for: session),
                "stale-date": Int(Date().timeIntervalSince1970) + 900,
            ]
        ]
        apns.send(deviceToken: token, payload: payload,
                  label: "start \(session.projectName)") { [queue] ok in
            queue.async {
                if ok {
                    session.lastPushAt = Date()
                } else {
                    session.startPushSent = false
                }
            }
        }
    }

    private func pushUpdate(_ session: SessionState, alert: [String: Any]? = nil) {
        guard let token = tokens.activityTokens[session.id] else { return }
        var aps: [String: Any] = [
            "timestamp": Int(Date().timeIntervalSince1970),
            "event": "update",
            "content-state": contentState(for: session),
            "relevance-score": relevance(for: session),
            "stale-date": Int(Date().timeIntervalSince1970) + 900,
        ]
        if let alert { aps["alert"] = alert }
        session.lastPushAt = Date()
        apns.send(deviceToken: token, payload: ["aps": aps],
                  label: "update \(session.projectName) [\(session.status)]") { _ in }
    }

    private func pushEnd(_ session: SessionState, status: String = "done",
                         detail: String = "セッション終了", dismissAfter: Int = 180,
                         alert: [String: Any]? = nil) {
        guard let token = tokens.activityTokens[session.id] else { return }
        var state = contentState(for: session)
        state["status"] = status
        state["detail"] = detail
        state["currentTool"] = ""
        var aps: [String: Any] = [
            "timestamp": Int(Date().timeIntervalSince1970),
            "event": "end",
            "content-state": state,
            "dismissal-date": Int(Date().timeIntervalSince1970) + dismissAfter,
        ]
        if let alert { aps["alert"] = alert }
        let payload: [String: Any] = ["aps": aps]
        apns.send(deviceToken: token, payload: payload,
                  label: "end \(session.projectName)") { _ in }
        log("セッション終了 (\(status)): \(session.projectName) (\(session.id.prefix(8)))")
    }

    // MARK: 接続断の監視

    /// working/compacting のまま、この時間フックが来なければ接続断とみなす。
    /// 長時間かかるビルド等の誤検知を避けるため余裕を持たせる
    private let disconnectTimeout: TimeInterval = 15 * 60

    private func startWatchdog() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 60, repeating: 60)
        timer.setEventHandler { [weak self] in
            self?.checkForDisconnectedSessions()
        }
        timer.resume()
        watchdogTimer = timer
    }

    private func checkForDisconnectedSessions() {
        let now = Date()
        var changed = false
        for session in sessions.values {
            guard session.status == "working" || session.status == "compacting" else { continue }
            guard now.timeIntervalSince(session.lastHookAt) > disconnectTimeout else { continue }
            log("接続が途切れたと判断してアクティビティを終了: \(session.projectName) (\(session.id.prefix(8)))")
            releaseQuestion(sessionId: session.id, answer: nil, notify: false)
            session.settleTimer?.cancel()
            pushEnd(session, status: "error", detail: "接続が途切れたため終了しました", dismissAfter: 60)
            sessions.removeValue(forKey: session.id)
            if tokens.activityTokens.removeValue(forKey: session.id) != nil {
                changed = true
            }
        }
        if changed { tokens.save() }
    }

    // MARK: スリープ・シャットダウンの即時検知

    /// 無音タイムアウトを待たず、Mac がスリープ／シャットダウンする瞬間に
    /// 全セッションのライブアクティビティを終了する
    private func observeSystemPowerEvents() {
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.willSleepNotification,
                           object: nil, queue: nil) { [weak self] _ in
            self?.queue.async { self?.endAllForPowerEvent(reason: "Mac がスリープしたため終了しました") }
        }
        center.addObserver(forName: NSWorkspace.willPowerOffNotification,
                           object: nil, queue: nil) { [weak self] _ in
            self?.queue.async { self?.endAllForPowerEvent(reason: "Mac がシャットダウンしたため終了しました") }
        }
        center.addObserver(forName: NSWorkspace.didWakeNotification,
                           object: nil, queue: nil) { [weak self] _ in
            self?.queue.async { log("Mac のスリープ復帰を検知") }
        }
    }

    private func endAllForPowerEvent(reason: String) {
        var changed = false
        for session in sessions.values {
            guard session.status != "done" else { continue }
            log("\(reason): \(session.projectName) (\(session.id.prefix(8)))")
            releaseQuestion(sessionId: session.id, answer: nil, notify: false)
            session.settleTimer?.cancel()
            pushEnd(session, status: "error", detail: reason, dismissAfter: 30)
            if tokens.activityTokens.removeValue(forKey: session.id) != nil {
                changed = true
            }
        }
        sessions.removeAll()
        if changed { tokens.save() }
    }
}

// MARK: - エントリポイント

let config = Config.load()
let daemon = Daemon(config: config)
daemon.start()
// NSWorkspace の通知（スリープ/シャットダウン検知）は CFRunLoop を回さないと
// 配信されないため、dispatchMain() ではなく RunLoop.main.run() で待ち受ける
RunLoop.main.run()
