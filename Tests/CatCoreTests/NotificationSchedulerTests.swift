import XCTest
@testable import CatCore

final class NotificationSchedulerTests: XCTestCase {
    private let scheduler = NotificationScheduler()
    private let placeA = EventLocation(latitude: 35.7000, longitude: 139.7671, name: "A")

    private func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        Fixture.date(2026, 9, day, hour, minute)
    }

    /// 開始 10:00、出発 9:25 の予定。
    private func scheduledPlan(
        _ identifier: String = "a",
        start: Date? = nil,
        departure: Date? = nil
    ) -> DeparturePlan {
        let startDate = start ?? at(1, 10)
        return DeparturePlan(
            key: Fixture.key(identifier),
            startDate: startDate,
            origin: .home(placeA),
            outcome: .scheduled(
                departureTime: departure ?? startDate.addingTimeInterval(-35 * 60),
                mode: .transit,
                travelTime: 25 * 60,
                distanceMeters: 5_000
            )
        )
    }

    private func plan(
        _ plans: [DeparturePlan],
        isPremium: Bool,
        previous: [EventKey: Date] = [:],
        now: Date? = nil
    ) -> NotificationPlan {
        scheduler.plan(
            plans: plans,
            isPremium: isPremium,
            previousDepartureTimes: previous,
            now: now ?? at(1, 6)
        )
    }

    // MARK: - 通知タイミング

    func testFreeGetsTwoNotifications() {
        let target = scheduledPlan()

        let result = plan([target], isPremium: false)

        XCTAssertEqual(result.notifications.map(\.kind), [.departure, .start])
        XCTAssertEqual(result.notifications.map(\.fireDate), [at(1, 9, 25), at(1, 10)])
    }

    func testPremiumGetsFourNotifications() {
        let target = scheduledPlan()

        let result = plan([target], isPremium: true)

        XCTAssertEqual(
            result.notifications.map(\.kind),
            [.ninetyMinutesBeforeStart, .sixtyMinutesBeforeStart, .departure, .thirtyMinutesBeforeStart]
        )
    }

    /// Premium の各タイミングが開始時刻から逆算される。
    func testPremiumLeadTimesAreCountedBackFromTheStart() {
        let target = scheduledPlan(start: at(1, 15))

        let result = plan([target], isPremium: true)
        let byKind = Dictionary(uniqueKeysWithValues: result.notifications.map { ($0.kind, $0.fireDate) })

        XCTAssertEqual(byKind[.ninetyMinutesBeforeStart], at(1, 13, 30))
        XCTAssertEqual(byKind[.sixtyMinutesBeforeStart], at(1, 14))
        XCTAssertEqual(byKind[.thirtyMinutesBeforeStart], at(1, 14, 30))
    }

    func testFreeDoesNotGetTheLeadUpNotifications() {
        let result = plan([scheduledPlan()], isPremium: false)

        XCTAssertFalse(result.notifications.contains { $0.kind == .ninetyMinutesBeforeStart })
        XCTAssertFalse(result.notifications.contains { $0.kind == .sixtyMinutesBeforeStart })
        XCTAssertFalse(result.notifications.contains { $0.kind == .thirtyMinutesBeforeStart })
    }

    func testPremiumDoesNotGetTheStartNotification() {
        let result = plan([scheduledPlan()], isPremium: true)

        XCTAssertFalse(result.notifications.contains { $0.kind == .start })
    }

    /// 出発時刻が開始1.5時間前より後（＝リードタイムの通知に挟まれる）場合。
    /// 出発時刻がちょうど 30分前 と重なると、同じ時刻に2件登録される。
    /// 重複したときの扱いは仕様に記載が無いため、まとめずそのまま出している。
    func testDepartureCollidingWithALeadTimeProducesTwoNotificationsAtTheSameInstant() {
        // 移動時間20分 + バッファ10分 = 開始30分前ちょうど。
        let target = scheduledPlan(start: at(1, 10), departure: at(1, 9, 30))

        let result = plan([target], isPremium: true)
        let atThirty = result.notifications.filter { $0.fireDate == at(1, 9, 30) }

        XCTAssertEqual(atThirty.count, 2, "仕様に重複の規定が無いのでまとめていない")
        XCTAssertEqual(Set(atThirty.map(\.kind)), [.thirtyMinutesBeforeStart, .departure])
    }

    /// 出発時刻が開始1.5時間前より前でも、リードタイムの通知は変わらず出る。
    func testLongTravelPutsDepartureBeforeTheLeadUpNotifications() {
        let target = scheduledPlan(start: at(1, 10), departure: at(1, 7, 30))

        let result = plan([target], isPremium: true)

        XCTAssertEqual(result.notifications.first?.kind, .departure)
        XCTAssertEqual(result.notifications.count, 4)
    }

    // MARK: - 既に過ぎたタイミング

    func testTimingsAlreadyInThePastAreNotScheduled() {
        // 9:40 時点。出発 9:25 は過ぎている。開始 10:00 はまだ。
        let result = plan([scheduledPlan()], isPremium: false, now: at(1, 9, 40))

        XCTAssertEqual(result.notifications.map(\.kind), [.start])
    }

    func testPremiumTimingsAlreadyInThePastAreNotScheduled() {
        // 9:00 時点。1.5時間前(8:30) と 1時間前(9:00) は過ぎている。
        let result = plan([scheduledPlan()], isPremium: true, now: at(1, 9))

        XCTAssertEqual(result.notifications.map(\.kind), [.departure, .thirtyMinutesBeforeStart])
    }

    func testATimingExactlyAtNowIsNotScheduled() {
        let result = plan([scheduledPlan()], isPremium: false, now: at(1, 9, 25))

        XCTAssertEqual(result.notifications.map(\.kind), [.start])
    }

    // MARK: - 出発時刻が変わった場合

    func testPremiumGetsAnImmediateNotificationWhenDepartureMovesTenMinutesEarlier() {
        let target = scheduledPlan(start: at(1, 10), departure: at(1, 9))
        // 前回は 9:10。10分早まった。
        let result = plan(
            [target],
            isPremium: true,
            previous: [target.key: at(1, 9, 10)],
            now: at(1, 8)
        )

        let immediate = result.notifications.filter { $0.kind == .departureMovedEarlier }
        XCTAssertEqual(immediate.count, 1)
        XCTAssertEqual(immediate.first?.fireDate, at(1, 8), "算出時刻に送る")
    }

    func testNoImmediateNotificationWhenDepartureMovesLessThanTenMinutesEarlier() {
        let target = scheduledPlan(start: at(1, 10), departure: at(1, 9))
        // 前回は 9:09。9分しか早まっていない。
        let result = plan(
            [target],
            isPremium: true,
            previous: [target.key: at(1, 9, 9)],
            now: at(1, 8)
        )

        XCTAssertFalse(result.notifications.contains { $0.kind == .departureMovedEarlier })
    }

    func testNoImmediateNotificationWhenDepartureMovesLater() {
        let target = scheduledPlan(start: at(1, 10), departure: at(1, 9, 30))
        let result = plan(
            [target],
            isPremium: true,
            previous: [target.key: at(1, 9)],
            now: at(1, 8)
        )

        XCTAssertFalse(result.notifications.contains { $0.kind == .departureMovedEarlier })
    }

    /// 10分以上早まる規定は Premium だけ。
    func testFreeDoesNotGetTheImmediateNotification() {
        let target = scheduledPlan(start: at(1, 10), departure: at(1, 9))
        let result = plan(
            [target],
            isPremium: false,
            previous: [target.key: at(1, 9, 30)],
            now: at(1, 8)
        )

        XCTAssertFalse(result.notifications.contains { $0.kind == .departureMovedEarlier })
    }

    func testDepartureAlreadyPassedBecomesAnUrgentNotification() {
        let target = scheduledPlan(start: at(1, 10), departure: at(1, 8, 30))
        // 8:45 時点で、新しい出発時刻 8:30 は既に過ぎている。
        let result = plan(
            [target],
            isPremium: false,
            previous: [target.key: at(1, 9, 25)],
            now: at(1, 8, 45)
        )

        let urgent = result.notifications.filter { $0.kind == .departureAlreadyPassed }
        XCTAssertEqual(urgent.count, 1)
        XCTAssertEqual(urgent.first?.fireDate, at(1, 8, 45))
        XCTAssertFalse(result.notifications.contains { $0.kind == .departure }, "過ぎた出発時刻は登録しない")
    }

    /// 緊急通知はプランを問わない（仕様 4-3 は Premium と書いていない）。
    func testUrgentNotificationAppliesToPremiumToo() {
        let target = scheduledPlan(start: at(1, 10), departure: at(1, 8, 30))
        let result = plan(
            [target],
            isPremium: true,
            previous: [target.key: at(1, 9, 25)],
            now: at(1, 8, 45)
        )

        XCTAssertTrue(result.notifications.contains { $0.kind == .departureAlreadyPassed })
    }

    /// 前回の値が無い（初回の算出）ときは、変更ではないので即時も緊急も出さない。
    func testFirstCalculationProducesNoChangeNotifications() {
        let target = scheduledPlan(start: at(1, 10), departure: at(1, 8, 30))
        let result = plan([target], isPremium: true, previous: [:], now: at(1, 8, 45))

        XCTAssertFalse(result.notifications.contains { $0.kind == .departureAlreadyPassed })
        XCTAssertFalse(result.notifications.contains { $0.kind == .departureMovedEarlier })
    }

    func testUnchangedDepartureProducesNoChangeNotifications() {
        let target = scheduledPlan()
        let result = plan([target], isPremium: true, previous: [target.key: at(1, 9, 25)])

        XCTAssertFalse(result.notifications.contains { $0.kind == .departureMovedEarlier })
        XCTAssertFalse(result.notifications.contains { $0.kind == .departureAlreadyPassed })
    }

    // MARK: - 移動時間を取得できなかった場合

    func testTravelTimeUnavailableProducesItsOwnNotification() {
        let target = DeparturePlan(
            key: Fixture.key("a"),
            startDate: at(1, 10),
            origin: .home(placeA),
            outcome: .travelTimeUnavailable(mode: .transit, distanceMeters: 5_000)
        )

        let result = plan([target], isPremium: false, now: at(1, 8))

        XCTAssertEqual(result.notifications.map(\.kind), [.travelTimeUnavailable])
        XCTAssertEqual(result.notifications.first?.fireDate, at(1, 8))
        XCTAssertTrue(result.departureTimes.isEmpty)
    }

    // MARK: - 対象外

    func testCarriedOverEventProducesNoNotifications() {
        let target = DeparturePlan(
            key: Fixture.key("crossing"),
            startDate: at(1, 23),
            origin: .home(placeA),
            outcome: .notComputedOnThisDay
        )

        XCTAssertTrue(plan([target], isPremium: true).notifications.isEmpty)
    }

    // MARK: - 記録

    func testDepartureTimesAreReturnedForTheNextComparison() {
        let first = scheduledPlan("a", start: at(1, 10))
        let second = scheduledPlan("b", start: at(1, 15))

        let result = plan([first, second], isPremium: false)

        XCTAssertEqual(result.departureTimes[first.key], at(1, 9, 25))
        XCTAssertEqual(result.departureTimes[second.key], at(1, 14, 25))
    }

    func testIdentifierIsStablePerEventAndKind() {
        let target = scheduledPlan()
        let first = plan([target], isPremium: false).notifications
        let second = plan([target], isPremium: false).notifications

        XCTAssertEqual(first.map(\.identifier), second.map(\.identifier))
        XCTAssertEqual(Set(first.map(\.identifier)).count, first.count, "種別ごとに別の identifier")
    }

    func testRecurringOccurrencesGetDistinctIdentifiers() {
        let morning = DeparturePlan(
            key: Fixture.key("standup", occurrence: at(1, 9)),
            startDate: at(1, 9),
            origin: .home(placeA),
            outcome: .scheduled(departureTime: at(1, 8, 30), mode: .walking, travelTime: 20 * 60, distanceMeters: 900)
        )
        let evening = DeparturePlan(
            key: Fixture.key("standup", occurrence: at(1, 18)),
            startDate: at(1, 18),
            origin: .home(placeA),
            outcome: .scheduled(departureTime: at(1, 17, 30), mode: .walking, travelTime: 20 * 60, distanceMeters: 900)
        )

        let result = plan([morning, evening], isPremium: false, now: at(1, 6))

        XCTAssertEqual(Set(result.notifications.map(\.identifier)).count, 4)
    }

    // MARK: - 本文

    func testPlaceholderBodyIdentifiesTheKind() {
        let result = plan([scheduledPlan()], isPremium: false)

        for notification in result.notifications {
            XCTAssertTrue(
                notification.placeholderBody.contains(notification.kind.rawValue),
                "種別が判別できること: \(notification.placeholderBody)"
            )
        }
    }
}
