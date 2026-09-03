import Foundation

/// 保存期間と削除。アプリ起動時に実行する。
public struct RetentionPolicy {
    /// 完了済みスナップショットの保存期間。既定は14日。
    ///
    /// 7日にしてはいけない。後続フェーズの週次サマリーが「先週」を表示するため、
    /// 月曜に閲覧する場合に最大13日前のデータが必要になる。
    public let completedSnapshotRetention: TimeInterval
    /// 枠の状態を保持する日数。既定は3日。
    public let slotRetentionDays: Int
    /// 失敗したジオコーディングキャッシュの保存期間。既定は24時間。成功エントリは無期限。
    public let failedGeocodeRetention: TimeInterval

    private let calendar: Calendar

    public init(
        calendar: Calendar,
        completedSnapshotRetention: TimeInterval = 14 * 24 * 60 * 60,
        slotRetentionDays: Int = 3,
        failedGeocodeRetention: TimeInterval = 24 * 60 * 60
    ) {
        self.calendar = calendar
        self.completedSnapshotRetention = completedSnapshotRetention
        self.slotRetentionDays = slotRetentionDays
        self.failedGeocodeRetention = failedGeocodeRetention
    }

    /// 完了から `completedSnapshotRetention` 経過したスナップショットを削除する。
    public func pruneSnapshots(
        _ snapshots: [EventKey: EventSnapshot],
        now: Date
    ) -> [EventKey: EventSnapshot] {
        snapshots.filter { _, snapshot in
            guard snapshot.isCompleted, let completedAt = snapshot.completedAt else { return true }
            return now.timeIntervalSince(completedAt) < completedSnapshotRetention
        }
    }

    /// `slotRetentionDays` より前の日の枠を削除する。
    public func pruneSlots(_ slots: [Date: DailySlots], now: Date) -> [Date: DailySlots] {
        let today = calendar.startOfDay(for: now)
        guard let cutoff = calendar.date(byAdding: .day, value: -slotRetentionDays, to: today) else {
            return slots
        }
        return slots.filter { _, value in value.date >= cutoff }
    }

    /// 失敗エントリのうち `failedGeocodeRetention` を過ぎたものを削除する。成功エントリは残す。
    public func pruneGeocodeCache(
        _ cache: [String: GeocodeCacheEntry],
        now: Date
    ) -> [String: GeocodeCacheEntry] {
        cache.filter { _, entry in
            if entry.isSuccess { return true }
            return now.timeIntervalSince(entry.resolvedAt) < failedGeocodeRetention
        }
    }
}
