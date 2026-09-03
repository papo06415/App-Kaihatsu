import XCTest
@testable import CatCore

final class CompletionEvaluatorTests: XCTestCase {
    private let evaluator = CompletionEvaluator()

    func testNotCompletedOneSecondBeforeStart() {
        let start = Fixture.date(2026, 9, 1, 10, 0)
        let event = Fixture.event("a", start: start)
        XCTAssertFalse(evaluator.isCompleted(event, now: start.addingTimeInterval(-1)))
    }

    func testCompletedExactlyAtStart() {
        let start = Fixture.date(2026, 9, 1, 10, 0)
        let event = Fixture.event("a", start: start)
        XCTAssertTrue(evaluator.isCompleted(event, now: start))
    }

    func testCompletedOneSecondAfterStart() {
        let start = Fixture.date(2026, 9, 1, 10, 0)
        let event = Fixture.event("a", start: start)
        XCTAssertTrue(evaluator.isCompleted(event, now: start.addingTimeInterval(1)))
    }

    /// 終日予定は開始時刻が 0:00 なので、その日になっていれば完了扱い。仕様どおりの挙動。
    func testAllDayEventIsCompletedOnceTheDayHasStarted() {
        let day = Fixture.date(2026, 9, 1)
        let event = Fixture.allDayEvent("all", day: day)
        XCTAssertTrue(evaluator.isCompleted(event, now: Fixture.date(2026, 9, 1, 0, 0, 1)))
        XCTAssertFalse(evaluator.isCompleted(event, now: Fixture.date(2026, 8, 31, 23, 59, 59)))
    }

    /// 基準は開始時刻であって終了時刻ではない。
    func testUsesStartDateNotEndDate() {
        let event = Fixture.event("a", start: Fixture.date(2026, 9, 1, 10, 0), durationMinutes: 120)
        XCTAssertTrue(evaluator.isCompleted(event, now: Fixture.date(2026, 9, 1, 10, 30)))
    }
}
