import Foundation

/// 前回起動時の予定の状態。変更検知と編集回数のカウントに使う。
///
/// 比較対象は `startDate` / `endDate` / `latitude` / `longitude` の4つだけ。
/// タイトルやメモは保存も比較もしない。
public struct EventSnapshot: Codable, Equatable {
    public let key: EventKey
    public var startDate: Date
    public var endDate: Date
    public var latitude: Double?
    public var longitude: Double?
    public var editCount: Int
    public var isCompleted: Bool
    public var completedAt: Date?
    /// この予定について支援（出発通知）を送信した日時。未送信なら nil。
    ///
    /// 枠の解放の判定に使う。送信前に予定が消えたなら枠は返すが、送信後に消えても返さない
    /// （送信済みの支援は取り消せないので、1日の上限を消費したものとして扱う）。
    /// 実際に値を入れるのは後続フェーズの通知処理。
    public var supportSentAt: Date?

    public init(
        key: EventKey,
        startDate: Date,
        endDate: Date,
        latitude: Double? = nil,
        longitude: Double? = nil,
        editCount: Int = 0,
        isCompleted: Bool = false,
        completedAt: Date? = nil,
        supportSentAt: Date? = nil
    ) {
        self.key = key
        self.startDate = startDate
        self.endDate = endDate
        self.latitude = latitude
        self.longitude = longitude
        self.editCount = editCount
        self.isCompleted = isCompleted
        self.completedAt = completedAt
        self.supportSentAt = supportSentAt
    }

    /// 予定から新しいスナップショットを作る（editCount は 0）。
    public init(event: CalendarEvent) {
        self.init(
            key: event.key,
            startDate: event.startDate,
            endDate: event.endDate,
            latitude: event.location?.latitude,
            longitude: event.location?.longitude,
            editCount: 0,
            isCompleted: false,
            completedAt: nil,
            supportSentAt: nil
        )
    }

    /// 変更検知の対象となる4項目が予定と一致しているか。
    public func matchesTrackedFields(of event: CalendarEvent) -> Bool {
        startDate == event.startDate
            && endDate == event.endDate
            && latitude == event.location?.latitude
            && longitude == event.location?.longitude
    }

    /// 変更検知の対象となる4項目を予定の値に合わせる。
    public mutating func applyTrackedFields(from event: CalendarEvent) {
        startDate = event.startDate
        endDate = event.endDate
        latitude = event.location?.latitude
        longitude = event.location?.longitude
    }
}
