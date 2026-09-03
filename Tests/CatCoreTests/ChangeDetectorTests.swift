import XCTest
@testable import CatCore

final class ChangeDetectorTests: XCTestCase {
    private let detector = ChangeDetector()

    /// まだ開始していない時刻。完了判定に引っかからないようにするため。
    private let now = Fixture.date(2026, 9, 1, 8, 0)
    private let start = Fixture.date(2026, 9, 1, 10, 0)

    func testNewEventStartsWithZeroEdits() {
        let event = Fixture.event("a", start: start)
        let result = detector.detectChanges(events: [event], snapshots: [:], now: now)

        XCTAssertEqual(result.updated[event.key]?.editCount, 0)
        XCTAssertEqual(result.updated[event.key]?.startDate, start)
        XCTAssertFalse(result.updated[event.key]?.isCompleted ?? true)
        XCTAssertTrue(result.changed.isEmpty)
        XCTAssertTrue(result.deleted.isEmpty)
    }

    func testTitleOnlyChangeDoesNotCountAsEdit() {
        let event = Fixture.event("a", start: start, title: "会議")
        let first = detector.detectChanges(events: [event], snapshots: [:], now: now)

        let renamed = Fixture.event("a", start: start, title: "打ち合わせ")
        let second = detector.detectChanges(events: [renamed], snapshots: first.updated, now: now)

        XCTAssertEqual(second.updated[event.key]?.editCount, 0)
        XCTAssertTrue(second.changed.isEmpty)
    }

    func testStartDateChangeCountsAsOneEdit() {
        let event = Fixture.event("a", start: start)
        let first = detector.detectChanges(events: [event], snapshots: [:], now: now)

        // 単発予定のキーは eventIdentifier だけなので、開始時刻を動かしてもキーは変わらない。
        let moved = Fixture.event("a", start: start.addingTimeInterval(3600))
        XCTAssertEqual(moved.key, event.key, "開始時刻を動かしても同一の予定として識別される")

        let second = detector.detectChanges(events: [moved], snapshots: first.updated, now: now)

        XCTAssertEqual(second.updated[event.key]?.editCount, 1)
        XCTAssertEqual(second.updated[event.key]?.startDate, start.addingTimeInterval(3600))
        XCTAssertEqual(second.changed, [event.key])
    }

    func testEndDateChangeCountsAsOneEdit() {
        let event = Fixture.event("a", start: start, durationMinutes: 60)
        let first = detector.detectChanges(events: [event], snapshots: [:], now: now)

        // 開始時刻はそのままで終了時刻だけ伸ばす。
        let extended = Fixture.event("a", start: start, durationMinutes: 120)
        let second = detector.detectChanges(events: [extended], snapshots: first.updated, now: now)

        XCTAssertEqual(second.updated[event.key]?.editCount, 1)
        XCTAssertEqual(second.updated[event.key]?.endDate, extended.endDate)
        XCTAssertEqual(second.changed, [event.key])
    }

    /// 同時に複数項目が変わっても編集は1回。
    func testSimultaneousStartAndLocationChangeCountsAsOneEdit() {
        let event = Fixture.event("a", start: start, location: Fixture.tokyo)
        let first = detector.detectChanges(events: [event], snapshots: [:], now: now)

        let moved = Fixture.event(
            "a",
            start: start.addingTimeInterval(3600),
            location: Fixture.shinjuku
        )
        let second = detector.detectChanges(events: [moved], snapshots: first.updated, now: now)

        XCTAssertEqual(second.updated[event.key]?.editCount, 1)
    }

    func testThreeSuccessiveChangesCountAsThreeEdits() {
        let event = Fixture.event("a", start: start)
        var snapshots = detector.detectChanges(events: [event], snapshots: [:], now: now).updated

        for offset in 1...3 {
            let moved = Fixture.event(
                "a",
                start: start.addingTimeInterval(TimeInterval(offset) * 600)
            )
            snapshots = detector.detectChanges(events: [moved], snapshots: snapshots, now: now).updated
        }

        XCTAssertEqual(snapshots[event.key]?.editCount, 3)
    }

    /// 完了後は凍結。値も編集回数も更新しない。
    func testCompletedSnapshotIsFrozen() {
        let event = Fixture.event("a", start: start)
        let afterStart = start.addingTimeInterval(60)
        let first = detector.detectChanges(events: [event], snapshots: [:], now: afterStart)
        XCTAssertTrue(first.updated[event.key]?.isCompleted ?? false)
        XCTAssertEqual(first.updated[event.key]?.completedAt, afterStart)

        let moved = Fixture.event("a", start: start.addingTimeInterval(7200))
        let second = detector.detectChanges(
            events: [moved],
            snapshots: first.updated,
            now: afterStart.addingTimeInterval(60)
        )

        XCTAssertEqual(second.updated[event.key]?.editCount, 0)
        XCTAssertEqual(second.updated[event.key]?.startDate, start, "完了後は startDate も更新されない")
        XCTAssertEqual(second.updated[event.key]?.completedAt, afterStart, "completedAt も動かない")
        XCTAssertTrue(second.changed.isEmpty)
    }

