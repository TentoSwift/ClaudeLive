import SwiftUI

/// セッション一覧（ルート画面）
struct WatchContentView: View {
    @EnvironmentObject private var model: WatchModel
    @State private var path: [String] = []

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if model.sessions.isEmpty {
                    if !model.isReachable {
                        Text("iPhone に到達できません。iPhone の ClaudeLive アプリを開いて、Watch の近くに置いてください")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("セッションなし")
                            .foregroundStyle(.secondary)
                    }
                }
                // 新規セッション開始
                NavigationLink(value: "__new__") {
                    Label("新規セッション", systemImage: "plus.circle.fill")
                        .font(.headline)
                        .foregroundStyle(Color(red: 0.85, green: 0.47, blue: 0.34))
                }
                ForEach(model.sessions) { session in
                    NavigationLink(value: session.id) {
                        VStack(alignment: .leading, spacing: 2) {
                            // ランダムな内部名（例 "claud-9b"）より、会話の中身を表す
                            // 直前のプロンプト（無ければ最初の指示）を見出しにする
                            Text(session.lastPrompt.isEmpty
                                 ? (session.title.isEmpty
                                    ? (session.name.isEmpty ? session.project : session.name)
                                    : session.title)
                                 : session.lastPrompt)
                                .font(.headline)
                                .lineLimit(1)
                            Text(statusLabel(session.status))
                                .font(.caption2)
                                .foregroundStyle(statusColor(session.status))
                        }
                    }
                }
                if let error = model.lastError {
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
                Text(model.isReachable ? "iPhone: 接続中" : "iPhone: 未接続")
                    .font(.system(size: 11).monospaced())
                    .foregroundStyle(model.isReachable ? Color.secondary : Color.red)
                Text(model.lastFetchInfo)
                    .font(.system(size: 11).monospaced())
                    .foregroundStyle(.tertiary)
            }
            .navigationTitle("ClaudeLive")
            .navigationDestination(for: String.self) { value in
                if value == "__new__" {
                    WatchNewSessionView()
                } else {
                    WatchSessionDetailView(sessionId: value)
                }
            }
        }
        .task {
            model.recheckContext()
            // 画面が出ている間は数秒おきに取得し直す
            // （URL 同期の完了が取得より後になるケースの取りこぼしも防ぐ）
            while !Task.isCancelled {
                await model.refresh()
                if let id = model.focusSessionId {
                    model.focusSessionId = nil
                    path = [id]
                }
                try? await Task.sleep(for: .seconds(4))
            }
        }
        .onChange(of: model.focusSessionId) { _, id in
            if let id {
                model.focusSessionId = nil
                path = [id]
            }
        }
    }
}

/// セッション詳細。全文のプロンプト・返答・会話と、質問への回答ボタン
struct WatchSessionDetailView: View {
    @EnvironmentObject private var model: WatchModel
    let sessionId: String
    @State private var messages: [WatchModel.Message] = []
    @State private var promptInput = ""
    @State private var sending = false
    @State private var answerInput = ""
    @State private var answering = false
    @State private var showModelPicker = false
    @State private var showCommandPicker = false
    /// 複数質問・複数選択(multiSelect)のときの選択状態。質問のインデックス → 選んだ選択肢
    @State private var selections: [Int: Set<String>] = [:]

