import Foundation

/// 前回起動時の予定の状態。変更検知と編集回数のカウントに使う。
///
/// 比較対象は `startDate` / `endDate` / `latitude` / `longitude` の4つだけ。
/// タイトルやメモは保存も比較もしない。
public struct EventSnapshot: Codable, Equatable {
    public let key: EventKey
    public var startDate: Date
    public var endDate: Date
    public var latitude: Double?
    public var longitude: Double?
    public var editCount: Int
    public var isCompleted: Bool
    public var completedAt: Date?

    public init(
        key: EventKey,
        startDate: Date,
        endDate: Date,
        latitude: Double? = nil,
        longitude: Double? = nil,
        editCount: Int = 0,
        isCompleted: Bool = false,
        completedAt: Date? = nil
    ) {
        self.key = key
        self.startDate = startDate
        self.endDate = endDate
        self.latitude = latitude
        self.longitude = longitude
        self.editCount = editCount
        self.isCompleted = isCompleted
        self.completedAt = completedAt
    }

    /// 予定から新しいスナップショットを作る（editCount は 0）。
    public init(event: CalendarEvent) {
        self.init(
            key: event.key,
            startDate: event.startDate,
            endDate: event.endDate,
            latitude: event.location?.latitude,
            longitude: event.location?.longitude,
            editCount: 0,
            isCompleted: false,
            completedAt: nil
        )
    }

    /// 変更検知の対象となる4項目が予定と一致しているか。
    public func matchesTrackedFields(of event: CalendarEvent) -> Bool {
        startDate == event.startDate
            && endDate == event.endDate
            && latitude == event.location?.latitude
            && longitude == event.location?.longitude
    }

    /// 変更検知の対象となる4項目を予定の値に合わせる。
    public mutating func applyTrackedFields(from event: CalendarEvent) {
        startDate = event.startDate
        endDate = event.endDate
        latitude = event.location?.latitude
        longitude = event.location?.longitude
    }
}
