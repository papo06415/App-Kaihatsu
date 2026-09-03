import Foundation
@testable import CatCore

/// テスト用の GeocodingService。
///
/// actor にしてあるのは、呼び出しが並行しているかどうかを検出するため。actor は await を
/// またいで再入するので、LocationResolver が TaskGroup などで並行実行していれば
/// `maxConcurrentCalls` が 2 以上になる。
actor MockGeocodingService: GeocodingService {
    /// query -> 返す結果。未登録の query には `defaultResult` を返す。
    var results: [String: LocationResolution]
    var defaultResult: LocationResolution

    private(set) var callLog: [String] = []
    private(set) var maxConcurrentCalls = 0
    private var activeCalls = 0

    init(
        results: [String: LocationResolution] = [:],
        defaultResult: LocationResolution = .permanentFailure
    ) {
        self.results = results
        self.defaultResult = defaultResult
    }

    func resolve(query: String) async -> LocationResolution {
        callLog.append(query)
        activeCalls += 1
        maxConcurrentCalls = max(maxConcurrentCalls, activeCalls)

        // 並行実行されていれば、この中断点で他の呼び出しが割り込んでくる。
        for _ in 0..<4 { await Task.yield() }

        activeCalls -= 1
        return results[query] ?? defaultResult
    }

    var callCount: Int { callLog.count }
}
