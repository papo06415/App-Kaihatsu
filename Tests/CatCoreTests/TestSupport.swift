import Foundation
@testable import CatCore

/// テストから日付とカレンダーを固定するための道具立て。
/// Calendar.current には一切依存しない。
enum Fixture {
    static let timeZone = TimeZone(identifier: "Asia/Tokyo")!

    static var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }()

    static func date(
        _ year: Int,
        _ month: Int,
        _ day: Int,
        _ hour: Int = 0,
        _ minute: Int = 0,
        _ second: Int = 0
    ) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.second = second
        guard let date = calendar.date(from: components) else {
            fatalError("invalid date components: \(year)-\(month)-\(day) \(hour):\(minute):\(second)")
        }
        return date
    }

    static func key(_ identifier: String, occurrence: Date? = nil) -> EventKey {
        EventKey(eventIdentifier: identifier, occurrenceDate: occurrence)
    }

    /// 既定では 1 時間の予定。`key` は identifier と start から作る。
    static func event(
        _ identifier: String,
        start: Date,
        durationMinutes: Int = 60,
        end: Date? = nil,
        locationText: String? = nil,
        location: EventLocation? = nil,
        isAllDay: Bool = false,
        title: String? = nil,
        creationDate: Date? = nil,
        key: EventKey? = nil
    ) -> CalendarEvent {
        CalendarEvent(
            key: key ?? EventKey(eventIdentifier: identifier),
            title: title ?? identifier,
            startDate: start,
            endDate: end ?? start.addingTimeInterval(TimeInterval(durationMinutes) * 60),
            locationText: locationText,
            location: location,
            isAllDay: isAllDay,
            calendarTitle: "テスト",
            creationDate: creationDate
        )
    }

    /// 繰り返し予定の1回ぶん。occurrenceDate で回を区別する。
    static func recurringEvent(
        _ identifier: String,
        occurrence: Date,
        start: Date? = nil,
        durationMinutes: Int = 60,
        locationText: String? = nil,
        location: EventLocation? = nil,
        creationDate: Date? = nil
    ) -> CalendarEvent {
        event(
            identifier,
            start: start ?? occurrence,
            durationMinutes: durationMinutes,
            locationText: locationText,
            location: location,
            creationDate: creationDate,
            key: EventKey(eventIdentifier: identifier, occurrenceDate: occurrence)
        )
    }

    static func allDayEvent(_ identifier: String, day: Date) -> CalendarEvent {
        let start = calendar.startOfDay(for: day)
        let end = calendar.date(byAdding: .day, value: 1, to: start)!
        return CalendarEvent(
            key: EventKey(eventIdentifier: identifier),
            title: identifier,
            startDate: start,
            endDate: end,
            locationText: nil,
            location: nil,
            isAllDay: true,
            calendarTitle: "テスト"
        )
    }

    static let tokyo = EventLocation(latitude: 35.681236, longitude: 139.767125, name: "東京駅")
    static let shinjuku = EventLocation(latitude: 35.690921, longitude: 139.700257, name: "新宿駅")
}
