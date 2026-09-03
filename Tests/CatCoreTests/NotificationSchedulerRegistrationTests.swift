import XCTest
@testable import CatCore

/// 計算層の出力から通知を登録するところまでの経路。
final class NotificationSchedulerRegistrationTests: XCTestCase {
    private let scheduler = NotificationScheduler()
    private let placeA = EventLocation(latitude: 35.7000, longitude: 139.7671, name: "A")

    private func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        Fixture.date(2026, 9, day, hour, minute)
    }

    private func scheduledPlan(_ identifier: String, start: Date, departure: Date) -> DeparturePlan {
        DeparturePlan(
            key: Fixture.key(identifier),
            startDate: start,
            origin: .home(placeA),
            outcome: .scheduled(
                departureTime: departure,
                mode: .transit,
                travelTime: 25 * 60,
                distanceMeters: 5_000
            )
        )
    }

    func testNotificationsAreRegisteredInFireDateOrder() async {
        let target = scheduledPlan("a", start: at(1, 10), departure: at(1, 9, 25))
        let plan = scheduler.plan(
            plans: [target],
            isPremium: false,
            previousDepartureTimes: [:],
            now: at(1, 6)
        )
        let stub = StubNotificationScheduler()

        await scheduler.register(plan, using: stub)

        let kinds = await stub.kinds
        let fireDates = await stub.fireDates
        XCTAssertEqual(kinds, [.departure, .start])
        XCTAssertEqual(fireDates, [at(1, 9, 25), at(1, 10)])
    }

    /// 翌日の予定にも通知が登録される。Premium の1.5時間前通知に間に合わせるため。
    func testTomorrowEventsGetTheirNotificationsRegisteredToday() async {
        let today = scheduledPlan("today", start: at(1, 15), departure: at(1, 14, 25))
        // 翌日 1:00 開始。1.5時間前は 9/1 23:30 なので今日のうちに登録が要る。
        let earlyTomorrow = scheduledPlan("early", start: at(2, 1), departure: at(2, 0, 20))
        let result = DeparturePlanResult(today: [today], tomorrow: [earlyTomorrow])

        let plan = scheduler.plan(
            result,
            isPremium: true,
            previousDepartureTimes: [:],
            now: at(1, 8)
        )
        let stub = StubNotificationScheduler()
        await scheduler.register(plan, using: stub)

        let added = await stub.added
        let tomorrowOnes = added.filter { $0.key.eventIdentifier == "early" }
        XCTAssertEqual(tomorrowOnes.count, 4)

        let byKind = Dictionary(uniqueKeysWithValues: tomorrowOnes.map { ($0.kind, $0.fireDate) })
        XCTAssertEqual(byKind[.ninetyMinutesBeforeStart], at(1, 23, 30), "前日のうちに発火する")
        XCTAssertEqual(byKind[.sixtyMinutesBeforeStart], at(2, 0))
        XCTAssertEqual(byKind[.thirtyMinutesBeforeStart], at(2, 0, 30))
        XCTAssertEqual(byKind[.departure], at(2, 0, 20))
    }

    func testBothDaysAreRegisteredTogether() async {
        let today = scheduledPlan("today", start: at(1, 15), departure: at(1, 14, 25))
        let tomorrow = scheduledPlan("tomorrow", start: at(2, 10), departure: at(2, 9, 25))
        let result = DeparturePlanResult(today: [today], tomorrow: [tomorrow])

        let plan = scheduler.plan(result, isPremium: false, previousDepartureTimes: [:], now: at(1, 8))
        let stub = StubNotificationScheduler()
        await scheduler.register(plan, using: stub)

        let identifiers = await stub.identifiers
        XCTAssertEqual(identifiers.count, 4)
        XCTAssertEqual(Set(identifiers).count, 4, "identifier が重複しない")
    }

    /// 出発時刻が変わったら、同じ identifier で登録し直すことで古い通知が差し替わる。
    func testChangedDepartureReusesTheSameIdentifier() async {
        let key = Fixture.key("a")
        let first = scheduler.plan(
            plans: [scheduledPlan("a", start: at(1, 10), departure: at(1, 9, 25))],
            isPremium: false,
            previousDepartureTimes: [:],
            now: at(1, 6)
        )
        let second = scheduler.plan(
            plans: [scheduledPlan("a", start: at(1, 10), departure: at(1, 9))],
            isPremium: false,
            previousDepartureTimes: [key: at(1, 9, 25)],
            now: at(1, 6)
        )

        let firstDeparture = first.notifications.first { $0.kind == .departure }
        let secondDeparture = second.notifications.first { $0.kind == .departure }

        XCTAssertEqual(firstDeparture?.identifier, secondDeparture?.identifier)
        XCTAssertNotEqual(firstDeparture?.fireDate, secondDeparture?.fireDate)
    }
}
