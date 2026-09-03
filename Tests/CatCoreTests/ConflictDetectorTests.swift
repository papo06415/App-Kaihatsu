import XCTest
@testable import CatCore

final class ConflictDetectorTests: XCTestCase {
    private let detector = ConflictDetector()

    private func at(_ hour: Int, _ minute: Int = 0) -> Date {
        Fixture.date(2026, 9, 1, hour, minute)
    }

    func testIdenticalStartTimesProduceOneSameStartTimeConflict() {
        let a = Fixture.event("a", start: at(9), durationMinutes: 60)
        let b = Fixture.event("b", start: at(9), durationMinutes: 30)

        let conflicts = detector.detectConflicts(in: [a, b])

        XCTAssertEqual(conflicts.count, 1)
        XCTAssertEqual(conflicts.first?.kind, .sameStartTime)
        XCTAssertEqual(Set(conflicts.first?.keys ?? []), Set([a.key, b.key]))
    }

    func testNestedTimeRangeIsAPartialOverlap() {
        // 9:00-10:30 と 9:30-10:00
        let a = Fixture.event("a", start: at(9), end: at(10, 30))
        let b = Fixture.event("b", start: at(9, 30), end: at(10))

        let conflicts = detector.detectConflicts(in: [a, b])

        XCTAssertEqual(conflicts.count, 1)
        XCTAssertEqual(conflicts.first?.kind, .partialOverlap)
    }

    func testTouchingBoundariesAreNotAConflict() {
        // 9:00-10:00 と 10:00-11:00
        let a = Fixture.event("a", start: at(9), end: at(10))
        let b = Fixture.event("b", start: at(10), end: at(11))

        XCTAssertTrue(detector.detectConflicts(in: [a, b]).isEmpty)
    }

    func testThreeMutuallyOverlappingEventsProduceThreePairs() {
        let a = Fixture.event("a", start: at(9), end: at(12))
        let b = Fixture.event("b", start: at(10), end: at(13))
        let c = Fixture.event("c", start: at(11), end: at(14))

        let conflicts = detector.detectConflicts(in: [a, b, c])

        XCTAssertEqual(conflicts.count, 3)
        let pairs = Set(conflicts.map { Set($0.keys) })
        XCTAssertEqual(pairs, Set([Set([a.key, b.key]), Set([a.key, c.key]), Set([b.key, c.key])]))
    }

    func testTheSamePairIsNeverReportedTwice() {
        let a = Fixture.event("a", start: at(9), end: at(12))
        let b = Fixture.event("b", start: at(10), end: at(11))

        let conflicts = detector.detectConflicts(in: [a, b, a, b])
            .filter { Set($0.keys) == Set([a.key, b.key]) }

        // 入力に重複があっても、ひとつの組み合わせは i < j で1回しか作られない。
        XCTAssertEqual(Set(conflicts.map { Set($0.keys) }).count, 1)
    }

    func testConflictsAreOrderIndependent() {
        let a = Fixture.event("a", start: at(9), end: at(12))
        let b = Fixture.event("b", start: at(10), end: at(11))

        XCTAssertEqual(detector.detectConflicts(in: [a, b]), detector.detectConflicts(in: [b, a]))
    }

    func testAllDayEventsAreExcluded() {
        let allDay = Fixture.allDayEvent("allday", day: Fixture.date(2026, 9, 1))
        let a = Fixture.event("a", start: at(9), end: at(10))
        let b = Fixture.event("b", start: at(9, 30), end: at(11))

        let conflicts = detector.detectConflicts(in: [allDay, a, b])

        XCTAssertEqual(conflicts.count, 1)
        XCTAssertFalse(conflicts.contains { $0.keys.contains(allDay.key) })
    }

    func testNonOverlappingEventsProduceNothing() {
        let a = Fixture.event("a", start: at(9), end: at(10))
        let b = Fixture.event("b", start: at(11), end: at(12))

        XCTAssertTrue(detector.detectConflicts(in: [a, b]).isEmpty)
    }
}
