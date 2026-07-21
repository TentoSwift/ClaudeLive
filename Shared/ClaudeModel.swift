import AppIntents
import Foundation

/// 選択できるモデルの固定リスト（Claude Code の /model や `claude --model` が
/// 受け付ける ID をそのまま使う）。ショートカットの選択式ピッカーにも
/// iOS/Watch アプリのメニューにも共用する
enum ClaudeModelChoice: String, AppEnum, CaseIterable, Identifiable {
    case opus = "claude-opus-4-8"
    case sonnet = "claude-sonnet-5"
    case haiku = "claude-haiku-4-5-20251001"
    case fable = "claude-fable-5"

    var id: String { rawValue }

    /// メニュー・ピッカー表示用の短い名前
    var label: String {
        switch self {
        case .opus: return "Opus 4.8"
        case .sonnet: return "Sonnet 5"
        case .haiku: return "Haiku 4.5"
        case .fable: return "Fable 5"
        }
    }

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "モデル"
    static var caseDisplayRepresentations: [ClaudeModelChoice: DisplayRepresentation] = [
        .opus: "Opus 4.8",
        .sonnet: "Sonnet 5",
        .haiku: "Haiku 4.5",
        .fable: "Fable 5",
    ]
}
