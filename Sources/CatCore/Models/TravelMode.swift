import Foundation

/// 移動手段。
public enum TravelMode: String, Codable, Equatable {
    case walking
    case transit
    case automobile
}

extension PrimaryTransport {
    /// ユーザーが選択した交通手段に対応する移動手段。
    public var travelMode: TravelMode {
        switch self {
        case .transit: return .transit
        case .automobile: return .automobile
        }
    }
}
