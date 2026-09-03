import Foundation

/// いつ・どの予定に対して・どの種別の通知を出すかを決める。
///
/// 実際の登録は `NotificationScheduling` 越しに行うので、この型は UserNotifications を知らない。
public struct NotificationScheduler {
    /// Premium で開始前に送る通知の種別と、開始時刻からの逆算量。
    static let premiumLeadTimes: [(kind: NotificationKind, beforeStart: TimeInterval)] = [
        (.ninetyMinutesBeforeStart, 90 * 60),
        (.sixtyMinutesBeforeStart, 60 * 60),
        (.thirtyMinutesBeforeStart, 30 * 60)
    ]

    /// Premium で即時通知に切り替わる、出発時刻の繰り上がり量。
    public let earlierNotificationThreshold: TimeInterval

    public init(earlierNotificationThreshold: TimeInterval = 10 * 60) {
        self.earlierNotificationThreshold = earlierNotificationThreshold
    }

    // MARK: - 算出

    /// 今日と翌日の両方を対象にする。
    ///
    /// 翌日ぶんも含めるのは、Premium が開始1.5時間前から通知するため、翌日の早朝に開始する
    /// 予定は今日のうちに登録しておく必要があるから。
    public func plan(
        _ result: DeparturePlanResult,
        isPremium: Bool,
        previousDepartureTimes: [EventKey: Date],
        completedKeys: Set<EventKey> = [],
        now: Date
    ) -> NotificationPlan {
        plan(
            plans: result.today + result.tomorrow,
            isPremium: isPremium,
            previousDepartureTimes: previousDepartureTimes,
            completedKeys: completedKeys,
            now: now
        )
    }

    /// - Parameters:
    ///   - plans: 計算層の出力。
    ///   - isPremium: Premium なら開始前の3回を加える。
    ///   - previousDepartureTimes: 前回算出した出発時刻。変更の判定に使う。
    ///   - completedKeys: 完了した予定。未発火の通知を取り消し、新しい通知も出さない。
    ///   - now: 算出時刻。即時通知・緊急通知の発火時刻になる。
    public func plan(
        plans: [DeparturePlan],
        isPremium: Bool,
        previousDepartureTimes: [EventKey: Date],
        completedKeys: Set<EventKey> = [],
        now: Date
    ) -> NotificationPlan {
        var notifications: [ScheduledNotification] = []
        var departureTimes: [EventKey: Date] = [:]
        var cancelled: [String] = []

        for plan in plans {
            // 完了した予定に残っている通知は「既に始まった予定の準備を促す通知」になるので
            // 取り消す。新しい通知も出さない。
            if completedKeys.contains(plan.key) {
                cancelled.append(contentsOf: ScheduledNotification.allIdentifiers(for: plan.key))
                continue
            }

            switch plan.outcome {
            case .notComputedOnThisDay:
                // 日跨ぎ予定の2日目。通知の対象外。
                continue

            case .destinationLocationUnavailable:
                // 仕様 4-2。枠を持っているのに何も起きないと不具合と区別が付かないため、
                // 場所が分からなかったことを伝える。
                notifications.append(
                    ScheduledNotification(key: plan.key, kind: .locationUnavailable, fireDate: now)
                )

            case .originUnavailable:
                // 自宅が未設定のときだけ起きる。オンボーディングで必須にしている（決定13）ので
                // 通常フローでは発生しない。通知の規定も無いので何も出さない。
                continue

            case .travelTimeUnavailable:
                // 仕様 4-2。発火時刻の指定が無いので算出時刻に送る。
                notifications.append(
                    ScheduledNotification(key: plan.key, kind: .travelTimeUnavailable, fireDate: now)
                )

            case .scheduled(let departureTime, _, _, _):
                departureTimes[plan.key] = departureTime
                notifications.append(
                    contentsOf: changeNotifications(
                        for: plan,
                        departureTime: departureTime,
                        previous: previousDepartureTimes[plan.key],
                        isPremium: isPremium,
                        now: now
                    )
                )
                notifications.append(
                    contentsOf: regularNotifications(
                        for: plan,
                        departureTime: departureTime,
                        isPremium: isPremium,
                        now: now
                    )
                )
            }
        }

        notifications.sort { lhs, rhs in
            if lhs.fireDate != rhs.fireDate { return lhs.fireDate < rhs.fireDate }
            if lhs.key != rhs.key { return EventKey.isOrderedBefore(lhs.key, rhs.key) }
            return lhs.kind.rawValue < rhs.kind.rawValue
        }

        return NotificationPlan(
            notifications: notifications,
            departureTimes: departureTimes,
            cancelledIdentifiers: cancelled
        )
    }

    // MARK: - 登録

    /// 算出した通知を登録する。登録順は発火時刻の昇順。
    public func register(_ plan: NotificationPlan, using scheduler: NotificationScheduling) async {
        if !plan.cancelledIdentifiers.isEmpty {
            await scheduler.removeAll(withIdentifiers: plan.cancelledIdentifiers)
        }
        for notification in plan.notifications {
            await scheduler.add(notification)
        }
    }

    // MARK: - 定期の通知

    private func regularNotifications(
        for plan: DeparturePlan,
        departureTime: Date,
        isPremium: Bool,
        now: Date
    ) -> [ScheduledNotification] {
        var candidates: [(NotificationKind, Date)] = []

        if isPremium {
            // Premium: 開始1.5時間前 / 1時間前 / 30分前 / 出発時刻
            for lead in Self.premiumLeadTimes {
                candidates.append((lead.kind, plan.startDate.addingTimeInterval(-lead.beforeStart)))
            }
            candidates.append((.departure, departureTime))
        } else {
            // Free: 出発時刻 / 開始時刻
            candidates.append((.departure, departureTime))
            candidates.append((.start, plan.startDate))
        }

        // 既に過ぎたタイミングは登録しない。
        // 同じ時刻に重なったら1件にまとめ、出発時刻を優先する（行動に直結するため）。
        // 移動20分＋バッファ10分で開始30分前ちょうど、といった重なり方をする。
        var byFireDate: [Date: NotificationKind] = [:]
        for (kind, fireDate) in candidates where fireDate > now {
            if byFireDate[fireDate] == nil || kind == .departure {
                byFireDate[fireDate] = kind
            }
        }

        return byFireDate
            .map { ScheduledNotification(key: plan.key, kind: $0.value, fireDate: $0.key) }
    }

    // MARK: - 出発時刻が変わった場合

    private func changeNotifications(
        for plan: DeparturePlan,
        departureTime: Date,
        previous: Date?,
        isPremium: Bool,
        now: Date
    ) -> [ScheduledNotification] {
        // 出発時刻が既に過ぎている → 緊急通知。プランを問わず、初回の算出でも出す。
        // ユーザーから見れば初回でも変更後でも「もう出ないと間に合わない」ことに変わりがない。
        if departureTime <= now {
            return [ScheduledNotification(key: plan.key, kind: .departureAlreadyPassed, fireDate: now)]
        }

        // ここから先は「変わった場合」の規定なので、前回の値が無ければ何も出さない。
        guard let previous, previous != departureTime else { return [] }

        if isPremium, previous.timeIntervalSince(departureTime) >= earlierNotificationThreshold {
            // Premium で出発時刻が10分以上早まった → 即時通知。
            return [ScheduledNotification(key: plan.key, kind: .departureMovedEarlier, fireDate: now)]
        }

        return []
    }
}
