import SwiftUI

/// 表示用のステータス定義（アプリ・ウィジェット共用）
enum ClaudeStatus: String {
    case working
    case permission
    case waiting
    case question
    case done
    case error
    case compacting

    init(_ raw: String) {
        self = ClaudeStatus(rawValue: raw) ?? .working
    }

    var label: String {
        switch self {
        case .working:    return "作業中"
        case .permission: return "許可待ち"
        case .waiting:    return "入力待ち"
        case .question:   return "質問"
        case .done:       return "完了"
        case .error:      return "エラー"
        case .compacting: return "圧縮中"
        }
    }

    var icon: String {
        switch self {
        case .working:    return "hammer.fill"
        case .permission: return "hand.raised.fill"
        case .waiting:    return "bubble.left.and.text.bubble.right.fill"
        case .question:   return "questionmark.circle.fill"
        case .done:       return "checkmark.circle.fill"
        case .error:      return "exclamationmark.triangle.fill"
        case .compacting: return "arrow.down.right.and.arrow.up.left"
        }
    }

    var color: Color {
        switch self {
        case .working:    return .claudeBrand
        case .permission: return .yellow
        case .waiting:    return .cyan
        case .question:   return .indigo
        case .done:       return .claudeBrand
        case .error:      return .red
        case .compacting: return .purple
        }
    }

    /// アニメーションなどで「注意を引くべき状態」か
    var needsAttention: Bool {
        self == .permission || self == .waiting || self == .question
    }
}

/// モデル ID を短い表示名にする（例 "claude-fable-5" → "Fable 5"）。
/// 未知の ID はそのまま返す
func shortModelName(_ raw: String) -> String {
    let known: [String: String] = [
        "claude-fable-5": "Fable 5",
        "claude-sonnet-5": "Sonnet 5",
        "claude-opus-4-8": "Opus 4.8",
        "claude-opus-4-7": "Opus 4.7",
        "claude-haiku-4-5-20251001": "Haiku 4.5",
    ]
    if let name = known[raw] { return name }
    // 未知の ID は "claude-" を落として大文字化する程度に留める
    return raw.hasPrefix("claude-") ? String(raw.dropFirst("claude-".count)) : raw
}
