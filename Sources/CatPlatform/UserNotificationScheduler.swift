#if canImport(UserNotifications)
import Foundation
import UserNotifications
import CatCore

/// UNUserNotificationCenter に通知を積む。
public final class UserNotificationScheduler: NotificationScheduling {
    private let center: UNUserNotificationCenter
    private let calendar: Calendar

    public init(center: UNUserNotificationCenter = .current(), calendar: Calendar) {
        self.center = center
        self.calendar = calendar
    }

    /// 通知の許可を求める。初回のみ。
    @discardableResult
    public func requestAuthorization() async -> Bool {
        do {
            return try await center.requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            return false
        }
    }

    public func add(_ notification: ScheduledNotification) async {
        let content = UNMutableNotificationContent()
        // 猫の文言は後続フェーズ。ここでは種別が判別できるプレースホルダを入れる。
        content.body = notification.placeholderBody
        content.sound = .default
        content.userInfo = [
            "eventIdentifier": notification.key.eventIdentifier,
            "kind": notification.kind.rawValue
        ]

        let request = UNNotificationRequest(
            identifier: notification.identifier,
            content: content,
            // 即時通知・緊急通知は trigger を付けない（すぐ配信される）。
            trigger: notification.isImmediate ? nil : Self.trigger(at: notification.fireDate, calendar: calendar)
        )

        // 同じ identifier で登録すると差し替えになるので、出発時刻が変わったときは
        // 登録し直すだけで古い通知が消える。
        try? await center.add(request)
    }

    private static func trigger(at date: Date, calendar: Calendar) -> UNNotificationTrigger {
        let components = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: date
        )
        return UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
    }
}
#endif
