import XCTest
@testable import CatCore

final class CalendarLayerTests: XCTestCase {
    private var store: InMemoryFileStore!
    private var repository: Repository!

    override func setUp() {
        super.setUp()
        store = InMemoryFileStore()
        repository = Repository(store: store)
    }

    private func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        Fixture.date(2026, 9, day, hour, minute)
    }

    private func makeLayer(
        source: MockCalendarSource,
        geocoder: MockGeocodingService
    ) -> CalendarLayer {
        CalendarLayer(
            source: source,
            geocoder: geocoder,
            repository: repository,
            calendar: Fixture.calendar
        )
    }

    private func located(_ identifier: String, _ start: Date, minutes: Int = 60) -> CalendarEvent {
        Fixture.event(identifier, start: start, durationMinutes: minutes, locationText: "L-\(identifier)")
    }

    // MARK: - 権限

    func testWriteOnlyAccessIsTreatedAsUnusable() async {
        let source = MockCalendarSource(authorization: .writeOnly)
        let layer = makeLayer(source: source, geocoder: MockGeocodingService())

        do {
            _ = try await layer.refreshOnLaunch(now: at(1, 8))
            XCTFail("エラーになるはず")
        } catch {
            XCTAssertEqual(error as? CalendarLayerError, .calendarAccessWriteOnly)
        }
    }

    func testDeniedAndNotDeterminedAccessThrow() async {
        for (authorization, expected) in [
            (CalendarAuthorization.denied, CalendarLayerError.calendarAccessDenied),
            (CalendarAuthorization.notDetermined, CalendarLayerError.calendarAccessNotDetermined)
        ] {
            let layer = makeLayer(
                source: MockCalendarSource(authorization: authorization),
                geocoder: MockGeocodingService()
            )
            do {
                _ = try await layer.refreshOnLaunch(now: at(1, 8))
                XCTFail("エラーになるはず")
            } catch {
                XCTAssertEqual(error as? CalendarLayerError, expected)
            }
        }
    }

    // MARK: - 正常系

    func testLaunchConfirmsThreeSlotsAndCallsGeocoderExactlyThreeTimes() async throws {
        let events = [
            located("a", at(1, 9)),
            located("b", at(1, 10)),
            located("c", at(1, 11)),
            located("d", at(1, 12))
        ]
        let source = MockCalendarSource(events: events)
        let geocoder = MockGeocodingService(defaultResult: .resolved(Fixture.tokyo))
        let layer = makeLayer(source: source, geocoder: geocoder)

        let result = try await layer.refreshOnLaunch(now: at(1, 8))

        XCTAssertEqual(result.todaySlots.confirmedKeys.map(\.eventIdentifier), ["a", "b", "c"])
        XCTAssertEqual(result.outOfSlotKeys.map(\.eventIdentifier), ["d"])
        let calls = await geocoder.callCount
        XCTAssertEqual(calls, 3, "ジオコーディングは通常ちょうど3回")
        XCTAssertTrue(result.noLocationKeys.isEmpty)
    }

    func testFetchRangeCoversThreeDaysBackAndThirtyDaysAhead() async throws {
        let source = MockCalendarSource(events: [])
        let layer = makeLayer(source: source, geocoder: MockGeocodingService())

        _ = try await layer.refreshOnLaunch(now: at(1, 8))

        XCTAssertEqual(source.fetchRanges.count, 1)
        XCTAssertEqual(source.fetchRanges.first?.from, Fixture.date(2026, 8, 29))
        XCTAssertEqual(source.fetchRanges.first?.to, Fixture.date(2026, 10, 2))
    }

    func testAllDayEventsAreReportedSeparatelyAndDoNotTakeSlots() async throws {
        let allDay = Fixture.allDayEvent("holiday", day: at(1, 0))
        let source = MockCalendarSource(events: [allDay, located("a", at(1, 9))])
        let geocoder = MockGeocodingService(defaultResult: .resolved(Fixture.tokyo))
        let layer = makeLayer(source: source, geocoder: geocoder)

        let result = try await layer.refreshOnLaunch(now: at(1, 8))

        XCTAssertEqual(result.allDayKeys.map(\.eventIdentifier), ["holiday"])
        XCTAssertEqual(result.todaySlots.confirmedKeys.map(\.eventIdentifier), ["a"])
    }

    func testUnresolvableEventIsReportedAndDoesNotTakeASlot() async throws {
        let source = MockCalendarSource(events: [
            located("bad", at(1, 9)),
            located("good", at(1, 10))
        ])
        let geocoder = MockGeocodingService(
            results: ["L-bad": .permanentFailure, "L-good": .resolved(Fixture.tokyo)]
        )
        let layer = makeLayer(source: source, geocoder: geocoder)

        let result = try await layer.refreshOnLaunch(now: at(1, 8))

        XCTAssertEqual(result.todaySlots.confirmedKeys.map(\.eventIdentifier), ["good"])
        XCTAssertEqual(result.noLocationKeys.map(\.eventIdentifier), ["bad"])
    }

    func testConflictsAreDetectedForToday() async throws {
        let source = MockCalendarSource(events: [
            located("a", at(1, 9), minutes: 90),
            located("b", at(1, 10), minutes: 30)
        ])
        let geocoder = MockGeocodingService(defaultResult: .resolved(Fixture.tokyo))
        let layer = makeLayer(source: source, geocoder: geocoder)

        let result = try await layer.refreshOnLaunch(now: at(1, 8))

        XCTAssertEqual(result.conflicts.count, 1)
        XCTAssertEqual(result.conflicts.first?.kind, .partialOverlap)
    }

    // MARK: - 日跨ぎ予定と carriedOverKeys

    func testCrossingEventTakesASlotOnBothDaysAndIsCarriedOverOnlyOnTheSecondDay() async throws {
        let crossing = Fixture.event(
            "crossing",
            start: at(1, 23, 30),
            end: at(2, 2, 0),
            locationText: "L-crossing"
        )
        let source = MockCalendarSource(events: [crossing])
        let geocoder = MockGeocodingService(defaultResult: .resolved(Fixture.tokyo))
        let layer = makeLayer(source: source, geocoder: geocoder)

        // 9/1 に起動: 9/1 の枠も 9/2 の枠も消費する。9/1 では日跨ぎ扱いではない。
        let first = try await layer.refreshOnLaunch(now: at(1, 8))
        XCTAssertEqual(first.todaySlots.confirmedKeys.map(\.eventIdentifier), ["crossing"])
        XCTAssertEqual(first.tomorrowSlots.confirmedKeys.map(\.eventIdentifier), ["crossing"])
        XCTAssertTrue(first.carriedOverKeys.isEmpty, "開始日は日跨ぎ扱いにしない")

        // 9/2 に起動: 同じ予定が 9/2 の枠を持ったまま、日跨ぎとして報告される。
        let second = try await layer.refreshOnLaunch(now: at(2, 8))
        XCTAssertEqual(second.todaySlots.confirmedKeys.map(\.eventIdentifier), ["crossing"])
        XCTAssertEqual(second.carriedOverKeys.map(\.eventIdentifier), ["crossing"])
    }

    // MARK: - 前日未起動

    func testLaunchingAtFourteenHundredWithoutAPreviousLaunchSkipsPastEvents() async throws {
        let source = MockCalendarSource(events: [
            located("morning", at(1, 9)),
            located("late-morning", at(1, 11)),
            located("afternoon", at(1, 15)),
            located("evening", at(1, 18))
        ])
        let geocoder = MockGeocodingService(defaultResult: .resolved(Fixture.tokyo))
        let layer = makeLayer(source: source, geocoder: geocoder)

        let result = try await layer.refreshOnLaunch(now: at(1, 14))

        XCTAssertEqual(
            result.todaySlots.confirmedKeys.map(\.eventIdentifier),
            ["afternoon", "evening"]
        )
        let log = await geocoder.callLog
        XCTAssertFalse(log.contains("L-morning"), "枠に入れない予定にジオコーディングを使わない")
    }

    // MARK: - 永続化と2回目の起動

    func testSlotsSurviveRelaunchAndAreNotReshuffled() async throws {
        let events = [
            located("b", at(1, 10)),
            located("c", at(1, 11)),
            located("d", at(1, 12))
        ]
        let source = MockCalendarSource(events: events)
        let geocoder = MockGeocodingService(defaultResult: .resolved(Fixture.tokyo))
        let layer = makeLayer(source: source, geocoder: geocoder)

        let first = try await layer.refreshOnLaunch(now: at(1, 8))
        XCTAssertEqual(first.todaySlots.confirmedKeys.map(\.eventIdentifier), ["b", "c", "d"])

        // より早い時刻の予定が後から登録されても押し出さない。
        source.events.append(located("a", at(1, 9)))
        let second = try await layer.refreshOnLaunch(now: at(1, 8, 30))

        XCTAssertEqual(second.todaySlots.confirmedKeys.map(\.eventIdentifier), ["b", "c", "d"])
        XCTAssertEqual(second.outOfSlotKeys.map(\.eventIdentifier), ["a"])
    }

    func testGeocodeCacheIsReusedOnRelaunch() async throws {
        let source = MockCalendarSource(events: [located("a", at(1, 9))])
        let geocoder = MockGeocodingService(defaultResult: .resolved(Fixture.tokyo))
        let layer = makeLayer(source: source, geocoder: geocoder)

        _ = try await layer.refreshOnLaunch(now: at(1, 8))
        _ = try await layer.refreshOnLaunch(now: at(1, 8, 30))

        let calls = await geocoder.callCount
        XCTAssertEqual(calls, 1, "2回目はキャッシュを使う")
    }

    func testSnapshotsRecordEditsAcrossLaunches() async throws {
        let event = located("a", at(1, 9))
        let source = MockCalendarSource(events: [event])
        let geocoder = MockGeocodingService(defaultResult: .resolved(Fixture.tokyo))
        let layer = makeLayer(source: source, geocoder: geocoder)

        _ = try await layer.refreshOnLaunch(now: at(1, 8))
        XCTAssertEqual(repository.loadSnapshots()[event.key]?.editCount, 0)

        // 開始時刻だけ動かす（EventKey は識別子なので据え置き）。
        source.events = [Fixture.event("a", start: at(1, 10), locationText: "L-a", key: event.key)]
        _ = try await layer.refreshOnLaunch(now: at(1, 8, 30))

        XCTAssertEqual(repository.loadSnapshots()[event.key]?.editCount, 1)
    }

    func testEditLimitExceededKeysReportsSnapshotsAtTheFreeLimit() async throws {
        let event = located("a", at(1, 9))
        var snapshot = EventSnapshot(event: event)
        snapshot.editCount = 3
        try repository.saveSnapshots([event.key: snapshot])

        let source = MockCalendarSource(events: [event])
        let geocoder = MockGeocodingService(defaultResult: .resolved(Fixture.tokyo))
        let layer = makeLayer(source: source, geocoder: geocoder)

        let result = try await layer.refreshOnLaunch(now: at(1, 8))

        XCTAssertEqual(result.editLimitExceededKeys, [event.key])
    }

    func testPremiumUserGetsEverySlot() async throws {
        try repository.savePreferences(UserPreferences(isPremium: true))
        let events = (9...15).map { located("e\($0)", at(1, $0)) }
        let source = MockCalendarSource(events: events)
        let geocoder = MockGeocodingService(defaultResult: .resolved(Fixture.tokyo))
        let layer = makeLayer(source: source, geocoder: geocoder)

        let result = try await layer.refreshOnLaunch(now: at(1, 8))

        XCTAssertEqual(result.todaySlots.confirmedKeys.count, events.count)
        XCTAssertEqual(result.todaySlots.slotLimit, Int.max)
        XCTAssertTrue(result.editLimitExceededKeys.isEmpty)
    }

    func testExpiredDataIsPrunedOnLaunch() async throws {
        // 完了から15日経ったスナップショットと、25時間前の失敗キャッシュ。
        let old = located("old", Fixture.date(2026, 8, 10, 9, 0))
        var oldSnapshot = EventSnapshot(event: old)
        oldSnapshot.isCompleted = true
        oldSnapshot.completedAt = Fixture.date(2026, 8, 17, 9, 0)
        try repository.saveSnapshots([old.key: oldSnapshot])
        try repository.saveGeocodeCache([
            "古い失敗": GeocodeCacheEntry(
                query: "古い失敗",
                latitude: nil,
                longitude: nil,
                resolvedAt: Fixture.date(2026, 8, 31, 6, 0)
            )
        ])

        let layer = makeLayer(source: MockCalendarSource(events: []), geocoder: MockGeocodingService())
        _ = try await layer.refreshOnLaunch(now: at(1, 8))

        XCTAssertTrue(repository.loadSnapshots().isEmpty)
        XCTAssertTrue(repository.loadGeocodeCache().isEmpty)
    }

    func testSnapshotsOutsideTheFetchWindowAreNotTreatedAsDeleted() async throws {
        // 5日前の完了済み予定。取得範囲（3日前〜）の外にあるが消してはいけない。
        let past = located("past", Fixture.date(2026, 8, 27, 9, 0))
        var snapshot = EventSnapshot(event: past)
        snapshot.isCompleted = true
        snapshot.completedAt = Fixture.date(2026, 8, 27, 9, 0)
        try repository.saveSnapshots([past.key: snapshot])

        let layer = makeLayer(source: MockCalendarSource(events: []), geocoder: MockGeocodingService())
        _ = try await layer.refreshOnLaunch(now: at(1, 8))

        XCTAssertNotNil(repository.loadSnapshots()[past.key])
    }
}
