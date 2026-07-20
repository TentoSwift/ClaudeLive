import AppIntents
import Foundation

/// Siri・ショートカット・アクションボタンから直接 Claude にプロンプトを
/// 送るための App Intent。「指示を送る」から音声/テキストを渡すと、
/// 直近のアクティブセッション（作業中・許可待ち・入力待ちのいずれか、
/// 無ければ最新のセッション）へ Mac デーモンの /prompt を叩いて注入する
struct SendPromptIntent: AppIntent {
    static var title: LocalizedStringResource = "Claude に指示を送る"
    static var description = IntentDescription("直近の Claude Code セッションに指示を送ります")
    static var openAppWhenRun: Bool = false

    @Parameter(title: "指示")
    var text: String

    static var parameterSummary: some ParameterSummary {
        Summary("Claude に「\(\.$text)」を送る")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard var base = UserDefaults.standard.string(forKey: "lastDaemonURL"), !base.isEmpty else {
            return .result(dialog: "Mac の接続先が分かりません。ClaudeLive アプリを一度開いてください")
        }
        base = sanitizeDaemonURL(base)
        let picked = await Self.pickSessionId(base: base)
        guard let sessionId = picked.id else {
            // どこで失敗したかを音声で返す（ネットワーク到達性の切り分け用）
            return .result(dialog: "セッションが見つかりませんでした（\(base)、\(picked.detail)）")
        }
        let payload: [String: Any] = ["sessionId": sessionId, "text": text]
        guard let body = try? JSONSerialization.data(withJSONObject: payload),
              let url = URL(string: base + "/prompt") else {
            return .result(dialog: "送信に失敗しました")
        }
        var request = URLRequest(url: url, timeoutInterval: 8)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                return .result(dialog: "Mac がエラーを返しました")
            }
        } catch {
            return .result(dialog: "Mac に届きませんでした: \(error.localizedDescription)")
        }
        return .result(dialog: "送りました")
    }

    /// 作業中・許可待ち・入力待ちのセッションを優先し、無ければ最新のものを選ぶ。
    /// 失敗理由を detail に入れて返す（診断用）
    private static func pickSessionId(base: String) async -> (id: String?, detail: String) {
        guard let url = URL(string: base + "/sessions") else {
            return (nil, "不正なURL")
        }
        let data: Data
        do {
            let (d, response) = try await URLSession.shared.data(from: url)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                return (nil, "HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
            }
            data = d
        } catch {
            return (nil, "通信失敗: \(error.localizedDescription)")
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sessions = object["sessions"] as? [[String: Any]] else {
            return (nil, "解析失敗")
        }
        guard !sessions.isEmpty else {
            return (nil, "0件")
        }
        let active = ["working", "permission", "waiting", "question", "compacting"]
        if let hit = sessions.first(where: { active.contains($0["status"] as? String ?? "") }) {
            return (hit["sessionId"] as? String, "OK")
        }
        return (sessions.first?["sessionId"] as? String, "OK(非アクティブ)")
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
    }
}
