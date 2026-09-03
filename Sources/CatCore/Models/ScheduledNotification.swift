import Foundation

/// 通知の種別。
public enum NotificationKind: String, Codable, Equatable {
    /// 開始1.5時間前（Premium）。
    case ninetyMinutesBeforeStart
    /// 開始1時間前（Premium）。
    case sixtyMinutesBeforeStart
    /// 開始30分前（Premium）。
    case thirtyMinutesBeforeStart
    /// 出発時刻（Free / Premium）。
    case departure
    /// 開始時刻（Free）。
    case start
    /// 出発時刻が10分以上早まった（Premium）。即時に送る。
    case departureMovedEarlier
    /// 新しい出発時刻が既に過ぎている。緊急として送る。
    case departureAlreadyPassed
    /// 移動時間を取得できなかった。
    case travelTimeUnavailable
}

/// 登録する通知1件。
public struct ScheduledNotification: Equatable {
    public let key: EventKey
    public let kind: NotificationKind
    /// 発火時刻。即時通知・緊急通知は算出時刻（now）。
    public let fireDate: Date
    /// 猫の文言は後続フェーズ。ここでは種別が判別できるプレースホルダを入れてある。
    public let placeholderBody: String

    public init(key: EventKey, kind: NotificationKind, fireDate: Date) {
        self.key = key
        self.kind = kind
        self.fireDate = fireDate
        self.placeholderBody = "[\(kind.rawValue)] 猫の文言は後続フェーズ"
    }

    /// 同じ予定・同じ種別なら同じ値になる。
    ///
    /// UNUserNotificationCenter は同じ identifier で登録すると差し替えになるので、
    /// 出発時刻が変わったときは登録し直すだけで古い通知が消える。
    public var identifier: String {
        let occurrence = key.occurrenceDate.map { String($0.timeIntervalSince1970) } ?? "-"
        return "\(key.eventIdentifier)|\(occurrence)|\(kind.rawValue)"
    }

    /// 発火時刻が算出時刻と同じ通知（即時通知・緊急通知）。
    public var isImmediate: Bool {
        kind == .departureMovedEarlier
            || kind == .departureAlreadyPassed
            || kind == .travelTimeUnavailable
    }
}

/// 通知のスケジュールの算出結果。
public struct NotificationPlan: Equatable {
    /// 登録すべき通知。発火時刻の昇順。
    public let notifications: [ScheduledNotification]
    /// 今回算出された出発時刻。次回の起動で「10分以上早まったか」を判定するために保存する。
    public let departureTimes: [EventKey: Date]

    public init(notifications: [ScheduledNotification], departureTimes: [EventKey: Date]) {
        self.notifications = notifications
        self.departureTimes = departureTimes
    }
}
