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
        /// AskUserQuestion に含まれていた質問の総数。
        /// ライブアクティビティは領域の都合で 1 問目しか出せないため、
        /// 2 問以上あるときは選択肢を出さずアプリへ誘導する
        /// （1 問目だけ答えて残りが未回答のまま Claude に返る事故を防ぐ）。
        /// 旧バージョンのデーモンから届いた content-state でもデコードが
        /// 落ちないよう Optional にしてある（nil は 1 問として扱う）
        var questionCount: Int?
        /// true = マーキーを1周流し終えて静止表示に切り替える段階。
        /// 新しいテキストが来ると false に戻り、また1周流れる。
        /// ウィジェット側は時間経過を自力監視できないため、この判断は
        /// Mac 側デーモンがタイマーで行い、専用の push で切り替える
        var textSettled: Bool
        /// 直近のアシスタント発言が使ったモデル名（例 "claude-fable-5"）。空 = 不明
        var model: String
        /// true = DI コンパクトの作業中アイコンをコマ送りアニメーションにする。
        /// 過去にライブアクティビティが強制終了される不具合を起こしたため、
        /// アプリの設定画面から任意にオン/オフして安定性を検証できるようにした
        var compactAnimated: Bool
        /// 直近に使ったツール名（例 "Bash"）。currentTool と違い完了後も残る。
        /// 完了時、そのツールのチェックマーク付きカスタムアイコンを出すのに使う
        var lastTool: String
        /// バックグラウンドタスク（タスクリスト）の完了数。タスクが無いセッションでは nil。
        /// 旧バージョンのデーモンから届いた content-state でもデコードが落ちないよう Optional
        var taskDone: Int?
        /// バックグラウンドタスクの総数。nil = タスクなし（旧デーモン互換のため Optional）
        var taskTotal: Int?
        /// 進行中タスクの activeForm（例 "〜を作成中"）。無ければ空文字か nil。
        /// 旧デーモン互換のため Optional
        var taskActive: String?
    }

    var sessionId: String
    var projectName: String
    var hostName: String
}


// Color.claudeBrand は Watch ターゲットからも使うため
// Shared/ClaudeBrandColor.swift へ移動した

