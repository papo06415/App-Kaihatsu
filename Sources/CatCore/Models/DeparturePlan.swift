import Foundation

/// 1件の予定に対する出発時刻の計算結果。
public struct DeparturePlan: Equatable {
    /// 出発地点。
    public enum Origin: Equatable {
        case home(EventLocation)
        /// 前のサポート対象の場所。
        case previousEvent(EventKey, EventLocation)
        /// 起点が決まらなかった（自宅の座標が未設定）。
        case unavailable
    }

    public enum Outcome: Equatable {
        /// 出発時刻を算出できた。
        case scheduled(
            departureTime: Date,
            mode: TravelMode,
            travelTime: TimeInterval,
            distanceMeters: Double
        )
        /// 目的地の座標が無い（noLocationKeys に含まれる予定）。
        case destinationLocationUnavailable
        /// 出発地点が決まらない。自宅の座標が未設定で、前のサポート対象にも場所がない。
        /// この場合の扱いは仕様に記載が無いため、算出せずここに落としている。
        case originUnavailable
        /// 移動時間を取得できなかった。この場合の扱いは仕様に記載が無いため、
        /// 出発時刻を算出せずここに落としている。
        case travelTimeUnavailable(mode: TravelMode, distanceMeters: Double)
        /// 日跨ぎ予定。枠は消費するが、出発時刻の計算と通知は開始日にのみ行う。
        case notComputedOnThisDay
    }

    public let key: EventKey
    public let startDate: Date
    public let origin: Origin
    public let outcome: Outcome

    public init(key: EventKey, startDate: Date, origin: Origin, outcome: Outcome) {
        self.key = key
        self.startDate = startDate
        self.origin = origin
        self.outcome = outcome
    }

    /// 算出できた出発時刻。算出できなかった場合は nil。
    public var departureTime: Date? {
        if case .scheduled(let departureTime, _, _, _) = outcome { return departureTime }
        return nil
    }
}

/// 今日と翌日それぞれの計算結果。連鎖は日ごとに独立している
/// （「その日の最初のサポート対象 → 自宅から」のため）。
public struct DeparturePlanResult: Equatable {
    public let today: [DeparturePlan]
    public let tomorrow: [DeparturePlan]

    public init(today: [DeparturePlan], tomorrow: [DeparturePlan]) {
        self.today = today
        self.tomorrow = tomorrow
    }
}
