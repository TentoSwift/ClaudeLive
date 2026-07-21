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
import Darwin
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

    /// APNs へプッシュを送る。pushType は "liveactivity"（既定）または
    /// "alert"（通常のプッシュ通知。質問の返信アクション付き通知に使う）。
    /// completion(成功したか)
    func send(deviceToken: String, payload: [String: Any],
              label: String, pushType: String = "liveactivity",
              completion: @escaping (Bool) -> Void) {
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
        // alert（通常通知）の topic はバンドル ID そのもの。
        // Live Activity は ".push-type.liveactivity" サフィックスが必要
        let topic = pushType == "liveactivity"
            ? "\(config.bundleId).push-type.liveactivity"
            : config.bundleId
        request.setValue(topic, forHTTPHeaderField: "apns-topic")
        request.setValue(pushType, forHTTPHeaderField: "apns-push-type")
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
    /// DI コンパクトの作業中アイコンをコマ送りアニメーションにするか。
    /// アプリの設定画面からのトグルがここに反映される（既定 false = 静止）
    var compactAnimated: Bool = false
    /// 通常のプッシュ通知（質問の返信アクション付き通知）用のデバイストークン
    var remoteDeviceToken: String?

    init() {}

    // 手書きの init(from:) が必要な理由: 自動合成の Decodable はプロパティの
    // デフォルト値を無視し、キーが1つでも足りないと decode 全体が失敗して
    // TokenStore() にフォールバックしてしまう（compactAnimated 追加時に、
    // 既存の tokens.json に無いキーのせいで登録済みトークンが消えた実例あり）。
    // decodeIfPresent で個別にフォールバックさせ、旧バージョンの JSON とも
    // 前方互換にする
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        pushToStartToken = try c.decodeIfPresent(String.self, forKey: .pushToStartToken)
        activityTokens = try c.decodeIfPresent([String: String].self, forKey: .activityTokens) ?? [:]
        deviceName = try c.decodeIfPresent(String.self, forKey: .deviceName)
        compactAnimated = try c.decodeIfPresent(Bool.self, forKey: .compactAnimated) ?? false
        remoteDeviceToken = try c.decodeIfPresent(String.self, forKey: .remoteDeviceToken)
    }

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

// MARK: - AskUserQuestion の 1 問分

