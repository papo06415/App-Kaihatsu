import Foundation

/// 通知の登録と取り消し。実装は CatPlatform（UNUserNotificationCenter）側に置く。
public protocol NotificationScheduling {
    /// 通知を登録する。同じ identifier の登録済み通知があれば差し替える。
    func add(_ notification: ScheduledNotification) async
    /// 指定した identifier の未発火の通知を取り消す。既に配信済みのものは対象外。
    func removeAll(withIdentifiers identifiers: [String]) async
}
