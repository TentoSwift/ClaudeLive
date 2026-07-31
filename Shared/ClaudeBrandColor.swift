import SwiftUI

/// Claude のブランドカラー。
///
/// iOS アプリ・ウィジェット・Watch アプリの 3 ターゲットすべてで使うため、
/// 独立したファイルにしている。元は ClaudeActivityAttributes.swift にあったが、
/// あのファイルは Watch ターゲットに含まれていないため Watch から参照できなかった。
///
/// アプリ全体のアクセント（ボタン・トグル・リンクなど）は
/// 各アプリのルートで `.tint(Color.claudeBrand)` として適用している。
extension Color {
    /// Claude のブランドカラー（クレイ系オレンジ）
    static let claudeBrand = Color(red: 0.85, green: 0.47, blue: 0.34)
}
