import RealityKit
import SwiftUI

/// セッションの状態を演じる 3D キャラクター（v1 プレースホルダー）。
///
/// 本格的な USDZ アニメーションモデルはまだ用意せず、RealityKit の基本
/// ジオメトリ（球体 + 円柱）を組んだ抽象フォルムにポーズ差分だけ付けて動かす。
/// 見た目とロジックをこのビューに閉じ込めてあるので、本物のモデルへの
/// 差し替えはこのファイルだけ直せばよい（VISIONOS_SPEC.md 参照）。
///
/// 状態 → 演技:
///   working/compacting → 机に向かって両腕を交互に上下（タイピング）
///   waiting/idle       → 本を持って読書、頭がゆっくり左右
///   permission/question→ 右腕を上げて小刻みに振る + 2D 吹き出し
///   done               → 腕を下ろして体がゆっくり上下（ひと息）
struct CharacterPoseView: View {
    let status: ClaudeStatus
    /// question のときに吹き出しへ出す文面（先頭 1 行に切り詰めて表示）
    var questionText: String = ""

    /// ポーズのグルーピング（status → 演技の種類）
    private enum Pose: String {
        case typing, reading, attention, rest
    }

    private var pose: Pose {
        switch status {
        case .working, .compacting: return .typing
        case .waiting:              return .reading
        case .permission, .question: return .attention
        case .done:                 return .rest
        case .error:                return .attention
        }
    }

