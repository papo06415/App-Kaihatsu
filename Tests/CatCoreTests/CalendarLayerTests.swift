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

        // 開始時刻だけ動かす。単発予定のキーは eventIdentifier だけなので同一と判定される。
        source.events = [Fixture.event("a", start: at(1, 10), locationText: "L-a")]
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

    // MARK: - 枠の解放（支援送信の有無）

    func testDeletedEventReturnsItsSlotWhenSupportWasNotSent() async throws {
        let confirmed = [located("a", at(1, 9)), located("b", at(1, 10)), located("c", at(1, 11))]
        let waiting = located("d", at(1, 12))
        let source = MockCalendarSource(events: confirmed + [waiting])
        let geocoder = MockGeocodingService(defaultResult: .resolved(Fixture.tokyo))
        let layer = makeLayer(source: source, geocoder: geocoder)

        let first = try await layer.refreshOnLaunch(now: at(1, 8))
        XCTAssertEqual(first.todaySlots.confirmedKeys.map(\.eventIdentifier), ["a", "b", "c"])

        // b を削除する。支援はまだ送っていない。
        source.events = [confirmed[0], confirmed[2], waiting]
        let second = try await layer.refreshOnLaunch(now: at(1, 8, 30))

        XCTAssertEqual(second.todaySlots.confirmedKeys.map(\.eventIdentifier), ["a", "c", "d"])
        XCTAssertEqual(second.todaySlots.supportSentSlotCount, 0)
    }

    func testDeletedEventKeepsItsSlotSpentWhenSupportWasAlreadySent() async throws {
        let confirmed = [located("a", at(1, 9)), located("b", at(1, 10)), located("c", at(1, 11))]
        let waiting = located("d", at(1, 12))
        let source = MockCalendarSource(events: confirmed + [waiting])
        let geocoder = MockGeocodingService(defaultResult: .resolved(Fixture.tokyo))
        let layer = makeLayer(source: source, geocoder: geocoder)

        _ = try await layer.refreshOnLaunch(now: at(1, 8))

        // b に支援を送信したことを記録してから b を削除する。
        try repository.markSupportSent(for: confirmed[1].key, at: at(1, 8, 15))
        source.events = [confirmed[0], confirmed[2], waiting]
        let second = try await layer.refreshOnLaunch(now: at(1, 8, 30))

        XCTAssertEqual(second.todaySlots.confirmedKeys.map(\.eventIdentifier), ["a", "c"])
        XCTAssertEqual(second.todaySlots.supportSentSlotCount, 1)
        XCTAssertEqual(second.outOfSlotKeys.map(\.eventIdentifier), ["d"])

        // 次の起動でも枠は戻らない。
        let third = try await layer.refreshOnLaunch(now: at(1, 9, 0))
        XCTAssertEqual(third.todaySlots.confirmedKeys.map(\.eventIdentifier), ["a", "c"])
    }

    // MARK: - tomorrowEvents

    func testTomorrowEventsCarriesTheEventBodiesForTheNextDay() async throws {
        let today = located("today", at(1, 10))
        let earlyTomorrow = located("early", at(2, 1))
        let laterTomorrow = located("later", at(2, 14))
        let source = MockCalendarSource(events: [today, earlyTomorrow, laterTomorrow])
        let geocoder = MockGeocodingService(defaultResult: .resolved(Fixture.tokyo))
        let layer = makeLayer(source: source, geocoder: geocoder)

        let result = try await layer.refreshOnLaunch(now: at(1, 8))

        XCTAssertEqual(result.tomorrowEvents.map(\.title), ["early", "later"])
        // 開始時刻と座標が取れること（Premium の 1.5 時間前通知に必要）。
        let early = try XCTUnwrap(result.tomorrowEvents.first)
        XCTAssertEqual(early.startDate, at(2, 1))
        XCTAssertEqual(early.location, Fixture.tokyo)
        XCTAssertFalse(result.tomorrowEvents.contains { $0.title == "today" })
    }

    /// 翌日ぶんの日跨ぎ判定が tomorrowEvents と tomorrowSlots.date から行えること。
    func testCarriedOverCanBeDerivedFromTomorrowEvents() async throws {
        let crossing = Fixture.event(
            "crossing",
            start: at(1, 23, 30),
            end: at(2, 2, 0),
            locationText: "L-crossing"
        )
        let daytime = located("daytime", at(2, 10))
        let source = MockCalendarSource(events: [crossing, daytime])
        let geocoder = MockGeocodingService(defaultResult: .resolved(Fixture.tokyo))
        let layer = makeLayer(source: source, geocoder: geocoder)

        let result = try await layer.refreshOnLaunch(now: at(1, 8))

        let calendar = Fixture.calendar
        let carriedOver = result.tomorrowEvents.filter {
            !calendar.isDate($0.startDate, inSameDayAs: result.tomorrowSlots.date)
        }
        XCTAssertEqual(carriedOver.map(\.title), ["crossing"])
    }

    func testKeyArraysCoverTodayOnly() async throws {
        // 翌日に、キー配列のどれかに載りそうな予定を一通り置く。
        let todayEvent = located("today", at(1, 10))
        let tomorrowAllDay = Fixture.allDayEvent("tomorrow-allday", day: at(2, 0))
        let tomorrowNoLocation = Fixture.event("tomorrow-nowhere", start: at(2, 9), locationText: nil)
        let tomorrowExtra = (10...14).map { located("tomorrow-x\($0)", at(2, $0)) }
        let source = MockCalendarSource(
            events: [todayEvent, tomorrowAllDay, tomorrowNoLocation] + tomorrowExtra
        )
        let geocoder = MockGeocodingService(defaultResult: .resolved(Fixture.tokyo))
        let layer = makeLayer(source: source, geocoder: geocoder)

        let result = try await layer.refreshOnLaunch(now: at(1, 8))

        // 翌日の枠は確定しているが、キー配列には翌日の予定が一切混ざらない。
        XCTAssertEqual(result.tomorrowSlots.confirmedKeys.count, 3)
        for keys in [
            result.editLimitExceededKeys,
            result.outOfSlotKeys,
            result.noLocationKeys,
            result.allDayKeys,
            result.carriedOverKeys
        ] {
            XCTAssertFalse(
                keys.contains { $0.eventIdentifier.hasPrefix("tomorrow") },
                "翌日の予定が混入している: \(keys.map(\.eventIdentifier))"
            )
        }
    }

    // MARK: - 開始済みの予定（第1段階・第2段階で同じ扱い）

    func testStartedEventsAreExcludedOnTheSecondStageToo() async throws {
        let source = MockCalendarSource(events: [located("morning", at(1, 9))])
        let geocoder = MockGeocodingService(defaultResult: .resolved(Fixture.tokyo))
        let layer = makeLayer(source: source, geocoder: geocoder)

        // 8:00 に起動して第1段階を確定させる。
        let first = try await layer.refreshOnLaunch(now: at(1, 8))
        XCTAssertEqual(first.todaySlots.confirmedKeys.map(\.eventIdentifier), ["morning"])

        // 14:00 に、既に始まった予定が追加される（第2段階）。
        source.events = [located("morning", at(1, 9)), located("noon", at(1, 12))]
        let second = try await layer.refreshOnLaunch(now: at(1, 14))

        XCTAssertFalse(
            second.todaySlots.confirmedKeys.map(\.eventIdentifier).contains("noon"),
            "開始済みの予定は第2段階でも枠に入らない"
        )
        XCTAssertEqual(second.todaySlots.confirmedKeys.map(\.eventIdentifier), ["morning"],
                       "既に枠を持っている予定は開始済みでも保持する")
    }

    /// 開始済みの予定は、初回起動でも2回目以降でも同じ扱い（どこにも報告されない）になる。
    func testStartedEventsAreReportedIdenticallyOnFirstAndLaterLaunches() async throws {
        let events = [located("morning", at(1, 9)), located("evening", at(1, 18))]

        // ケースA: その日の初回起動が 14:00（第1段階）。
        let sourceA = MockCalendarSource(events: events)
        let layerA = makeLayer(
            source: sourceA,
            geocoder: MockGeocodingService(defaultResult: .resolved(Fixture.tokyo))
        )
        let a = try await layerA.refreshOnLaunch(now: at(1, 14))

        // ケースB: 8:00 に一度起動してから 14:00 に再起動（第2段階）。
        store = InMemoryFileStore()
        repository = Repository(store: store)
        let sourceB = MockCalendarSource(events: [events[1]])
        let layerB = makeLayer(
            source: sourceB,
            geocoder: MockGeocodingService(defaultResult: .resolved(Fixture.tokyo))
        )
        _ = try await layerB.refreshOnLaunch(now: at(1, 8))
        sourceB.events = events
        let b = try await layerB.refreshOnLaunch(now: at(1, 14))

        for result in [a, b] {
            let reported = result.todaySlots.confirmedKeys + result.outOfSlotKeys
                + result.noLocationKeys + result.editLimitExceededKeys
            XCTAssertFalse(
                reported.contains { $0.eventIdentifier == "morning" },
                "開始済みの予定はどこにも報告されない"
            )
            XCTAssertTrue(result.todaySlots.confirmedKeys.map(\.eventIdentifier).contains("evening"))
        }
    }

    // MARK: - 場所なし予定に後から場所が追加された場合
    //
    // 「新たな枠を消費しない」は「1日の上限3件を超えない」という意味。
    // 一度枠を逃した予定が以後も枠を取れない、という制約は設けない。

    func testEventGainingALocationTakesAFreeSlot() async throws {
        let confirmed = located("a", at(1, 9))
        let noLocation = Fixture.event("later", start: at(1, 12), locationText: nil)
        let source = MockCalendarSource(events: [confirmed, noLocation])
        let geocoder = MockGeocodingService(defaultResult: .resolved(Fixture.tokyo))
        let layer = makeLayer(source: source, geocoder: geocoder)

        let first = try await layer.refreshOnLaunch(now: at(1, 8))
        XCTAssertEqual(first.todaySlots.confirmedKeys.map(\.eventIdentifier), ["a"])
        XCTAssertEqual(first.noLocationKeys.map(\.eventIdentifier), ["later"])

        // ユーザーが場所欄を埋めた。空き枠が2つあるので入る。
        source.events = [confirmed, located("later", at(1, 12))]
        let second = try await layer.refreshOnLaunch(now: at(1, 8, 30))

        XCTAssertEqual(second.todaySlots.confirmedKeys.map(\.eventIdentifier), ["a", "later"])
        XCTAssertLessThanOrEqual(second.todaySlots.confirmedKeys.count, 3)
    }

    func testEventGainingALocationIsRejectedWhenSlotsAreFull() async throws {
        let confirmed = (9...11).map { located("f\($0)", at(1, $0)) }
        let noLocation = Fixture.event("later", start: at(1, 12), locationText: nil)
        let source = MockCalendarSource(events: confirmed + [noLocation])
        let geocoder = MockGeocodingService(defaultResult: .resolved(Fixture.tokyo))
        let layer = makeLayer(source: source, geocoder: geocoder)

        let first = try await layer.refreshOnLaunch(now: at(1, 8))
        XCTAssertEqual(first.todaySlots.confirmedKeys.map(\.eventIdentifier), ["f9", "f10", "f11"])

        // 場所を埋めても枠は空いていないので入らない。
        source.events = confirmed + [located("later", at(1, 12))]
        let second = try await layer.refreshOnLaunch(now: at(1, 8, 30))

        XCTAssertEqual(second.todaySlots.confirmedKeys.map(\.eventIdentifier), ["f9", "f10", "f11"])
        XCTAssertEqual(second.outOfSlotKeys.map(\.eventIdentifier), ["later"])
        XCTAssertLessThanOrEqual(second.todaySlots.confirmedKeys.count, 3)
    }

    /// 場所を後から埋める予定が何件あっても、1日の枠は3件を超えない。
    func testLateAddedLocationsNeverPushTheDayAboveThreeSlots() async throws {
        let confirmed = located("a", at(1, 9))
        let pending = (10...14).map { Fixture.event("p\($0)", start: at(1, $0), locationText: nil) }
        let source = MockCalendarSource(events: [confirmed] + pending)
        let geocoder = MockGeocodingService(defaultResult: .resolved(Fixture.tokyo))
        let layer = makeLayer(source: source, geocoder: geocoder)

        _ = try await layer.refreshOnLaunch(now: at(1, 8))

        // 5件すべてに場所が入った。
        source.events = [confirmed] + (10...14).map { located("p\($0)", at(1, $0)) }

        var result = try await layer.refreshOnLaunch(now: at(1, 8, 30))
        XCTAssertEqual(result.todaySlots.confirmedKeys.count, 3)

        // 何度起動しても増えない。
        result = try await layer.refreshOnLaunch(now: at(1, 8, 45))
        XCTAssertEqual(result.todaySlots.confirmedKeys.count, 3)
        XCTAssertEqual(result.todaySlots.confirmedKeys.map(\.eventIdentifier), ["a", "p10", "p11"])
    }

    // MARK: - 登録順と繰り返し予定

    func testSecondStageUsesCreationDateOrderNotStartTimeOrder() async throws {
        let confirmed = [located("a", at(1, 9)), located("b", at(1, 10))]
        let source = MockCalendarSource(events: confirmed)
        let geocoder = MockGeocodingService(defaultResult: .resolved(Fixture.tokyo))
        let layer = makeLayer(source: source, geocoder: geocoder)

        _ = try await layer.refreshOnLaunch(now: at(1, 8))

        // 開始時刻は earlyStart のほうが早いが、登録は firstRegistered が先。
        let firstRegistered = Fixture.event(
            "first-registered",
            start: at(1, 16),
            locationText: "L1",
            creationDate: Fixture.date(2026, 8, 20, 9, 0)
        )
        let earlyStart = Fixture.event(
            "early-start",
            start: at(1, 15),
            locationText: "L2",
            creationDate: Fixture.date(2026, 8, 25, 9, 0)
        )
        // fetchEvents は開始時刻順で返す（EventKit と同じ）。登録順は creationDate だけが決める。
        source.events = confirmed + [earlyStart, firstRegistered]

        let result = try await layer.refreshOnLaunch(now: at(1, 8, 30))

        XCTAssertEqual(
            result.todaySlots.confirmedKeys.map(\.eventIdentifier),
            ["a", "b", "first-registered"]
        )
    }

    func testRecurringOccurrencesOnTheSameDayAreTreatedAsSeparateEvents() async throws {
        let morning = Fixture.recurringEvent("standup", occurrence: at(1, 9), locationText: "L-am")
        let evening = Fixture.recurringEvent("standup", occurrence: at(1, 18), locationText: "L-pm")
        let source = MockCalendarSource(events: [morning, evening])
        let geocoder = MockGeocodingService(defaultResult: .resolved(Fixture.tokyo))
        let layer = makeLayer(source: source, geocoder: geocoder)

        let result = try await layer.refreshOnLaunch(now: at(1, 8))

        XCTAssertEqual(result.todaySlots.confirmedKeys.count, 2)
        XCTAssertEqual(repository.loadSnapshots().count, 2, "回ごとに別のスナップショットを持つ")
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
