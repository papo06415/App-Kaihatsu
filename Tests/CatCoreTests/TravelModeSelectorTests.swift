import XCTest
@testable import CatCore

final class TravelModeSelectorTests: XCTestCase {
    private let selector = TravelModeSelector()
    private let origin = EventLocation(latitude: 35.681236, longitude: 139.767125, name: "東京駅")

    /// 東京駅から真北に指定メートルだけ離れた地点。緯度1度あたりの距離から逆算する。
    private func northOf(_ meters: Double) -> EventLocation {
        let metersPerDegreeLatitude = 6_371_008.8 * .pi / 180
        return EventLocation(
            latitude: origin.latitude + meters / metersPerDegreeLatitude,
            longitude: origin.longitude,
            name: nil
        )
    }

    func testDistanceHelperIsAccurateEnoughToPlaceTestPoints() {
        let distance = TravelModeSelector.straightLineDistanceMeters(from: origin, to: northOf(1_500))
        XCTAssertEqual(distance, 1_500, accuracy: 0.1)
    }

    // MARK: - 境界
    //
    // 緯度経度から「ちょうど 1500.0m」の地点は浮動小数点の丸めで作れないため、
    // 境界そのものは距離を直接与えて検証する。

    func testExactlyFifteenHundredMetersIsWalking() {
        XCTAssertEqual(
            selector.mode(forDistanceMeters: 1_500, primaryTransport: .transit),
            .walking,
            "1.5km ちょうどは徒歩"
        )
    }

    func testJustOverFifteenHundredMetersUsesTheSelectedTransport() {
        XCTAssertEqual(
            selector.mode(forDistanceMeters: 1_500.001, primaryTransport: .transit),
            .transit,
            "1.5km をわずかでも超えたら選択した交通手段"
        )
    }

    func testJustUnderFifteenHundredMetersIsWalking() {
        XCTAssertEqual(
            selector.mode(forDistanceMeters: 1_499.999, primaryTransport: .automobile),
            .walking
        )
    }

    // MARK: - 座標から

    func testCoordinatesJustUnderThresholdAreWalking() {
        let result = selector.select(from: origin, to: northOf(1_490), primaryTransport: .transit)

        XCTAssertEqual(result.mode, .walking)
    }

    func testCoordinatesJustOverThresholdUseTheSelectedTransport() {
        let result = selector.select(from: origin, to: northOf(1_510), primaryTransport: .transit)

        XCTAssertEqual(result.mode, .transit)
    }

    func testOverThresholdWithAutomobileSelected() {
        let result = selector.select(from: origin, to: northOf(5_000), primaryTransport: .automobile)

        XCTAssertEqual(result.mode, .automobile)
    }

    func testOverThresholdWithTransitSelected() {
        let result = selector.select(from: origin, to: northOf(5_000), primaryTransport: .transit)

        XCTAssertEqual(result.mode, .transit)
    }

    /// 閾値以下なら、選択した交通手段が何であれ徒歩。
    func testUnderThresholdIgnoresTheSelectedTransport() {
        for transport in [PrimaryTransport.transit, .automobile] {
            let result = selector.select(from: origin, to: northOf(800), primaryTransport: transport)
            XCTAssertEqual(result.mode, .walking, "\(transport) を選んでいても徒歩")
        }
    }

    func testSameLocationIsZeroDistanceAndWalking() {
        let result = selector.select(from: origin, to: origin, primaryTransport: .automobile)

        XCTAssertEqual(result.distanceMeters, 0, accuracy: 0.001)
        XCTAssertEqual(result.mode, .walking)
    }

    func testDistanceIsSymmetric() {
        let far = northOf(3_000)
        XCTAssertEqual(
            TravelModeSelector.straightLineDistanceMeters(from: origin, to: far),
            TravelModeSelector.straightLineDistanceMeters(from: far, to: origin),
            accuracy: 0.001
        )
    }
}
