import Foundation
@testable import CatCore

/// テスト用の CalendarSource。
final class MockCalendarSource: CalendarSource {
    /// fetchEvents が返す予定。この配列の順序が「登録順」として扱われる。
    var events: [CalendarEvent]
    var authorization: CalendarAuthorization
    var fetchError: Error?

    private(set) var fetchRanges: [(from: Date, to: Date)] = []

    init(
        events: [CalendarEvent] = [],
        authorization: CalendarAuthorization = .authorized
    ) {
        self.events = events
        self.authorization = authorization
    }

    func fetchEvents(from: Date, to: Date) throws -> [CalendarEvent] {
        fetchRanges.append((from, to))
        if let fetchError { throw fetchError }
        return events.filter { $0.startDate < to && $0.endDate > from }
    }

    func authorizationStatus() -> CalendarAuthorization {
        authorization
    }
}
