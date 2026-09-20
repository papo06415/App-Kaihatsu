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
        mode: TravelMode,
        arrivalDate: Date
    ) async -> TravelTimeResult {
        let request = MKDirections.Request()
        request.source = Self.mapItem(for: from)
        request.destination = Self.mapItem(for: to)
        request.transportType = Self.transportType(for: mode)
        // 到着時刻を指定する。知りたいのは「その時刻に着くには何分かかるか」だから。
        // 未指定だと MapKit は現在時刻を基準にするので、翌朝の予定を深夜のダイヤで
        // 計算してしまう。
        //
        // 交通手段で出し分けていないのは、Apple のドキュメントが arrivalDate を
        // 「サーバーが経路を最適化するための追加情報」としか説明しておらず、交通機関に
        // 限る記述も徒歩で無視されるという記述も無いため。分岐は MapKit の内部挙動を
        // 推測することになる。
        request.arrivalDate = arrivalDate

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
        // MKMapItem(placemark:) は新しい SDK で非推奨（代替は init(location:address:)）だが、
        // 代替は iOS 26 以降。このパッケージのデプロイメントターゲットは iOS 17 なので
        // こちらを使う。新しい SDK でビルドすると非推奨の警告が出る。
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
