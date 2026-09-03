import Foundation

/// その日にサポートする予定（枠）を確定する。
///
/// 枠は2段階で決まる。
/// - 第1段階（前日まで）: 開始時刻の早い順に上位 N 件を確定する。
/// - 第2段階（確定後）  : 空き枠がある場合に限り、登録順で追加する。既存の枠は押し出さない。
public struct SlotConfirmer {
    /// 枠の解放の内訳。第2段階の計算をそのまま外へ出したもの。
    ///
    /// `CalendarLayer` が「あと何件ジオコーディングすべきか」を決めるのにも使うので、
    /// 同じ計算が2か所に分かれないよう公開している。
    public struct SlotAccounting: Equatable {
        /// 引き続き枠を持ち続けるキー。
        public let keptKeys: [EventKey]
        /// 支援を送信済みのまま消えたため、返せない枠の累計。
        public let supportSentSlotCount: Int
        /// 第2段階で追加できる件数。
        public let additionBudget: Int
    }

    private let calendar: Calendar
    /// 無料版の1日あたりの枠数。
    public let freeSlotLimit: Int

    public init(calendar: Calendar, freeSlotLimit: Int = 3) {
        self.calendar = calendar
        self.freeSlotLimit = freeSlotLimit
    }

    /// 予定が対象日に重なるか。開始日だけでなく、予定が存在する全ての日で真になる。
    ///
    /// 例: 9/1 23:30 〜 9/2 2:00 の予定は 9/1 の枠も 9/2 の枠も1つずつ消費する。
    public static func overlaps(_ event: CalendarEvent, targetDate: Date, calendar: Calendar) -> Bool {
        let dayStart = calendar.startOfDay(for: targetDate)
        guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else { return false }
        return event.startDate < dayEnd && event.endDate > dayStart
    }

    public func overlaps(_ event: CalendarEvent, targetDate: Date) -> Bool {
        Self.overlaps(event, targetDate: targetDate, calendar: calendar)
    }

    /// 枠の解放を計算する。
    ///
    /// - Parameters:
    ///   - current: 保存済みの枠。
    ///   - presentKeys: いまカレンダーに存在し、対象日の枠候補になれるキー。
    ///   - supportSentKeys: 既に支援を送信した予定のキー。
    ///   - limit: その日の枠数。
    public func accounting(
        current: DailySlots,
        presentKeys: Set<EventKey>,
        supportSentKeys: Set<EventKey>,
        limit: Int
    ) -> SlotAccounting {
        let kept = current.confirmedKeys.filter { presentKeys.contains($0) }
        // 消えた予定のうち、支援を送信済みだったものの枠は返さない。
        // 送信前に消えたものの枠はそのまま次の予定に回す。
        let unreturnable = current.confirmedKeys.filter {
            !presentKeys.contains($0) && supportSentKeys.contains($0)
        }
        let supportSent = current.supportSentSlotCount + unreturnable.count

        let budget: Int
        if limit == Int.max {
            budget = Int.max
        } else {
            budget = max(0, limit - kept.count - supportSent)
        }

        return SlotAccounting(keptKeys: kept, supportSentSlotCount: supportSent, additionBudget: budget)
    }

    /// - Parameters:
    ///   - slotEligible: 座標解決を通過した予定（LocationResolver の結果）。
    ///   - registrationOrdered: 同じ集合を登録順（creationDate 昇順）に並べたもの。
    ///   - current: 保存済みの枠。無ければ nil。
    ///   - targetDate: 対象日。
    ///   - now: 現在時刻。
    ///   - isPremium: Premium なら枠数は無制限。
    ///   - supportSentKeys: 既に支援を送信した予定のキー。枠を返すかどうかの判定に使う。
    public func confirmSlots(
        slotEligible: [CalendarEvent],
        registrationOrdered: [CalendarEvent],
        current: DailySlots?,
        targetDate: Date,
        now: Date,
        isPremium: Bool,
        supportSentKeys: Set<EventKey> = []
    ) -> DailySlots {
        let dayStart = calendar.startOfDay(for: targetDate)
        let limit = isPremium ? Int.max : freeSlotLimit

        // 対象外: 終日予定、対象日に重ならない予定。
        // 座標が恒久的に解決できなかった予定は slotEligible の時点で除外されている。
        let eligible = slotEligible.filter { !$0.isAllDay && overlaps($0, targetDate: dayStart) }
        let eligibleKeys = Set(eligible.map(\.key))

        // Premium は段階分けを適用せず、対象予定すべてを枠に入れる。
        if isPremium {
            let keys = eligible.sorted(by: CalendarEvent.isOrderedBefore).map(\.key)
            return DailySlots(
                date: dayStart,
                confirmedKeys: keys,
                confirmedAt: current?.confirmedAt ?? now,
                slotLimit: Int.max,
                supportSentSlotCount: 0
            )
        }

        guard let current, let confirmedAt = current.confirmedAt else {
            return firstStage(eligible: eligible, dayStart: dayStart, now: now, limit: limit)
        }

        return secondStage(
            current: current,
            confirmedAt: confirmedAt,
            eligibleKeys: eligibleKeys,
            supportSentKeys: supportSentKeys,
            registrationOrdered: registrationOrdered,
            dayStart: dayStart,
            limit: limit
        )
    }

    // MARK: - 第1段階（開始時刻順）

    private func firstStage(
        eligible: [CalendarEvent],
        dayStart: Date,
        now: Date,
        limit: Int
    ) -> DailySlots {
        var pool = eligible

        // 前日にアプリを開かなかった場合の救済。
        // 対象日が今日なら、既に開始してしまった予定は枠から外す。これが無いと 14:00 に
        // 起動したとき 9:00 / 11:00 / 13:00 が枠を埋め、しかも完了済みの予定は枠を解放
        // しないため、その日は一切サポートが機能しなくなる。
        if calendar.isDate(dayStart, inSameDayAs: now) {
            pool = pool.filter { $0.startDate >= now }
        }

        let keys = pool
            .sorted(by: CalendarEvent.isOrderedBefore)
            .prefix(limit)
            .map(\.key)

        return DailySlots(
            date: dayStart,
            confirmedKeys: Array(keys),
            confirmedAt: now,
            slotLimit: limit,
            supportSentSlotCount: 0
        )
    }

    // MARK: - 第2段階（登録順）

    private func secondStage(
        current: DailySlots,
        confirmedAt: Date,
        eligibleKeys: Set<EventKey>,
        supportSentKeys: Set<EventKey>,
        registrationOrdered: [CalendarEvent],
        dayStart: Date,
        limit: Int
    ) -> DailySlots {
        // 枠の解放。取得結果から消えた予定（外部で削除された／別の日に移動した）を外す。
        // 完了済みの予定は取得結果に残り続けるので、ここで外れることはない。
        let accounting = accounting(
            current: current,
            presentKeys: eligibleKeys,
            supportSentKeys: supportSentKeys,
            limit: limit
        )

        var confirmed = accounting.keptKeys
        if accounting.additionBudget > 0 {
            var taken = Set(confirmed)
            var added = 0
            for event in registrationOrdered {
                guard added < accounting.additionBudget else { break }
                guard eligibleKeys.contains(event.key), !taken.contains(event.key) else { continue }
                confirmed.append(event.key)
                taken.insert(event.key)
                added += 1
            }
        }

        return DailySlots(
            date: dayStart,
            confirmedKeys: confirmed,
            confirmedAt: confirmedAt,
            slotLimit: limit,
            supportSentSlotCount: accounting.supportSentSlotCount
        )
    }
}
