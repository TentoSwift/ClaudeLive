import SwiftUI

/// ミニタイル: 1 セッション = 1 ウィンドウの小型パネル。
/// Mac Virtual Display の周囲に並べて置く用途（visionOS がウィンドウ位置を
/// 永続化するので、再起動後も置いた場所に復元される）
struct TileView: View {
    @Environment(VisionAppModel.self) private var model
    @Environment(\.dismissWindow) private var dismissWindow
    let sessionId: String

    @State private var answering = false
    @AppStorage(controlModeKey) private var controlMode = false
    /// セッションが一覧から消えた後も「完了」表示で固定するための最後の姿
    @State private var lastSeen: VisionAppModel.Session?

    private var session: VisionAppModel.Session? {
        model.session(id: sessionId) ?? lastSeen
    }

    var body: some View {
        HStack(spacing: 12) {
            // 左: 状態を演じるキャラクター
            CharacterPoseView(status: ClaudeStatus(session?.status ?? "working"),
                              questionText: session?.question ?? "")
                .frame(width: 110)

            // 右: セッション情報
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(session?.project ?? "")
                        .font(.headline)
                        .lineLimit(1)
                    Spacer()
                    if let session {
                        let status = ClaudeStatus(session.status)
                        Label(status.label, systemImage: status.icon)
                            .font(.caption.bold())
                            .foregroundStyle(status.color)
                    }
                }
                if let session {
                    if !session.currentTool.isEmpty {
                        Text(session.currentTool)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                    // 直近の説明文/返答（マーキーは不要。数行そのまま出す）
                    if !session.lastResponse.isEmpty {
                        Text(session.lastResponse)
                            .font(.footnote)
                            .lineLimit(3)
                    } else if !session.lastPrompt.isEmpty {
                        Text(session.lastPrompt)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    Spacer(minLength: 0)
                    // 質問: 単一質問はその場のボタンで即答、複数はダッシュボードへ誘導
                    if !session.question.isEmpty {
                        questionArea(session)
                    } else {
                        HStack {
                            Text(session.startedAt, style: .relative)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                            Spacer()
                        }
                    }
                } else {
                    Text("セッションは終了しました")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Button("閉じる") { dismissWindow() }
                        .font(.caption)
                }
            }
        }
        .padding()
        .frame(width: 420, height: 260)
        .task {
            model.beginPolling()
        }
        .onDisappear { model.endPolling() }
        .onChange(of: model.sessions.first(where: { $0.id == sessionId })?.status) { _, _ in
            if let live = model.session(id: sessionId) {
                lastSeen = live
            }
        }
    }

    @ViewBuilder
    private func questionArea(_ session: VisionAppModel.Session) -> some View {
        if session.questions.count > 1 {
            Text("\(session.questions.count)件の質問 — ダッシュボードで回答")
                .font(.caption.bold())
                .foregroundStyle(Color.claudeBrand)
        } else if controlMode {
            // 視線 + タップで即答
            HStack(spacing: 6) {
                ForEach(session.options.prefix(3), id: \.self) { option in
                    Button {
                        answering = true
                        Task {
                            _ = await model.answer(sessionId: sessionId, answers: [[option]])
                            answering = false
                        }
                    } label: {
                        Text(option)
                            .font(.caption)
                            .lineLimit(1)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.claudeBrand)
                    .disabled(answering)
                }
            }
        } else {
            Text("質問が来ています（回答は操作モードをオンに）")
                .font(.caption)
                .foregroundStyle(Color.claudeBrand)
        }
    }
}
