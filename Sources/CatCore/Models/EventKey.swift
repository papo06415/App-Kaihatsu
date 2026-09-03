import Foundation

/// 予定を一意に識別する複合キー。
///
/// EventKit の `eventIdentifier` は繰り返し予定の全ての回で同じ値になるため、
/// 単独ではキーとして使えない。開始時刻と組にして初めて「その回」を指せる。
public struct EventKey: Codable, Equatable, Hashable {
    public let eventIdentifier: String
    public let startDate: Date

    public init(eventIdentifier: String, startDate: Date) {
        self.eventIdentifier = eventIdentifier
        self.startDate = startDate
    }
}
