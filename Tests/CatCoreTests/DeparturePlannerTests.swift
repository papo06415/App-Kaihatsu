import XCTest
@testable import CatCore

final class DeparturePlannerTests: XCTestCase {
    private let planner = DeparturePlanner(calendar: Fixture.calendar)
    private let day = Fixture.date(2026, 9, 1)

    private let home = EventLocation(latitude: 35.6812, longitude: 139.7671, name: "自宅")
    private let placeA = EventLocation(latitude: 35.7000, longitude: 139.7671, name: "A")
    private let placeB = EventLocation(latitude: 35.7300, longitude: 139.7671, name: "B")

    private func at(_ hour: Int, _ minute: Int = 0) -> Date {
        Fixture.date(2026, 9, 1, hour, minute)
    }

    private func event(_ identifier: String, _ hour: Int, location: EventLocation?) -> CalendarEvent {
        Fixture.event(
            identifier,
            start: at(hour),
            locationText: location == nil ? nil : identifier,
            location: location
        )
    }

    private func plan(
        _ events: [CalendarEvent],
        home: EventLocation?,
        transport: PrimaryTransport = .transit,
        unresolved: Set<EventKey> = [],
        service: StubTravelTimeService
    ) async -> [DeparturePlan] {
        await planner.plan(
            targets: events,
            day: day,
            home: home,
            primaryTransport: transport,
            unresolvedKeys: unresolved,
            service: service
        )
    }

    // MARK: - 出発時刻

    func testDepartureIsStartMinusTravelTimeMinusTenMinutes() async {
        let service = StubTravelTimeService(defaultResult: .available(25 * 60))
        let target = event("a", 10, location: placeA)

        let plans = await plan([target], home: home, service: service)

        // 10:00 − 25分 − 10分 = 9:25
        XCTAssertEqual(plans.first?.departureTime, at(9, 25))
    }

    func testBufferIsTenMinutesForWalkingToo() async {
        let service = StubTravelTimeService(defaultResult: .available(8 * 60))
        let nearby = EventLocation(latitude: home.latitude + 0.005, longitude: home.longitude, name: "近所")
        let target = event("walk", 10, location: nearby)

        let plans = await plan([target], home: home, service: service)

        guard case .scheduled(let departure, let mode, _, _) = plans.first?.outcome else {
            return XCTFail("算出できるはず: \(String(describing: plans.first?.outcome))")
        }
        XCTAssertEqual(mode, .walking)
        // 10:00 − 8分 − 10分 = 9:42
        XCTAssertEqual(departure, at(9, 42))
    }

    func testZeroTravelTimeStillSubtractsTheBuffer() async {
        let service = StubTravelTimeService(defaultResult: .available(0))
        let plans = await plan([event("a", 10, location: placeA)], home: home, service: service)

        XCTAssertEqual(plans.first?.departureTime, at(9, 50))
    }

    // MARK: - 交通手段

    func testSelectedTransportIsUsedWhenBeyondWalkingDistance() async {
        for (transport, expected) in [
            (PrimaryTransport.transit, TravelMode.transit),
            (PrimaryTransport.automobile, TravelMode.automobile)
        ] {
            let service = StubTravelTimeService()
            _ = await plan(
                [event("far", 10, location: placeB)],
                home: home,
                transport: transport,
                service: service
            )
            let modes = await service.modes
            XCTAssertEqual(modes, [expected])
        }
    }

    // MARK: - 到着時刻の指定
    //
    // arrivalDate を MKDirections に渡すのは CatPlatform 側なので Linux では検証できない。
    // ここで確かめられるのは「プロトコルに何を渡しているか」まで。

    func testArrivalDateIsTheEventStartTime() async {
        let service = StubTravelTimeService()
        let target = event("a", 10, location: placeA)

        _ = await plan([target], home: home, service: service)

        let arrivals = await service.arrivalDates
        XCTAssertEqual(arrivals, [at(10)], "バッファを引く前の開始時刻を渡す")
    }

