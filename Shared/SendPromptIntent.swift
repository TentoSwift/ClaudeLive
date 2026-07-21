import AppIntents
import Foundation

/// ショートカットで選べるセッション。EntityQuery が Mac デーモンの /sessions を
/// 取得して候補一覧を返すので、ショートカットのパラメータでピッカーから選べる
struct ClaudeSessionEntity: AppEntity, Identifiable {
    let id: String        // sessionId（= cliSessionId）
    var name: String
    var project: String
    var status: String
    var title: String
    var lastPrompt: String

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Claude セッション"
    static var defaultQuery = ClaudeSessionQuery()

    var displayRepresentation: DisplayRepresentation {
        // "claud-9b" のようなランダムな内部名だけでは一覧で見分けがつかないため、
        // 会話の中身を表す文字列を見出しにする。直前のプロンプトの方が
        // 「今何をしているセッションか」を表すので、最初の指示（title）より優先する
        let label: String
        if !lastPrompt.isEmpty { label = lastPrompt }
        else if !title.isEmpty { label = title }
        else { label = name.isEmpty ? project : name }
        let subtitle = name.isEmpty ? status : "\(project) ・ \(status)"
        return DisplayRepresentation(title: "\(label)", subtitle: "\(subtitle)")
    }
}

struct ClaudeSessionQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [ClaudeSessionEntity] {
        let all = try await suggestedEntities()
        return all.filter { identifiers.contains($0.id) }
    }

    func suggestedEntities() async throws -> [ClaudeSessionEntity] {
        guard let data = await daemonRequest(path: "/sessions"),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sessions = object["sessions"] as? [[String: Any]] else { return [] }
        return sessions.compactMap { entry in
            guard let id = entry["sessionId"] as? String else { return nil }
            return ClaudeSessionEntity(
                id: id,
                name: entry["name"] as? String ?? "",
                project: entry["project"] as? String ?? "",
                status: entry["status"] as? String ?? "",
                title: entry["title"] as? String ?? "",
                lastPrompt: entry["lastPrompt"] as? String ?? "")
        }
    }
}

/// Siri・ショートカット・アクションボタンから直接 Claude にプロンプトを
/// 送るための App Intent。「指示を送る」から音声/テキストを渡すと、
/// 指定されたセッション（省略時は直近のアクティブセッション）へ
/// Mac デーモンの /prompt を叩いて注入する
struct SendPromptIntent: AppIntent {
    static var title: LocalizedStringResource = "Claude に指示を送る"
    static var description = IntentDescription("選んだ Claude Code セッションに指示を送ります")
    static var openAppWhenRun: Bool = false

    /// 送信先セッション。必須にしているので、ショートカット実行時に値が
    /// 未設定なら、その場でセッション一覧のピッカーが出て選べる。
    /// text より先に宣言することで、こちらを先に尋ねさせる
    @Parameter(title: "セッション", requestValueDialog: "どのセッションに送りますか？")
    var session: ClaudeSessionEntity

    @Parameter(title: "指示", requestValueDialog: "指示の内容は？")
    var text: String

    static var parameterSummary: some ParameterSummary {
        Summary("Claude の \(\.$session) に「\(\.$text)」を送る")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        // ショートカットで text に空（「指定入力」の誤配線など）が渡ると、
        // 以前は無言で失敗していた。空ならその場で指示を尋ね直す。
        // session は先に宣言しているので、この再入力は必ずセッション選択の後になる
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw $text.needsValueError("送る指示を入力してください")
        }
        let ok = await Self.sendPrompt(sessionId: session.id, text: text)
        return .result(dialog: ok ? "送りました" : "Mac に届きませんでした")
    }

    /// Mac デーモンの /prompt へプロンプトを送る。/answer と同じキー入力方式
    /// （typeIntoClaudeApp）で Claude Desktop に即反映される。
    /// 通知のテキスト入力アクション（NotificationManager）からも共有する
    static func sendPrompt(sessionId: String, text: String) async -> Bool {
        let payload: [String: Any] = ["sessionId": sessionId, "text": text]
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return false }
        return await daemonRequestOK(path: "/prompt", body: body)
    }
}

struct ClaudeLiveShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: SendPromptIntent(),
            phrases: [
                "\(.applicationName) で指示を送る",
                "\(.applicationName) にプロンプトを送る",
            ],
            shortTitle: "指示を送る",
            systemImageName: "mic.fill")
        AppShortcut(
            intent: StartNewSessionIntent(),
            phrases: [
                "\(.applicationName) で新規セッションを開始する",
                "\(.applicationName) で新しいセッションを始める",
            ],
            shortTitle: "新規セッションを開始",
            systemImageName: "plus.circle.fill")
        AppShortcut(
            intent: ChangeModelIntent(),
            phrases: [
                "\(.applicationName) でモデルを変更する",
                "\(.applicationName) のモデルを切り替える",
            ],
            shortTitle: "モデルを変更",
            systemImageName: "cpu.fill")
        AppShortcut(
            intent: SendCommandIntent(),
            phrases: [
                "\(.applicationName) でコマンドを送る",
                "\(.applicationName) にコマンドを送信する",
            ],
            shortTitle: "コマンドを送る",
            systemImageName: "terminal.fill")
    }
}
