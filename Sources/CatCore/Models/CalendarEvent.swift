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

    public var id: EventKey { key }

    public init(
        key: EventKey,
        title: String,
        startDate: Date,
        endDate: Date,
        locationText: String? = nil,
        location: EventLocation? = nil,
        isAllDay: Bool = false,
        calendarTitle: String? = nil
    ) {
        self.key = key
        self.title = title
        self.startDate = startDate
        self.endDate = endDate
        self.locationText = locationText
        self.location = location
        self.isAllDay = isAllDay
        self.calendarTitle = calendarTitle
    }
}