    /// 交通手段によらず到着時刻を渡す。
    func testArrivalDateIsPassedForEveryTravelMode() async {
        let nearby = EventLocation(latitude: home.latitude + 0.005, longitude: home.longitude, name: "近所")

        for (transport, destination, expectedMode) in [
            (PrimaryTransport.transit, nearby, TravelMode.walking),
            (PrimaryTransport.transit, placeB, TravelMode.transit),
            (PrimaryTransport.automobile, placeB, TravelMode.automobile)
        ] {
            let service = StubTravelTimeService()
            let target = event("a", 10, location: destination)
            _ = await plan([target], home: home, transport: transport, service: service)

            let calls = await service.calls
            XCTAssertEqual(calls.map(\.mode), [expectedMode])
            XCTAssertEqual(calls.map(\.arrivalDate), [at(10)], "\(expectedMode) でも到着時刻を渡す")
        }
    }

    func testEachEventGetsItsOwnArrivalDate() async {
        let service = StubTravelTimeService()
        let events = [
            event("a", 9, location: placeA),
            event("b", 13, location: placeB),
            event("c", 18, location: placeA)
        ]

        _ = await plan(events, home: home, service: service)

        let arrivals = await service.arrivalDates
        XCTAssertEqual(arrivals, [at(9), at(13), at(18)])
    }

    // MARK: - 出発地点の連鎖

    func testFirstSupportedEventStartsFromHome() async {
        let service = StubTravelTimeService()
        let plans = await plan([event("a", 10, location: placeA)], home: home, service: service)

        XCTAssertEqual(plans.first?.origin, .home(home))
        let origins = await service.origins
        XCTAssertEqual(origins, [home])
    }

    func testSecondEventStartsFromTheFirstEventsLocation() async {
        let service = StubTravelTimeService()
        let first = event("a", 10, location: placeA)
        let second = event("b", 14, location: placeB)

        let plans = await plan([first, second], home: home, service: service)

        XCTAssertEqual(plans[0].origin, .home(home))
        XCTAssertEqual(plans[1].origin, .previousEvent(first.key, placeA))
        let origins = await service.origins
        XCTAssertEqual(origins, [home, placeA])
    }

    func testSecondEventFallsBackToHomeWhenTheFirstHasNoLocation() async {
        let service = StubTravelTimeService()
        let first = event("a", 10, location: nil)
        let second = event("b", 14, location: placeB)

        let plans = await plan([first, second], home: home, service: service)

        XCTAssertEqual(plans[0].outcome, .destinationLocationUnavailable)
        XCTAssertEqual(plans[1].origin, .home(home), "前のサポート対象に場所がないので自宅から")
        let origins = await service.origins
        XCTAssertEqual(origins, [home], "場所のない予定では移動時間を取りにいかない")
    }

    func testThreeEventsChainTheirOrigins() async {
        let service = StubTravelTimeService()
        let first = event("a", 9, location: home)
        let second = event("b", 12, location: placeA)
        let third = event("c", 16, location: placeB)

        let plans = await plan([first, second, third], home: home, service: service)

        XCTAssertEqual(plans[0].origin, .home(home))
        XCTAssertEqual(plans[1].origin, .previousEvent(first.key, home))
        XCTAssertEqual(plans[2].origin, .previousEvent(second.key, placeA))
        let origins = await service.origins
        XCTAssertEqual(origins, [home, home, placeA])
    }

    func testChainRecoversAfterAnEventWithoutALocation() async {
        let service = StubTravelTimeService()
        let first = event("a", 9, location: placeA)
        let second = event("b", 12, location: nil)
        let third = event("c", 16, location: placeB)

        let plans = await plan([first, second, third], home: home, service: service)

        XCTAssertEqual(plans[0].origin, .home(home))
        XCTAssertEqual(plans[1].origin, .previousEvent(first.key, placeA))
        XCTAssertEqual(plans[1].outcome, .destinationLocationUnavailable)
        XCTAssertEqual(plans[2].origin, .home(home), "直前に場所がないので自宅に戻る")
    }

