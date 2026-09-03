import XCTest
@testable import CatCore

final class SlotConfirmerTests: XCTestCase {
    private let confirmer = SlotConfirmer(calendar: Fixture.calendar)
    private let today = Fixture.date(2026, 9, 1)
    private let tomorrow = Fixture.date(2026, 9, 2)
    /// 対象日の前日。第1段階が「前日までの確定」として走るようにするための現在時刻。
    private let previousEvening = Fixture.date(2026, 8, 31, 20, 0)

    private func at(_ hour: Int, _ minute: Int = 0, day: Int = 1) -> Date {
        Fixture.date(2026, 9, day, hour, minute)
    }

    private func confirm(
        eligible: [CalendarEvent],
        registrationOrdered: [CalendarEvent]? = nil,
        current: DailySlots? = nil,
        targetDate: Date? = nil,
        now: Date? = nil,
        isPremium: Bool = false,
        supportSentKeys: Set<EventKey> = []
    ) -> DailySlots {
        confirmer.confirmSlots(
            slotEligible: eligible,
            registrationOrdered: registrationOrdered ?? eligible,
            current: current,
            targetDate: targetDate ?? today,
            now: now ?? previousEvening,
            isPremium: isPremium,
            supportSentKeys: supportSentKeys
        )
    }

    private func identifiers(_ slots: DailySlots) -> [String] {
        slots.confirmedKeys.map(\.eventIdentifier)
    }

    // MARK: - 第1段階

    func testFirstStageTakesThreeEarliestOfFour() {
        let events = [
            Fixture.event("d", start: at(15)),
            Fixture.event("a", start: at(9)),
            Fixture.event("c", start: at(13)),
            Fixture.event("b", start: at(11))
        ]

        let slots = confirm(eligible: events)

        XCTAssertEqual(identifiers(slots), ["a", "b", "c"])
        XCTAssertEqual(slots.confirmedAt, previousEvening)
        XCTAssertEqual(slots.slotLimit, 3)
    }

    func testSameStartTimeIsBrokenByEventIdentifierAscending() {
        let events = [
            Fixture.event("z", start: at(10)),
            Fixture.event("m", start: at(10)),
            Fixture.event("a", start: at(10)),
            Fixture.event("x", start: at(9))
        ]

        let slots = confirm(eligible: events)

        XCTAssertEqual(identifiers(slots), ["x", "a", "m"])
    }

    /// 前日にアプリを開かなかった場合の救済。
    func testFirstStageOnTheDayItselfSkipsEventsThatAlreadyStarted() {
        let now = at(14)
        let events = [
            Fixture.event("morning", start: at(9)),
            Fixture.event("late-morning", start: at(11)),
            Fixture.event("afternoon", start: at(15)),
            Fixture.event("evening", start: at(18))
        ]

        let slots = confirm(eligible: events, now: now)

        XCTAssertEqual(identifiers(slots), ["afternoon", "evening"])
        XCTAssertFalse(identifiers(slots).contains("morning"))
        XCTAssertFalse(identifiers(slots).contains("late-morning"))
    }

    // MARK: - 第2段階

    func testFourthEventIsRejectedWhenAllThreeSlotsAreTaken() {
        let confirmed = [
            Fixture.event("a", start: at(9)),
            Fixture.event("b", start: at(11)),
            Fixture.event("c", start: at(13))
        ]
        let first = confirm(eligible: confirmed)

        let added = Fixture.event("d", start: at(15))
        let second = confirm(eligible: confirmed + [added], current: first, now: at(8))

        XCTAssertEqual(identifiers(second), ["a", "b", "c"])
    }

    func testThirdEventIsAcceptedWhenOneSlotWasNeverFilled() {
        let confirmed = [
            Fixture.event("a", start: at(9)),
            Fixture.event("b", start: at(11))
        ]
        let first = confirm(eligible: confirmed)
        XCTAssertEqual(identifiers(first), ["a", "b"])

        let added = Fixture.event("c", start: at(13))
        let second = confirm(eligible: confirmed + [added], current: first, now: at(8))

        XCTAssertEqual(identifiers(second), ["a", "b", "c"])
    }

    /// 既に確定した枠を押し出さない。
    func testEarlierEventAddedAfterConfirmationDoesNotDisplaceExistingSlots() {
        let confirmed = [
            Fixture.event("b", start: at(10)),
            Fixture.event("c", start: at(11)),
            Fixture.event("d", start: at(12))
        ]
        let first = confirm(eligible: confirmed)

        let earlier = Fixture.event("a", start: at(9))
        let second = confirm(
            eligible: [earlier] + confirmed,
            registrationOrdered: confirmed + [earlier],
            current: first,
            now: at(8)
        )

        XCTAssertEqual(identifiers(second), ["b", "c", "d"])
    }

