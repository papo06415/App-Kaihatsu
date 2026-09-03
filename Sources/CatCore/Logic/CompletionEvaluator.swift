import Foundation

/// 予定が「完了した」かどうかの判定。
///
/// 基準は開始時刻であって終了時刻ではない。出発サポートは開始時刻に間に合わせるための
/// ものなので、開始してしまった時点で役目が終わる。
///
/// 終日予定は開始時刻が 0:00 になるため、その日になった瞬間に完了扱いになる。これは正しい挙動。
///
/// バックグラウンド実行は不要。アプリ起動時にこの判定を全予定に対して評価するだけで足りる
/// ように、状態を持たない純粋関数にしてある。
public struct CompletionEvaluator {
    public init() {}

    public func isCompleted(_ event: CalendarEvent, now: Date) -> Bool {
        now >= event.startDate
    }
}
