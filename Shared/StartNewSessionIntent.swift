import AppIntents
import Foundation

/// ショートカットで選べるプロジェクト。EntityQuery が Mac デーモンの /projects を
/// 取得して候補一覧を返す（過去に使った cwd、更新時刻の新しい順）
struct ClaudeProjectEntity: AppEntity, Identifiable {
    let id: String        // cwd の絶対パス
    var name: String

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Claude プロジェクト"
    static var defaultQuery = ClaudeProjectQuery()

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)")
    }
}

struct ClaudeProjectQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [ClaudeProjectEntity] {
        let all = try await suggestedEntities()
        return all.filter { identifiers.contains($0.id) }
    }

    func suggestedEntities() async throws -> [ClaudeProjectEntity] {
        guard let data = await daemonRequest(path: "/projects"),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let projects = object["projects"] as? [[String: Any]] else { return [] }
        return projects.compactMap { entry in
            guard let path = entry["path"] as? String,
                  let name = entry["name"] as? String else { return nil }
            return ClaudeProjectEntity(id: path, name: name)
        }
    }
}

/// Siri・ショートカット・アクションボタンから新規 Claude Code セッションを
/// 開始する App Intent。プロジェクトを選んで最初の指示を渡すと、Mac デーモンの
/// /newsession を叩いて `claude -p`（--resume なし）をそのディレクトリで起動する
struct StartNewSessionIntent: AppIntent {
    static var title: LocalizedStringResource = "Claude で新規セッションを開始"
    static var description = IntentDescription("選んだプロジェクトで新しい Claude Code セッションを開始します")
    static var openAppWhenRun: Bool = false

    /// 開始先プロジェクト。text より先に宣言することで、こちらを先に尋ねさせる
    @Parameter(title: "プロジェクト", requestValueDialog: "どのプロジェクトで開始しますか？")
    var project: ClaudeProjectEntity

    /// モデル省略可（未指定なら CLI の既定モデル）。ショートカットでは
    /// 空欄のままにしておけば尋ねられずスキップされる
    @Parameter(title: "モデル")
    var model: ClaudeModelChoice?

    @Parameter(title: "最初の指示", requestValueDialog: "最初に何を頼みますか？")
    var text: String

    static var parameterSummary: some ParameterSummary {
        Summary("\(\.$project) で新規セッションを開始し「\(\.$text)」を送る") {
            \.$model
        }
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        // 操作モードがオフなら実行しない（Mac 上の Claude Code を動かす機能のため）
        guard isControlModeEnabled else {
            return .result(dialog: "\(controlModeDisabledMessage)")
        }
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw $text.needsValueError("最初の指示を入力してください")
        }
        let ok = await Self.startNewSession(cwd: project.id, text: text, model: model?.rawValue ?? "")
        return .result(dialog: ok ? "開始しました" : "Mac に届きませんでした")
    }

    static func startNewSession(cwd: String, text: String, model: String = "") async -> Bool {
        var payload: [String: Any] = ["cwd": cwd, "text": text]
        if !model.isEmpty { payload["model"] = model }
        guard let body = try? JSONSerialization.data(withJSONObject: payload) else { return false }
        return await daemonRequestOK(path: "/newsession", body: body)
    }
}
