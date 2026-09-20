#if canImport(EventKit)
import Foundation
#if canImport(CoreLocation) && canImport(MapKit)
import CoreLocation
import MapKit
import CatCore

/// CLGeocoder → MKLocalSearch の順で座標を解決する。
///
/// CLGeocoder は住所形式に強いが店名だと失敗しやすいため、MKLocalSearch へのフォールバックが要る。
public final class AppleGeocodingService: GeocodingService {
    private let geocoder: CLGeocoder

    public init(geocoder: CLGeocoder = CLGeocoder()) {
        self.geocoder = geocoder
    }

    public func resolve(query: String) async -> LocationResolution {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .permanentFailure }

        // 1. 住所として解決する。
        do {
            let placemarks = try await geocoder.geocodeAddressString(trimmed)
            if let coordinate = placemarks.first?.location?.coordinate {
                return .resolved(
                    EventLocation(latitude: coordinate.latitude, longitude: coordinate.longitude, name: trimmed)
                )
            }
        } catch let error as CLError {
            // 通信断・レート制限は再試行すべき一時的な失敗。
            if Self.isTemporary(error) { return .temporaryFailure }
        } catch {
            // 種類の判別が付かないものは店名検索に賭ける。
        }

        // 2. 場所名として検索する。
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = trimmed
        do {
            let response = try await MKLocalSearch(request: request).start()
            if let item = response.mapItems.first {
                let coordinate = item.placemark.coordinate
                return .resolved(
                    EventLocation(
                        latitude: coordinate.latitude,
                        longitude: coordinate.longitude,
                        name: item.name ?? trimmed
                    )
                )
            }
            // 0件。住所としても場所名としても解決できない。
            return .permanentFailure
        } catch let error as MKError {
            switch error.code {
            case .loadingThrottled, .serverFailure:
                return .temporaryFailure
            default:
                return .permanentFailure
            }
        } catch {
            return .temporaryFailure
        }
    }

    private static func isTemporary(_ error: CLError) -> Bool {
        switch error.code {
        case .network:
            return true
        default:
            return false
        }
    }
}
#endif
#endif
