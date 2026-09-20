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
        completed: Set<EventKey> = [],
        now: Date? = nil
    ) -> NotificationPlan {
        scheduler.plan(
            plans: plans,
            isPremium: isPremium,
            previousDepartureTimes: previous,
            completedKeys: completed,
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

    /// 出発時刻がリードタイムとちょうど重なったら1件にまとめ、departure を優先する。
    func testDepartureCollidingWithALeadTimeIsMergedIntoDeparture() {
        // 移動時間20分 + バッファ10分 = 開始30分前ちょうど。
        let target = scheduledPlan(start: at(1, 10), departure: at(1, 9, 30))

        let result = plan([target], isPremium: true)
        let atThirty = result.notifications.filter { $0.fireDate == at(1, 9, 30) }

        XCTAssertEqual(atThirty.count, 1, "同じ時刻には1件だけ")
        XCTAssertEqual(atThirty.first?.kind, .departure, "出発時刻を優先する")
        XCTAssertEqual(result.notifications.count, 3, "4件ぶんの候補が3件にまとまる")
    }

    func testDepartureCollidingWithTheOneHourLeadTimeIsMergedToo() {
        // 移動時間50分 + バッファ10分 = 開始1時間前ちょうど。
        let target = scheduledPlan(start: at(1, 10), departure: at(1, 9))

        let result = plan([target], isPremium: true)
        let atOneHour = result.notifications.filter { $0.fireDate == at(1, 9) }

        XCTAssertEqual(atOneHour.map(\.kind), [.departure])
    }

    func testDepartureCollidingWithTheNinetyMinuteLeadTimeIsMergedToo() {
        // 移動時間80分 + バッファ10分 = 開始1.5時間前ちょうど。
        let target = scheduledPlan(start: at(1, 10), departure: at(1, 8, 30))

        let result = plan([target], isPremium: true)
        let atNinety = result.notifications.filter { $0.fireDate == at(1, 8, 30) }

        XCTAssertEqual(atNinety.map(\.kind), [.departure])
    }

    /// 別々の予定が同じ時刻になっても、まとめるのは同じ予定の中だけ。
    func testCollisionsAcrossDifferentEventsAreNotMerged() {
        let first = scheduledPlan("a", start: at(1, 10), departure: at(1, 9, 30))
        let second = scheduledPlan("b", start: at(1, 12), departure: at(1, 9, 30))

        let result = plan([first, second], isPremium: false)
        let collided = result.notifications.filter { $0.fireDate == at(1, 9, 30) }

        XCTAssertEqual(collided.count, 2)
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
        // 9:40 時点。出発 9:25 は過ぎているので登録されず、代わりに緊急通知になる。
        let result = plan([scheduledPlan()], isPremium: false, now: at(1, 9, 40))

        XCTAssertEqual(result.notifications.map(\.kind), [.departureAlreadyPassed, .start])
        XCTAssertFalse(result.notifications.contains { $0.kind == .departure })
    }

    func testPremiumTimingsAlreadyInThePastAreNotScheduled() {
        // 9:00 時点。1.5時間前(8:30) と 1時間前(9:00) は過ぎている。
        let result = plan([scheduledPlan()], isPremium: true, now: at(1, 9))

        XCTAssertEqual(result.notifications.map(\.kind), [.departure, .thirtyMinutesBeforeStart])
    }

    func testATimingExactlyAtNowIsNotScheduled() {
        // 出発時刻ちょうど。定期の通知としては登録されない。
        let result = plan([scheduledPlan()], isPremium: false, now: at(1, 9, 25))

        XCTAssertFalse(result.notifications.contains { $0.kind == .departure })
        XCTAssertTrue(result.notifications.contains { $0.kind == .start })
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

    /// 初回の算出でも、出発時刻が既に過ぎていれば緊急通知を出す。
    /// ユーザーから見れば初回でも変更後でも「もう出ないと間に合わない」ことに変わりがない。
    func testFirstCalculationWithAPastDepartureStillProducesTheUrgentNotification() {
        let target = scheduledPlan(start: at(1, 10), departure: at(1, 8, 30))
        let result = plan([target], isPremium: true, previous: [:], now: at(1, 8, 45))

        XCTAssertTrue(result.notifications.contains { $0.kind == .departureAlreadyPassed })
        XCTAssertFalse(result.notifications.contains { $0.kind == .departureMovedEarlier })
    }

    /// 初回の算出で出発時刻がまだ先なら、即時も緊急も出さない。
    func testFirstCalculationWithAFutureDepartureProducesNoChangeNotifications() {
        let result = plan([scheduledPlan()], isPremium: true, previous: [:], now: at(1, 6))

        XCTAssertFalse(result.notifications.contains { $0.kind == .departureAlreadyPassed })
        XCTAssertFalse(result.notifications.contains { $0.kind == .departureMovedEarlier })
    }

    func testFreeAlsoGetsTheUrgentNotificationOnAFirstCalculation() {
        let target = scheduledPlan(start: at(1, 10), departure: at(1, 8, 30))
        let result = plan([target], isPremium: false, previous: [:], now: at(1, 8, 45))

        XCTAssertTrue(result.notifications.contains { $0.kind == .departureAlreadyPassed })
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

    // MARK: - 場所が分からなかった場合

    func testLocationUnavailableProducesItsOwnNotification() {
        let target = DeparturePlan(
            key: Fixture.key("a"),
            startDate: at(1, 10),
            origin: .home(placeA),
            outcome: .destinationLocationUnavailable
        )

        let result = plan([target], isPremium: false, now: at(1, 8))

        XCTAssertEqual(result.notifications.map(\.kind), [.locationUnavailable])
        XCTAssertEqual(result.notifications.first?.fireDate, at(1, 8), "即時に送る")
        XCTAssertTrue(result.departureTimes.isEmpty)
    }

    func testLocationUnavailableIsSentForPremiumToo() {
        let target = DeparturePlan(
            key: Fixture.key("a"),
            startDate: at(1, 10),
            origin: .home(placeA),
            outcome: .destinationLocationUnavailable
        )

        XCTAssertEqual(
            plan([target], isPremium: true, now: at(1, 8)).notifications.map(\.kind),
            [.locationUnavailable]
        )
    }

    /// 自宅が未設定のときだけ起きる。オンボーディングで必須にしているので通常は発生しない。
    func testOriginUnavailableProducesNoNotification() {
        let target = DeparturePlan(
            key: Fixture.key("a"),
            startDate: at(1, 10),
            origin: .unavailable,
            outcome: .originUnavailable
        )

        XCTAssertTrue(plan([target], isPremium: true).notifications.isEmpty)
    }

    // MARK: - 完了した予定

    func testCompletedEventHasItsPendingNotificationsCancelled() {
        let target = scheduledPlan()

        let result = plan([target], isPremium: true, completed: [target.key])

        XCTAssertTrue(result.notifications.isEmpty, "新しい通知は出さない")
        XCTAssertEqual(
            Set(result.cancelledIdentifiers),
            Set(ScheduledNotification.allIdentifiers(for: target.key))
        )
    }

    func testCancellationCoversEveryNotificationKind() {
        let target = scheduledPlan()

        let result = plan([target], isPremium: true, completed: [target.key])

        XCTAssertEqual(result.cancelledIdentifiers.count, NotificationKind.allCases.count)
    }

    func testOnlyCompletedEventsAreCancelled() {
        let completed = scheduledPlan("done", start: at(1, 10))
        let upcoming = scheduledPlan("next", start: at(1, 15))

        let result = plan([completed, upcoming], isPremium: false, completed: [completed.key])

        XCTAssertEqual(Set(result.notifications.map(\.key)), [upcoming.key])
        XCTAssertTrue(result.cancelledIdentifiers.allSatisfy { $0.hasPrefix("done|") })
    }

    func testNothingIsCancelledWhenNoEventIsCompleted() {
        let result = plan([scheduledPlan()], isPremium: false)

        XCTAssertTrue(result.cancelledIdentifiers.isEmpty)
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
