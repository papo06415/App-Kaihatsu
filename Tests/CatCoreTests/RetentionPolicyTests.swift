import XCTest
@testable import CatCore

final class RetentionPolicyTests: XCTestCase {
    private let policy = RetentionPolicy(calendar: Fixture.calendar)
    private let now = Fixture.date(2026, 9, 15, 9, 0)

    private func completedSnapshot(_ identifier: String, completedAt: Date?) -> EventSnapshot {
        let start = completedAt ?? now
        return EventSnapshot(
            key: Fixture.key(identifier, start),
            startDate: start,
            endDate: start.addingTimeInterval(3600),
            editCount: 0,
            isCompleted: completedAt != nil,
            completedAt: completedAt
        )
    }

    func testSnapshotCompletedFifteenDaysAgoIsDeleted() {
        let snapshot = completedSnapshot("old", completedAt: now.addingTimeInterval(-15 * 24 * 3600))

        let kept = policy.pruneSnapshots([snapshot.key: snapshot], now: now)

        XCTAssertTrue(kept.isEmpty)
    }

    /// 14日にしてある理由: 週次サマリーが「先週」を出すため、月曜には最大13日前が要る。
    func testSnapshotCompletedThirteenDaysAgoIsKept() {
        let snapshot = completedSnapshot("recent", completedAt: now.addingTimeInterval(-13 * 24 * 3600))

        let kept = policy.pruneSnapshots([snapshot.key: snapshot], now: now)

        XCTAssertEqual(kept.count, 1)
    }

    func testUncompletedSnapshotIsNeverPrunedByAge() {
        let snapshot = completedSnapshot("pending", completedAt: nil)

        let kept = policy.pruneSnapshots([snapshot.key: snapshot], now: now)

        XCTAssertEqual(kept.count, 1)
    }

    func testSlotsOlderThanThreeDaysAreDeleted() {
        func slots(_ dayOffset: Int) -> DailySlots {
            let day = Fixture.calendar.date(byAdding: .day, value: dayOffset, to: Fixture.date(2026, 9, 15))!
            return DailySlots(date: day, confirmedKeys: [], slotLimit: 3)
        }
        let all = [slots(-4), slots(-3), slots(-1), slots(0), slots(1)]
        let dictionary = Dictionary(all.map { ($0.date, $0) }, uniquingKeysWith: { a, _ in a })

        let kept = policy.pruneSlots(dictionary, now: now)

        XCTAssertEqual(kept.count, 4)
        XCTAssertNil(kept[slots(-4).date], "4日前は削除される")
        XCTAssertNotNil(kept[slots(-3).date], "3日前は残る")
    }

    func testSuccessfulGeocodeCacheIsNeverDeleted() {
        let entry = GeocodeCacheEntry(
            query: "東京駅",
            latitude: Fixture.tokyo.latitude,
            longitude: Fixture.tokyo.longitude,
            resolvedAt: Fixture.date(2020, 1, 1)
        )

        let kept = policy.pruneGeocodeCache([entry.query: entry], now: now)

        XCTAssertEqual(kept.count, 1)
    }

    func testFailedGeocodeCacheOlderThan24HoursIsDeleted() {
        let stale = GeocodeCacheEntry(
            query: "謎",
            latitude: nil,
            longitude: nil,
            resolvedAt: now.addingTimeInterval(-25 * 3600)
        )
        let fresh = GeocodeCacheEntry(
            query: "別の謎",
            latitude: nil,
            longitude: nil,
            resolvedAt: now.addingTimeInterval(-23 * 3600)
        )

        let kept = policy.pruneGeocodeCache([stale.query: stale, fresh.query: fresh], now: now)

        XCTAssertEqual(Array(kept.keys), ["別の謎"])
    }
}