    func testSecondStageAddsInRegistrationOrder() {
        let confirmed = [
            Fixture.event("a", start: at(9)),
            Fixture.event("b", start: at(11))
        ]
        let first = confirm(eligible: confirmed)

        // 開始時刻は early のほうが早いが、登録は late のほうが先。
        let early = Fixture.event("early", start: at(12), creationDate: Fixture.date(2026, 8, 30, 12, 0))
        let late = Fixture.event("late", start: at(13), creationDate: Fixture.date(2026, 8, 30, 9, 0))
        let candidates = confirmed + [early, late]
        let byRegistration = candidates.sorted(by: CalendarEvent.isOrderedByRegistrationBefore)

        let second = confirm(
            eligible: candidates,
            registrationOrdered: byRegistration,
            current: first,
            now: at(8)
        )

        XCTAssertEqual(identifiers(second), ["a", "b", "late"], "登録が先の late が空き枠を取る")
    }

    // MARK: - 枠の解放

    func testDeletingAConfirmedEventFreesItsSlot() {
        let events = [
            Fixture.event("a", start: at(9)),
            Fixture.event("b", start: at(11)),
            Fixture.event("c", start: at(13))
        ]
        let first = confirm(eligible: events)

        // b が外部で削除された。
        let second = confirm(eligible: [events[0], events[2]], current: first, now: at(8))

        XCTAssertEqual(identifiers(second), ["a", "c"])
        XCTAssertEqual(second.confirmedKeys.count, 2)
    }

    /// 支援を送る前に消えた予定の枠は、次の予定に回す。
    func testSlotIsReturnedWhenTheEventDisappearsBeforeSupportWasSent() {
        let confirmed = [
            Fixture.event("a", start: at(9)),
            Fixture.event("b", start: at(11)),
            Fixture.event("c", start: at(13))
        ]
        let waiting = Fixture.event("d", start: at(15))
        let first = confirm(eligible: confirmed + [waiting])
        XCTAssertEqual(identifiers(first), ["a", "b", "c"])

        // b が削除される。b にはまだ支援を送っていない。
        let remaining = [confirmed[0], confirmed[2], waiting]
        let second = confirm(eligible: remaining, current: first, now: at(8))

        XCTAssertEqual(identifiers(second), ["a", "c", "d"], "空いた枠が d に回る")
        XCTAssertEqual(second.supportSentSlotCount, 0)
    }

    /// 支援を送ったあとに消えた予定の枠は返さない。送信済みの通知は取り消せないので、
    /// 1日の上限を消費したものとして数える。
    func testSlotIsNotReturnedWhenTheEventDisappearsAfterSupportWasSent() {
        let confirmed = [
            Fixture.event("a", start: at(9)),
            Fixture.event("b", start: at(11)),
            Fixture.event("c", start: at(13))
        ]
        let waiting = Fixture.event("d", start: at(15))
        let first = confirm(eligible: confirmed + [waiting])

        // b に支援を送信済みの状態で b が削除される。
        let remaining = [confirmed[0], confirmed[2], waiting]
        let second = confirm(
            eligible: remaining,
            current: first,
            now: at(8),
            supportSentKeys: [confirmed[1].key]
        )

        XCTAssertEqual(identifiers(second), ["a", "c"], "d は繰り上がらない")
        XCTAssertEqual(second.supportSentSlotCount, 1)

        // 次の起動でも繰り上がらない。
        let third = confirm(eligible: remaining, current: second, now: at(8, 30))
        XCTAssertEqual(identifiers(third), ["a", "c"])
        XCTAssertEqual(third.supportSentSlotCount, 1)
    }

    /// 完了しても枠は解放しない。これが無いと1日に何件でもサポートされてしまう。
    func testCompletedEventsKeepTheirSlots() {
        let events = [
            Fixture.event("a", start: at(9)),
            Fixture.event("b", start: at(10)),
            Fixture.event("c", start: at(11))
        ]
        let first = confirm(eligible: events)

        // 3件とも開始済みの時刻に4件目を追加する。予定自体はカレンダーに残り続ける。
        let added = Fixture.event("d", start: at(18))
        let second = confirm(eligible: events + [added], current: first, now: at(12))

        XCTAssertEqual(identifiers(second), ["a", "b", "c"])
        XCTAssertFalse(identifiers(second).contains("d"))
    }

    func testEventMovedToAnotherDayLosesItsSlot() {
        let events = [
            Fixture.event("a", start: at(9)),
            Fixture.event("b", start: at(11))
        ]
        let first = confirm(eligible: events)

        // b が翌日に移動した（対象日に重ならなくなった）。
        let moved = Fixture.event("b", start: at(11, 0, day: 2), key: events[1].key)
        let second = confirm(eligible: [events[0], moved], current: first, now: at(8))

        XCTAssertEqual(identifiers(second), ["a"])
    }

    // MARK: - 対象から外れるもの

