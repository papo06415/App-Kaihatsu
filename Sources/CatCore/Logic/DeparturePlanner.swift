import Foundation

/// サポート対象の予定について、出発時刻を計算する。
///
/// 移動時間そのものは `TravelTimeService` 越しに受け取るだけで、この型は MapKit を知らない。
public struct DeparturePlanner {
    private let calendar: Calendar
    private let modeSelector: TravelModeSelector
    /// 開始時刻の何秒前に着いておくか。仕様上、全交通手段で一律10分。
    public let departureBuffer: TimeInterval

    public init(
        calendar: Calendar,
        walkingThresholdMeters: Double = 1_500,
        departureBuffer: TimeInterval = 10 * 60
    ) {
        self.calendar = calendar
        self.modeSelector = TravelModeSelector(walkingThresholdMeters: walkingThresholdMeters)
        self.departureBuffer = departureBuffer
    }

    // MARK: - LaunchResult から計算する

    /// カレンダー層の結果をそのまま入力にする。
    ///
    /// 翌日ぶんも計算するのは、Premium が開始1.5時間前から通知するため、翌日の早朝に
    /// 開始する予定は今日のうちに出発時刻が要るから。
    public func plan(
        launch: LaunchResult,
        preferences: UserPreferences,
        service: TravelTimeService
    ) async -> DeparturePlanResult {
        let home = Self.homeLocation(of: preferences)

        let todayTargets = Self.supportedEvents(
            keys: launch.todaySlots.confirmedKeys,
            among: launch.todayEvents
        )
        let today = await plan(
            targets: todayTargets,
            day: launch.todaySlots.date,
            home: home,
            primaryTransport: preferences.primaryTransport,
            // 座標が解決できなかった予定は出発時刻を算出せず、連鎖では「場所がない」として扱う。
            unresolvedKeys: Set(launch.noLocationKeys),
            service: service
        )

        let tomorrowTargets = Self.supportedEvents(
            keys: launch.tomorrowSlots.confirmedKeys,
            among: launch.tomorrowEvents
        )
        let tomorrow = await plan(
            targets: tomorrowTargets,
            day: launch.tomorrowSlots.date,
            home: home,
            primaryTransport: preferences.primaryTransport,
            // 翌日ぶんの noLocationKeys は LaunchResult に無いので、予定の座標の有無で判定する。
            unresolvedKeys: [],
            service: service
        )

        return DeparturePlanResult(today: today, tomorrow: tomorrow)
    }

    // MARK: - 1日ぶんを計算する

    /// - Parameters:
    ///   - targets: その日のサポート対象。開始時刻順に並べ替えてから処理する。
    ///   - day: 対象日。日跨ぎ予定の判定に使う。
    ///   - home: 自宅の座標。未設定なら nil。
    ///   - primaryTransport: ユーザーが選択した交通手段。
    ///   - unresolvedKeys: 座標が解決できなかった予定のキー。
    ///   - service: 移動時間の取得。
    ///
    /// 移動時間は1件ずつ順番に取得する。並行実行はしない。
    public func plan(
        targets: [CalendarEvent],
        day: Date,
        home: EventLocation?,
        primaryTransport: PrimaryTransport,
        unresolvedKeys: Set<EventKey>,
        service: TravelTimeService
    ) async -> [DeparturePlan] {
        let ordered = targets.sorted(by: CalendarEvent.isOrderedBefore)
        var plans: [DeparturePlan] = []
        plans.reserveCapacity(ordered.count)

        // 直前のサポート対象の場所。場所が無かった予定の後は nil に戻し、自宅を起点にする。
        var previous: (key: EventKey, location: EventLocation)?

        for event in ordered {
            let origin: DeparturePlan.Origin
            if let previous {
                origin = .previousEvent(previous.key, previous.location)
            } else if let home {
                origin = .home(home)
            } else {
                origin = .unavailable
            }

            // 日跨ぎ予定は、その開始日にのみ出発時刻を計算する。
            if !calendar.isDate(event.startDate, inSameDayAs: day) {
                plans.append(
                    DeparturePlan(
                        key: event.key,
                        startDate: event.startDate,
                        origin: origin,
                        outcome: .notComputedOnThisDay
                    )
                )
                previous = event.location.map { (event.key, $0) }
                continue
            }

            guard let destination = event.location, !unresolvedKeys.contains(event.key) else {
                plans.append(
                    DeparturePlan(
                        key: event.key,
                        startDate: event.startDate,
                        origin: origin,
                        outcome: .destinationLocationUnavailable
                    )
                )
                // 場所がないので、次のサポート対象は自宅を起点にする。
                previous = nil
                continue
            }

            guard let originLocation = Self.location(of: origin) else {
                plans.append(
                    DeparturePlan(
                        key: event.key,
                        startDate: event.startDate,
                        origin: origin,
                        outcome: .originUnavailable
                    )
                )
                previous = (event.key, destination)
                continue
            }

            let selection = modeSelector.select(
                from: originLocation,
                to: destination,
                primaryTransport: primaryTransport
            )

            let outcome: DeparturePlan.Outcome
            switch await service.travelTime(from: originLocation, to: destination, mode: selection.mode) {
            case .available(let travelTime):
                // 出発時刻 = 開始時刻 − 移動時間 − バッファ
                outcome = .scheduled(
                    departureTime: event.startDate
                        .addingTimeInterval(-travelTime)
                        .addingTimeInterval(-departureBuffer),
                    mode: selection.mode,
                    travelTime: travelTime,
                    distanceMeters: selection.distanceMeters
                )
            case .unavailable:
                outcome = .travelTimeUnavailable(
                    mode: selection.mode,
                    distanceMeters: selection.distanceMeters
                )
            }

            plans.append(
                DeparturePlan(
                    key: event.key,
                    startDate: event.startDate,
                    origin: origin,
                    outcome: outcome
                )
            )
            previous = (event.key, destination)
        }

        return plans
    }

    // MARK: - ユーティリティ

    static func homeLocation(of preferences: UserPreferences) -> EventLocation? {
        guard let latitude = preferences.homeLatitude, let longitude = preferences.homeLongitude else {
            return nil
        }
        return EventLocation(latitude: latitude, longitude: longitude, name: nil)
    }

    private static func location(of origin: DeparturePlan.Origin) -> EventLocation? {
        switch origin {
        case .home(let location): return location
        case .previousEvent(_, let location): return location
        case .unavailable: return nil
        }
    }

    private static func supportedEvents(keys: [EventKey], among events: [CalendarEvent]) -> [CalendarEvent] {
        let confirmed = Set(keys)
        return events.filter { confirmed.contains($0.key) }
    }
}
