import Foundation
import WatchConnectivity

/// Apple Watch のコンパニオンアプリとの窓口。
/// Watch は Mac デーモンと直接通信せず、必ずこの iPhone アプリを経由する。
/// Watch からのリクエスト（セッション一覧取得・質問への回答・プロンプト送信など）を
/// WatchConnectivity 経由で受け取り、AppModel.relayRequest で Mac デーモンへ中継して返す
final class WatchLink: NSObject {
    static let shared = WatchLink()

    private override init() {
        super.init()
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }
}

extension WatchLink: WCSessionDelegate {
    func session(_ session: WCSession,
                 activationDidCompleteWith activationState: WCSessionActivationState,
                 error: Error?) {}

    func sessionDidBecomeInactive(_ session: WCSession) {}

    func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }

    /// Watch からのリクエストを Mac デーモンへ中継する。
    /// message: {"path": "/sessions", "method": "GET", "body": "<JSON文字列 省略可>"}
    /// 返信: 成功時 {"data": "<JSON文字列>"}、失敗時 {"error": "<説明>"}
    func session(_ session: WCSession, didReceiveMessage message: [String: Any],
                 replyHandler: @escaping ([String: Any]) -> Void) {
        guard let path = message["path"] as? String else {
            replyHandler(["error": "不正なリクエスト"])
            return
        }
        let method = message["method"] as? String ?? "GET"
        let bodyData = (message["body"] as? String)?.data(using: .utf8)
        // 操作モードの判定は iPhone 側で行う。Watch は独立した UserDefaults を
        // 持つためトグルが同期されず、Watch 側の UI 制御だけでは当てにできない。
        // 全リクエストがこの中継を通るので、ここで止めれば確実に効く
        if Self.isControlPath(path), !isControlModeEnabled {
            replyHandler(["error": "操作モードがオフです（iPhone の ClaudeLive で設定）"])
            return
        }
        Task { @MainActor in
            let data = await AppModel.shared.relayRequest(path: path, method: method, bodyData: bodyData)
            if let data, let text = String(data: data, encoding: .utf8) {
                replyHandler(["data": text])
            } else {
                replyHandler(["error": "Mac に届きませんでした"])
            }
        }
    }

    /// Mac 上の Claude Code を動かす（＝操作モードを要する）エンドポイントか。
    /// 閲覧系（/sessions・/messages・/projects）は操作モードなしでも通す
    private static func isControlPath(_ path: String) -> Bool {
        let controlPaths = ["/prompt", "/command", "/changemodel", "/newsession", "/answer"]
        return controlPaths.contains { path.hasPrefix($0) }
    }
}