    func testEventWithoutResolvableCoordinatesDoesNotConsumeASlot() {
        let resolvable = [
            Fixture.event("b", start: at(10), locationText: "東京駅", location: Fixture.tokyo),
            Fixture.event("c", start: at(11), locationText: "新宿駅", location: Fixture.shinjuku)
        ]
        // "a" は .permanentFailure だったので slotEligible に含まれない。
        let slots = confirm(eligible: resolvable)

        XCTAssertEqual(identifiers(slots), ["b", "c"])
    }

    /// オフラインで一度失敗しただけの予定を締め出さない。
    func testTemporaryFailureEventStillTakesASlot() {
        let temporary = Fixture.event("offline", start: at(9), locationText: "東京駅", location: nil)
        let slots = confirm(eligible: [temporary, Fixture.event("b", start: at(10), location: Fixture.tokyo)])

        XCTAssertEqual(identifiers(slots), ["offline", "b"])
    }

    func testAllDayEventDoesNotConsumeASlot() {
        let events = [
            Fixture.allDayEvent("allday", day: today),
            Fixture.event("a", start: at(9)),
            Fixture.event("b", start: at(11)),
            Fixture.event("c", start: at(13)),
            Fixture.event("d", start: at(15))
        ]

        let slots = confirm(eligible: events)

        XCTAssertEqual(identifiers(slots), ["a", "b", "c"])
    }

    /// 繰り返し予定の各回は occurrenceDate で区別され、それぞれ枠を消費する。
    func testRecurringOccurrencesOnTheSameDayTakeSeparateSlots() {
        let morning = Fixture.recurringEvent("standup", occurrence: at(9))
        let afternoon = Fixture.recurringEvent("standup", occurrence: at(14))
        let evening = Fixture.recurringEvent("standup", occurrence: at(18))

        let slots = confirm(eligible: [morning, afternoon, evening])

        XCTAssertEqual(slots.confirmedKeys.count, 3, "同じ eventIdentifier でも別々の枠を取る")
        XCTAssertEqual(
            slots.confirmedKeys.map(\.occurrenceDate),
            [at(9), at(14), at(18)]
        )
    }

    func testPremiumTakesEveryEvent() {
        let events = (9...15).map { Fixture.event("e\($0)", start: at($0)) }

        let slots = confirm(eligible: events, isPremium: true)

        XCTAssertEqual(slots.confirmedKeys.count, events.count)
        XCTAssertEqual(slots.slotLimit, Int.max)
    }

    // MARK: - 日跨ぎ予定

    private var crossingEvent: CalendarEvent {
        Fixture.event(
            "crossing",
            start: Fixture.date(2026, 9, 1, 23, 30),
            end: Fixture.date(2026, 9, 2, 2, 0)
        )
    }

    func testEventCrossingMidnightConsumesASlotOnItsStartDay() {
        let slots = confirm(eligible: [crossingEvent], targetDate: today)

        XCTAssertEqual(identifiers(slots), ["crossing"])
    }

    func testEventCrossingMidnightAlsoConsumesASlotOnTheNextDay() {
        let slots = confirm(eligible: [crossingEvent], targetDate: tomorrow)

        XCTAssertEqual(identifiers(slots), ["crossing"])
    }

    func testCrossingEventLeavesOnlyTwoSlotsForTheNextDay() {
        let daytime = [
            Fixture.event("a", start: at(10, 0, day: 2)),
            Fixture.event("b", start: at(12, 0, day: 2)),
            Fixture.event("c", start: at(14, 0, day: 2))
        ]

        let slots = confirm(
            eligible: [crossingEvent] + daytime,
            targetDate: tomorrow,
            now: Fixture.date(2026, 9, 1, 20, 0)
        )

        XCTAssertEqual(identifiers(slots), ["crossing", "a", "b"])
        XCTAssertEqual(slots.confirmedKeys.count, 3)
    }

    func testEventEndingBeforeMidnightDoesNotConsumeTheNextDaysSlot() {
        let event = Fixture.event(
            "late",
            start: Fixture.date(2026, 9, 1, 22, 0),
            end: Fixture.date(2026, 9, 1, 23, 0)
        )

        let slots = confirm(eligible: [event], targetDate: tomorrow)

        XCTAssertTrue(slots.confirmedKeys.isEmpty)
    }

    func testOverlapsHelperMatchesEveryDayTheEventSpans() {
        let calendar = Fixture.calendar
        XCTAssertTrue(SlotConfirmer.overlaps(crossingEvent, targetDate: today, calendar: calendar))
        XCTAssertTrue(SlotConfirmer.overlaps(crossingEvent, targetDate: tomorrow, calendar: calendar))
        XCTAssertFalse(
            SlotConfirmer.overlaps(crossingEvent, targetDate: Fixture.date(2026, 9, 3), calendar: calendar)
        )
    }
}
