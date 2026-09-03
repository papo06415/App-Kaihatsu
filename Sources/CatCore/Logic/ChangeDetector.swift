import Foundation

/// 予定の変更検知と編集回数のカウント。
public struct ChangeDetector {
    private let completion: CompletionEvaluator

    public init(completion: CompletionEvaluator = CompletionEvaluator()) {
        self.completion = completion
    }

    /// - Parameters:
    ///   - events: 今回取得した予定。
    ///   - snapshots: 前回保存したスナップショット。
    ///   - now: 現在時刻。
    /// - Returns: 更新後のスナップショット全体、今回変更が検出されたキー、外部で削除されたキー。
    ///
    /// 編集回数の上限判定はここでは行わない。`editCount` を返すだけにして判定は呼び出し側に任せる。
    /// 上限を超えても計算は最新のデータで続行する（外部での編集は巻き戻せないため）。
    public func detectChanges(
        events: [CalendarEvent],
        snapshots: [EventKey: EventSnapshot],
        now: Date
    ) -> (updated: [EventKey: EventSnapshot], changed: [EventKey], deleted: [EventKey]) {
        var updated = snapshots
        var changed: [EventKey] = []
        var deleted: [EventKey] = []
        var seen = Set<EventKey>()

        for event in events {
            seen.insert(event.key)

            guard var snapshot = updated[event.key] else {
                // 新規。editCount は 0。
                var fresh = EventSnapshot(event: event)
                if completion.isCompleted(event, now: now) {
                    fresh.isCompleted = true
                    fresh.completedAt = now
                }
                updated[event.key] = fresh
                continue
            }

            // 完了後は凍結する。値が変わっていても更新せず、editCount も増やさない。
            if snapshot.isCompleted {
                continue
            }

            if !snapshot.matchesTrackedFields(of: event) {
                // 同時に複数項目が変わっても編集は1回。
                snapshot.editCount += 1
                snapshot.applyTrackedFields(from: event)
                changed.append(event.key)
            }

            if completion.isCompleted(event, now: now) {
                snapshot.isCompleted = true
                snapshot.completedAt = now
            }

            updated[event.key] = snapshot
        }

        // 取得結果に無いスナップショット＝外部で削除された。
        for (key, snapshot) in snapshots where !seen.contains(key) {
            if snapshot.isCompleted {
                // 完了済みは保持し続ける（保存期間の管理は RetentionPolicy に任せる）。
                continue
            }
            deleted.append(key)
            updated.removeValue(forKey: key)
        }

        // 辞書の列挙順は不定なので、呼び出し側が安定した結果を得られるよう並べておく。
        changed.sort(by: EventKey.isOrderedBefore)
        deleted.sort(by: EventKey.isOrderedBefore)

        return (updated, changed, deleted)
    }
}
