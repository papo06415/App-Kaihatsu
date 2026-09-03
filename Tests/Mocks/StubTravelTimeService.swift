import Foundation
@testable import CatCore

/// テスト用の TravelTimeService。
///
/// actor にしてあるのは呼び出しの記録を安全に取るため。並行実行の検出にも使える。
actor StubTravelTimeService: TravelTimeService {
    struct Call: Equatable {
        let from: EventLocation
        let to: EventLocation
        let mode: TravelMode
    }

    /// 目的地の緯度経度をキーにした個別の応答。未登録なら `defaultResult` を返す。
    var results: [String: TravelTimeResult]
    var defaultResult: TravelTimeResult

    private(set) var calls: [Call] = []
    private(set) var maxConcurrentCalls = 0
    private var activeCalls = 0

    init(
        results: [String: TravelTimeResult] = [:],
        defaultResult: TravelTimeResult = .available(20 * 60)
    ) {
        self.results = results
        self.defaultResult = defaultResult
    }

    static func key(_ location: EventLocation) -> String {
        "\(location.latitude),\(location.longitude)"
    }

    func travelTime(from: EventLocation, to: EventLocation, mode: TravelMode) async -> TravelTimeResult {
        calls.append(Call(from: from, to: to, mode: mode))
        activeCalls += 1
        maxConcurrentCalls = max(maxConcurrentCalls, activeCalls)
        for _ in 0..<4 { await Task.yield() }
        activeCalls -= 1
        return results[Self.key(to)] ?? defaultResult
    }

    var callCount: Int { calls.count }
    var origins: [EventLocation] { calls.map(\.from) }
    var modes: [TravelMode] { calls.map(\.mode) }
}