    private var session: WatchModel.Session? {
        model.sessions.first { $0.id == sessionId }
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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                if let session {
                    // 状態行 + モデル変更ボタン（watchOS には Menu が無いのでシートで選ぶ）。
                    // 作業中は Dynamic Island と同じ Claude マークのモーフィングアニメを添える
                    HStack(spacing: 4) {
                        if session.status == "working" {
                            WatchSpinnerView(size: 18)
                        }
                        Text(statusLabel(session.status))
                            .font(.headline)
                            .foregroundStyle(statusColor(session.status))
                        if !session.currentTool.isEmpty {
                            watchToolRunningIcon(session.currentTool)
                                .frame(width: 14, height: 14)
                                .foregroundStyle(.secondary)
                            Text(session.currentTool)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        // 閲覧専用（Cowork）はコマンド送信・モデル変更ができないので出さない
                        if !session.readOnly {
                            Button {
                                showCommandPicker = true
                            } label: {
                                Image(systemName: "terminal")
                            }
                            .buttonStyle(.plain)
                            Button {
                                showModelPicker = true
                            } label: {
                                Image(systemName: "cpu")
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .sheet(isPresented: $showModelPicker) {
                        WatchModelPickerView(sessionId: sessionId)
                    }
                    .sheet(isPresented: $showCommandPicker) {
                        WatchCommandPickerView(sessionId: sessionId)
                    }

                    if session.readOnly {
                        Label("閲覧のみ (Cowork)", systemImage: "eye")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }

                    // プロンプト送信（音声ディクテーション対応の標準 TextField）。
                    // 閲覧専用セッションでは送っても届かないので出さない
                    if !session.readOnly {
                    HStack(spacing: 4) {
                        TextField("指示を送る…", text: $promptInput)
                            .font(.footnote)
                        if !promptInput.isEmpty {
                            Button {
                                let text = promptInput
                                promptInput = ""
                                sending = true
                                Task {
                                    await model.sendPrompt(sessionId: sessionId, text: text)
                                    sending = false
                                }
                            } label: {
                                Image(systemName: sending ? "hourglass" : "arrow.up.circle.fill")
                            }
                            .buttonStyle(.plain)
                            .disabled(sending)
                        }
                    }

                    // 質問 + 回答ボタン。単一質問・単一選択はタップで即送信、
                    // 複数質問や multiSelect の質問があるときは選んでからまとめて送信する
                    if !session.question.isEmpty {
                        let questions = session.questions.isEmpty
                            ? [WatchModel.QuestionItem(question: session.question,
                                                        options: session.options, multiSelect: false)]
                            : session.questions
                        let accumulate = questions.count > 1 || (questions.first?.multiSelect ?? false)

                        ForEach(Array(questions.enumerated()), id: \.offset) { index, q in
                            Text(q.question)
                                .font(.footnote)
                            ForEach(q.options, id: \.self) { option in
                                let isSelected = selections[index]?.contains(option) ?? false
                                Button {
                                    if accumulate {
                                        toggleSelection(option, at: index, multiSelect: q.multiSelect)
                                    } else {
                                        Task { await model.answer(sessionId: sessionId, answer: option) }
                                    }
                                } label: {
                                    HStack {
                                        Text(option).font(.footnote.bold())
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
                                    .font(.footnote.bold())
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(Color(red: 0.85, green: 0.47, blue: 0.34))
                            .disabled(answering || selections.values.allSatisfy(\.isEmpty))
                        } else {
                            // 選択肢にない答えを自由入力できるようにする
                            HStack(spacing: 4) {
                                TextField("自由入力で回答…", text: $answerInput)
                                    .font(.footnote)
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
                                    }
                                    .buttonStyle(.plain)
                                    .disabled(answering)
                                }
                            }
                        }
                    }
                    }  // if !session.readOnly（プロンプト送信＋質問回答をまとめて隠す）

                    // 直近のやり取り（省略なしの全文）
                    if !session.lastPrompt.isEmpty {
                        label("入力")
                        Text(session.lastPrompt).font(.footnote)
                    }
                    if !session.lastResponse.isEmpty {
                        label("返答")
                        Text(session.lastResponse).font(.footnote)
                    }
                }

                // 会話履歴
                if !messages.isEmpty {
                    label("会話")
                    ForEach(messages) { message in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(message.role == "user" ? "あなた" : "Claude")
                                .font(.caption2.bold())
                                .foregroundStyle(.secondary)
                            Text(message.text)
                                .font(.footnote)
                        }
                        .padding(.bottom, 3)
                    }
                }
            }
        }
        .navigationTitle(session.map { s in
            if !s.lastPrompt.isEmpty { return s.lastPrompt }
            return s.title.isEmpty ? (s.name.isEmpty ? s.project : s.name) : s.title
        } ?? "セッション")
        .task {
            await model.refresh()
            messages = await model.fetchMessages(sessionId: sessionId)
        }
        .refreshable {
            await model.refresh()
            messages = await model.fetchMessages(sessionId: sessionId)
        }
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(.caption2.bold())
            .foregroundStyle(.secondary)
            .padding(.top, 4)
    }
}

/// 新規セッション開始: プロジェクトを選んで最初の指示を送る
struct WatchNewSessionView: View {
    @EnvironmentObject private var model: WatchModel
    @Environment(\.dismiss) private var dismiss
    @State private var selectedPath = ""
    @State private var selectedModel: ClaudeModelChoice?
    @State private var promptInput = ""
    @State private var sending = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text("プロジェクト")
                    .font(.caption2.bold())
                    .foregroundStyle(.secondary)
                ForEach(model.projects, id: \.path) { project in
                    Button {
                        selectedPath = project.path
                    } label: {
                        HStack {
                            Text(project.name).font(.footnote).lineLimit(1)
                            Spacer()
                            if selectedPath == project.path {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }

                Divider()
                Picker("モデル", selection: $selectedModel) {
                    Text("既定のまま").tag(ClaudeModelChoice?.none)
                    ForEach(ClaudeModelChoice.allCases) { choice in
                        Text(choice.label).tag(ClaudeModelChoice?.some(choice))
                    }
                }
                .font(.footnote)

                Divider()
                TextField("最初の指示…", text: $promptInput)
                    .font(.footnote)
                Button {
                    let cwd = selectedPath.isEmpty ? (model.projects.first?.path ?? "") : selectedPath
                    let text = promptInput
                    let modelId = selectedModel?.rawValue ?? ""
                    sending = true
                    Task {
                        await model.newSession(cwd: cwd, text: text, model: modelId)
                        sending = false
                        dismiss()
                    }
                } label: {
                    HStack {
                        Image(systemName: sending ? "hourglass" : "paperplane.fill")
                        Text(sending ? "開始中…" : "開始")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color(red: 0.85, green: 0.47, blue: 0.34))
                .disabled(promptInput.isEmpty || sending)
            }
        }
        .navigationTitle("新規セッション")
        .task {
            await model.loadProjects()
            if selectedPath.isEmpty { selectedPath = model.projects.first?.path ?? "" }
        }
    }
}

/// モデル変更の選択シート（watchOS には Menu が無いためシートで代用）
struct WatchModelPickerView: View {
    @EnvironmentObject private var model: WatchModel
    @Environment(\.dismiss) private var dismiss
    let sessionId: String

    var body: some View {
        List {
            ForEach(ClaudeModelChoice.allCases) { choice in
                Button(choice.label) {
                    Task {
                        await model.changeModel(sessionId: sessionId, model: choice.rawValue)
                        dismiss()
                    }
                }
            }
        }
        .navigationTitle("モデル変更")
    }
}

/// クイックコマンドの選択シート
struct WatchCommandPickerView: View {
    @EnvironmentObject private var model: WatchModel
    @Environment(\.dismiss) private var dismiss
    let sessionId: String

    var body: some View {
        List {
            ForEach(ClaudeQuickCommand.allCases) { command in
                Button(command.label) {
                    Task {
                        await model.sendCommand(sessionId: sessionId, command: command.rawValue)
                        dismiss()
                    }
                }
            }
        }
        .navigationTitle("コマンド送信")
    }
}

// MARK: - 状態表示（Shared の ClaudeStatus は ActivityKit 依存のため使わず自前で持つ）

func statusLabel(_ status: String) -> String {
    switch status {
    case "working":    return "作業中"
    case "permission": return "許可待ち"
    case "waiting":    return "入力待ち"
    case "question":   return "質問"
    case "done":       return "完了"
    case "error":      return "エラー"
    case "compacting": return "圧縮中"
    default:           return status
    }
}

func statusColor(_ status: String) -> Color {
    switch status {
    case "working", "done": return Color(red: 0.85, green: 0.47, blue: 0.34)
    case "permission":      return .yellow
    case "waiting":         return .cyan
    case "question":        return .indigo
    case "error":           return .red
    case "compacting":      return .purple
    default:                return .secondary
    }
}
