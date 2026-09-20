import Foundation

/// ジオコーディング結果のキャッシュ1件。
///
/// 成功エントリ（`latitude != nil`）は無期限。
/// 失敗エントリ（`latitude == nil`）は `resolvedAt` から24時間で失効する。
public struct GeocodeCacheEntry: Codable, Equatable {
    public let query: String
    /// 失敗時は nil。
    public let latitude: Double?
    public let longitude: Double?
    public let resolvedAt: Date

    public init(query: String, latitude: Double?, longitude: Double?, resolvedAt: Date) {
        self.query = query
        self.latitude = latitude
        self.longitude = longitude
        self.resolvedAt = resolvedAt
    }

    public var isSuccess: Bool { latitude != nil && longitude != nil }
}
