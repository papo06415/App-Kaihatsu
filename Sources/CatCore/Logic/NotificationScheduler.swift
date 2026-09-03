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
        now: Date
    ) -> NotificationPlan {
        plan(
            plans: result.today + result.tomorrow,
            isPremium: isPremium,
            previousDepartureTimes: previousDepartureTimes,
            now: now
        )
    }

    /// - Parameters:
    ///   - plans: 計算層の出力。
    ///   - isPremium: Premium なら開始前の3回を加える。
    ///   - previousDepartureTimes: 前回算出した出発時刻。変更の判定に使う。
    ///   - now: 算出時刻。即時通知・緊急通知の発火時刻になる。
    public func plan(
        plans: [DeparturePlan],
        isPremium: Bool,
        previousDepartureTimes: [EventKey: Date],
        now: Date
    ) -> NotificationPlan {
        var notifications: [ScheduledNotification] = []
        var departureTimes: [EventKey: Date] = [:]

        for plan in plans {
            switch plan.outcome {
            case .notComputedOnThisDay:
                // 日跨ぎ予定の2日目。通知の対象外。
                continue

            case .destinationLocationUnavailable, .originUnavailable:
                // どちらも通知の仕様が無い（README の「確認が必要な項目」を参照）。
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

        return NotificationPlan(notifications: notifications, departureTimes: departureTimes)
    }

    // MARK: - 登録

    /// 算出した通知を登録する。登録順は発火時刻の昇順。
    public func register(_ plan: NotificationPlan, using scheduler: NotificationScheduling) async {
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
        return candidates
            .filter { $0.1 > now }
            .map { ScheduledNotification(key: plan.key, kind: $0.0, fireDate: $0.1) }
    }

    // MARK: - 出発時刻が変わった場合

    private func changeNotifications(
        for plan: DeparturePlan,
        departureTime: Date,
        previous: Date?,
        isPremium: Bool,
        now: Date
    ) -> [ScheduledNotification] {
        // 仕様 4-3 は「出発時刻が変わった場合」の規定なので、前回の値が無ければ何も出さない。
        guard let previous, previous != departureTime else { return [] }

        if departureTime <= now {
            // 新しい出発時刻が既に過ぎている → 緊急通知。プランを問わない。
            return [ScheduledNotification(key: plan.key, kind: .departureAlreadyPassed, fireDate: now)]
        }

        if isPremium, previous.timeIntervalSince(departureTime) >= earlierNotificationThreshold {
            // Premium で出発時刻が10分以上早まった → 即時通知。
            return [ScheduledNotification(key: plan.key, kind: .departureMovedEarlier, fireDate: now)]
        }

        return []
    }
}
