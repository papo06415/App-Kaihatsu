import Foundation

/// 予定の場所文字列から座標を解決し、同時に「枠の候補になれるか」を決める。
///
/// 座標が解決できるかどうかで枠の消費有無が変わるため、先に全件解決することも
/// 先に枠を決めることもできない（循環する）。そのため逐次処理で、枠が埋まった時点で打ち切る。
public struct LocationResolver {
    /// 候補を処理する順序。
    ///
    /// 枠が埋まった時点で打ち切るので、この順序がそのまま「どの予定が枠の候補になれるか」を決める。
    public enum CandidateOrder {
        /// 開始時刻の昇順。第1段階（開始時刻順に上位 N 件）で使う。
        case startTime
        /// 呼び出し側が渡した順のまま。第2段階（登録順で追加）で使う。
        case asGiven
    }

    /// 失敗エントリの有効期間。既定は24時間。
    public let failureCacheDuration: TimeInterval

    public init(failureCacheDuration: TimeInterval = 24 * 60 * 60) {
        self.failureCacheDuration = failureCacheDuration
    }

    /// - Parameters:
    ///   - candidates: 終日予定を除いた対象日の予定。
    ///   - slotLimit: 埋めるべき枠の数。無料版は3、Premium は Int.max。
    ///   - cache: ジオコーディングのキャッシュ。呼び出しの中で更新される。
    ///   - service: ジオコーディング実装。
    ///   - now: 現在時刻。失敗エントリの失効判定に使う。
    ///   - order: 候補を処理する順序。既定は開始時刻順。
    /// - Returns: 座標を反映した予定（処理順）と、枠の候補になれるキー。
    ///
    /// service は1件ずつ順番に await する。TaskGroup などで並行実行しない
    /// （ジオコーディングにはレート制限があるため）。
    public func resolveLocations(
        candidates: [CalendarEvent],
        slotLimit: Int,
        cache: inout [String: GeocodeCacheEntry],
        service: GeocodingService,
        now: Date,
        order: CandidateOrder = .startTime
    ) async -> (resolved: [CalendarEvent], slotEligible: [EventKey]) {
        let ordered: [CalendarEvent]
        switch order {
        case .startTime: ordered = candidates.sorted(by: CalendarEvent.isOrderedBefore)
        case .asGiven: ordered = candidates
        }

        var resolved: [CalendarEvent] = []
        resolved.reserveCapacity(ordered.count)
        var slotEligible: [EventKey] = []

        for (index, event) in ordered.enumerated() {
            // 枠が埋まったら以降はサービスを呼ばない。残りは未解決のまま返す。
            if slotEligible.count >= slotLimit {
                resolved.append(contentsOf: ordered[index...])
                break
            }

            var event = event

            // 1. 既に座標があればサービスを呼ばない。
            if event.location != nil {
                resolved.append(event)
                slotEligible.append(event.key)
                continue
            }

            // 2. 場所欄が空なら解決しようがない。サービスも呼ばない。
            let query = event.locationText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !query.isEmpty else {
                resolved.append(event)
                continue
            }

            // 3. キャッシュを引く。
            if let entry = cache[query] {
                if let latitude = entry.latitude, let longitude = entry.longitude {
                    // 成功エントリは無期限。
                    event.location = EventLocation(latitude: latitude, longitude: longitude, name: event.locationText)
                    resolved.append(event)
                    slotEligible.append(event.key)
                    continue
                }
                if now.timeIntervalSince(entry.resolvedAt) < failureCacheDuration {
                    // 失敗エントリが有効期間内。恒久失敗として扱い、枠も消費しない。
                    resolved.append(event)
                    continue
                }
                // 24時間を超えた失敗エントリは再試行する。
            }

            // 4. サービスに問い合わせる。
            switch await service.resolve(query: query) {
            case .resolved(let location):
                event.location = location
                cache[query] = GeocodeCacheEntry(
                    query: query,
                    latitude: location.latitude,
                    longitude: location.longitude,
                    resolvedAt: now
                )
                resolved.append(event)
                slotEligible.append(event.key)

            case .temporaryFailure:
                // キャッシュしない。次回起動時に必ず再試行するため。
                // 枠には入れる。オフラインで一度失敗しただけの予定を締め出さない。
                resolved.append(event)
                slotEligible.append(event.key)

            case .permanentFailure:
                cache[query] = GeocodeCacheEntry(
                    query: query,
                    latitude: nil,
                    longitude: nil,
                    resolvedAt: now
                )
                resolved.append(event)
            }
        }

        return (resolved, slotEligible)
    }
}
