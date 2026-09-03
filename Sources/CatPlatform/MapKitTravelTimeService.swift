#if canImport(MapKit)
import Foundation
import MapKit
import CatCore

/// MKDirections で移動時間を取得する。
///
/// 経路そのものは要らないので `calculateETA()` を使う。`calculate()` は交通機関の
/// 経路を返さないため、公共交通の所要時間はこちらでしか取れない。
public final class MapKitTravelTimeService: TravelTimeService {
    public init() {}

    public func travelTime(
        from: EventLocation,
        to: EventLocation,
        mode: TravelMode
    ) async -> TravelTimeResult {
        let request = MKDirections.Request()
        request.source = Self.mapItem(for: from)
        request.destination = Self.mapItem(for: to)
        request.transportType = Self.transportType(for: mode)
        // 出発時刻・到着時刻は指定していない。どちらを基準に経路を引くべきかが
        // 仕様に無いため（README の「確認が必要な項目」を参照）。
        // 未指定のとき MapKit は現在時刻を基準にする。

        do {
            let response = try await MKDirections(request: request).calculateETA()
            return .available(response.expectedTravelTime)
        } catch {
            // 経路が見つからない、通信できない、その交通手段に未対応、のいずれか。
            // 呼び出し側（DeparturePlanner）は出発時刻を算出せずに結果へ残すだけにしている。
            return .unavailable
        }
    }

    private static func mapItem(for location: EventLocation) -> MKMapItem {
        let coordinate = CLLocationCoordinate2D(
            latitude: location.latitude,
            longitude: location.longitude
        )
        return MKMapItem(placemark: MKPlacemark(coordinate: coordinate))
    }

    private static func transportType(for mode: TravelMode) -> MKDirectionsTransportType {
        switch mode {
        case .walking: return .walking
        case .transit: return .transit
        case .automobile: return .automobile
        }
    }
}
#endif
