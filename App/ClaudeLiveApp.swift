import SwiftUI

@main
struct ClaudeLiveApp: App {
    // push-to-start でバックグラウンド起動された場合でも確実にトークン監視を始めるため、
    // App の初期化時点で共有インスタンスを立ち上げる
    @StateObject private var model = AppModel.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                model.refresh()
                model.registerToServer()
            }
        }
    }
}
