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
    /// true = 1周流し終えて静止表示にする段階（Mac 側デーモンが判断して送る）。
    /// ウィジェット自身は時間経過を監視できないため、この判定は呼び出し元任せ
    var isSettled: Bool = false

    private var uiFont: UIFont { .systemFont(ofSize: uiFontSize, weight: uiFontWeight) }

    // ★ この方式は特殊フォントの「1 秒ごと偶数/奇数の点滅＝周期 2 秒」に
    //   完全に依存しているため、ループ長は 2 秒固定でなければ動かない
    //   （変えるとコマの表示タイミングが点滅と噛み合わず静止する）。
    //   動作実証済みのスピナーと同じ値。長文だと速いのは技術的な宿命
    private let loopDuration: TimeInterval = 2.0
    private let frameCount: Int = 8  // 実証済みスピナーと同じコマ数

    private func textWidth(_ text: String) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: uiFont]).width
    }

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let measured = textWidth(text)
            if text.isEmpty {
                EmptyView()
            } else if measured <= width || isSettled {
                // 収まる、または「1周流し終わって静止段階」→ アニメ不要
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
