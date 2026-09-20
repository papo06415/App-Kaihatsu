import Foundation

/// 同じ日の予定どうしの重複検知。
///
/// 枠内の3件に限らず、その日の全予定を対象とする。
public struct ConflictDetector {
    public init() {}

    public func detectConflicts(in events: [CalendarEvent]) -> [EventConflict] {
        // 終日予定は対象外。出力順を安定させるため開始時刻順に並べる。
        let targets = events
            .filter { !$0.isAllDay }
            .sorted(by: CalendarEvent.isOrderedBefore)

        var conflicts: [EventConflict] = []

        // i < j の組み合わせだけを見るので、同じ組が二重に出ることはない。
        for i in targets.indices {
            for j in targets.index(after: i)..<targets.endIndex {
                let a = targets[i]
                let b = targets[j]

                if a.startDate == b.startDate {
                    conflicts.append(EventConflict(keys: [a.key, b.key], kind: .sameStartTime))
                    continue
                }

                let overlaps = (a.startDate < b.startDate && b.startDate < a.endDate)
                    || (b.startDate < a.startDate && a.startDate < b.endDate)
                if overlaps {
                    conflicts.append(EventConflict(keys: [a.key, b.key], kind: .partialOverlap))
                }
            }
        }

        return conflicts
    }
}
