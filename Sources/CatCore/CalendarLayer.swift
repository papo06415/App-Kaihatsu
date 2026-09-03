import Foundation

/// アプリ起動時に1回走らせるカレンダー層の実行結果。
public struct LaunchResult: Equatable {
    /// 今日に重なる予定（終日予定も含む）。開始時刻順。
    public let todayEvents: [CalendarEvent]
    public let todaySlots: DailySlots
    public let tomorrowSlots: DailySlots
    /// 今日の予定どうしの重複。
    public let conflicts: [EventConflict]
    // 以下のキー配列はいずれも「今日」を対象にしたもの（todayEvents / conflicts と同じ範囲）。
    // 翌日ぶんは tomorrowSlots から後続フェーズで導出する。

    /// 無料版で editCount >= 上限に達した予定。
    public let editLimitExceededKeys: [EventKey]
    /// 枠に入らなかった予定。
    public let outOfSlotKeys: [EventKey]
    /// 座標が解決できなかった予定。
    public let noLocationKeys: [EventKey]
    /// 終日予定。
    public let allDayKeys: [EventKey]
    /// 前日以前から続く日跨ぎ予定。枠は消費するが、出発時刻の計算と通知は開始日にのみ行う。
    public let carriedOverKeys: [EventKey]

    public init(
        todayEvents: [CalendarEvent],
        todaySlots: DailySlots,
        tomorrowSlots: DailySlots,
        conflicts: [EventConflict],
        editLimitExceededKeys: [EventKey],
        outOfSlotKeys: [EventKey],
        noLocationKeys: [EventKey],
        allDayKeys: [EventKey],
        carriedOverKeys: [EventKey]
    ) {
        self.todayEvents = todayEvents
        self.todaySlots = todaySlots
        self.tomorrowSlots = tomorrowSlots
        self.conflicts = conflicts
        self.editLimitExceededKeys = editLimitExceededKeys
        self.outOfSlotKeys = outOfSlotKeys
        self.noLocationKeys = noLocationKeys
        self.allDayKeys = allDayKeys
        self.carriedOverKeys = carriedOverKeys
    }
}

/// カレンダー層の統合。依存するのはプロトコルだけなので、モックを差し込めば Linux でテストできる。
public struct CalendarLayer {
    private let source: CalendarSource
    private let geocoder: GeocodingService
    private let repository: Repository
    private let calendar: Calendar

    private let completion: CompletionEvaluator
    private let changeDetector: ChangeDetector
    private let locationResolver: LocationResolver
    private let slotConfirmer: SlotConfirmer
    private let conflictDetector: ConflictDetector
    private let retention: RetentionPolicy

    /// 無料版の1日あたりの枠数。
    public let freeSlotLimit: Int
    /// 無料版の編集回数の上限。
    public let freeEditLimit: Int
    /// 取得範囲（過去）。
    public let fetchPastDays: Int
    /// 取得範囲（未来）。
    public let fetchFutureDays: Int

    public init(
        source: CalendarSource,
        geocoder: GeocodingService,
        repository: Repository,
        calendar: Calendar,
        freeSlotLimit: Int = 3,
        freeEditLimit: Int = 3,
        fetchPastDays: Int = 3,
        fetchFutureDays: Int = 30,
        locationResolver: LocationResolver = LocationResolver(),
        retention: RetentionPolicy? = nil
    ) {
        self.source = source
        self.geocoder = geocoder
        self.repository = repository
        self.calendar = calendar
        self.freeSlotLimit = freeSlotLimit
        self.freeEditLimit = freeEditLimit
        self.fetchPastDays = fetchPastDays
        self.fetchFutureDays = fetchFutureDays
        self.completion = CompletionEvaluator()
        self.changeDetector = ChangeDetector()
        self.locationResolver = locationResolver
        self.slotConfirmer = SlotConfirmer(calendar: calendar, freeSlotLimit: freeSlotLimit)
        self.conflictDetector = ConflictDetector()
        self.retention = retention ?? RetentionPolicy(calendar: calendar)
    }

