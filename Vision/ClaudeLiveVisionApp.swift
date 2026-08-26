import SwiftUI

/// visionOS クライアント。
/// Mac デーモン（port 53536）を HTTP ポーリングし、セッション状態を
/// 空間に常駐するウィンドウとして表示する。APNs・push-to-start・/register は
/// 一切使わない（VISIONOS_SPEC.md 参照）。
@main
struct ClaudeLiveVisionApp: App {
    @State private var model = VisionAppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        // メイン: セッション一覧 + 詳細
        WindowGroup(id: "dashboard") {
            DashboardView()
                .environment(model)
                .tint(Color.claudeBrand)
        }
        .defaultSize(width: 640, height: 720)

        // ミニタイル: 1 セッション = 1 ウィンドウ。
        // Mac Virtual Display の周囲に好きなだけ並べて置ける
        WindowGroup(id: "tile", for: String.self) { $sessionId in
            if let sessionId {
                TileView(sessionId: sessionId)
                    .environment(model)
                    .tint(Color.claudeBrand)
            }
        }
        .windowResizability(.contentSize)
        .defaultSize(width: 420, height: 260)
    }
}
