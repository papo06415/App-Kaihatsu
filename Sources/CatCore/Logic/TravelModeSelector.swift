import Foundation

/// 2地点の直線距離から移動手段を決める。
public struct TravelModeSelector {
    /// 徒歩と判定する上限（メートル）。この値ちょうどまでは徒歩。
    public let walkingThresholdMeters: Double

    public init(walkingThresholdMeters: Double = 1_500) {
        self.walkingThresholdMeters = walkingThresholdMeters
    }

    /// 直線距離（メートル）。
    ///
    /// 大円距離（Haversine）で求める。CoreLocation の `CLLocation.distance(from:)` は
    /// WGS84 の測地線距離なので、同じ2点でもわずかに違う値になる（1.5km 付近で数メートル程度）。
    /// 判定を Linux 上でテストできるようにするため、こちら側で計算している。
    public static func straightLineDistanceMeters(from: EventLocation, to: EventLocation) -> Double {
        // IUGG の平均地球半径。
        let earthRadius = 6_371_008.8
        let phi1 = from.latitude * .pi / 180
        let phi2 = to.latitude * .pi / 180
        let deltaPhi = (to.latitude - from.latitude) * .pi / 180
        let deltaLambda = (to.longitude - from.longitude) * .pi / 180

        let a = sin(deltaPhi / 2) * sin(deltaPhi / 2)
            + cos(phi1) * cos(phi2) * sin(deltaLambda / 2) * sin(deltaLambda / 2)
        return 2 * earthRadius * atan2(sqrt(a), sqrt(1 - a))
    }

    /// 距離が閾値以下なら徒歩、超えていればユーザーが選択した交通手段。
    ///
    /// 距離の算出と切り離してあるのは、境界（ちょうど閾値）の扱いを緯度経度の丸めに
    /// 左右されずに検証できるようにするため。
    public func mode(forDistanceMeters distance: Double, primaryTransport: PrimaryTransport) -> TravelMode {
        distance <= walkingThresholdMeters ? .walking : primaryTransport.travelMode
    }

    /// 直線距離が閾値以下なら徒歩、超えていればユーザーが選択した交通手段。
    public func select(
        from: EventLocation,
        to: EventLocation,
        primaryTransport: PrimaryTransport
    ) -> (mode: TravelMode, distanceMeters: Double) {
        let distance = Self.straightLineDistanceMeters(from: from, to: to)
        return (mode(forDistanceMeters: distance, primaryTransport: primaryTransport), distance)
    }
}
