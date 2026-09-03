import XCTest
@testable import CatCore

final class LocationResolverTests: XCTestCase {
    private let resolver = LocationResolver()
    private let now = Fixture.date(2026, 9, 1, 8, 0)

    private func start(_ hour: Int) -> Date { Fixture.date(2026, 9, 1, hour, 0) }

    func testEventWithExistingCoordinateDoesNotCallService() async {
        let service = MockGeocodingService()
        let event = Fixture.event("a", start: start(10), locationText: "東京駅", location: Fixture.tokyo)
        var cache: [String: GeocodeCacheEntry] = [:]

        let result = await resolver.resolveLocations(
            candidates: [event],
            slotLimit: 3,
            cache: &cache,
            service: service,
            now: now
        )

        let calls = await service.callCount
        XCTAssertEqual(calls, 0)
        XCTAssertEqual(result.slotEligible, [event.key])
        XCTAssertEqual(result.resolved.first?.location, Fixture.tokyo)
    }

    func testNilLocationTextDoesNotCallService() async {
        let service = MockGeocodingService()
        let event = Fixture.event("a", start: start(10), locationText: nil)
        var cache: [String: GeocodeCacheEntry] = [:]

        let result = await resolver.resolveLocations(
            candidates: [event],
            slotLimit: 3,
            cache: &cache,
            service: service,
            now: now
        )

        let calls = await service.callCount
        XCTAssertEqual(calls, 0)
        XCTAssertTrue(result.slotEligible.isEmpty, "場所が無い予定は枠を消費しない")
        XCTAssertTrue(cache.isEmpty, "問い合わせていないのでキャッシュも書かない")
    }

    func testEmptyLocationTextDoesNotCallService() async {
        let service = MockGeocodingService()
        let event = Fixture.event("a", start: start(10), locationText: "   ")
        var cache: [String: GeocodeCacheEntry] = [:]

        _ = await resolver.resolveLocations(
            candidates: [event],
            slotLimit: 3,
            cache: &cache,
            service: service,
            now: now
        )

        let calls = await service.callCount
        XCTAssertEqual(calls, 0)
    }

    func testSuccessCacheEntryIsUsedWithoutCallingService() async {
        let service = MockGeocodingService()
        let event = Fixture.event("a", start: start(10), locationText: "東京駅")
        var cache = [
            "東京駅": GeocodeCacheEntry(
                query: "東京駅",
                latitude: Fixture.tokyo.latitude,
                longitude: Fixture.tokyo.longitude,
                // 1年前でも成功エントリは無期限。
                resolvedAt: Fixture.date(2025, 9, 1)
            )
        ]

        let result = await resolver.resolveLocations(
            candidates: [event],
            slotLimit: 3,
            cache: &cache,
            service: service,
            now: now
        )

        let calls = await service.callCount
        XCTAssertEqual(calls, 0)
        XCTAssertEqual(result.resolved.first?.location?.latitude, Fixture.tokyo.latitude)
        XCTAssertEqual(result.slotEligible, [event.key])
    }

    func testFailureCacheEntryFrom23HoursAgoDoesNotCallService() async {
        let service = MockGeocodingService(results: ["謎の場所": .resolved(Fixture.tokyo)])
        let event = Fixture.event("a", start: start(10), locationText: "謎の場所")
        var cache = [
            "謎の場所": GeocodeCacheEntry(
                query: "謎の場所",
                latitude: nil,
                longitude: nil,
                resolvedAt: now.addingTimeInterval(-23 * 3600)
            )
        ]

        let result = await resolver.resolveLocations(
            candidates: [event],
            slotLimit: 3,
            cache: &cache,
            service: service,
            now: now
        )

        let calls = await service.callCount
        XCTAssertEqual(calls, 0)
        XCTAssertTrue(result.slotEligible.isEmpty)
    }

    func testFailureCacheEntryFrom25HoursAgoIsRetried() async {
        let service = MockGeocodingService(results: ["謎の場所": .resolved(Fixture.tokyo)])
        let event = Fixture.event("a", start: start(10), locationText: "謎の場所")
        var cache = [
            "謎の場所": GeocodeCacheEntry(
                query: "謎の場所",
                latitude: nil,
                longitude: nil,
                resolvedAt: now.addingTimeInterval(-25 * 3600)
            )
        ]

        let result = await resolver.resolveLocations(
            candidates: [event],
            slotLimit: 3,
            cache: &cache,
            service: service,
            now: now
        )

        let calls = await service.callCount
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(result.slotEligible, [event.key])
        XCTAssertEqual(cache["謎の場所"]?.latitude, Fixture.tokyo.latitude)
    }

