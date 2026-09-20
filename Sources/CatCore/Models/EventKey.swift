import Foundation

/// 予定を一意に識別するキー。
///
/// EventKit の `eventIdentifier` は繰り返し予定の全ての回で同じ値になるため、それだけでは
/// 回を区別できない。一方で開始時刻をキーに含めると、ユーザーが時刻を動かした瞬間にキーが
/// 変わり、「編集」ではなく「削除＋新規」に見えてしまう。
///
/// そこで、回の区別に使うのは **その回の元の開始時刻（occurrenceDate）** だけにしてある。
/// occurrenceDate は予定を動かしても変わらないので、両方を満たせる。
///
/// - 単発予定: `occurrenceDate` は nil。`eventIdentifier` だけで識別する。
/// - 繰り返し予定: `occurrenceDate` にその回の元の開始時刻が入る。
///
/// 繰り返しかどうかの判定は EventKit 側（`EventKitCalendarSource`）で行う。
public struct EventKey: Codable, Equatable, Hashable {
    public let eventIdentifier: String
    /// 繰り返し予定の回を区別するための、その回の元の開始時刻。単発予定は nil。
    public let occurrenceDate: Date?

    public init(eventIdentifier: String, occurrenceDate: Date? = nil) {
        self.eventIdentifier = eventIdentifier
        self.occurrenceDate = occurrenceDate
    }

    /// 出力順を安定させるための順序。eventIdentifier の昇順、同一なら occurrenceDate の昇順。
    /// キー自体は時刻情報を持たないので、開始時刻順に並べたい場合は `CalendarEvent` 側を使う。
    static func isOrderedBefore(_ lhs: EventKey, _ rhs: EventKey) -> Bool {
        if lhs.eventIdentifier != rhs.eventIdentifier {
            return lhs.eventIdentifier < rhs.eventIdentifier
        }
        switch (lhs.occurrenceDate, rhs.occurrenceDate) {
        case let (left?, right?): return left < right
        case (nil, .some): return true
        case (.some, nil): return false
        case (nil, nil): return false
        }
    }
}
