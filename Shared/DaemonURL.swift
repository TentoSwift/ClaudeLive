import Foundation
import Network

/// 保存済みのデーモン URL に紛れ込んだインターフェースのスコープ ID
/// （"192.168.0.1%en0" の "%en0" 部分）を落とす。NWEndpoint.Host の
/// 文字列化で IPv4 でも混入することがあり、そのままでは URLSession が
/// 解決できない。過去に壊れた値が保存されている可能性があるので、
/// 保存時だけでなく読み込み時にも通す
func sanitizeDaemonURL(_ url: String) -> String {
    guard let percent = url.range(of: "%"),
          let colon = url[percent.upperBound...].firstIndex(of: ":") else { return url }
    return String(url[..<percent.lowerBound]) + String(url[colon...])
}

/// 手動指定欄の入力を "host:port" に正規化する。Tailscale の管理画面等から
/// コピーすると "https://100.x.x.x" のように scheme や末尾のパスが付いてくることが
/// あり、素朴に `host.contains(":")` でポート有無を判定すると "http://" の ":" に
/// 反応して壊れた URL（"http://http://100.x.x.x:53536"）になってしまっていた
func normalizedManualHostPort(_ raw: String) -> String {
    var host = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    for prefix in ["https://", "http://"] where host.lowercased().hasPrefix(prefix) {
        host = String(host.dropFirst(prefix.count))
    }
    if let slashIndex = host.firstIndex(of: "/") {
        host = String(host[..<slashIndex])
    }
    // ポート指定の有無は「最後の ':' 以降がすべて数字か」で判定する
    // （scheme 由来の ':' を誤ってポート区切りと見なさないため）
    if let colonIndex = host.lastIndex(of: ":") {
        let portPart = host[host.index(after: colonIndex)...]
        if !portPart.isEmpty, portPart.allSatisfy(\.isNumber) {
            return host
        }
    }
    return "\(host):53536"
}

/// Mac デーモンへのリクエストを、複数の経路に同時に投げて最初に成功した
/// ものを採用する。以前は「Bonjour → LAN の IP → 手動指定」の順に1つずつ
/// タイムアウトを待ってから次を試していたため、Wi-Fi を切っている（＝
/// Bonjour と LAN の IP は必ずタイムアウトする）と、Tailscale の手動指定が
/// 生きていても全体のタイムアウトの方が先に来て「繋がらない」ことがあった。
/// 経路は次の3つを並行に試す（Tailscale 越しでも Wi-Fi と同時に間に合う）:
///   - Bonjour サービス名へ直接接続（IP に依存しない最も確実な経路。同一 LAN 限定）
///   - 直近成功した LAN の IP（lastDaemonURL）
///   - 手動指定（Tailscale の IP など。Wi-Fi 外からの唯一の経路になりうる）
/// Mac デーモンが要求する共有シークレット（Mac の ~/.claudelive/config.json の
/// authToken と同じ値）。アプリの設定画面で入力して保存する。
/// これが一致しないとデーモンは 401 を返す（loopback からの hooks だけは免除）
let daemonAuthTokenKey = "daemonAuthToken"

var daemonAuthToken: String {
    UserDefaults.standard.string(forKey: daemonAuthTokenKey) ?? ""
}

func daemonRequest(path: String, method: String = "GET", body: Data? = nil,
                    timeout: TimeInterval = 5) async -> Data? {
    let defaults = UserDefaults.standard
    let token = daemonAuthToken

    var urls: [URL] = []
    if let saved = defaults.string(forKey: "lastDaemonURL"),
       let url = URL(string: sanitizeDaemonURL(saved) + path) {
        urls.append(url)
    }
    if let manual = defaults.string(forKey: "manualHost"), !manual.isEmpty {
        let hostPort = normalizedManualHostPort(manual)
        if let url = URL(string: "http://\(hostPort)\(path)") {
            urls.append(url)
        }
    }
    let serviceName = defaults.string(forKey: "lastServiceName")

    guard !urls.isEmpty || serviceName != nil else { return nil }

    return await withTaskGroup(of: Data?.self) { group in
        if let serviceName {
            group.addTask {
                guard let raw = await requestOverBonjourService(
                    name: serviceName, path: path, method: method, body: body,
                    timeout: timeout, token: token)
                else { return nil }
                return httpResponseBody(raw)
            }
        }
        for url in urls {
            group.addTask {
                var request = URLRequest(url: url, timeoutInterval: timeout)
                request.httpMethod = method
                if !token.isEmpty {
                    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                }
                if let body {
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    request.httpBody = body
                }
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

/// 便利版: POST が成功したかどうかだけ知りたい呼び出し用
func daemonRequestOK(path: String, method: String = "POST", body: Data? = nil) async -> Bool {
    await daemonRequest(path: path, method: method, body: body) != nil
}

/// Bonjour サービスエンドポイントへ TCP 接続して素の HTTP/1.1 を話す
/// （IP 解決を Network.framework に任せられるので、IP が変わっていても確実に届く）
private func requestOverBonjourService(name: String, path: String, method: String,
                                        body: Data?, timeout: TimeInterval,
                                        token: String) async -> Data? {
    let endpoint = NWEndpoint.service(name: name, type: "_claudelive._tcp", domain: "local", interface: nil)
    return await withCheckedContinuation { continuation in
        let queue = DispatchQueue(label: "claudelive.daemonrequest")
        let connection = NWConnection(to: endpoint, using: .tcp)
        var responseData = Data()
        var finished = false
        let finish: (Data?) -> Void = { data in
            queue.async {
                guard !finished else { return }
                finished = true
                connection.cancel()
                continuation.resume(returning: data)
            }
        }
        queue.asyncAfter(deadline: .now() + timeout) { finish(nil) }
        func receiveLoop() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) {
                data, _, isComplete, error in
                if let data { responseData.append(data) }
                if error != nil {
                    finish(nil)
                } else if isComplete {
                    finish(responseData)
                } else {
                    receiveLoop()
                }
            }
        }
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                var request = Data("\(method) \(path) HTTP/1.1\r\nHost: claudelive\r\nConnection: close\r\n".utf8)
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
                    guard error == nil else { finish(nil); return }
                    receiveLoop()
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

/// 素の HTTP/1.1 レスポンス（ヘッダ含む）から本文だけを取り出す。200 以外は nil
func httpResponseBody(_ response: Data) -> Data? {
    guard let range = response.range(of: Data("\r\n\r\n".utf8)),
          String(data: response.prefix(64), encoding: .utf8)?.contains(" 200 ") == true
    else { return nil }
    return Data(response[range.upperBound...])
}
