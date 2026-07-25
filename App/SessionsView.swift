import SwiftUI

/// セッション一覧のセクション（ContentView に埋め込む）
struct SessionsSection: View {
    @EnvironmentObject private var model: AppModel
    @State private var showNewSession = false

    var body: some View {
        Section("Mac のセッション") {
            Button {
                showNewSession = true
            } label: {
                Label("新規セッション", systemImage: "plus.circle.fill")
            }
            if model.remoteSessions.isEmpty {
                Text("セッションなし（Mac に接続できているか確認）")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.remoteSessions) { session in
                    NavigationLink(value: session.id) {
                        SessionRow(session: session)
                    }
                }
            }
        }
        .sheet(isPresented: $showNewSession) {
            NewSessionSheet()
        }
    }
}

/// 新規セッション開始シート：プロジェクトを選んで最初の指示を送ると、
/// Mac 側で `claude -p`（--resume なし）が新しいセッションとして起動する
private struct NewSessionSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var selectedPath = ""
    @State private var selectedModel: ClaudeModelChoice?
    @State private var promptInput = ""
    @State private var sending = false

    var body: some View {
        NavigationStack {
            Form {
                Section("プロジェクト") {
                    if model.projects.isEmpty {
                        Text("読み込み中…")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(model.projects, id: \.path) { project in
                            Button {
                                selectedPath = project.path
                            } label: {
                                HStack {
                                    Text(project.name)
                                    Spacer()
                                    if selectedPath == project.path {
                                        Image(systemName: "checkmark")
                                            .foregroundStyle(.tint)
                                    }
                                }
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.primary)
                        }
                    }
                }
                Section("モデル") {
                    Picker("モデル", selection: $selectedModel) {
                        Text("既定のまま").tag(ClaudeModelChoice?.none)
                        ForEach(ClaudeModelChoice.allCases) { choice in
                            Text(choice.label).tag(ClaudeModelChoice?.some(choice))
                        }
                    }
                    .pickerStyle(.menu)
                }
                Section("最初の指示") {
                    TextField("何をしてほしいか…", text: $promptInput, axis: .vertical)
                        .lineLimit(3...6)
                }
            }
            .navigationTitle("新規セッション")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("開始") {
                        let cwd = selectedPath.isEmpty ? (model.projects.first?.path ?? "") : selectedPath
                        let text = promptInput
                        let modelId = selectedModel?.rawValue ?? ""
                        sending = true
                        Task {
                            await model.startNewSession(cwd: cwd, text: text, model: modelId)
                            sending = false
                            dismiss()
                        }
                    }
                    .disabled(promptInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                              || model.projects.isEmpty || sending)
                }
            }
            .task {
                await model.loadProjects()
                if selectedPath.isEmpty { selectedPath = model.projects.first?.path ?? "" }
            }
            .overlay {
                if sending {
                    ProgressView("開始しています…")
                        .padding()
                        .background(.regularMaterial, in: .rect(cornerRadius: 12))
                }
            }
        }
    }
}

private struct SessionRow: View {
    let session: AppModel.RemoteSession

