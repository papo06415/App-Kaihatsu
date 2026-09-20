import Foundation

public enum PrimaryTransport: String, Codable, Equatable {
    /// 電車が多い。
    case transit
    /// 車が多い。
    case automobile
}

public struct UserPreferences: Codable, Equatable {
    public var homeLatitude: Double?
    public var homeLongitude: Double?
    public var primaryTransport: PrimaryTransport
    public var isPremium: Bool
    public var hasCompletedOnboarding: Bool

    public init(
        homeLatitude: Double? = nil,
        homeLongitude: Double? = nil,
        primaryTransport: PrimaryTransport = .transit,
        isPremium: Bool = false,
        hasCompletedOnboarding: Bool = false
    ) {
        self.homeLatitude = homeLatitude
        self.homeLongitude = homeLongitude
        self.primaryTransport = primaryTransport
        self.isPremium = isPremium
        self.hasCompletedOnboarding = hasCompletedOnboarding
    }
}
