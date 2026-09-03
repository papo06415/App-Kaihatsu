import Foundation

/// カレンダーへのアクセス権限の状態。
public enum CalendarAuthorization: Equatable {
    case authorized
    /// 予定を読めないため利用不可として扱う。
    case writeOnly
    case denied
    case notDetermined
}

/// カレンダーの読み取り。実装は CatPlatform（EventKit）側に置く。
public protocol CalendarSource {
    /// 指定範囲の予定を取得する。
    func fetchEvents(from: Date, to: Date) throws -> [CalendarEvent]
    /// カレンダーへのアクセス権限の状態。
    func authorizationStatus() -> CalendarAuthorization
}