/// AskUserQuestion の questions 配列の 1 要素。multiSelect が true の質問は
/// 選択肢を複数選んでから確定する（iPhone/Watch/Mac のダイアログ共通の仕様）
struct QuestionItem {
    var question: String
    var options: [String]
    var multiSelect: Bool
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
    /// 直近に使ったツール名。currentTool と違い PostToolUse で空にしない。
    /// 完了時、最後に使ったツールのチェックマーク付きアイコンを出すのに使う
    var lastTool = ""
    var logs: [String] = []
    var toolCount = 0
    var lastPrompt = ""
    var lastResponse = ""
    /// 直近のアシスタント発言が使ったモデル名（transcript の message.model 由来）
    var model = ""
    /// このターン（直近の UserPromptSubmit）が始まった時点の transcript ファイルサイズ。
    /// これより前のバイトは前のターンの内容なので、latestAssistantTurn で拾わないよう
    /// 読み取り開始位置をこれ未満に遡らせない（前ターンの返答が作業中に再表示される事故を防ぐ）
    var turnStartOffset: UInt64 = 0
    /// AskUserQuestion の質問文と選択肢（iPhone 回答待ちの間だけ入る）。
    /// 複数質問・複数選択に対応する前からの互換フィールドで、常に
    /// questionItems の最初の1問を反映する（ライブアクティビティの
    /// マーキー表示など、1問だけを前提にした場所はこちらを見ればよい）
    var question = ""
    var options: [String] = []
    /// AskUserQuestion が渡した質問をすべて保持する（1回のツール呼び出しに
    /// 複数の質問が含まれることがあり、各質問は複数選択(multiSelect)のこともある）
    var questionItems: [QuestionItem] = []
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

/// PID の生死だけでは不十分（macOS は PID を再利用するため、セッション
/// 終了後に別プロセスが同じ番号を持つと「生きたまま」と誤判定してしまう）。
/// 実行ファイル名が "claude" かどうかも確認する
private func isClaudeProcess(pid: Int32) -> Bool {
    var pathBuf = [Int8](repeating: 0, count: Int(4 * MAXPATHLEN))
    let len = proc_pidpath(pid, &pathBuf, UInt32(pathBuf.count))
    guard len > 0 else { return false }
    let path = String(cString: pathBuf)
    return (path as NSString).lastPathComponent == "claude"
}

func loadSessionRegistry() -> [String: RegistryEntry] {
    let dir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/sessions", isDirectory: true)
    var result: [String: RegistryEntry] = [:]
    let files = (try? FileManager.default.contentsOfDirectory(
        at: dir, includingPropertiesForKeys: nil)) ?? []
    for file in files where file.pathExtension == "json" {
        guard let pid = Int32(file.deletingPathExtension().lastPathComponent),
              pid > 0, kill(pid, 0) == 0, isClaudeProcess(pid: pid),
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
        /// Mac 側に出す選択ダイアログ（osascript）。他の経路で回答されたら kill する
        var dialog: Process?
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
            // iPhone のライブアクティビティのボタン（AnswerQuestionIntent）から。
            // 複数質問対応の "answers"（質問ごとの選択配列）を優先し、
            // 無ければ従来の単一 "answer" 文字列を1問分の回答として扱う
            if let json = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any],
               let sessionId = json["sessionId"] as? String {
                let answers: [[String]]
                if let structured = json["answers"] as? [[String]] {
                    answers = structured
                } else if let legacy = json["answer"] as? String, !legacy.isEmpty {
                    answers = [[legacy]]
                } else {
                    answers = []
                }
                handleAnswer(sessionId: sessionId, answers: answers, pass: json["pass"] as? Bool ?? false)
                respond(connection)
            } else {
                respond(connection, status: "400 Bad Request", json: #"{"ok":false}"#)
            }
        case ("POST", "/prompt"):
            // Watch / iPhone からのプロンプト送信。`claude -p --resume` で
            // 該当セッションに注入する（tmux 前提にしない構成のため）。
            // LAN + Tailscale 内限定の API という前提（ユーザー了承済み）
            if let json = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any],
               let sessionId = json["sessionId"] as? String,
               let text = json["text"] as? String,
               !text.trimmingCharacters(in: .whitespaces).isEmpty {
                respond(connection)
                runPrompt(sessionId: sessionId, text: text)
            } else {
                respond(connection, status: "400 Bad Request", json: #"{"ok":false}"#)
            }
        case ("POST", "/changemodel"):
            // Watch / iPhone からのモデル変更。/prompt と同じキー入力方式で
            // 「/model <id>」を該当セッションに送るだけ（Claude Code 本体の
            // /model スラッシュコマンドがモデル切り替えを処理する）
            if let json = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any],
               let sessionId = json["sessionId"] as? String,
               let model = json["model"] as? String,
               !model.trimmingCharacters(in: .whitespaces).isEmpty {
                respond(connection)
                runPrompt(sessionId: sessionId, text: "/model \(model)")
            } else {
                respond(connection, status: "400 Bad Request", json: #"{"ok":false}"#)
            }
        case ("POST", "/command"):
            // Watch / iPhone からのスラッシュコマンド送信（/compact 等）。
            // /prompt と同じキー入力方式でそのまま該当セッションに送るだけ
            if let json = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any],
               let sessionId = json["sessionId"] as? String,
               let command = json["command"] as? String,
               !command.trimmingCharacters(in: .whitespaces).isEmpty {
                let normalized = command.hasPrefix("/") ? command : "/\(command)"
                respond(connection)
                runPrompt(sessionId: sessionId, text: normalized)
            } else {
                respond(connection, status: "400 Bad Request", json: #"{"ok":false}"#)
            }
        case ("GET", "/projects"):
            // 新規セッションを開始できるプロジェクト（過去に使った cwd）の一覧
            respond(connection, json: projectsJSON())
        case ("POST", "/newsession"):
            // 新規 Claude Code セッションを cwd で開始する（--resume なし）。
            // cwd 省略時は最初のプロジェクトを使う。model 省略時は既定のモデルを使う
            if let json = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any],
               let text = json["text"] as? String,
               !text.trimmingCharacters(in: .whitespaces).isEmpty {
                let cwd = (json["cwd"] as? String) ?? knownProjectPaths().first ?? ""
                let model = json["model"] as? String ?? ""
                respond(connection)
                startNewSession(cwd: cwd, text: text, model: model)
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
                "question": session?.question ?? "",
                "options": session?.options ?? [],
                "questions": (session?.questionItems ?? []).map {
                    ["question": $0.question, "options": $0.options, "multiSelect": $0.multiSelect]
                },
                "model": session?.model ?? "",
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
        latestAssistantTurn(forSessionId: sessionId).text
    }

    /// transcript 末尾から直近のアシスタント発言のモデル名だけを拾う。
    /// テキストと違いターン境界（turnStartOffset）は無視する:
    /// /model で切り替えた直後はまだ新ターンの発言が書かれていないことがあり、
    /// ターン内に限定すると「モデル不明」のまま古い表示が残ってしまうため
    private func latestModel(forSessionId sessionId: String) -> String? {
        guard let path = transcriptPath(for: sessionId),
              let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
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
                  let model = message["model"] as? String, !model.isEmpty else { continue }
            return model
        }
        return nil
    }

