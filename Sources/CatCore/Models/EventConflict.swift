import Foundation

/// 同じ日に重なっている予定の組。
public struct EventConflict: Codable, Equatable {
    public enum Kind: String, Codable, Equatable {
        /// 開始時刻が完全に一致。
        case sameStartTime
        /// 時間帯が一部重なる。
        case partialOverlap
    }

    public let keys: [EventKey]
    public let kind: Kind

    public init(keys: [EventKey], kind: Kind) {
        self.keys = keys
        self.kind = kind
    }
}
