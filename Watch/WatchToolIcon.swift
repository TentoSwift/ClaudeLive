import SwiftUI

// Widget/ClaudeLiveActivityWidget.swift の toolSymbolName / カスタムシンボル
// 分岐と同じ考え方。Watch アプリはウィジェット拡張とは別ターゲットなので、
// あの ActivityKit/WidgetKit 依存のファイルは持ち込めず、ここに小さく複製する

/// ツール名に対応する SF Symbol 名（Widget 側と同じ対応表）
func watchToolSymbolName(_ tool: String) -> String {
    switch tool {
    case "Bash":                          return "terminal"
    case "Read":                          return "doc.text"
    case "Edit", "Write", "NotebookEdit": return "pencil"
    case "Grep", "Glob":                  return "magnifyingglass"
    case "WebFetch", "WebSearch":         return "globe"
    default:                              return "wrench.and.screwdriver"
    }
}

/// 実行中ツールのアイコン。Task/Agent（サブエージェント）は Widget と同じ
/// カスタムシンボル（Assets.xcassets の ClaudeTaskRunning）を使う
@ViewBuilder
func watchToolRunningIcon(_ tool: String) -> some View {
    if tool == "Task" || tool == "Agent" {
        Image("ClaudeTaskRunning")
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
    } else {
        Image(systemName: watchToolSymbolName(tool))
            .resizable()
            .scaledToFit()
    }
}
