import SwiftUI

/// セッション詳細: 会話ビュー + 質問回答 + （操作モード ON なら）送信系
struct VisionSessionDetailView: View {
    @Environment(VisionAppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    let sessionId: String

    @State private var messages: [VisionAppModel.Message] = []
    @State private var promptInput = ""
    @State private var sending = false
    @State private var answering = false
    /// 質問のインデックス → 選んだ選択肢
    @State private var selections: [Int: Set<String>] = [:]
    @AppStorage(controlModeKey) private var controlMode = false

    private var session: VisionAppModel.Session? {
        model.session(id: sessionId)
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let session {
                        statusHeader(session)
                    }
                    // 会話（古い → 新しい、下ほど最新）
                    ForEach(messages) { message in
                        MessageRow(message: message)
                    }
                    if let session, !session.question.isEmpty {
                        questionCard(session)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding()
            }
            .onChange(of: messages.count) { _, _ in
                withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .task {
                model.beginPolling()
                // 会話ビューを開いている間だけ /messages を追加ポーリング
                while !Task.isCancelled {
                    messages = await model.fetchMessages(sessionId: sessionId)
                    try? await Task.sleep(for: .seconds(3))
                }
            }
            .onDisappear { model.endPolling() }
        }
        .navigationTitle(session.map { s in
            s.lastPrompt.isEmpty
                ? (s.title.isEmpty ? s.project : s.title)
                : s.lastPrompt
        } ?? "セッション")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    openWindow(id: "tile", value: sessionId)
                } label: {
                    Label("タイルとして取り出す", systemImage: "rectangle.on.rectangle")
                }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if controlMode {
                promptBar
            }
        }
    }

    private func statusHeader(_ session: VisionAppModel.Session) -> some View {
        HStack(spacing: 8) {
            let status = ClaudeStatus(session.status)
            Label(status.label, systemImage: status.icon)
                .font(.headline)
                .foregroundStyle(status.color)
            if !session.currentTool.isEmpty {
                Text(session.currentTool)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if !session.model.isEmpty {
                Text(shortModelName(session.model))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - 質問

    private func questionCard(_ session: VisionAppModel.Session) -> some View {
        let questions = session.questions.isEmpty
            ? [VisionAppModel.QuestionItem(question: session.question,
                                           options: session.options, multiSelect: false)]
            : session.questions
        let accumulate = questions.count > 1 || (questions.first?.multiSelect ?? false)

        return VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(questions.enumerated()), id: \.offset) { index, q in
                VStack(alignment: .leading, spacing: 8) {
                    Text(q.question)
                        .font(.subheadline.bold())
                    ForEach(q.options, id: \.self) { option in
                        let isSelected = selections[index]?.contains(option) ?? false
                        Button {
                            if accumulate {
                                toggleSelection(option, at: index, multiSelect: q.multiSelect)
                            } else {
                                answering = true
                                Task {
                                    _ = await model.answer(sessionId: sessionId, answers: [[option]])
                                    answering = false
                                }
                            }
                        } label: {
                            HStack {
                                Text(option)
                                if accumulate {
                                    Spacer()
                                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                }
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(accumulate && !isSelected ? Color.gray.opacity(0.4) : Color.claudeBrand)
                        .disabled(answering || !controlMode)
                    }
                }
            }
            if accumulate {
                // 全問に選択があるまで送らせない（iPhone 版と同じ方針）
                let answeredCount = (0..<questions.count)
                    .filter { !(selections[$0] ?? []).isEmpty }.count
                let allAnswered = answeredCount == questions.count
                if questions.count > 1 {
                    Text("\(questions.count)問中 \(answeredCount)問を選択")
                        .font(.caption)
                        .foregroundStyle(allAnswered ? .secondary : Color.orange)
                }
                Button {
                    let answers = (0..<questions.count).map { Array(selections[$0] ?? []) }
                    answering = true
                    Task {
                        _ = await model.answer(sessionId: sessionId, answers: answers)
                        answering = false
                        selections = [:]
                    }
                } label: {
                    Text(answering ? "送信中…"
                         : (allAnswered ? "回答する" : "すべての質問を選んでください"))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(answering || !allAnswered || !controlMode)
            }
            if !controlMode {
                Text("回答するには設定で操作モードをオンにしてください")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private func toggleSelection(_ option: String, at index: Int, multiSelect: Bool) {
        var set = selections[index] ?? []
        if multiSelect {
            if set.contains(option) { set.remove(option) } else { set.insert(option) }
        } else {
            set = [option]
        }
        selections[index] = set
    }

    // MARK: - 送信

    private var promptBar: some View {
        HStack(spacing: 8) {
            TextField("指示を送る…", text: $promptInput)
                .textFieldStyle(.roundedBorder)
                .onSubmit(sendPrompt)
            Button(action: sendPrompt) {
                Image(systemName: sending ? "hourglass" : "arrow.up.circle.fill")
                    .font(.title2)
            }
            .disabled(sending || promptInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .padding()
        .background(.regularMaterial)
    }

    private func sendPrompt() {
        let text = promptInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        promptInput = ""
        sending = true
        Task {
            _ = await model.sendPrompt(sessionId: sessionId, text: text)
            sending = false
        }
    }
}

private struct MessageRow: View {
    let message: VisionAppModel.Message

    var body: some View {
        HStack {
            if message.role == "user" { Spacer(minLength: 60) }
            Group {
                if message.role == "user" {
                    Text(message.text)
                        .foregroundStyle(.white)
                } else {
                    MarkdownText(text: message.text)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                message.role == "user"
                    ? AnyShapeStyle(Color.claudeBrand.opacity(0.85))
                    : AnyShapeStyle(.regularMaterial),
                in: RoundedRectangle(cornerRadius: 16))
            .textSelection(.enabled)
            if message.role != "user" { Spacer(minLength: 60) }
        }
    }
}