    func testUncompletedEventRemovedExternallyIsReportedAsDeleted() {
        let event = Fixture.event("a", start: start)
        let first = detector.detectChanges(events: [event], snapshots: [:], now: now)

        let second = detector.detectChanges(events: [], snapshots: first.updated, now: now)

        XCTAssertEqual(second.deleted, [event.key])
        XCTAssertNil(second.updated[event.key])
    }

    func testCompletedEventRemovedExternallyKeepsItsSnapshot() {
        let event = Fixture.event("a", start: start)
        let afterStart = start.addingTimeInterval(60)
        let first = detector.detectChanges(events: [event], snapshots: [:], now: afterStart)

        let second = detector.detectChanges(events: [], snapshots: first.updated, now: afterStart)

        XCTAssertTrue(second.deleted.isEmpty)
        XCTAssertNotNil(second.updated[event.key])
    }

    func testLocationAppearingCountsAsOneEdit() {
        let event = Fixture.event("a", start: start, location: nil)
        let first = detector.detectChanges(events: [event], snapshots: [:], now: now)
        XCTAssertNil(first.updated[event.key]?.latitude)

        let located = Fixture.event("a", start: start, location: Fixture.tokyo)
        let second = detector.detectChanges(events: [located], snapshots: first.updated, now: now)

        XCTAssertEqual(second.updated[event.key]?.editCount, 1)
        XCTAssertEqual(second.updated[event.key]?.latitude, Fixture.tokyo.latitude)
    }

    func testLocationDisappearingCountsAsOneEdit() {
        let event = Fixture.event("a", start: start, location: Fixture.tokyo)
        let first = detector.detectChanges(events: [event], snapshots: [:], now: now)

        let cleared = Fixture.event("a", start: start, location: nil)
        let second = detector.detectChanges(events: [cleared], snapshots: first.updated, now: now)

        XCTAssertEqual(second.updated[event.key]?.editCount, 1)
        XCTAssertNil(second.updated[event.key]?.latitude)
    }

    /// 繰り返し予定。eventIdentifier が同じでも occurrenceDate が違えば別のスナップショットになる。
    func testRecurringOccurrencesTrackEditsIndependently() {
        let firstOccurrence = Fixture.date(2026, 9, 1, 10, 0)
        let secondOccurrence = Fixture.date(2026, 9, 8, 10, 0)
        let occurrence1 = Fixture.recurringEvent("recurring", occurrence: firstOccurrence)
        let occurrence2 = Fixture.recurringEvent("recurring", occurrence: secondOccurrence)

        XCTAssertNotEqual(occurrence1.key, occurrence2.key)
        XCTAssertEqual(occurrence1.key.eventIdentifier, occurrence2.key.eventIdentifier)

        var snapshots = detector.detectChanges(
            events: [occurrence1, occurrence2],
            snapshots: [:],
            now: now
        ).updated
        XCTAssertEqual(snapshots.count, 2)

        // 1回目だけ時刻を動かす。occurrenceDate は動かさないのでキーは同じまま。
        let movedFirst = Fixture.recurringEvent(
            "recurring",
            occurrence: firstOccurrence,
            start: firstOccurrence.addingTimeInterval(1800)
        )
        XCTAssertEqual(movedFirst.key, occurrence1.key)

        snapshots = detector.detectChanges(
            events: [movedFirst, occurrence2],
            snapshots: snapshots,
            now: now
        ).updated

        XCTAssertEqual(snapshots[occurrence1.key]?.editCount, 1)
        XCTAssertEqual(snapshots[occurrence2.key]?.editCount, 0, "もう片方の回には影響しない")
    }

    /// 単発予定のキーには時刻が入らない。
    func testSingleEventKeyIgnoresStartDate() {
        let morning = Fixture.event("a", start: Fixture.date(2026, 9, 1, 9, 0))
        let evening = Fixture.event("a", start: Fixture.date(2026, 9, 1, 19, 0))

        XCTAssertEqual(morning.key, evening.key)
        XCTAssertNil(morning.key.occurrenceDate)
    }

    /// 支援を送信済みかどうかは変更検知では触らない。枠の解放の判定用に持ち回るだけ。
    func testSupportSentAtIsPreservedAcrossUpdates() {
        let event = Fixture.event("a", start: start)
        var snapshot = EventSnapshot(event: event)
        snapshot.supportSentAt = Fixture.date(2026, 9, 1, 7, 0)

        let moved = Fixture.event("a", start: start.addingTimeInterval(3600))
        let result = detector.detectChanges(events: [moved], snapshots: [event.key: snapshot], now: now)

        XCTAssertEqual(result.updated[event.key]?.editCount, 1)
        XCTAssertEqual(result.updated[event.key]?.supportSentAt, Fixture.date(2026, 9, 1, 7, 0))
    }
}
