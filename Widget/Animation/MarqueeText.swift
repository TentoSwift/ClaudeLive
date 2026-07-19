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

    // 文字数が多いほどループを長くして、読める速さ（目安: 秒間 9 文字）を保つ。
    // コマ数はレイヤーが増えすぎないよう上限 24 で頭打ちにする
    // （長文ほど 1 コマの表示時間が延びてカクつきが増えるが、実用上の妥協点）
    private var loopDuration: TimeInterval {
        max(4, Double(text.count) / 9.0)
    }
    private var frameCount: Int {
        min(24, max(8, Int((loopDuration * 2.2).rounded())))
    }

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
                // 右端の外から入り、左端の外まで完全に出て一巡（ジャンプカットで再開）
                let gap: CGFloat = 32
                let startX = width
                let endX = -(measured + gap)
                FrameAnimatingView(
                    coverWidth: width,
                    coverHeight: lineHeight,
                    loopDuration: loopDuration,
                    frames: (0..<frameCount).map { i -> AnyView in
                        let t = CGFloat(i) / CGFloat(frameCount)
                        let x = startX + (endX - startX) * t
                        return AnyView(
                            Text(text)
                                .font(font)
                                .foregroundStyle(color)
                                .lineLimit(1)
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
