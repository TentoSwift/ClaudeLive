import Foundation
import UIKit
import UserNotifications

/// AskUserQuestion への「アプリを開かない回答」を実現する通知まわりの管理。
/// Mac デーモンが質問時に返信アクション付きの通常プッシュ通知を送り、
/// ユーザーは通知を長押し →「回答を入力」でシステムのテキスト入力欄
/// （メッセージアプリの返信と同じ UI）に直接入力できる。
/// 送信時はアプリがバックグラウンドのまま起こされ、ここの delegate が
/// Mac の /answer へ回答を届ける。アプリは一切前面に出ない
final class NotificationManager: NSObject {
    static let shared = NotificationManager()

    static let questionCategoryId = "CLAUDE_QUESTION"
    static let answerActionId = "ANSWER_TEXT"

    private override init() {
        super.init()
    }

    /// 起動時に呼ぶ: delegate 設定・カテゴリ登録・許可要求・リモート通知登録
    func setup() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self

        // 「回答を入力」テキスト入力アクション。foreground オプションを
        // 付けないことで、アプリを開かずバックグラウンドで処理される
        let answerAction = UNTextInputNotificationAction(
            identifier: Self.answerActionId,
            title: "回答を入力",
            options: [],
            textInputButtonTitle: "送信",
            textInputPlaceholder: "回答…")
        let category = UNNotificationCategory(
            identifier: Self.questionCategoryId,
            actions: [answerAction],
            intentIdentifiers: [],
            options: [])
        center.setNotificationCategories([category])

        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            DispatchQueue.main.async {
                UIApplication.shared.registerForRemoteNotifications()
            }
        }
    }
}

extension NotificationManager: UNUserNotificationCenterDelegate {
    /// 通知アクションへの応答。テキスト入力の回答を Mac へ送る
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let userInfo = response.notification.request.content.userInfo
        let sessionId = userInfo["sessionId"] as? String ?? ""

        if response.actionIdentifier == Self.answerActionId,
           let textResponse = response as? UNTextInputNotificationResponse,
           !sessionId.isEmpty {
            let answer = textResponse.userText
            Task {
                _ = await AnswerQuestionIntent.sendAnswer(
                    sessionId: sessionId, answer: answer, pass: false)
                completionHandler()
            }
            return
        }

        // 通知本体のタップ（アプリが開く）: 該当セッションの回答アラートへ
        if response.actionIdentifier == UNNotificationDefaultActionIdentifier, !sessionId.isEmpty {
            Task { @MainActor in
                AppModel.shared.focusSessionId = sessionId
            }
        }
        completionHandler()
    }

    /// フォアグラウンド中でも通知バナーを出す（質問を見逃さないように）
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler:
                                    @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}

/// リモート通知のデバイストークン受け取りに必要な AppDelegate。
/// SwiftUI App からは @UIApplicationDelegateAdaptor で接続する
final class ClaudeLiveAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
        UserDefaults.standard.set(hex, forKey: "remoteDeviceToken")
        // トークンを Mac へ届ける（/register の payload に含まれる）
        Task { @MainActor in
            AppModel.shared.registerToServer()
        }
    }
}