    /// 一覧で見分けやすいように、ランダムな内部名（例 "claud-9b"）より会話の
    /// 中身を表す文字列を見出しにする。会話が進むと最初の指示（title）より
    /// 直前のプロンプト（lastPrompt）の方が「今何をしているセッションか」を
    /// 表すので、そちらを優先する
    private var headline: String {
        if !session.lastPrompt.isEmpty { return session.lastPrompt }
        if !session.title.isEmpty { return session.title }
        return session.name.isEmpty ? session.project : session.name
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(headline)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                let status = ClaudeStatus(session.status)
                Label(session.status == "idle" ? "待機" : status.label,
                      systemImage: session.status == "idle" ? "moon.zzz" : status.icon)
                    .font(.caption)
                    .foregroundStyle(session.status == "idle" ? Color.secondary : status.color)
            }
            HStack(spacing: 6) {
                Text(session.project)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !session.name.isEmpty {
                    Text(session.name)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                if session.toolCount > 0 {
                    Text("ツール \(session.toolCount) 回")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            // 見出しが直前のプロンプトになったので、元々何を頼んだセッションかが
            // わかるよう最初の指示（title）を添える。質問中はボタン UI が主役なので出さない
            if !session.title.isEmpty, session.title != headline,
               session.status != "question" {
                Text(session.title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}

/// セッション詳細：会話の閲覧、質問への回答（選択肢ボタン + 自由入力）、
/// 新しい指示の送信（キー入力方式で Claude Desktop に即反映される）
struct SessionDetailView: View {
    @EnvironmentObject private var model: AppModel
    let sessionId: String

    @State private var messages: [AppModel.ChatMessage] = []
    @State private var loaded = false
    @State private var answerInput = ""
    @State private var answering = false
    @State private var promptInput = ""
    @State private var sendingPrompt = false
    /// 複数質問・複数選択(multiSelect)のときの選択状態。質問のインデックス → 選んだ選択肢
    @State private var selections: [Int: Set<String>] = [:]

    private var session: AppModel.RemoteSession? {
        model.remoteSessions.first { $0.id == sessionId }
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    promptSection
                    if let session, !session.question.isEmpty {
                        questionSection(session)
                    }
                    if !loaded {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .padding()
                    } else if messages.isEmpty {
                        Text("会話履歴を読み込めませんでした")
                            .foregroundStyle(.secondary)
                            .padding()
                    }
                    ForEach(messages) { message in
                        MessageBubble(message: message)
                            .id(message.id)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .onChange(of: messages.count) { _, _ in
                if let last = messages.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
        .navigationTitle(session.map { s in
            if !s.lastPrompt.isEmpty { return s.lastPrompt }
            return s.title.isEmpty ? (s.name.isEmpty ? s.project : s.name) : s.title
        } ?? "セッション")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    ForEach(ClaudeQuickCommand.allCases) { command in
                        Button(command.label) {
                            Task {
                                _ = await SendCommandIntent.sendCommand(
                                    sessionId: sessionId, command: command.rawValue)
                            }
                        }
                    }
                } label: {
                    Image(systemName: "terminal")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    ForEach(ClaudeModelChoice.allCases) { choice in
                        Button(choice.label) {
                            Task {
                                _ = await ChangeModelIntent.changeModel(
                                    sessionId: sessionId, model: choice.rawValue)
                            }
                        }
                    }
                } label: {
                    Image(systemName: "cpu")
                }
            }
        }
        .task {
            await reload()
            loaded = true
            // 表示中は数秒おきに更新（閲覧専用なので Mac 側への書き込みは発生しない）
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(4))
                await reload()
            }
        }
    }

    private func reload() async {
        if let fetched = await model.fetchMessages(sessionId: sessionId) {
            messages = fetched
        }
        await model.loadRemoteSessions()
    }

    /// 新しい指示の送信。Mac 側はキー入力方式（typeIntoClaudeApp）で
    /// Claude Desktop に即反映する。ただし今フォーカスされているセッションに
    /// 入るため、他のセッションが前面のときは意図した相手に届かない点に注意
    private var promptSection: some View {
        HStack(spacing: 8) {
            TextField("指示を送る…", text: $promptInput)
                .textFieldStyle(.roundedBorder)
            Button {
                let text = promptInput
                promptInput = ""
                sendingPrompt = true
                Task {
                    _ = await SendPromptIntent.sendPrompt(sessionId: sessionId, text: text)
                    sendingPrompt = false
                }
            } label: {
                Image(systemName: sendingPrompt ? "hourglass" : "arrow.up.circle.fill")
                    .font(.title2)
            }
            .disabled(promptInput.isEmpty || sendingPrompt)
        }
        .padding(.horizontal, 12)
    }

    @ViewBuilder
    /// 単一質問・単一選択のときはタップで即送信（従来通り）。
    /// 複数質問、または multiSelect の質問があるときは、選んでから
    /// 「回答する」でまとめて送信する（1回の AskUserQuestion への回答は
    /// ひとまとめに解決する必要があるため）
    private func questionSection(_ session: AppModel.RemoteSession) -> some View {
        let questions = session.questions.isEmpty
            ? [AppModel.QuestionItem(question: session.question, options: session.options, multiSelect: false)]
            : session.questions
        let accumulate = questions.count > 1 || (questions.first?.multiSelect ?? false)

        return VStack(alignment: .leading, spacing: 14) {
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
                                    await model.answer(sessionId: sessionId, answer: option)
                                    answering = false
                                }
                            }
                        } label: {
                            HStack {
                                Text(option).font(.subheadline.bold())
                                if accumulate {
                                    Spacer()
                                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                                }
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(accumulate && !isSelected
                              ? Color.gray.opacity(0.35)
                              : Color(red: 0.85, green: 0.47, blue: 0.34))
                    }
                }
            }
            if accumulate {
                Button {
                    let answers = (0..<questions.count).map { Array(selections[$0] ?? []) }
                    answering = true
                    Task {
                        await model.answer(sessionId: sessionId, answers: answers)
                        answering = false
                        selections = [:]
                    }
                } label: {
                    Text(answering ? "送信中…" : "回答する")
                        .font(.subheadline.bold())
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color(red: 0.85, green: 0.47, blue: 0.34))
                .disabled(answering || selections.values.allSatisfy(\.isEmpty))
            } else {
                // 選択肢にない答えを自由入力できるようにする
                HStack(spacing: 6) {
                    TextField("自由入力で回答…", text: $answerInput)
                        .textFieldStyle(.roundedBorder)
                    if !answerInput.isEmpty {
                        Button {
                            let text = answerInput
                            answerInput = ""
                            answering = true
                            Task {
                                await model.answer(sessionId: sessionId, answer: text)
                                answering = false
                            }
                        } label: {
                            Image(systemName: answering ? "hourglass" : "arrow.up.circle.fill")
                                .font(.title2)
                        }
                        .disabled(answering)
                    }
                }
            }
        }
        .padding(12)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal, 12)
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
}

private struct MessageBubble: View {
    let message: AppModel.ChatMessage

    var body: some View {
        HStack {
            if message.role == "user" { Spacer(minLength: 40) }
            Group {
                if message.role == "user" {
                    Text(message.text)
                        .font(.subheadline)
                        .foregroundStyle(.white)
                } else {
                    // Claude の返答は Markdown レンダリング
                    MarkdownText(text: message.text)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                message.role == "user"
                    ? Color.accentColor.opacity(0.85)
                    : Color(.secondarySystemBackground),
                in: RoundedRectangle(cornerRadius: 14))
            .textSelection(.enabled)
            if message.role != "user" { Spacer(minLength: 40) }
        }
    }
}
