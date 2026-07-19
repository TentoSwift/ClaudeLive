import SwiftUI
import WidgetKit

@main
struct ClaudeLiveWidgetBundle: WidgetBundle {
    init() {
        // コマ送りアニメーション用の特殊フォントを実行時登録する
        FrameAnimation.registerFont()
    }

    var body: some Widget {
        ClaudeLiveActivityWidget()
    }
}
