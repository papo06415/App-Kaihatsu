import XCTest
@testable import CatCore

/// LaunchResult をそのまま入力にする経路のテスト。
final class DeparturePlannerLaunchResultTests: XCTestCase {
    private let planner = DeparturePlanner(calendar: Fixture.calendar)
    // UserPreferences は自宅の名称を持たないので、名前は nil になる。
    private let home = EventLocation(latitude: 35.6812, longitude: 139.7671, name: nil)
    private let placeA = EventLocation(latitude: 35.7000, longitude: 139.7671, name: "A")
    private let placeB = EventLocation(latitude: 35.7300, longitude: 139.7671, name: "B")

    private func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        Fixture.date(2026, 9, day, hour, minute)
    }

    private var preferences: UserPreferences {
        UserPreferences(
            homeLatitude: home.latitude,
            homeLongitude: home.longitude,
            primaryTransport: .transit
        )
    }

    private func launchResult(
        todayEvents: [CalendarEvent],
        tomorrowEvents: [CalendarEvent] = [],
        todayConfirmed: [EventKey]? = nil,
        tomorrowConfirmed: [EventKey]? = nil,
        noLocationKeys: [EventKey] = []
    ) -> LaunchResult {
        LaunchResult(
            todayEvents: todayEvents,
            tomorrowEvents: tomorrowEvents,
            todaySlots: DailySlots(
                date: at(1, 0),
                confirmedKeys: todayConfirmed ?? todayEvents.map(\.key),
                confirmedAt: at(1, 8),
                slotLimit: 3
            ),
            tomorrowSlots: DailySlots(
                date: at(2, 0),
                confirmedKeys: tomorrowConfirmed ?? tomorrowEvents.map(\.key),
                confirmedAt: at(1, 8),
                slotLimit: 3
            ),
            conflicts: [],
            editLimitExceededKeys: [],
            outOfSlotKeys: [],
            noLocationKeys: noLocationKeys,
            allDayKeys: [],
            carriedOverKeys: []
        )
    }

    func testOnlyConfirmedEventsArePlanned() async {
        let confirmed = Fixture.event("in-slot", start: at(1, 10), location: placeA)
        let outOfSlot = Fixture.event("out-of-slot", start: at(1, 11), location: placeB)
        let launch = launchResult(
            todayEvents: [confirmed, outOfSlot],
            todayConfirmed: [confirmed.key]
        )

        let result = await planner.plan(
            launch: launch,
            preferences: preferences,
            service: StubTravelTimeService()
        )

        XCTAssertEqual(result.today.map(\.key.eventIdentifier), ["in-slot"])
    }

    func testNoLocationKeysAreSkippedAndResetTheChainToHome() async {
        let first = Fixture.event("a", start: at(1, 10), location: placeA)
        let second = Fixture.event("b", start: at(1, 14), location: placeB)
        let launch = launchResult(
            todayEvents: [first, second],
            noLocationKeys: [first.key]
        )
        let service = StubTravelTimeService()

        let result = await planner.plan(launch: launch, preferences: preferences, service: service)

        XCTAssertEqual(result.today[0].outcome, .destinationLocationUnavailable)
        XCTAssertEqual(result.today[1].origin, .home(home))
        let origins = await service.origins
        XCTAssertEqual(origins, [home])
    }

    /// Premium の 1.5 時間前通知に備えて、翌日ぶんも計算する。
    func testTomorrowEventsArePlannedToo() async {
        let today = Fixture.event("today", start: at(1, 10), location: placeA)
        let earlyTomorrow = Fixture.event("early", start: at(2, 1), location: placeB)
        let launch = launchResult(todayEvents: [today], tomorrowEvents: [earlyTomorrow])
        let service = StubTravelTimeService(defaultResult: .available(30 * 60))

        let result = await planner.plan(launch: launch, preferences: preferences, service: service)

        XCTAssertEqual(result.tomorrow.map(\.key.eventIdentifier), ["early"])
        // 9/2 1:00 − 30分 − 10分 = 9/2 0:20
        XCTAssertEqual(result.tomorrow.first?.departureTime, at(2, 0, 20))
    }

    /// 翌日の予定にも、その予定自身の開始時刻を到着時刻として渡す。
    /// 今日のうちに計算しても、深夜のダイヤで引いてしまわないようにするため。
    func testTomorrowEventsUseTheirOwnStartTimeAsArrivalDate() async {
        let today = Fixture.event("today", start: at(1, 10), location: placeA)
        let earlyTomorrow = Fixture.event("early", start: at(2, 1), location: placeB)
        let launch = launchResult(todayEvents: [today], tomorrowEvents: [earlyTomorrow])
        let service = StubTravelTimeService()

        _ = await planner.plan(launch: launch, preferences: preferences, service: service)

        let arrivals = await service.arrivalDates
        XCTAssertEqual(arrivals, [at(1, 10), at(2, 1)])
    }

    /// 連鎖は日ごとに独立している（その日の最初は自宅から）。
    func testEachDayStartsItsChainFromHome() async {
        let today = Fixture.event("today", start: at(1, 10), location: placeA)
        let tomorrow = Fixture.event("tomorrow", start: at(2, 10), location: placeB)
        let launch = launchResult(todayEvents: [today], tomorrowEvents: [tomorrow])

        let result = await planner.plan(
            launch: launch,
            preferences: preferences,
            service: StubTravelTimeService()
        )

        XCTAssertEqual(result.today.first?.origin, .home(home))
        XCTAssertEqual(result.tomorrow.first?.origin, .home(home), "翌日も自宅から始まる")
    }

    /// 日跨ぎ予定は開始日にのみ出発時刻を計算する。翌日側では計算しない。
    func testCarriedOverEventIsNotPlannedOnTheSecondDay() async {
        let crossing = Fixture.event(
            "crossing",
            start: at(1, 23, 30),
            end: at(2, 2, 0),
            location: placeA
        )
        let daytime = Fixture.event("daytime", start: at(2, 10), location: placeB)
        let launch = launchResult(
            todayEvents: [crossing],
            tomorrowEvents: [crossing, daytime]
        )
        let service = StubTravelTimeService()

        let result = await planner.plan(launch: launch, preferences: preferences, service: service)

        // 9/1 側では計算する。
        XCTAssertNotNil(result.today.first?.departureTime)
        // 9/2 側では計算しない。
        XCTAssertEqual(result.tomorrow[0].key.eventIdentifier, "crossing")
        XCTAssertEqual(result.tomorrow[0].outcome, .notComputedOnThisDay)
        XCTAssertNotNil(result.tomorrow[1].departureTime)
    }

    func testHomeIsUnavailableWhenPreferencesHaveNoCoordinates() async {
        let target = Fixture.event("a", start: at(1, 10), location: placeA)
        let launch = launchResult(todayEvents: [target])

        let result = await planner.plan(
            launch: launch,
            preferences: UserPreferences(primaryTransport: .automobile),
            service: StubTravelTimeService()
        )

        XCTAssertEqual(result.today.first?.outcome, .originUnavailable)
    }
}
