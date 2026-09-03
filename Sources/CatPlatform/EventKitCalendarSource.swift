#if canImport(EventKit)
import Foundation
import EventKit
import CatCore

/// EventKit を使った CalendarSource の実装。
public final class EventKitCalendarSource: CalendarSource {
    private let store: EKEventStore

    public init(store: EKEventStore = EKEventStore()) {
        self.store = store
    }

    /// iOS 17 以降のフルアクセス要求。
    @discardableResult
    public func requestAccess() async -> Bool {
        do {
            return try await store.requestFullAccessToEvents()
        } catch {
            return false
        }
    }

    public func authorizationStatus() -> CalendarAuthorization {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess:
            return .authorized
        case .writeOnly:
            // 予定を読めないため利用不可。
            return .writeOnly
        case .denied, .restricted:
            return .denied
        case .notDetermined:
            return .notDetermined
        @unknown default:
            return .denied
        }
    }

    public func fetchEvents(from: Date, to: Date) throws -> [CalendarEvent] {
        // calendars: nil で全カレンダーを対象にする。
        let predicate = store.predicateForEvents(withStart: from, end: to, calendars: nil)
        let events = store.events(matching: predicate)
        return events
            .compactMap(Self.makeCalendarEvent)
            .sorted { lhs, rhs in
                if lhs.startDate != rhs.startDate { return lhs.startDate < rhs.startDate }
                return lhs.key.eventIdentifier < rhs.key.eventIdentifier
            }
    }

    static func makeCalendarEvent(_ event: EKEvent) -> CalendarEvent? {
        guard let identifier = event.eventIdentifier,
              let startDate = event.startDate,
              let endDate = event.endDate
        else { return nil }

        // 繰り返し予定は全ての回で eventIdentifier が同じになるため、開始時刻と組にする。
        //
        // ここで使うのは startDate ではなく occurrenceDate（その回の「元の」開始時刻）。
        // 単一の回の時刻をユーザーが動かしても occurrenceDate は変わらないので、
        // 「開始時刻の変更」を削除＋新規ではなく編集として検知できる。
        let occurrenceDate: Date = event.occurrenceDate
        let key = EventKey(eventIdentifier: identifier, startDate: occurrenceDate)

        var location: EventLocation?
        if let coordinate = event.structuredLocation?.geoLocation?.coordinate {
            location = EventLocation(
                latitude: coordinate.latitude,
                longitude: coordinate.longitude,
                name: event.structuredLocation?.title ?? event.location
            )
        }

        return CalendarEvent(
            key: key,
            title: event.title ?? "",
            startDate: startDate,
            endDate: endDate,
            // 座標が無い場合に文字列から解決するための元データ。
            locationText: event.location,
            location: location,
            isAllDay: event.isAllDay,
            calendarTitle: event.calendar?.title
        )
    }
}
#endif
