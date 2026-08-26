import RealityKit
import SwiftUI

/// セッションの状態を演じる 3D の Claude マーク（スターバースト）。
///
/// 中心から放射状に伸びる 12 本のスポークを円柱で組んだ立体マークで、
/// 状態を動きで表現する:
///   working/compacting → 小さくなったり大きくなったりの脈動（鼓動）
///   waiting/idle       → ごくゆっくり回転（待機）
///   permission/question→ 速い脈動 + 2D 吹き出し（注意喚起）
///   done               → 静止（ひと息）
///
/// 見た目とロジックはこのビューに閉じているので、表現を変えるときは
/// このファイルだけ直せばよい（VISIONOS_SPEC.md 参照）。
struct CharacterPoseView: View {
    let status: ClaudeStatus
    /// question のときに吹き出しへ出す文面（先頭 1 行に切り詰めて表示）
    var questionText: String = ""

    /// 動きのグルーピング（status → 演出の種類）
    private enum Motion: String {
        case pulse       // 作業中: ゆったり脈動
        case spin        // 入力待ち: ゆっくり回転
        case attention   // 質問/許可待ち: 速い脈動
        case still       // 完了: 静止
    }

    private var motion: Motion {
        switch status {
        case .working, .compacting:  return .pulse
        case .waiting:               return .spin
        case .permission, .question: return .attention
        case .error:                 return .attention
        case .done:                  return .still
        }
    }

    var body: some View {
        RealityView { content in
            let root = Entity()
            root.name = "markRoot"
            content.add(root)
            Self.build(motion: motion, into: root)
        } update: { content in
            guard let root = content.entities.first(where: { $0.name == "markRoot" })
            else { return }
            // 動きが変わったときだけ組み直す（update は頻繁に呼ばれるため）
            if root.components[MotionMarker.self]?.motion != motion.rawValue {
                Self.build(motion: motion, into: root)
            }
        }
        .overlay(alignment: .top) {
            // 3D attachment の吹き出しは v1 では先送りし、2D で重ねる
            if motion == .attention {
                Text(bubbleText)
                    .font(.caption2)
                    .lineLimit(1)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.regularMaterial, in: Capsule())
                    .overlay(Capsule().stroke(Color.claudeBrand.opacity(0.6), lineWidth: 1))
            }
        }
    }

    private var bubbleText: String {
        if status == .question, !questionText.isEmpty {
            return String(questionText.prefix(20))
        }
        return status == .permission ? "許可を求めています" : "質問があります"
    }

    /// 動き判定用に root へ付けるマーカー
    private struct MotionMarker: Component {
        var motion: String
    }

    // MARK: - モデル組み立て

    private static let markMaterial = SimpleMaterial(
        color: UIColor(red: 0.85, green: 0.47, blue: 0.34, alpha: 1), isMetallic: false)

    private static func build(motion: Motion, into root: Entity) {
        root.children.removeAll()
        root.components.set(MotionMarker(motion: motion.rawValue))
        root.transform = .identity

        // スターバースト: 長さのまちまちなスポークを放射状に。
        // 実際の Claude マークと同じく均等でない有機的な配置にする
        // （角度は 30° 刻み + わずかなずらし、長さは交互に長短）
        let mark = Entity()
        mark.name = "mark"
        let lengths: [Float] = [0.034, 0.024, 0.031, 0.022, 0.033, 0.026,
                                0.032, 0.023, 0.030, 0.025, 0.034, 0.024]
        let jitters: [Float] = [0, 0.06, -0.04, 0.05, 0, -0.06,
                                0.04, -0.05, 0.06, 0, -0.04, 0.05]
        for i in 0..<12 {
            let length = lengths[i]
            let spoke = ModelEntity(
                mesh: .generateCylinder(height: length, radius: 0.0042),
                materials: [markMaterial])
            let pivot = Entity()
            let angle = Float(i) * (.pi / 6) + jitters[i]
            pivot.orientation = simd_quatf(angle: angle, axis: [0, 0, 1])
            // 円柱の原点は中央なので、半分だけ外へずらすと中心から生える
            spoke.position = [0, length / 2 + 0.004, 0]
            pivot.addChild(spoke)
            mark.addChild(pivot)
        }
        // 立体感: 中心にわずかな厚みのハブ
        let hub = ModelEntity(mesh: .generateSphere(radius: 0.006),
                              materials: [markMaterial])
        hub.scale = [1, 1, 0.6]
        mark.addChild(hub)
        root.addChild(mark)

        // ウィンドウ枠に収まるサイズと位置（実測調整値。
        // そのままだと左枠の下寄りに描画されたため、中央へ持ち上げる）
        root.scale = [0.55, 0.55, 0.55]
        root.position = [0, 0.022, 0]

        switch motion {
        case .pulse:
            // 作業中: 小さく ⇔ 大きくの鼓動。ゆったりめ
            pulse(mark, from: 0.82, to: 1.08, period: 1.2)

        case .spin:
            // 入力待ち: ゆっくり回り続ける
            spin(mark, period: 14)

        case .attention:
            // 質問/許可待ち: 速く強い鼓動で目を引く
            pulse(mark, from: 0.75, to: 1.15, period: 0.45)

        case .still:
            // 完了: 静止
            break
        }
    }

    /// 拡大縮小の繰り返し（FromToByAnimation の autoReverse。CPU タイマー不使用）
    private static func pulse(_ entity: Entity, from: Float, to: Float, period: TimeInterval) {
        var small = entity.transform
        var large = entity.transform
        small.scale = SIMD3(repeating: from)
        large.scale = SIMD3(repeating: to)
        guard let animation = try? AnimationResource.generate(with: FromToByAnimation(
            from: small, to: large, duration: period,
            timing: .easeInOut, bindTarget: .transform, repeatMode: .autoReverse)) else { return }
        entity.playAnimation(animation.repeat())
    }

    /// Z 軸まわりのゆっくりした連続回転
    private static func spin(_ entity: Entity, period: TimeInterval) {
        var quarter = entity.transform
        quarter.rotation = simd_quatf(angle: .pi / 2, axis: [0, 0, 1])
        guard let animation = try? AnimationResource.generate(with: FromToByAnimation(
            from: entity.transform, to: quarter, duration: period / 4,
            timing: .linear, bindTarget: .transform, repeatMode: .repeat)) else { return }
        entity.playAnimation(animation.repeat())
    }
}