    /// オフラインで一度失敗しただけの予定を24時間締め出さないための決定的なルール。
    func testTemporaryFailureIsNotCached() async {
        let service = MockGeocodingService(defaultResult: .temporaryFailure)
        let event = Fixture.event("a", start: start(10), locationText: "東京駅")
        var cache: [String: GeocodeCacheEntry] = [:]

        let result = await resolver.resolveLocations(
            candidates: [event],
            slotLimit: 3,
            cache: &cache,
            service: service,
            now: now
        )

        XCTAssertTrue(cache.isEmpty)
        XCTAssertEqual(result.slotEligible, [event.key], "一時失敗でも枠には入る")
        XCTAssertNil(result.resolved.first?.location)
    }

    func testPermanentFailureIsCached() async {
        let service = MockGeocodingService(defaultResult: .permanentFailure)
        let event = Fixture.event("a", start: start(10), locationText: "存在しない住所")
        var cache: [String: GeocodeCacheEntry] = [:]

        let result = await resolver.resolveLocations(
            candidates: [event],
            slotLimit: 3,
            cache: &cache,
            service: service,
            now: now
        )

        XCTAssertEqual(cache["存在しない住所"]?.latitude, nil)
        XCTAssertEqual(cache["存在しない住所"]?.resolvedAt, now)
        XCTAssertTrue(result.slotEligible.isEmpty)
    }

    /// レート制限があるので並行実行してはいけない。
    func testThreeEventsAreResolvedSequentiallyInStartOrder() async {
        let service = MockGeocodingService(defaultResult: .resolved(Fixture.tokyo))
        // わざと開始時刻の逆順で渡す。
        let events = [
            Fixture.event("c", start: start(13), locationText: "C"),
            Fixture.event("a", start: start(9), locationText: "A"),
            Fixture.event("b", start: start(11), locationText: "B")
        ]
        var cache: [String: GeocodeCacheEntry] = [:]

        let result = await resolver.resolveLocations(
            candidates: events,
            slotLimit: 3,
            cache: &cache,
            service: service,
            now: now
        )

        let log = await service.callLog
        let maxConcurrent = await service.maxConcurrentCalls
        XCTAssertEqual(log, ["A", "B", "C"])
        XCTAssertEqual(maxConcurrent, 1, "並行実行されていない")
        XCTAssertEqual(result.resolved.map(\.title), ["a", "b", "c"])
    }

    func testPermanentFailureIsSkippedSoTheNextEventBecomesACandidate() async {
        let service = MockGeocodingService(
            results: [
                "A": .permanentFailure,
                "B": .resolved(Fixture.tokyo),
                "C": .resolved(Fixture.shinjuku),
                "D": .resolved(Fixture.tokyo)
            ]
        )
        let events = [
            Fixture.event("a", start: start(9), locationText: "A"),
            Fixture.event("b", start: start(10), locationText: "B"),
            Fixture.event("c", start: start(11), locationText: "C"),
            Fixture.event("d", start: start(12), locationText: "D")
        ]
        var cache: [String: GeocodeCacheEntry] = [:]

        let result = await resolver.resolveLocations(
            candidates: events,
            slotLimit: 3,
            cache: &cache,
            service: service,
            now: now
        )

        let log = await service.callLog
        XCTAssertEqual(log, ["A", "B", "C", "D"], "A が落ちたぶん D まで進む")
        XCTAssertEqual(result.slotEligible.map(\.eventIdentifier), ["b", "c", "d"])
    }

    func testServiceIsNotCalledOnceThreeSlotsAreFilled() async {
        let service = MockGeocodingService(defaultResult: .resolved(Fixture.tokyo))
        let events = (9...14).map { hour in
            Fixture.event("e\(hour)", start: start(hour), locationText: "Q\(hour)")
        }
        var cache: [String: GeocodeCacheEntry] = [:]

        let result = await resolver.resolveLocations(
            candidates: events,
            slotLimit: 3,
            cache: &cache,
            service: service,
            now: now
        )

        let log = await service.callLog
        XCTAssertEqual(log, ["Q9", "Q10", "Q11"], "通常はちょうど3回で済む")
        XCTAssertEqual(result.slotEligible.count, 3)
        XCTAssertEqual(result.resolved.count, events.count, "処理しなかった予定もそのまま返す")
        XCTAssertNil(result.resolved.last?.location)
    }
}

/// 「並行実行していない」というアサーションが意味を持つことを確かめるためのテスト。
/// モック側の検出器が壊れていたら、逐次実行のテストは何も守らなくなる。
final class MockGeocodingServiceTests: XCTestCase {
    func testMockDetectsConcurrentCalls() async {
        let service = MockGeocodingService(defaultResult: .permanentFailure)

        await withTaskGroup(of: Void.self) { group in
            for index in 0..<3 {
                group.addTask { _ = await service.resolve(query: "q\(index)") }
            }
        }

        let maxConcurrent = await service.maxConcurrentCalls
        XCTAssertGreaterThan(maxConcurrent, 1, "並行実行を検出できること")
    }
}
