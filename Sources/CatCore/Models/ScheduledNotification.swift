import Foundation

/// 通知の種別。
public enum NotificationKind: String, Codable, Equatable, CaseIterable {
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
    /// 場所が分からなかった（座標を解決できなかった）。
    case locationUnavailable
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
    public var identifier: String { Self.identifier(for: key, kind: kind) }

    /// ある予定について考えられる全種別の identifier。取り消しに使う。
    public static func allIdentifiers(for key: EventKey) -> [String] {
        NotificationKind.allCases.map { identifier(for: key, kind: $0) }
    }

    static func identifier(for key: EventKey, kind: NotificationKind) -> String {
        let occurrence = key.occurrenceDate.map { String($0.timeIntervalSince1970) } ?? "-"
        return "\(key.eventIdentifier)|\(occurrence)|\(kind.rawValue)"
    }

    /// 発火時刻が算出時刻と同じ通知（即時通知・緊急通知）。
    public var isImmediate: Bool {
        kind == .departureMovedEarlier
            || kind == .departureAlreadyPassed
            || kind == .travelTimeUnavailable
            || kind == .locationUnavailable
    }
}

/// 通知のスケジュールの算出結果。
public struct NotificationPlan: Equatable {
    /// 登録すべき通知。発火時刻の昇順。
    public let notifications: [ScheduledNotification]
    /// 今回算出された出発時刻。次回の起動で「10分以上早まったか」を判定するために保存する。
    public let departureTimes: [EventKey: Date]
    /// 取り消すべき通知の identifier。完了した予定の未発火の通知。
    public let cancelledIdentifiers: [String]

    public init(
        notifications: [ScheduledNotification],
        departureTimes: [EventKey: Date],
        cancelledIdentifiers: [String] = []
    ) {
        self.notifications = notifications
        self.departureTimes = departureTimes
        self.cancelledIdentifiers = cancelledIdentifiers
    }
}
