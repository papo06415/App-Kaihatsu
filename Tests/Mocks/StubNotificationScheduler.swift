import Foundation
@testable import CatCore

/// テスト用の NotificationScheduling。何がいつ登録されたかを記録する。
actor StubNotificationScheduler: NotificationScheduling {
    private(set) var added: [ScheduledNotification] = []

    private(set) var removed: [String] = []

    func add(_ notification: ScheduledNotification) async {
        added.append(notification)
    }

    func removeAll(withIdentifiers identifiers: [String]) async {
        removed.append(contentsOf: identifiers)
    }

    var identifiers: [String] { added.map(\.identifier) }
    var kinds: [NotificationKind] { added.map(\.kind) }
    var fireDates: [Date] { added.map(\.fireDate) }
}
