import Foundation

/// 解決済みの座標。
public struct EventLocation: Codable, Equatable {
    public let latitude: Double
    public let longitude: Double
    public let name: String?

    public init(latitude: Double, longitude: Double, name: String? = nil) {
        self.latitude = latitude
        self.longitude = longitude
        self.name = name
    }
}

/// カレンダーから取得した予定。
public struct CalendarEvent: Codable, Equatable, Identifiable {
    public let key: EventKey
    public let title: String
    public let startDate: Date
    public let endDate: Date
    /// カレンダーの場所欄の文字列。
    public let locationText: String?
    /// 解決済みの座標。未解決なら nil。
    public var location: EventLocation?
    public let isAllDay: Bool
    public let calendarTitle: String?
    /// カレンダーに登録された日時。第2段階の追加順（登録順）を決めるのに使う。
    /// EventKit が返さない場合は nil。
    public let creationDate: Date?

    public var id: EventKey { key }

    public init(
        key: EventKey,
        title: String,
        startDate: Date,
        endDate: Date,
        locationText: String? = nil,
        location: EventLocation? = nil,
        isAllDay: Bool = false,
        calendarTitle: String? = nil,
        creationDate: Date? = nil
    ) {
        self.key = key
        self.title = title
        self.startDate = startDate
        self.endDate = endDate
        self.locationText = locationText
        self.location = location
        self.isAllDay = isAllDay
        self.calendarTitle = calendarTitle
        self.creationDate = creationDate
    }
}

extension CalendarEvent {
    /// 開始時刻の昇順。同一なら EventKey の順序で決める。
    static func isOrderedBefore(_ lhs: CalendarEvent, _ rhs: CalendarEvent) -> Bool {
        if lhs.startDate != rhs.startDate { return lhs.startDate < rhs.startDate }
        return EventKey.isOrderedBefore(lhs.key, rhs.key)
    }

    /// 登録順（creationDate の昇順）。第2段階の追加順に使う。
    /// creationDate を持たない予定は最後に回し、開始時刻順で並べる。
    static func isOrderedByRegistrationBefore(_ lhs: CalendarEvent, _ rhs: CalendarEvent) -> Bool {
        switch (lhs.creationDate, rhs.creationDate) {
        case let (left?, right?):
            if left != right { return left < right }
            return isOrderedBefore(lhs, rhs)
        case (.some, nil):
            return true
        case (nil, .some):
            return false
        case (nil, nil):
            return isOrderedBefore(lhs, rhs)
        }
    }
}
