import SwiftUI

/// watchOS コンパニオンアプリ。
/// Smart Stack のライブアクティビティをタップすると開き、
/// ライブアクティビティでは省略されていた全文（プロンプト・返答・会話）を
/// 表示したり、AskUserQuestion に回答したりできる。
/// Mac デーモンへは iPhone から WatchConnectivity 経由で受け取った URL で
/// 直接 HTTP アクセスする
@main
struct ClaudeLiveWatchApp: App {
    @StateObject private var model = WatchModel.shared

    var body: some Scene {
        WindowGroup {
            WatchContentView()
                .environmentObject(model)
                .onOpenURL { url in
                    // claudelive://session/<sessionId>（ライブアクティビティのタップ）
                    if url.host == "session" || url.pathComponents.count > 1 {
                        let id = url.lastPathComponent
                        if !id.isEmpty { model.focusSessionId = id }
                    }
                }
        }
    }
}
