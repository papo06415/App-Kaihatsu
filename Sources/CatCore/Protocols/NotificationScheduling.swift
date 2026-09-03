import Foundation

/// 通知の登録。実装は CatPlatform（UNUserNotificationCenter）側に置く。
public protocol NotificationScheduling {
    /// 通知を登録する。同じ identifier の登録済み通知があれば差し替える。
    func add(_ notification: ScheduledNotification) async
}
