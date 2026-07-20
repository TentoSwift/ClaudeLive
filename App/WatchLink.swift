import Foundation
import WatchConnectivity

/// Apple Watch のコンパニオンアプリへ Mac デーモンの URL を共有する。
/// Watch 側はこの URL に直接 HTTP でアクセスして、セッション全文の閲覧や
/// AskUserQuestion への回答を行う（applicationContext は最新値だけが届く
/// 揮発的な同期で、この用途にちょうどよい）
final class WatchLink: NSObject {
    static let shared = WatchLink()

    private override init() {
        super.init()
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    /// 現在保存されているデーモン URL を Watch に送る。
    /// applicationContext（最新値のみ保持・Watch アプリ起動時に配送）に加え、
    /// 到達性のある時は transferUserInfo でも送って取りこぼしを減らす
    func syncDaemonURL() {
        guard WCSession.isSupported(),
              WCSession.default.activationState == .activated,
              let url = UserDefaults.standard.string(forKey: "lastDaemonURL"),
              !url.isEmpty else { return }
        try? WCSession.default.updateApplicationContext(["daemonURL": url])
        if WCSession.default.isReachable {
            WCSession.default.sendMessage(["daemonURL": url], replyHandler: nil)
        }
    }
}

extension WatchLink: WCSessionDelegate {
    func session(_ session: WCSession,
                 activationDidCompleteWith activationState: WCSessionActivationState,
                 error: Error?) {
        if activationState == .activated {
            DispatchQueue.main.async { self.syncDaemonURL() }
        }
    }

    func sessionDidBecomeInactive(_ session: WCSession) {}

    func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }
}