    public func refreshOnLaunch(now: Date = Date()) async throws -> LaunchResult {
        // 1. 権限を確認する。
        switch source.authorizationStatus() {
        case .authorized:
            break
        case .writeOnly:
            throw CalendarLayerError.calendarAccessWriteOnly
        case .denied:
            throw CalendarLayerError.calendarAccessDenied
        case .notDetermined:
            throw CalendarLayerError.calendarAccessNotDetermined
        }

        // 2. 保存済みデータを読み込む。
        var snapshots = repository.loadSnapshots()
        var slots = repository.loadSlots()
        var geocodeCache = repository.loadGeocodeCache()
        let preferences = repository.loadPreferences()

        // 3. 期限切れデータを削除する。
        snapshots = retention.pruneSnapshots(snapshots, now: now)
        slots = retention.pruneSlots(slots, now: now)
        geocodeCache = retention.pruneGeocodeCache(geocodeCache, now: now)

        // 4. 予定を取得する（3日前 〜 30日後）。
        let today = calendar.startOfDay(for: now)
        let tomorrow = addingDays(1, to: today)
        let rangeStart = addingDays(-fetchPastDays, to: today)
        let rangeEnd = addingDays(fetchFutureDays + 1, to: today)
        // fetchEvents が返した順を「登録順」として扱う（EventKit は作成日時を CalendarEvent に
        // 持たせていないため。README の「判断に迷った箇所」を参照）。
        let fetched = try source.fetchEvents(from: rangeStart, to: rangeEnd)

        let slotLimit = preferences.isPremium ? Int.max : freeSlotLimit
        // 枠を返すかどうかの判定に使う。支援を送る前に消えた予定の枠は次の予定に回す。
        let supportSentKeys = Set(snapshots.filter { $0.value.supportSentAt != nil }.keys)

        // 5. 今日と翌日それぞれについて座標を解決し、枠を確定する。
        var resolvedByKey: [EventKey: CalendarEvent] = [:]
        var noLocationKeys: [EventKey] = []
        var outOfSlotKeys: [EventKey] = []
        var carriedOverKeys: [EventKey] = []
        var trackedKeys: [EventKey] = []
        var allDayKeys: [EventKey] = []

        for day in [today, tomorrow] {
            let isToday = day == today
            let overlapping = fetched.filter { SlotConfirmer.overlaps($0, targetDate: day, calendar: calendar) }
            if isToday {
                allDayKeys.append(contentsOf: overlapping.filter(\.isAllDay).map(\.key))
            }

            let existing = slots[day]
            var candidates = overlapping
                .filter { !$0.isAllDay }
                .map { resolvedByKey[$0.key] ?? $0 }
                .sorted(by: CalendarEvent.isOrderedBefore)

            // 第1段階を今日に対して実行する場合は、既に開始した予定を先に落とす。
            // SlotConfirmer と同じ条件。ここで落としておかないとジオコーディングの
            // 呼び出し枠を、枠に入れない予定に使い切ってしまう。
            if existing?.confirmedAt == nil,
               calendar.isDate(day, inSameDayAs: now),
               !preferences.isPremium {
                candidates = candidates.filter { $0.startDate >= now }
            }

            if isToday {
                trackedKeys.append(contentsOf: candidates.map(\.key))
            }

            let outcome = await resolve(
                candidates: candidates,
                existing: existing,
                slotLimit: slotLimit,
                supportSentKeys: supportSentKeys,
                cache: &geocodeCache,
                now: now
            )
            for event in outcome.resolved {
                resolvedByKey[event.key] = event
            }
            if isToday {
                noLocationKeys.append(contentsOf: outcome.attempted.filter { resolvedByKey[$0]?.location == nil })
            }

            // 枠の判定に渡す集合。解決を試みるところまで到達しなかった予定でも、
            // 既に枠を持っていてカレンダーにも残っているなら枠を手放させない。
            var eligibleKeys = outcome.eligible
            let present = Set(candidates.map(\.key))
            let seen = Set(eligibleKeys)
            for key in existing?.confirmedKeys ?? [] where present.contains(key) && !seen.contains(key) {
                eligibleKeys.append(key)
            }
            let eligibleSet = Set(eligibleKeys)

            let eligibleEvents = candidates.filter { eligibleSet.contains($0.key) }
                .map { resolvedByKey[$0.key] ?? $0 }
            // 第2段階の追加順。カレンダーに登録された順に並べる。
            let registrationOrdered = eligibleEvents.sorted(by: CalendarEvent.isOrderedByRegistrationBefore)

            let confirmed = slotConfirmer.confirmSlots(
                slotEligible: eligibleEvents,
                registrationOrdered: registrationOrdered,
                current: existing,
                targetDate: day,
                now: now,
                isPremium: preferences.isPremium,
                supportSentKeys: supportSentKeys
            )
            slots[day] = confirmed

            guard isToday else { continue }
            let confirmedSet = Set(confirmed.confirmedKeys)
            outOfSlotKeys.append(contentsOf: candidates.map(\.key).filter { !confirmedSet.contains($0) })
            // 日跨ぎの判定は「今の開始時刻」で行う。EventKey.startDate は識別子であって
            // 予定が動いても変わらないため、そちらを使ってはいけない。
            carriedOverKeys.append(contentsOf: confirmed.confirmedKeys.filter { key in
                guard let event = resolvedByKey[key] else { return false }
                return !calendar.isDate(event.startDate, inSameDayAs: day)
            })
        }

        // 6. 変更を検知し、スナップショットを更新する。
        //    取得範囲の外にあるスナップショットは「取得結果に無い」だけで削除されたわけでは
        //    ないので、判定から外して手を触れない。
        let events = fetched.map { resolvedByKey[$0.key] ?? $0 }
        let inRange = snapshots.filter { $0.value.startDate >= rangeStart && $0.value.startDate < rangeEnd }
        let outOfRange = snapshots.filter { !($0.value.startDate >= rangeStart && $0.value.startDate < rangeEnd) }
        let detection = changeDetector.detectChanges(events: events, snapshots: inRange, now: now)
        snapshots = outOfRange.merging(detection.updated) { _, updated in updated }

        // 7. 重複を検知する（今日の全予定が対象）。
        let todayEvents = events
            .filter { SlotConfirmer.overlaps($0, targetDate: today, calendar: calendar) }
            .sorted(by: CalendarEvent.isOrderedBefore)
        let conflicts = conflictDetector.detectConflicts(in: todayEvents)

        // 8. データを保存する。
        try repository.saveSnapshots(snapshots)
        try repository.saveSlots(slots)
        try repository.saveGeocodeCache(geocodeCache)

        // 9. 結果を返す。
        let editLimitExceededKeys: [EventKey] = preferences.isPremium ? [] : trackedKeys.filter { key in
            (snapshots[key]?.editCount ?? 0) >= freeEditLimit
        }

        return LaunchResult(
            todayEvents: todayEvents,
            todaySlots: slots[today] ?? DailySlots(date: today, confirmedKeys: [], slotLimit: slotLimit),
            tomorrowSlots: slots[tomorrow] ?? DailySlots(date: tomorrow, confirmedKeys: [], slotLimit: slotLimit),
            conflicts: conflicts,
            editLimitExceededKeys: Self.deduplicated(editLimitExceededKeys),
            outOfSlotKeys: Self.deduplicated(outOfSlotKeys),
            noLocationKeys: Self.deduplicated(noLocationKeys),
            allDayKeys: Self.deduplicated(allDayKeys),
            carriedOverKeys: Self.deduplicated(carriedOverKeys)
        )
    }

