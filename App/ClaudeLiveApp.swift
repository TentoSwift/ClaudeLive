import SwiftUI

@main
struct ClaudeLiveApp: App {
    // push-to-start でバックグラウンド起動された場合でも確実にトークン監視を始めるため、
    // App の初期化時点で共有インスタンスを立ち上げる
    @StateObject private var model = AppModel.shared
    @Environment(\.scenePhase) private var scenePhase
    // リモート通知のデバイストークン受け取り用（質問への通知返信に必要）
    @UIApplicationDelegateAdaptor(ClaudeLiveAppDelegate.self) private var appDelegate

    init() {
        // ライブアクティビティのプレビュー表示（アプリ内）で同じアニメーションを
        // 使うため、フォントマスク方式の特殊フォントをここでも登録しておく
        FrameAnimation.registerFont()
        // Watch からの中継リクエストを受けられるよう、起動時に必ず
        // WatchConnectivity セッションを有効化しておく
        _ = WatchLink.shared
        // 質問プッシュ通知（返信アクション付き）のカテゴリ登録と許可要求
        NotificationManager.shared.setup()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                // アプリ全体のアクセントを Claude のブランドカラーに揃える。
                // ボタン・トグル・リンク・ナビゲーションの戻るなど、
                // 個別に指定していない標準コントロールがすべてこの色になる
                .tint(Color.claudeBrand)
                .onOpenURL { url in
                    // ライブアクティビティのタップ（claudelive://session/<id>）で
                    // 該当セッションの詳細（回答 UI 込み）を直接開く
                    guard url.scheme == "claudelive", url.host == "session" else { return }
                    let sessionId = url.pathComponents.dropFirst().first ?? ""
                    guard !sessionId.isEmpty else { return }
                    model.focusSessionId = sessionId
                }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                model.refresh()
                model.registerToServer()
            }
        }
    }
}
