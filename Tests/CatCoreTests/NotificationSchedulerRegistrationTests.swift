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

    // MARK: - 前回の出発時刻の保存（EventSnapshot 経由）

    private func repositoryWithSnapshot(for key: EventKey, startDate: Date) -> Repository {
        let repository = Repository(store: InMemoryFileStore())
        let snapshot = EventSnapshot(
            key: key,
            startDate: startDate,
            endDate: startDate.addingTimeInterval(3600)
        )
        try? repository.saveSnapshots([key: snapshot])
        return repository
    }

    /// 保存 → 読み出し → 判定 まで通しで、10分以上早まったら即時通知が入ること。
    func testStoredDepartureTimeDrivesTheImmediateNotification() async {
        let key = Fixture.key("a")
        let repository = repositoryWithSnapshot(for: key, startDate: at(1, 10))

        // 1回目: 出発 9:25 を算出して保存する。
        let first = scheduler.plan(
            plans: [scheduledPlan("a", start: at(1, 10), departure: at(1, 9, 25))],
            isPremium: true,
            previousDepartureTimes: repository.departureTimes(),
            now: at(1, 6)
        )
        XCTAssertFalse(first.notifications.contains { $0.kind == .departureMovedEarlier })
        try? repository.recordDepartureTimes(first.departureTimes)

        XCTAssertEqual(repository.departureTimes()[key], at(1, 9, 25), "スナップショットに残る")

        // 2回目: 出発が 9:10 に早まった（15分）。
        let second = scheduler.plan(
            plans: [scheduledPlan("a", start: at(1, 10), departure: at(1, 9, 10))],
            isPremium: true,
            previousDepartureTimes: repository.departureTimes(),
            now: at(1, 6, 30)
        )

        XCTAssertTrue(
            second.notifications.contains { $0.kind == .departureMovedEarlier },
            "保存した値と比較して即時通知が入る"
        )
    }

    /// 同じ通しで、10分未満の変化では即時通知が入らないこと。
    func testStoredDepartureTimeDoesNotTriggerForSmallChanges() {
        let key = Fixture.key("a")
        let repository = repositoryWithSnapshot(for: key, startDate: at(1, 10))

        let first = scheduler.plan(
            plans: [scheduledPlan("a", start: at(1, 10), departure: at(1, 9, 25))],
            isPremium: true,
            previousDepartureTimes: repository.departureTimes(),
            now: at(1, 6)
        )
        try? repository.recordDepartureTimes(first.departureTimes)

        // 9分早まっただけ。
        let second = scheduler.plan(
            plans: [scheduledPlan("a", start: at(1, 10), departure: at(1, 9, 16))],
            isPremium: true,
            previousDepartureTimes: repository.departureTimes(),
            now: at(1, 6, 30)
        )

        XCTAssertFalse(second.notifications.contains { $0.kind == .departureMovedEarlier })
    }

    func testRecordingIgnoresKeysWithoutASnapshot() {
        let repository = Repository(store: InMemoryFileStore())

        XCTAssertNoThrow(try repository.recordDepartureTimes([Fixture.key("ghost"): at(1, 9)]))
        XCTAssertTrue(repository.departureTimes().isEmpty)
    }

    /// 変更検知はこの値に触れない（枠の判定と同じく持ち回るだけ）。
    func testChangeDetectionPreservesTheStoredDepartureTime() {
        let event = Fixture.event("a", start: at(1, 10))
        var snapshot = EventSnapshot(event: event)
        snapshot.lastDepartureTime = at(1, 9, 25)

        let moved = Fixture.event("a", start: at(1, 11))
        let result = ChangeDetector().detectChanges(
            events: [moved],
            snapshots: [event.key: snapshot],
            now: at(1, 6)
        )

        XCTAssertEqual(result.updated[event.key]?.editCount, 1)
        XCTAssertEqual(result.updated[event.key]?.lastDepartureTime, at(1, 9, 25))
    }

    // MARK: - 取り消しの登録

    func testCompletedEventsPendingNotificationsAreRemovedThroughTheScheduler() async {
        let target = scheduledPlan("done", start: at(1, 10), departure: at(1, 9, 25))
        let plan = scheduler.plan(
            plans: [target],
            isPremium: true,
            previousDepartureTimes: [:],
            completedKeys: [target.key],
            now: at(1, 6)
        )
        let stub = StubNotificationScheduler()

        await scheduler.register(plan, using: stub)

        let removed = await stub.removed
        let added = await stub.added
        XCTAssertEqual(Set(removed), Set(ScheduledNotification.allIdentifiers(for: target.key)))
        XCTAssertTrue(added.isEmpty, "完了した予定には新しい通知を積まない")
    }

    func testNothingIsRemovedWhenNoEventIsCompleted() async {
        let target = scheduledPlan("a", start: at(1, 10), departure: at(1, 9, 25))
        let plan = scheduler.plan(
            plans: [target],
            isPremium: false,
            previousDepartureTimes: [:],
            now: at(1, 6)
        )
        let stub = StubNotificationScheduler()

        await scheduler.register(plan, using: stub)

        let removed = await stub.removed
        XCTAssertTrue(removed.isEmpty)
    }
}