    var body: some View {
        RealityView { content in
            let root = Entity()
            root.name = "characterRoot"
            content.add(root)
            Self.build(pose: pose, into: root)
        } update: { content in
            guard let root = content.entities.first(where: { $0.name == "characterRoot" })
            else { return }
            // ポーズが変わったときだけ組み直す（update は頻繁に呼ばれるため）
            if root.components[PoseMarker.self]?.pose != pose.rawValue {
                Self.build(pose: pose, into: root)
            }
        }
        .overlay(alignment: .top) {
            // 3D attachment の吹き出しは v1 では先送りし、2D で重ねる
            // （VISIONOS_SPEC.md の注記どおり）
            if pose == .attention {
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

    /// ポーズ判定用に root へ付けるマーカー
    private struct PoseMarker: Component {
        var pose: String
    }

    // MARK: - モデル組み立て

    private static let bodyColor = SimpleMaterial(
        color: UIColor(red: 0.85, green: 0.47, blue: 0.34, alpha: 1), isMetallic: false)
    private static let darkColor = SimpleMaterial(
        color: UIColor(white: 0.25, alpha: 1), isMetallic: false)
    private static let paperColor = SimpleMaterial(
        color: UIColor(white: 0.95, alpha: 1), isMetallic: false)

    private static func build(pose: String, into root: Entity) {
        build(pose: Pose(rawValue: pose) ?? .rest, into: root)
    }

    private static func build(pose: Pose, into root: Entity) {
        root.children.removeAll()
        root.components.set(PoseMarker(pose: pose.rawValue))

        // ウィンドウ内 RealityView に収まるサイズ感（メートル）。
        // 実機/シミュレータで見て調整する前提の初期値
        let s: Float = 1.0
        // ウィンドウ枠からはみ出さないよう全体を縮める（腕を前に出す
        // ポーズが手前へ突き抜けて見えた実測に合わせた調整値）
        root.scale = [0.55, 0.55, 0.55]
        root.position = [0, 0.005, 0]

        // 胴体
        let body = ModelEntity(mesh: .generateSphere(radius: 0.030 * s),
                               materials: [bodyColor])
        body.name = "body"
        body.scale = [1.0, 1.15, 0.9]
        root.addChild(body)

        // 頭
        let head = ModelEntity(mesh: .generateSphere(radius: 0.020 * s),
                               materials: [bodyColor])
        head.name = "head"
        head.position = [0, 0.045 * s, 0]
        root.addChild(head)

        // 目（黒い小球 2 つ。顔の向きを分からせる最小要素）
        for dx in [Float(-0.007), 0.007] {
            let eye = ModelEntity(mesh: .generateSphere(radius: 0.0025 * s),
                                  materials: [darkColor])
            eye.position = [dx * s, 0.003 * s, 0.018 * s]
            head.addChild(eye)
        }

        // 腕（細い円柱）。肩から生やし、ポーズごとに角度を変える
        let armMesh = MeshResource.generateCylinder(height: 0.030 * s, radius: 0.005 * s)
        let leftArm = ModelEntity(mesh: armMesh, materials: [bodyColor])
        let rightArm = ModelEntity(mesh: armMesh, materials: [bodyColor])
        leftArm.name = "leftArm"
        rightArm.name = "rightArm"
        // 円柱の原点は中央なので、肩を支点に回せるようピボット用の親を挟む
        let leftShoulder = Entity()
        let rightShoulder = Entity()
        leftShoulder.position = [-0.028 * s, 0.020 * s, 0]
        rightShoulder.position = [0.028 * s, 0.020 * s, 0]
        leftArm.position = [0, -0.015 * s, 0]
        rightArm.position = [0, -0.015 * s, 0]
        leftShoulder.addChild(leftArm)
        rightShoulder.addChild(rightArm)
        root.addChild(leftShoulder)
        root.addChild(rightShoulder)

        switch pose {
        case .typing:
            // 頭を少し前傾、両腕を前へ。腕を交互に小さく上下＝タイピング
            head.orientation = simd_quatf(angle: 0.25, axis: [1, 0, 0])
            leftShoulder.orientation = simd_quatf(angle: -0.9, axis: [1, 0, 0])
            rightShoulder.orientation = simd_quatf(angle: -0.9, axis: [1, 0, 0])
            wobble(leftShoulder, axis: [1, 0, 0], base: -0.9, amount: 0.18, period: 0.24)
            wobble(rightShoulder, axis: [1, 0, 0], base: -0.9, amount: 0.18, period: 0.24,
                   phaseOffset: true)
            // 手元のキーボード（薄い板）
            let keyboard = ModelEntity(
                mesh: .generateBox(size: [0.045 * s, 0.004 * s, 0.02 * s]),
                materials: [darkColor])
            keyboard.position = [0, -0.012 * s, 0.032 * s]
            root.addChild(keyboard)

        case .reading:
            // 本を体の前に。頭は下向き + ゆっくり左右（行を追う視線）
            head.orientation = simd_quatf(angle: 0.35, axis: [1, 0, 0])
            wobble(head, axis: [0, 1, 0], base: 0, amount: 0.15, period: 2.4,
                   pitchBase: 0.35)
            leftShoulder.orientation = simd_quatf(angle: -1.5, axis: [1, 0, 0])
            rightShoulder.orientation = simd_quatf(angle: -1.5, axis: [1, 0, 0])
            let book = ModelEntity(
                mesh: .generateBox(size: [0.038 * s, 0.028 * s, 0.004 * s]),
                materials: [paperColor])
            book.position = [0, 0.008 * s, 0.036 * s]
            book.orientation = simd_quatf(angle: -0.5, axis: [1, 0, 0])
            root.addChild(book)

        case .attention:
            // 右腕を高く上げて小刻みに振る（呼んでいる）。頭は正面
            leftShoulder.orientation = simd_quatf(angle: 0.2, axis: [0, 0, 1])
            rightShoulder.orientation = simd_quatf(angle: 2.6, axis: [0, 0, 1])
            wobble(rightShoulder, axis: [0, 0, 1], base: 2.6, amount: 0.25, period: 0.3)
            // 体も気持ち弾ませる
            wobble(body, axis: [1, 0, 0], base: 0, amount: 0.0, period: 0.6,
                   bouncing: 0.004 * s)

        case .rest:
            // 腕を下ろし、体がゆっくり上下（ひと息ついている）
            leftShoulder.orientation = simd_quatf(angle: 0.25, axis: [0, 0, 1])
            rightShoulder.orientation = simd_quatf(angle: -0.25, axis: [0, 0, 1])
            wobble(body, axis: [1, 0, 0], base: 0, amount: 0, period: 1.8,
                   bouncing: 0.003 * s)
            wobble(head, axis: [1, 0, 0], base: 0, amount: 0, period: 1.8,
                   bouncing: 0.003 * s)
        }
    }

    /// エンティティに繰り返しの揺れ（回転 or 上下）を付ける。
    /// FromToByAnimation の autoReverse 繰り返しで、CPU 側のタイマーを使わない
    private static func wobble(_ entity: Entity, axis: SIMD3<Float>,
                               base: Float, amount: Float, period: TimeInterval,
                               phaseOffset: Bool = false,
                               pitchBase: Float = 0,
                               bouncing: Float = 0) {
        var from = entity.transform
        var to = entity.transform
        if bouncing > 0 {
            to.translation.y += bouncing
        } else {
            let pitch = pitchBase != 0
                ? simd_quatf(angle: pitchBase, axis: [1, 0, 0]) : simd_quatf(angle: 0, axis: [0, 1, 0])
            from.rotation = pitch * simd_quatf(angle: base - amount, axis: axis)
            to.rotation = pitch * simd_quatf(angle: base + amount, axis: axis)
        }
        guard let animation = try? AnimationResource.generate(with: FromToByAnimation(
            from: from, to: to, duration: period,
            timing: .easeInOut, bindTarget: .transform, repeatMode: .autoReverse)) else { return }
        entity.playAnimation(animation.repeat(),
                             transitionDuration: phaseOffset ? period / 2 : 0)
    }
}
