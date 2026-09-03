import Foundation

public enum TravelTimeResult: Equatable {
    /// 移動時間（秒）。
    case available(TimeInterval)
    /// 取得できなかった。経路が見つからない、通信できない、その交通手段に未対応、など。
    ///
    /// 取得できなかったときにどう振る舞うべきかは仕様に記載が無い。
    /// この層では出発時刻を算出せず、そのことを結果に残すだけにしてある。
    case unavailable
}

/// 2地点間の移動時間を取得する。実装は CatPlatform（MKDirections）側に置く。
public protocol TravelTimeService {
    func travelTime(from: EventLocation, to: EventLocation, mode: TravelMode) async -> TravelTimeResult
}
