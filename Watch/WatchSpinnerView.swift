import SwiftUI
import UIKit

/// セッション詳細（作業中）に出す、Dynamic Island と同じ Claude マークの
/// モーフィングアニメーション。Widget/ロック画面版はライブアクティビティの
/// 更新制約を回避するためフォントマスクの力技（Widget/Animation/FrameAnimation.swift）
/// を使っているが、watchOS の通常のアプリ画面は普通に再描画され続けるので、
/// TimelineView でそのままコマ送りすれば十分
struct WatchSpinnerView: View {
    let size: CGFloat

    private static let frameNames = (1...8).map { "spinner-frame\($0)" }
    private static let loopDuration: TimeInterval = 2
    private static let frameDuration = loopDuration / TimeInterval(frameNames.count)

    var body: some View {
        TimelineView(.periodic(from: .now, by: Self.frameDuration)) { context in
            let elapsed = context.date.timeIntervalSinceReferenceDate
            let index = Int(elapsed / Self.frameDuration) % Self.frameNames.count
            frame(at: index)
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
        }
    }

    private func frame(at index: Int) -> Image {
        let name = Self.frameNames[index]
        if let url = Bundle.main.url(forResource: name, withExtension: "png"),
           let uiImage = UIImage(contentsOfFile: url.path) {
            return Image(uiImage: uiImage)
        }
        return Image(systemName: "sparkle")
    }
}