    // MARK: - 座標解決

    private struct ResolveOutcome {
        var resolved: [CalendarEvent]
        var eligible: [EventKey]
        /// ジオコーディングまで到達した（＝座標が無いと確定できる）キー。
        var attempted: [EventKey]
    }

    /// 既に枠を持っている予定を先に解決し、余った枠数のぶんだけ残りを解決する。
    ///
    /// LocationResolver は開始時刻順に処理して枠が埋まった時点で打ち切るため、素直に全候補を
    /// 渡すと「新しく登録された、より早い時刻の予定」がジオコーディングの呼び出しを食い尽くし、
    /// 既に枠を持っている予定の座標が取れなくなる。2回に分けることでそれを防ぐ。
    private func resolve(
        candidates: [CalendarEvent],
        existing: DailySlots?,
        slotLimit: Int,
        supportSentKeys: Set<EventKey>,
        cache: inout [String: GeocodeCacheEntry],
        now: Date
    ) async -> ResolveOutcome {
        guard let existing, existing.confirmedAt != nil else {
            let result = await locationResolver.resolveLocations(
                candidates: candidates,
                slotLimit: slotLimit,
                cache: &cache,
                service: geocoder,
                now: now
            )
            return ResolveOutcome(
                resolved: result.resolved,
                eligible: result.slotEligible,
                attempted: Self.attemptedKeys(in: result.resolved, eligible: result.slotEligible, slotLimit: slotLimit)
            )
        }

        let confirmedSet = Set(existing.confirmedKeys)
        let held = candidates.filter { confirmedSet.contains($0.key) }
        // 空き枠を争う候補は登録順で解決する。解決の順序がそのまま枠の候補を決めるので、
        // ここを開始時刻順にすると第2段階の「登録順で追加」が効かなくなる。
        let rest = candidates
            .filter { !confirmedSet.contains($0.key) }
            .sorted(by: CalendarEvent.isOrderedByRegistrationBefore)

        let first = await locationResolver.resolveLocations(
            candidates: held,
            slotLimit: held.count,
            cache: &cache,
            service: geocoder,
            now: now
        )
        var outcome = ResolveOutcome(
            resolved: first.resolved,
            eligible: first.slotEligible,
            attempted: Self.attemptedKeys(in: first.resolved, eligible: first.slotEligible, slotLimit: held.count)
        )

        // 追加できる件数は SlotConfirmer と同じ計算で求める。ここがずれると、
        // 枠が空いているのに座標を解決しない（またはその逆）ことになる。
        let budget = slotConfirmer.accounting(
            current: existing,
            presentKeys: Set(candidates.map(\.key)),
            supportSentKeys: supportSentKeys,
            limit: slotLimit
        ).additionBudget
        guard budget > 0, !rest.isEmpty else {
            outcome.resolved.append(contentsOf: rest)
            return outcome
        }

        let second = await locationResolver.resolveLocations(
            candidates: rest,
            slotLimit: budget,
            cache: &cache,
            service: geocoder,
            now: now,
            order: .asGiven
        )
        outcome.resolved.append(contentsOf: second.resolved)
        outcome.eligible.append(contentsOf: second.slotEligible)
        outcome.attempted.append(
            contentsOf: Self.attemptedKeys(in: second.resolved, eligible: second.slotEligible, slotLimit: budget)
        )
        return outcome
    }

    /// LocationResolver が実際に処理した範囲を、返り値から復元する。
    ///
    /// 枠が埋まりきらなかった場合は全件処理されている。埋まった場合は、最後に枠へ入った予定
    /// までが処理済みで、それ以降は手つかず。
    private static func attemptedKeys(
        in resolved: [CalendarEvent],
        eligible: [EventKey],
        slotLimit: Int
    ) -> [EventKey] {
        guard eligible.count >= slotLimit else { return resolved.map(\.key) }
        let eligibleSet = Set(eligible)
        guard let lastIndex = resolved.lastIndex(where: { eligibleSet.contains($0.key) }) else { return [] }
        return resolved[...lastIndex].map(\.key)
    }

    // MARK: - ユーティリティ

    private func addingDays(_ days: Int, to date: Date) -> Date {
        calendar.date(byAdding: .day, value: days, to: date)
            ?? date.addingTimeInterval(Double(days) * 24 * 60 * 60)
    }

    private static func deduplicated(_ keys: [EventKey]) -> [EventKey] {
        var seen = Set<EventKey>()
        return keys.filter { seen.insert($0).inserted }
    }
}
