import SwiftUI

/// セッション一覧（ルート画面）
struct WatchContentView: View {
    @EnvironmentObject private var model: WatchModel
    @State private var path: [String] = []
    /// 操作モード（iPhone アプリの設定と同じ既定値。Watch 単独では変更しない）
    @AppStorage(controlModeKey) private var controlMode = false

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
                // 新規セッション開始（操作モードのときだけ）
                if controlMode {
                    NavigationLink(value: "__new__") {
                        Label("新規セッション", systemImage: "plus.circle.fill")
                            .font(.headline)
                            .foregroundStyle(Color.claudeBrand)
                    }
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
    /// 選択肢に無い答えを質問ごとに書いたもの。質問のインデックス → 入力文字列
    @State private var customAnswers: [Int: String] = [:]
    /// 最下部（最新）付近を表示中か。下ほど新しい並びなので、上（過去）へ
    /// スクロールしたときだけ「最下部へ戻る」ボタンを出す判定に使う
    @State private var isNearBottom = true
    /// 操作モード。オフのあいだは送信系の UI を出さない（既定オフ）
    @AppStorage(controlModeKey) private var controlMode = false

    private var session: WatchModel.Session? {
        model.sessions.first { $0.id == sessionId }
    }

    /// 質問 index の回答＝選ばれた選択肢と自由入力を合わせたもの。
    /// 単一選択の質問で自由入力があれば、それを答えとして優先する
    private func composedAnswer(at index: Int, in questions: [WatchModel.QuestionItem]) -> [String] {
        let custom = (customAnswers[index] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let selected = Array(selections[index] ?? [])
        guard !custom.isEmpty else { return selected }
        return questions[index].multiSelect ? selected + [custom] : [custom]
    }

    /// 「返答」欄に出すテキスト。
    /// session.lastResponse はライブアクティビティ用に 300 文字へ切り詰めた値
    /// （APNs のペイロード上限があるためデーモン側で必要な措置）なので、
    /// そのまま出すと長い返答が途中で切れる。会話履歴（/messages 由来、
    /// 1 メッセージ最大 2000 文字）に同じメッセージの全文があればそちらを使う。
    /// 「同じメッセージか」は切り詰め前の先頭部分が一致するかで判定し、
    /// 履歴の取得が追いついていない（別の古い発言しか無い）ときは
    /// 誤った全文を出さず切り詰め版のままにする
    private func fullLastResponse(_ session: WatchModel.Session) -> String {
        let truncated = session.lastResponse
        guard let full = messages.last(where: { $0.role == "assistant" })?.text else {
            return truncated
        }
        // デーモンの切り詰めは「300 文字 + …」。末尾の … を除いた部分が
        // 全文の先頭と一致すれば同一メッセージとみなす。
        // 表を含まない返答は切り詰め時に改行が空白へ潰されているため、
        // 比較は両者とも空白に正規化して行う
        let head = truncated.hasSuffix("…") ? String(truncated.dropLast()) : truncated
        func normalized(_ s: String) -> String {
            s.replacingOccurrences(of: "\n", with: " ")
        }
        return normalized(full).hasPrefix(normalized(head)) ? full : truncated
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
        ScrollViewReader { proxy in
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
                        // コマンド送信・モデル変更は操作モードのときだけ
                        if controlMode {
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


                }

                // 会話履歴
                if !messages.isEmpty {
                    label("会話")
                    ForEach(messages) { message in
                        VStack(alignment: .leading, spacing: 1) {
                            // Claude の発言は文字ラベルではなく、DI の返答表示と同じ
                            // 吹き出しマーク（ClaudeBubbleReply）で示す
                            if message.role == "user" {
                                Text("あなた")
                                    .font(.caption2.bold())
                                    .foregroundStyle(.secondary)
                            } else {
                                Image("ClaudeBubbleReply")
                                    .renderingMode(.template)
                                    .resizable()
                                    .scaledToFit()
                                    .frame(width: 14, height: 14)
                                    .foregroundStyle(Color.claudeBrand)
                            }
                            // 素の Text だと表がパイプの羅列、見出しが "## " のまま
                            // 出てしまうので、iPhone 側と同じ Markdown 描画にする。
                            // compact は Watch の狭い横幅に表を詰めるため
                            MarkdownText(text: message.text, compact: true)
                        }
                        .padding(.bottom, 3)
                    }
                }

                // 下ほど新しい並び: 会話履歴（古い） → 直近のやり取り → 質問・送信（最新）。
                // チャットと同じ向きにして、開いて下を見れば今の状態が分かるようにする
                if let session {
                    // 直近のやり取り（省略なしの全文）。
                    // 会話履歴と同じく Markdown で描く——素の Text のままだと
                    // 表がパイプの羅列、見出しが "## " のまま出てしまう
                    // （会話履歴だけ Markdown 化してここが漏れていた）
                    if !session.lastPrompt.isEmpty {
                        label("入力")
                        Text(session.lastPrompt).font(.footnote)
                    }
                    if !session.lastResponse.isEmpty {
                        label("返答")
                        MarkdownText(text: fullLastResponse(session), compact: true)
                    }
                    // プロンプト送信・質問への回答は操作モードのときだけ出す
                    if controlMode {
                    // プロンプト送信（音声ディクテーション対応の標準 TextField）
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
                                      : Color.claudeBrand)
                            }
                            // 選択肢に無い答えを質問ごとに書けるようにする
                            if accumulate {
                                TextField("その他（自由入力）",
                                          text: Binding(get: { customAnswers[index] ?? "" },
                                                        set: { customAnswers[index] = $0 }))
                                    .font(.footnote)
                            }
                        }
                        if accumulate {
                            // iPhone 側と同じく、全問に選択があるまで送らせない
                            // （1問だけ答えて残りが未回答で返る事故を防ぐ）
                            let composed = (0..<questions.count)
                                .map { composedAnswer(at: $0, in: questions) }
                            let answeredCount = composed.filter { !$0.isEmpty }.count
                            let allAnswered = answeredCount == questions.count
                            if questions.count > 1 {
                                Text("\(questions.count)問中 \(answeredCount)問")
                                    .font(.caption2)
                                    .foregroundStyle(allAnswered ? .secondary : Color.orange)
                            }
                            Button {
                                let answers = composed
                                answering = true
                                Task {
                                    await model.answer(sessionId: sessionId, answers: answers)
                                    answering = false
                                    selections = [:]
                                    customAnswers = [:]
                                }
                            } label: {
                                Text(answering ? "送信中…"
                                     : (allAnswered ? "回答する" : "全問選んでください"))
                                    .font(.footnote.bold())
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(Color.claudeBrand)
                            .disabled(answering || !allAnswered)
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
                    }  // if controlMode（プロンプト送信＋質問回答をまとめて隠す）
                }
                // 開いたとき最下部（最新）へスクロールするためのアンカー
                Color.clear.frame(height: 1).id("bottom")
            }
        }
        .navigationTitle(session.map { s in
            if !s.lastPrompt.isEmpty { return s.lastPrompt }
            return s.title.isEmpty ? (s.name.isEmpty ? s.project : s.name) : s.title
        } ?? "セッション")
        .task {
            await model.refresh()
            messages = await model.fetchMessages(sessionId: sessionId)
            // 下ほど新しい並びなので、開いたら最新（最下部）から読めるようにする
            proxy.scrollTo("bottom", anchor: .bottom)
        }
        .refreshable {
            await model.refresh()
            messages = await model.fetchMessages(sessionId: sessionId)
        }
        .onChange(of: messages.count) { _, _ in
            withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
        }
        // 最下部（最新）付近にいるかを監視する。判定の余裕を画面の高さぶん
        // 持たせ、少し遡っただけで出ないように（＝表示が始まる位置を上に）する
        .onScrollGeometryChange(for: Bool.self) { geo in
            geo.contentOffset.y + geo.containerSize.height
                >= geo.contentSize.height - geo.containerSize.height
        } action: { _, nearBottom in
            // withAnimation で状態を変えることで、ツールバーの
            // 出現・消滅がフェードする
            withAnimation(.easeInOut(duration: 0.25)) {
                isNearBottom = nearBottom
            }
        }
        .toolbar {
            // 上（過去）へスクロールしたときだけ、最下部（最新）へ戻るボタンを
            // 画面下中央に出す
            if !isNearBottom {
                ToolbarItemGroup(placement: .bottomBar) {
                    Spacer()
                    Button {
                        withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
                    } label: {
                        Image(systemName: "arrow.down.to.line")
                            .foregroundStyle(Color.claudeBrand)
                    }
                    // ボタンの背景（すりガラスのカプセル）を消して
                    // Claude カラーの矢印だけを見せる
                    .tint(.clear)
                    Spacer()
                }
            }
        }
        }  // ScrollViewReader
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
                .tint(Color.claudeBrand)
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
    case "working", "done": return Color.claudeBrand
    case "permission":      return .yellow
    case "waiting":         return .cyan
    case "question":        return .indigo
    case "error":           return .red
    case "compacting":      return .purple
    default:                return .secondary
    }
}
