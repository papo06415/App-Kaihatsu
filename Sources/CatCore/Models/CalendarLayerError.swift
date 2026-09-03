import Foundation

public enum CalendarLayerError: Error, Equatable {
    case calendarAccessDenied
    /// 書き込みのみ許可。予定を読めないため利用不可。
    case calendarAccessWriteOnly
    case calendarAccessNotDetermined
    case persistenceFailed(String)
}
