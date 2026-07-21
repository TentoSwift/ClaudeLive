import AppIntents
import Foundation

/// watchOS の Smart Stack でライブアクティビティをタップしたときに
/// コンパニオンアプリを開くための App Intent。
/// Link / .widgetURL はどちらも実機で反応しなかったため、WidgetKit が
/// 公式に用意している「openAppWhenRun 付きの AppIntent をボタンとして使う」
/// 方式を試す
struct OpenClaudeLiveIntent: AppIntent {
    static var title: LocalizedStringResource = "ClaudeLive を開く"
    static var isDiscoverable: Bool = false
    static var openAppWhenRun: Bool = true

    func perform() async throws -> some IntentResult {
        .result()
    }
}

/// ライブアクティビティ上の明示的な「開いて回答」ボタン用。
/// Link / .widgetURL がタップに反応しないケースがあったため、iOS 側でも
/// openAppWhenRun 付きの AppIntent で確実にアプリを開く。
/// perform() は UserDefaults にセッション ID を書き込むだけ（App Intent は
/// ウィジェット拡張のプロセスで動くため、直接 SwiftUI の状態は触れない）。
/// アプリ側は起動・フォアグラウンド復帰のたびにこの値を読み、
/// あれば質問の回答アラートを出す
struct OpenSessionIntent: AppIntent {
    static var title: LocalizedStringResource = "セッションを開いて回答"
    static var isDiscoverable: Bool = false
    static var openAppWhenRun: Bool = true

    @Parameter(title: "Session ID")
    var sessionId: String

    init() { sessionId = "" }
    init(sessionId: String) { self.sessionId = sessionId }

    func perform() async throws -> some IntentResult {
        UserDefaults.standard.set(sessionId, forKey: "pendingFocusSessionId")
        return .result()
    }
}
