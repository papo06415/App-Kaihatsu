import Foundation
@testable import CatCore

/// テスト用の NotificationScheduling。何がいつ登録されたかを記録する。
actor StubNotificationScheduler: NotificationScheduling {
    private(set) var added: [ScheduledNotification] = []

    func add(_ notification: ScheduledNotification) async {
        added.append(notification)
    }

    var identifiers: [String] { added.map(\.identifier) }
    var kinds: [NotificationKind] { added.map(\.kind) }
    var fireDates: [Date] { added.map(\.fireDate) }
}
