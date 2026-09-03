import Foundation

public enum LocationResolution: Equatable {
    case resolved(EventLocation)
    /// 通信断・レート制限。再試行すべき。
    case temporaryFailure
    /// 住所として解決できない。
    case permanentFailure
}

/// 住所・店名の文字列から座標を解決する。実装は CatPlatform（CLGeocoder / MKLocalSearch）側。
public protocol GeocodingService {
    /// 住所や店名の文字列から座標を解決する。
    func resolve(query: String) async -> LocationResolution
}
