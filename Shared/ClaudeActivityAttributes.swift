import ActivityKit
import Foundation
import SwiftUI

/// Claude Code セッション 1 つ = ライブアクティビティ 1 つ。
/// 固定情報（セッション ID・プロジェクト名・Mac 名）は attributes、
/// 変化する状態はすべて ContentState に持たせる。
///
/// 注意: Mac 側デーモン（mac/ClaudeLiveDaemon.swift）が APNs ペイロードの
/// content-state をこの形で生成する。フィールドを変えたら両方更新すること。
/// Date は ActivityKit のデフォルト JSONDecoder 仕様により
/// 「2001-01-01 基準の秒数（timeIntervalSinceReferenceDate）」で送られてくる。
struct ClaudeActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        /// working / permission / waiting / done / error / compacting
        var status: String
        /// 状況の説明文（プロンプト冒頭、許可待ちの内容、完了メッセージなど）
        var detail: String
        /// 実行中のツール名。空文字 = なし
        var currentTool: String
        /// 直近のツール実行ログ（新しいものが先頭、最大 4 行）
        var recentLogs: [String]
        /// セッション開始時刻（経過時間タイマー用）
        var startedAt: Date
        /// 累計ツール実行数
        var toolCount: Int
        /// 直近のユーザー入力（プロンプト全文の先頭部分）
        var lastPrompt: String
        /// Claude の直近の返答（transcript から抽出したテキスト部分）
        var lastResponse: String
        /// セッション名（例 "claud-52"）。後から判明することがあるので ContentState 側に持つ
        var sessionName: String
        /// セッションのタイトル。最初のユーザー入力を短くしたもの（以後変わらない）。
        /// Claude Code 自体はタイトルを保存しないので、このアプリ側で作った代替物
        var sessionTitle: String
        /// Claude からの質問（AskUserQuestion）。空 = 質問なし
        var question: String
        /// 質問の選択肢ラベル（最大 4）。タップすると Mac へ回答が送られる
        var options: [String]
    }

    var sessionId: String
    var projectName: String
    var hostName: String
}

extension Color {
    /// Claude のブランドカラー（クレイ系オレンジ）
    static let claudeBrand = Color(red: 0.85, green: 0.47, blue: 0.34)
}

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
        case .done:       return .green
        case .error:      return .red
        case .compacting: return .purple
        }
    }

    /// アニメーションなどで「注意を引くべき状態」か
    var needsAttention: Bool {
        self == .permission || self == .waiting || self == .question
    }
}
