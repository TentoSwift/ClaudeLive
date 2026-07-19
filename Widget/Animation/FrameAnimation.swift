import CoreText
import SwiftUI

// WidgetKit / ActivityKit のビュー内で「連続アニメーション」を実現するための仕組み。
// 元ネタ: Kyome22/AnimationLimitBreaker（brycebostwick/WidgetAnimation ベース、いずれも公開 API のみ）
//
// 原理:
//  - ウィジェット内で唯一 push 無しに動き続けられるのは Text(date:style:.timer)。
//  - 偶数値=黒い四角 / 奇数値=透明 になる特殊フォント(FillRect-Regular)を当てると
//    1 秒周期で点滅する View になる。
//  - それを時間をずらして重ねて mask にすることで「秒未満の短い表示ウィンドウ」を作り、
//    画像を ZStack で並べればコマ送りアニメーションになる。
//
// 注意: 滑らかな連続アニメではなく「コマ送り」。フレーム数×表示時間の分だけ
// レイヤーが重なるので、枚数を増やしすぎるとウィジェットの複雑度制限に当たりうる。

enum FrameAnimation {
    static let fontName = "FillRect-Regular"

    /// 特殊フォントを実行時に登録する。ウィジェット拡張のバンドルから探す。
    /// 複数回呼ばれても害はない（登録済みなら false が返るだけ）
    @discardableResult
    static func registerFont() -> Bool {
        guard let url = Bundle(for: BundleToken.self)
            .url(forResource: fontName, withExtension: "otf")
            ?? Bundle.main.url(forResource: fontName, withExtension: "otf") else {
            return false
        }
        return CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
    }

    private final class BundleToken {}
}

/// 検証用: くるくる回る（ように見える）ゲージアイコンのコマ送りアニメ。
/// これが Live Activity 内で実際に動けば、フォントマスク方式が使えると分かる
struct SpinnerProofView: View {
    let size: CGFloat
    let color: Color

    private static let percents = [0, 33, 50, 67, 100, 67, 50, 33]

    var body: some View {
        FrameAnimatingView(
            size: size,
            loopDuration: 2,
            frames: Self.percents.map { p in
                Image(systemName: "gauge.with.dots.needle.\(p)percent")
                    .resizable()
                    .scaledToFit()
                    .frame(width: size, height: size)
                    .foregroundStyle(color)
            })
    }
}

/// timer テキスト + 特殊フォントで 1 秒周期に点滅する矩形
private struct BlinkingView: View {
    let date: Date
    let size: CGFloat

    var body: some View {
        Text(date, style: .timer)
            .font(.custom(FrameAnimation.fontName, size: size))
            .lineLimit(1)
            .multilineTextAlignment(.trailing)
            .truncationMode(.head)
            .dynamicTypeSize(.large)
            .frame(width: 2.5 * size, height: size, alignment: .trailing)
            .fixedSize()
            .frame(width: size, alignment: .trailing)
            .clipped()
    }
}

/// start〜end の短い区間だけ「黒」になるマスク。点滅を 2 枚ずらして重ねて作る
private struct FlashingView: View {
    let frontStart: Date
    let backStart: Date
    let size: CGFloat

    init(start: Date, end: Date, size: CGFloat) {
        self.frontStart = start
        self.backStart = end.addingTimeInterval(-0.99)
        self.size = size
    }

    var body: some View {
        BlinkingView(date: frontStart, size: size)
            .mask { BlinkingView(date: backStart, size: size) }
    }
}

/// 任意の View 配列を、指定した周期でコマ送りループ再生する。
/// 各コマは「その時間帯だけ表示される」マスクで切り替わる。
struct FrameAnimatingView<Content: View>: View {
    let size: CGFloat
    let loopDuration: TimeInterval
    let frames: [Content]

    init(size: CGFloat, loopDuration: TimeInterval = 2, frames: [Content]) {
        self.size = size
        self.loopDuration = loopDuration
        self.frames = frames
    }

    var body: some View {
        let per = loopDuration / TimeInterval(max(frames.count, 1))
        // timer テキストの基準は 2001-01-01 0:00。ここを起点に各コマの表示区間を割り当てる
        let base = Date(timeIntervalSinceReferenceDate: 0)
        ZStack {
            ForEach(Array(frames.enumerated()), id: \.offset) { index, frame in
                let start = base.addingTimeInterval(per * TimeInterval(index))
                let end = start.addingTimeInterval(per)
                frame
                    .mask { FlashingView(start: start, end: end, size: size) }
            }
        }
    }
}
