import SwiftUI
import UIKit

/// 1 行に収まらないテキストだけ、FrameAnimatingView（フォントマスク方式）で
/// 横スクロールさせる。収まる場合は普通に静止表示する（無駄なアニメーションを避ける）。
///
/// 実際のレンダリング幅の測定には NSString のサイズ計算 API を使う
/// （SwiftUI の Font から UIFont への直接変換手段が無いため、呼び出し側が
/// 見た目に近い UIFont サイズ・太さを指定する。ピクセル完全一致は狙わない）
struct MarqueeText: View {
    let text: String
    let font: Font
    let uiFontSize: CGFloat
    let uiFontWeight: UIFont.Weight
    let color: Color
    var lineHeight: CGFloat = 16

    private var uiFont: UIFont { .systemFont(ofSize: uiFontSize, weight: uiFontWeight) }

    // ★ ループ長は物理的に「2 秒」（秒の 1 の位の点滅）か「20 秒」（10 の位）の
    //   どちらかしか作れない。マーキーは読みやすさ優先で 20 秒モードを使う。
    //   コマ数は自動更新タイマーテキストの上限（多すぎると全静止）と
    //   滑らかさのバランスで決める（16 コマ = タイマーテキスト 32 個/マーキー）
    private let loopDuration: TimeInterval = 20.0
    private let frameCount: Int = 16

    private func textWidth(_ text: String) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: uiFont]).width
    }

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let measured = textWidth(text)
            if text.isEmpty {
                EmptyView()
            } else if measured <= width {
                // 収まるならアニメ不要
                Text(text)
                    .font(font)
                    .foregroundStyle(color)
                    .lineLimit(1)
                    .frame(width: width, alignment: .leading)
            } else {
                // テキストを 2 連結し、1 ループでちょうど 1 コピー分だけ進める。
                // ループ末尾と先頭で見た目が一致するので、リセットの飛びが見えない
                // シームレスなティッカーになる
                let gap: CGFloat = 48
                let copyLength = measured + gap
                FrameAnimatingView(
                    coverWidth: width,
                    coverHeight: lineHeight,
                    loopDuration: loopDuration,
                    slow: true,
                    frames: (0..<frameCount).map { i -> AnyView in
                        let x = -copyLength * CGFloat(i) / CGFloat(frameCount)
                        return AnyView(
                            HStack(spacing: gap) {
                                Text(text)
                                    .font(font)
                                    .foregroundStyle(color)
                                    .lineLimit(1)
                                    .fixedSize()
                                Text(text)
                                    .font(font)
                                    .foregroundStyle(color)
                                    .lineLimit(1)
                                    .fixedSize()
                            }
                            .fixedSize()
                            .offset(x: x)
                        )
                    })
                .frame(width: width, height: lineHeight, alignment: .leading)
                .clipped()
            }
        }
        .frame(height: lineHeight)
    }
}