    /// transcript 末尾から直近のアシスタント発言のテキストと使用モデル名を拾う。
    /// モデル名は message.model にそのまま入っている（例 "claude-fable-5"）
    private func latestAssistantTurn(forSessionId sessionId: String) -> (text: String?, model: String?) {
        guard let path = transcriptPath(for: sessionId),
              let handle = FileHandle(forReadingAtPath: path) else { return (nil, nil) }
        defer { try? handle.close() }
        // 直近の発言だけが目的なので末尾 64KB で十分。ただし今のターンより前には
        // 絶対に遡らない（前ターンの返答を誤って拾う事故を防ぐため）
        let maxBytes: UInt64 = 64 * 1024
        let size = (try? handle.seekToEnd()) ?? 0
        let turnStartOffset = sessions[sessionId]?.turnStartOffset ?? 0
        let tailOffset = size > maxBytes ? size - maxBytes : 0
        let offset = min(max(tailOffset, turnStartOffset), size)
        try? handle.seek(toOffset: offset)
        let data = (try? handle.readToEnd()) ?? Data()
        var lines = data.split(separator: UInt8(ascii: "\n"))
        if offset > 0, !lines.isEmpty { lines.removeFirst() }

        var latestModel: String?
        for line in lines.reversed() {
            guard let obj = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
                  obj["type"] as? String == "assistant",
                  obj["isSidechain"] as? Bool != true,
                  let message = obj["message"] as? [String: Any],
                  let content = message["content"] as? [[String: Any]] else { continue }
            if latestModel == nil { latestModel = message["model"] as? String }
            let text = content.compactMap { item in
                (item["type"] as? String) == "text" ? item["text"] as? String : nil
            }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { return (text, latestModel) }
        }
        return (nil, latestModel)
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
        if let compactAnimated = json["compactAnimated"] as? Bool,
           compactAnimated != tokens.compactAnimated {
            tokens.compactAnimated = compactAnimated
            tokens.save()
            log("コンパクトアニメーション設定: \(compactAnimated ? "オン" : "オフ")")
            // 表示中のライブアクティビティにもすぐ反映する
            for session in sessions.values { pushUpdate(session) }
        }
        if let remoteToken = json["remoteDeviceToken"] as? String,
           remoteToken != tokens.remoteDeviceToken {
            tokens.remoteDeviceToken = remoteToken
            log("リモート通知トークン登録（質問の返信用）")
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
    /// 1 回の呼び出しに複数の質問（questions 配列）が含まれることがあり、
    /// 各質問は multiSelect（複数選択可）のこともある。最大 4 問まで扱う
    private func handleQuestionHook(_ json: [String: Any], on connection: NWConnection) {
        guard json["agent_id"] == nil,
              let sessionId = json["session_id"] as? String,
              let toolInput = json["tool_input"] as? [String: Any],
              let rawQuestions = toolInput["questions"] as? [[String: Any]],
              !rawQuestions.isEmpty,
              tokens.activityTokens[sessionId] != nil  // アクティビティが出ていなければ保留する意味がない
        else {
            respond(connection, json: "{}")
            return
        }
        let items: [QuestionItem] = rawQuestions.prefix(4).compactMap { q in
            guard let text = q["question"] as? String,
                  let rawOptions = q["options"] as? [[String: Any]] else { return nil }
            let labels = rawOptions.compactMap { $0["label"] as? String }.prefix(4)
            guard !labels.isEmpty else { return nil }
            let multiSelect = q["multiSelect"] as? Bool ?? false
            return QuestionItem(question: text, options: Array(labels), multiSelect: multiSelect)
        }
        guard !items.isEmpty else {
            respond(connection, json: "{}")
            return
        }

        // 既存の保留が残っていたら素通しで解放（多重質問は起きないはずだが保険）
        releaseQuestion(sessionId: sessionId, answers: nil, notify: false)

        let session = ensureSession(sessionId, json: json)
        session.lastHookAt = Date()
        session.status = "question"
        session.questionItems = items
        session.question = Self.truncate(items[0].question, 200)
        session.options = items[0].options
        session.detail = ""
        session.currentTool = ""
        markTextChanged(session)

        let pending = PendingQuestion(connection: connection)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + config.questionHold)
        timer.setEventHandler { [weak self] in
            // 時間切れ: フックを素通しして Mac 側に質問を出す
            self?.releaseQuestion(sessionId: sessionId, answers: nil, notify: true)
        }
        timer.resume()
        pending.timer = timer
        pendingQuestions[sessionId] = pending

        let summary = items.count == 1 ? items[0].question : "\(items.count)件の質問"
        log("質問を iPhone へ送信: \(session.projectName)「\(Self.truncate(summary, 40))」")
        pushUpdate(session, alert: [
            "title": "\(session.projectName): 質問",
            "body": Self.truncate(summary, 100),
            "sound": "default",
        ])

        // 返信アクション付きの通常通知も送る。通知を長押し →「回答を入力」で
        // アプリを一切開かずにシステムのテキスト入力欄から自由回答できる
        pushQuestionNotification(session, questionText: summary)

        // Mac 側にも選択肢ダイアログを出す（保留中は Claude Desktop に質問が
        // 出ないため、その代わり）。選べば iPhone のボタンと同じ扱いで回答、
        // キャンセルすれば素通しして Claude Desktop 側の質問 UI に任せる
        showQuestionDialog(sessionId: sessionId, pending: pending, items: items)
    }

    /// 質問の返信アクション付き通常通知（apns-push-type: alert）を送る。
    /// iOS 側は NotificationManager が CLAUDE_QUESTION カテゴリとして受け、
    /// 通知上のテキスト入力（システム UI）だけで回答を返せる
    private func pushQuestionNotification(_ session: SessionState, questionText: String) {
        guard let remoteToken = tokens.remoteDeviceToken else { return }
        let payload: [String: Any] = [
            "aps": [
                "alert": [
                    "title": "\(session.projectName): 質問",
                    "body": Self.truncate(questionText, 160),
                ],
                "sound": "default",
                "category": "CLAUDE_QUESTION",
                "thread-id": session.id,
            ],
            "sessionId": session.id,
        ]
        apns.send(deviceToken: remoteToken, payload: payload,
                  label: "質問通知 \(session.projectName)", pushType: "alert") { _ in }
    }

    /// osascript の「choose from list」で質問ダイアログを表示する（質問が複数
    /// あれば順番に表示する）。multiSelect の質問は複数選択可にする。
    /// 各質問の選択結果は ASCII 31（項目区切り）・30（質問区切り）で連結して
    /// 1本の文字列として受け取り、Swift 側で分解する。
    /// iPhone 側で先に回答されたら releaseQuestion が dialog を terminate する
    private func showQuestionDialog(sessionId: String, pending: PendingQuestion, items: [QuestionItem]) {
        func esc(_ text: String) -> String {
            text.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
        }
        var scriptParts: [String] = []
        var joinedVars: [String] = []
        for (i, item) in items.enumerated() {
            let optList = item.options.map { "\"\(esc($0))\"" }.joined(separator: ", ")
            let multiClause = item.multiSelect ? " with multiple selections allowed" : ""
            let joinedVar = "joined\(i)"
            joinedVars.append(joinedVar)
            scriptParts.append("""
            set opts\(i) to {\(optList)}
            set sel\(i) to choose from list opts\(i) with title "ClaudeLive" with prompt "\(esc(item.question))"\(multiClause) default items {item 1 of opts\(i)}
            if sel\(i) is false then return ""
            set \(joinedVar) to ""
            repeat with x in sel\(i)
                if \(joinedVar) is "" then
                    set \(joinedVar) to x as text
                else
                    set \(joinedVar) to \(joinedVar) & (ASCII character 31) & (x as text)
                end if
            end repeat
            """)
        }
        let combine = joinedVars.joined(separator: " & (ASCII character 30) & ")
        let script = scriptParts.joined(separator: "\n") + "\nreturn \(combine)"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] _ in
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            self?.queue.async {
                guard let self, self.pendingQuestions[sessionId] === pending else { return }
                if output.isEmpty {
                    // キャンセル（いずれかの質問で）→ 素通しして Claude Desktop の質問 UI に任せる
                    log("Mac ダイアログでキャンセル → 素通し: \(sessionId.prefix(8))")
                    self.releaseQuestion(sessionId: sessionId, answers: nil, notify: true)
                } else {
                    let answers = output.components(separatedBy: "\u{1E}")
                        .map { $0.components(separatedBy: "\u{1F}") }
                    log("Mac ダイアログから回答: \(sessionId.prefix(8))")
                    self.releaseQuestion(sessionId: sessionId, answers: answers, notify: true)
                }
            }
        }
        do {
            try process.run()
            pending.dialog = process
        } catch {
            log("質問ダイアログ表示失敗: \(error.localizedDescription)")
        }
    }

    /// answers は質問ごとの選択結果の配列（multiSelect の質問は複数要素）。
    /// 単一質問・単一選択の従来どおりの回答も answers: [[text]] として渡ってくる
    private func handleAnswer(sessionId: String, answers: [[String]], pass: Bool) {
        let hasAnswer = answers.contains { !$0.isEmpty }
        if pass || !hasAnswer {
            log("iPhone から「Macで回答」: session \(sessionId.prefix(8))")
            releaseQuestion(sessionId: sessionId, answers: nil, notify: true)
            return
        }
        guard pendingQuestions[sessionId] != nil else {
            // 保留のタイムアウト（questionHold）を過ぎてすでに素通しされた質問。
            // ブロック中のフック接続がもう無く release では届けられないため、
            // /prompt と同じキー入力方式で Claude Desktop に直接反映する
            let items = sessions[sessionId]?.questionItems ?? []
            let text = composeAnswerText(items: items, answers: answers)
            log("iPhone から回答（保留期限切れ、キー入力で反映）: session \(sessionId.prefix(8))「\(Self.truncate(text, 40))」")
            typeIntoClaudeApp(text)
            return
        }
        log("iPhone から回答: session \(sessionId.prefix(8))")
        releaseQuestion(sessionId: sessionId, answers: answers, notify: true)
    }

    /// Watch / iPhone から送られたプロンプトを該当セッションに注入する。
    /// 宛先セッションを claude://resume?session=<id> のディープリンクで名指しで
    /// 前面に出してから、キー入力で流し込む。これで最前面でなかったセッションにも
    /// 送れて、しかも GUI に即反映される（トークンも使わない）。
    /// sessionId は hooks の session_id（= Claude Desktop の cliSessionId）
    private func runPrompt(sessionId: String, text: String) {
        typeIntoClaudeApp(text, focusCLISessionId: sessionId)
        log("プロンプト送信(セッション\(sessionId.prefix(8))を前面化→キー入力): 「\(Self.truncate(text, 60))」")
    }

    /// Claude アプリを前面に出し、クリップボード経由でテキストを貼り付けて Enter。
    /// 長文・日本語でも確実に入るよう keystroke ではなくペーストを使う。
    /// focusCLISessionId を渡すと、claude://resume?session=<id> のディープリンクで
    /// そのセッションを名指しで前面に出してから入力する（最前面でなくても届く）
    private func typeIntoClaudeApp(_ text: String, focusCLISessionId: String? = nil) {
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
        }
        // 宛先セッションを名指しで前面化する（指定があれば）。
        // ディープリンクの反映に少し時間がかかるので長めに待つ
        let focusScript: String
        if let cliId = focusCLISessionId,
           cliId.range(of: "^[0-9a-fA-F-]{36}$", options: .regularExpression) != nil {
            // 未キャッシュのセッションに切り替える場合、履歴の読み込み・描画に
            // 1.2秒では足りずコンポーザーにフォーカスが来る前にペーストしてしまい
            // 何も入力されないことがあったため、安全側に長めに待つ
            focusScript = """
            do shell script "open " & quoted form of "claude://resume?session=\(cliId)"
            delay 2.5
            """
        } else {
            focusScript = "tell application id \"com.anthropic.claudefordesktop\" to activate\ndelay 0.4"
        }
        let script = """
        set prev to ""
        try
            set prev to the clipboard as text
        end try
        set the clipboard to "\(esc(text))"
        \(focusScript)
        tell application "System Events"
            tell process "Claude"
                set frontmost to true
            end tell
            -- 既にそのセッションが前面表示されている場合、ディープリンクを
            -- 開き直しても画面遷移が起きず入力欄にフォーカスが来ないことがあり、
            -- その状態で貼り付けても何も入力されない不具合があった。
            -- ウィンドウ下端中央（入力欄がある位置）を直接クリックして
            -- 確実にフォーカスしてから貼り付ける
            try
                set winPos to position of window 1 of process "Claude"
                set winSize to size of window 1 of process "Claude"
                set clickX to (item 1 of winPos) + ((item 1 of winSize) / 2)
                set clickY to (item 2 of winPos) + (item 2 of winSize) - 40
                click at {clickX, clickY}
                delay 0.15
            end try
            keystroke "v" using command down
            delay 0.3
            key code 36
        end tell
        delay 0.2
        try
            set the clipboard to prev
        end try
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        process.standardOutput = FileHandle.nullDevice
        let errPipe = Pipe()
        process.standardError = errPipe
        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus != 0 {
                let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(),
                                 encoding: .utf8) ?? ""
                log("キー入力失敗: \(err.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
        } catch {
            log("キー入力失敗: \(error.localizedDescription)")
        }
    }

    /// 新規セッションを開始できる既知のプロジェクト（過去に使った cwd）の一覧。
    /// ~/.claude/projects/ のディレクトリ名（cwd を "-" 区切りにしたもの）を
    /// 実在パスに復元する。更新時刻の新しい順
    private func knownProjectEntries() -> [(path: String, name: String)] {
        let projectsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects", isDirectory: true)
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(
            at: projectsDir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return [] }
        var result: [(path: String, name: String, date: Date)] = []
        for dir in dirs where (try? dir.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
            // ディレクトリ名は cwd の英数字以外を "-" にしたもの。
            // 先頭 "-" は "/" 始まりの絶対パス由来なので "/" に戻し、以降の "-" も
            // "/" として復元してみて、実在するパスを採用する（曖昧さは実在チェックで解決）
            let munged = dir.lastPathComponent
            guard let path = Self.restorePath(fromMunged: munged) else { continue }
            let date = (try? dir.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            result.append((path, (path as NSString).lastPathComponent, date))
        }
        result.sort { $0.date > $1.date }
        return result.map { ($0.path, $0.name) }
    }

    private func knownProjectPaths() -> [String] { knownProjectEntries().map(\.path) }

    /// "-Users-foo-bar" のようなプロジェクトディレクトリ名から実在パスを復元する。
    /// "-" を順に "/" と "-"（元がハイフンだったケース）両方試して実在するものを返す
    private static func restorePath(fromMunged munged: String) -> String? {
        guard munged.hasPrefix("-") else { return nil }
        func normalize(_ p: String) -> String {
            // 連続スラッシュを畳み、末尾スラッシュを落とす
            var s = p
            while s.contains("//") { s = s.replacingOccurrences(of: "//", with: "/") }
            if s.count > 1 && s.hasSuffix("/") { s.removeLast() }
            return s
        }
        // まず単純に全 "-" を "/" に（大半のパスはこれで当たる）
        let simple = normalize("/" + munged.dropFirst().replacingOccurrences(of: "-", with: "/"))
        if FileManager.default.fileExists(atPath: simple) { return simple }
        // ダメならセグメントを貪欲に "/" 区切りで探索
        let parts = munged.dropFirst().split(separator: "-").map(String.init)
        var path = ""
        for part in parts {
            let candidate = path + "/" + part
            if FileManager.default.fileExists(atPath: candidate) {
                path = candidate
            } else if !path.isEmpty {
                // ハイフンを含むディレクトリ名だった可能性。直前セグメントと連結
                path = path + "-" + part
            } else {
                path = "/" + part
            }
        }
        return FileManager.default.fileExists(atPath: path) ? path : nil
    }

    private func projectsJSON() -> String {
        let list = knownProjectEntries().prefix(30).map {
            ["path": $0.path, "name": $0.name]
        }
        let data = (try? JSONSerialization.data(withJSONObject: ["ok": true, "projects": Array(list)]))
            ?? Data("{}".utf8)
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    /// 新規 Claude Code セッションを cwd で開始する（--resume なし）。
    /// ヘッドレスの別プロセスとして走り、SessionStart フックから
    /// push-to-start でライブアクティビティが立ち上がる。
    /// model 省略時（空文字）は --model を付けず CLI の既定モデルを使う
    private func startNewSession(cwd: String, text: String, model: String = "") {
        let claudePath = ("~/.local/bin/claude" as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: claudePath) else {
            log("新規セッション失敗: claude が見つからない")
            return
        }
        var isDir: ObjCBool = false
        guard !cwd.isEmpty, FileManager.default.fileExists(atPath: cwd, isDirectory: &isDir),
              isDir.boolValue else {
            log("新規セッション失敗: 不正な cwd (\(cwd))")
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: claudePath)
        var arguments = ["-p", text]  // --resume なし = 新規セッション
        if !model.isEmpty {
            arguments += ["--model", model]
        }
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let modelSuffix = model.isEmpty ? "" : " [\(model)]"
            log("新規セッション開始: \((cwd as NSString).lastPathComponent)\(modelSuffix)「\(Self.truncate(text, 60))」")
        } catch {
            log("新規セッション失敗: \(error.localizedDescription)")
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
    /// 質問とその回答をまとめて読める文章にする（複数質問の deny 理由や、
    /// 保留切れ後にそのままチャットへ貼り付ける文面として共用する）
    private func composeAnswerText(items: [QuestionItem], answers: [[String]]) -> String {
        if items.count <= 1 {
            let selected = answers.first ?? []
            return selected.joined(separator: "、")
        }
        var lines: [String] = []
        for (i, item) in items.enumerated() {
            let selected = i < answers.count ? answers[i] : []
            let answerText = selected.isEmpty ? "(未回答)" : selected.joined(separator: "、")
            lines.append("質問「\(item.question)」の回答: \(answerText)")
        }
        return lines.joined(separator: "\n")
    }

    /// answers は質問ごとの選択結果（multiSelect の質問は複数要素になる）。
    /// nil または空なら「回答なし＝素通しして Mac 側の質問 UI に任せる」
    private func releaseQuestion(sessionId: String, answers: [[String]]?, notify: Bool) {
        guard let pending = pendingQuestions.removeValue(forKey: sessionId) else { return }
        pending.timer?.cancel()
        // Mac 側のダイアログが出ていれば閉じる（terminationHandler は
        // pendingQuestions から消えた後なので二重解放にはならない）
        if let dialog = pending.dialog, dialog.isRunning {
            dialog.terminate()
        }

        let items = sessions[sessionId]?.questionItems ?? []
        let hasAnswer = (answers ?? []).contains { !$0.isEmpty }
        if let answers, hasAnswer {
            let reason: String
            if items.count <= 1 {
                let joined = (answers.first ?? []).map { "「\($0)」" }.joined(separator: "、")
                reason = "ユーザーは選択肢から\(joined)を選択しました。"
                    + "これをこの質問への回答として扱い、質問を再表示せずに続行してください。"
            } else {
                reason = "ユーザーは複数の質問に次の通り回答しました。\n"
                    + composeAnswerText(items: items, answers: answers)
                    + "\nこれらをそれぞれの質問への回答として扱い、質問を再表示せずに続行してください。"
            }
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
        if let answers, hasAnswer {
            session.status = "working"
            session.detail = "回答: \(Self.truncate(composeAnswerText(items: items, answers: answers), 60))"
        } else {
            session.status = "waiting"
            session.detail = "Mac で質問に回答してください"
        }
        session.question = ""
        session.options = []
        session.questionItems = []
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
            releaseQuestion(sessionId: sessionId, answers: nil, notify: false)
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
        // どのフックでもモデル名を拾い直す。PreToolUse / Stop だけだと
        // /model で切り替えても次のツール実行まで表示が古いままになる
        if let model = latestModel(forSessionId: session.id) {
            session.model = model
        }
        var alert: [String: Any]? = nil

        switch event {
        case "SessionStart":
            session.status = "waiting"
            session.detail = "セッション開始"

        case "UserPromptSubmit":
            session.status = "working"
            session.currentTool = ""
            session.lastTool = ""  // 新しいターンなので前ターンのツール表示は引き継がない
            session.detail = ""
            session.lastResponse = ""  // 新しいターンが始まるので前の返答は消す
            session.question = ""
            session.options = []
            // これ以降 latestAssistantTurn がこのオフセットより前を読まないようにし、
            // 前ターンの返答が「作業中」に一瞬再表示される事故を防ぐ
            if let path = transcriptPath(for: session.id),
               let handle = FileHandle(forReadingAtPath: path) {
                session.turnStartOffset = (try? handle.seekToEnd()) ?? 0
                try? handle.close()
            }
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
            session.lastTool = toolName
            session.toolCount += 1
            let line = Self.toolLogLine(
                name: toolName, input: json["tool_input"] as? [String: Any] ?? [:])
            session.logs.insert(line, at: 0)
            if session.logs.count > 6 { session.logs.removeLast() }

            // ツール呼び出し前に書いた説明文があれば、途中経過としてライブアクティビティにも
            // 反映する（transcript の非同期書き込みにより 1 手遅れになることがある）
            let turn = latestAssistantTurn(forSessionId: session.id)
            if let text = turn.text, text != session.lastResponse {
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
            "model": session.model,
            "compactAnimated": tokens.compactAnimated,
            "lastTool": session.lastTool,
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
            releaseQuestion(sessionId: session.id, answers: nil, notify: false)
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
            releaseQuestion(sessionId: session.id, answers: nil, notify: false)
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
