import AppIntents

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