    /// noLocationKeys に入っている予定は、座標があっても「場所がない」として扱う。
    func testUnresolvedKeysAreTreatedAsHavingNoLocation() async {
        let service = StubTravelTimeService()
        let first = event("a", 10, location: placeA)
        let second = event("b", 14, location: placeB)

        let plans = await plan(
            [first, second],
            home: home,
            unresolved: [first.key],
            service: service
        )

        XCTAssertEqual(plans[0].outcome, .destinationLocationUnavailable)
        XCTAssertEqual(plans[1].origin, .home(home))
    }

    func testTargetsAreProcessedInStartTimeOrder() async {
        let service = StubTravelTimeService()
        let late = event("late", 16, location: placeB)
        let early = event("early", 9, location: placeA)

        let plans = await plan([late, early], home: home, service: service)

        XCTAssertEqual(plans.map(\.key.eventIdentifier), ["early", "late"])
        XCTAssertEqual(plans[1].origin, .previousEvent(early.key, placeA))
    }

    // MARK: - 移動時間を取得できなかった場合
    //
    // 失敗時にどう振る舞うべきかは仕様に記載が無い。ここでは出発時刻を算出せず、
    // 取得できなかったことを結果に残すだけにしてある。

    func testTravelTimeFailureLeavesTheDepartureUnscheduled() async {
        let service = StubTravelTimeService(defaultResult: .unavailable)
        let plans = await plan([event("a", 10, location: placeB)], home: home, service: service)

        XCTAssertNil(plans.first?.departureTime)
        guard case .travelTimeUnavailable(let mode, _) = plans.first?.outcome else {
            return XCTFail("travelTimeUnavailable のはず: \(String(describing: plans.first?.outcome))")
        }
        XCTAssertEqual(mode, .transit)
    }

    /// 移動時間の取得に失敗しても、その予定の場所は次の起点として使える（場所自体はあるため）。
    func testChainContinuesFromAnEventWhoseTravelTimeFailed() async {
        let service = StubTravelTimeService(
            results: [StubTravelTimeService.key(placeA): .unavailable],
            defaultResult: .available(20 * 60)
        )
        let first = event("a", 10, location: placeA)
        let second = event("b", 14, location: placeB)

        let plans = await plan([first, second], home: home, service: service)

        XCTAssertNil(plans[0].departureTime)
        XCTAssertEqual(plans[1].origin, .previousEvent(first.key, placeA))
        XCTAssertNotNil(plans[1].departureTime)
    }

    // MARK: - 自宅が未設定

    func testMissingHomeLeavesTheFirstEventWithoutAnOrigin() async {
        let service = StubTravelTimeService()
        let first = event("a", 10, location: placeA)
        let second = event("b", 14, location: placeB)

        let plans = await plan([first, second], home: nil, service: service)

        XCTAssertEqual(plans[0].origin, .unavailable)
        XCTAssertEqual(plans[0].outcome, .originUnavailable)
        // 2件目は1件目の場所を起点にできる。
        XCTAssertEqual(plans[1].origin, .previousEvent(first.key, placeA))
        XCTAssertNotNil(plans[1].departureTime)
    }

    // MARK: - 逐次実行

    func testTravelTimesAreFetchedSequentially() async {
        let service = StubTravelTimeService()
        let events = [
            event("a", 9, location: placeA),
            event("b", 12, location: placeB),
            event("c", 16, location: placeA)
        ]

        _ = await plan(events, home: home, service: service)

        let maxConcurrent = await service.maxConcurrentCalls
        let count = await service.callCount
        XCTAssertEqual(count, 3)
        XCTAssertEqual(maxConcurrent, 1, "並行実行していない")
    }
}
