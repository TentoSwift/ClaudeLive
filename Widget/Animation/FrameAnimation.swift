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

/// 秒の「10 の位」だけを切り出した、周期 20 秒のゆっくり点滅。
/// 10 の位は 0-5 を繰り返し、偶奇が 10 秒ごとに入れ替わる（0-9 黒, 10-19 透明, …）。
/// このフォントは全グリフが等幅 1em（実測済み）なので、
/// 「末尾 2 桁を切り出して、その左半分だけ残す」で正確に分離できる
private struct TensBlinkingView: View {
    let date: Date
    let size: CGFloat

    var body: some View {
        Text(date, style: .timer)
            .font(.custom(FrameAnimation.fontName, size: size))
            .lineLimit(1)
            .multilineTextAlignment(.trailing)
            .truncationMode(.head)
            .dynamicTypeSize(.large)
            .frame(width: 3.5 * size, height: size, alignment: .trailing)
            .fixedSize()
            .frame(width: 2 * size, alignment: .trailing)  // 末尾 2 桁（SS）
            .clipped()
            .frame(width: size, alignment: .leading)       // その左側 = 10 の位
            .clipped()
    }
}

/// 20 秒周期の中で start〜end の区間だけ「黒」になるマスク（ゆっくりマーキー用）
private struct SlowFlashingView: View {
    let frontStart: Date
    let backStart: Date
    let size: CGFloat

    init(start: Date, end: Date, size: CGFloat) {
        self.frontStart = start
        self.backStart = end.addingTimeInterval(-9.99)
        self.size = size
    }

    var body: some View {
        TensBlinkingView(date: frontStart, size: size)
            .mask { TensBlinkingView(date: backStart, size: size) }
    }
}

/// 任意の View 配列を、指定した周期でコマ送りループ再生する。
/// 各コマは「その時間帯だけ表示される」マスクで切り替わる。
///
/// マスクは 1 コマにつき点滅 1 組（タイマーテキスト 2 個）だけにする。
/// タイルを敷き詰める方式は自動更新テキストが数百個になり、WidgetKit の
/// 上限を超えてタイマーが刻まれなくなる（＝全コマ静止する）ため使わない。
/// 実証済みのスピナー（8 コマ × 2 個 = 16 個）と同じ部品数スケールを守る
struct FrameAnimatingView<Content: View>: View {
    let coverWidth: CGFloat
    let coverHeight: CGFloat
    let loopDuration: TimeInterval
    /// true = 秒の 10 の位を使う 20 秒周期モード（ゆっくりマーキー用）。
    /// false = 1 の位を使う 2 秒周期モード（スピナー等）。
    /// この 2 つ以外の周期は物理的に作れない（フォント点滅の仕組み上の制約）
    let slow: Bool
    let frames: [Content]

    init(coverWidth: CGFloat, coverHeight: CGFloat, loopDuration: TimeInterval = 2,
         slow: Bool = false, frames: [Content]) {
        self.coverWidth = coverWidth
        self.coverHeight = coverHeight
        self.loopDuration = loopDuration
        self.slow = slow
        self.frames = frames
    }

    /// 正方形1枚で足りる用途（アイコンのコマ送りなど）向けの簡易イニシャライザ
    init(size: CGFloat, loopDuration: TimeInterval = 2, frames: [Content]) {
        self.init(coverWidth: size, coverHeight: size, loopDuration: loopDuration, frames: frames)
    }

    var body: some View {
        let per = loopDuration / TimeInterval(max(frames.count, 1))
        // timer テキストの基準は 2001-01-01 0:00。ここを起点に各コマの表示区間を割り当てる
        let base = Date(timeIntervalSinceReferenceDate: 0)
        // 覆いたい面の長辺に合わせた 1 枚の正方形マスクで覆う
        // （特殊フォントの黒四角グリフはベクターなので大きくしても描画は保たれる）
        let maskSize = max(coverWidth, coverHeight)
        // 黒四角グリフは右寄せ 1 文字ぶんの幅しかないため、横長の帯（マーキー）では
        // 右端しか覆えない。横に大きく引き伸ばして全幅を確実に覆う
        // （はみ出し過剰は無害。マスクが対象より大きい分には問題ない）
        let needsWide = coverWidth > coverHeight * 2
        ZStack {
            ForEach(Array(frames.enumerated()), id: \.offset) { index, frame in
                let start = base.addingTimeInterval(per * TimeInterval(index))
                let end = start.addingTimeInterval(per)
                frame
                    .mask {
                        Group {
                            if slow {
                                SlowFlashingView(start: start, end: end, size: maskSize)
                            } else {
                                FlashingView(start: start, end: end, size: maskSize)
                            }
                        }
                        .scaleEffect(x: needsWide ? 6 : 1, y: needsWide ? 1.5 : 1, anchor: .center)
                    }
            }
        }
    }
}
