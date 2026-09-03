import XCTest
@testable import CatCore

final class RepositoryTests: XCTestCase {
    private var store: InMemoryFileStore!
    private var repository: Repository!

    override func setUp() {
        super.setUp()
        store = InMemoryFileStore()
        repository = Repository(store: store)
    }

    func testSnapshotsRoundTrip() throws {
        let key = Fixture.key("a", Fixture.date(2026, 9, 1, 10, 0))
        let snapshot = EventSnapshot(
            key: key,
            startDate: Fixture.date(2026, 9, 1, 10, 0),
            endDate: Fixture.date(2026, 9, 1, 11, 0),
            latitude: Fixture.tokyo.latitude,
            longitude: Fixture.tokyo.longitude,
            editCount: 2,
            isCompleted: true,
            completedAt: Fixture.date(2026, 9, 1, 10, 0)
        )

        try repository.saveSnapshots([key: snapshot])

        XCTAssertEqual(repository.loadSnapshots(), [key: snapshot])
    }

    func testSlotsRoundTrip() throws {
        let day = Fixture.date(2026, 9, 1)
        let slots = DailySlots(
            date: day,
            confirmedKeys: [Fixture.key("a", Fixture.date(2026, 9, 1, 10, 0))],
            confirmedAt: Fixture.date(2026, 8, 31, 20, 0),
            slotLimit: 3,
            releasedSlotCount: 1
        )

        try repository.saveSlots([day: slots])

        XCTAssertEqual(repository.loadSlots(), [day: slots])
    }

    func testGeocodeCacheRoundTrip() throws {
        let entry = GeocodeCacheEntry(
            query: "東京駅",
            latitude: Fixture.tokyo.latitude,
            longitude: Fixture.tokyo.longitude,
            resolvedAt: Fixture.date(2026, 9, 1, 9, 0)
        )
        let failure = GeocodeCacheEntry(
            query: "謎",
            latitude: nil,
            longitude: nil,
            resolvedAt: Fixture.date(2026, 9, 1, 9, 0)
        )

        try repository.saveGeocodeCache(["東京駅": entry, "謎": failure])

        XCTAssertEqual(repository.loadGeocodeCache(), ["東京駅": entry, "謎": failure])
    }

    func testPreferencesRoundTrip() throws {
        let preferences = UserPreferences(
            homeLatitude: 35.0,
            homeLongitude: 139.0,
            primaryTransport: .automobile,
            isPremium: true,
            hasCompletedOnboarding: true
        )

        try repository.savePreferences(preferences)

        XCTAssertEqual(repository.loadPreferences(), preferences)
    }

    func testDatesAreEncodedAsISO8601() throws {
        let day = Fixture.date(2026, 9, 1)
        try repository.saveSlots([day: DailySlots(date: day, confirmedKeys: [], slotLimit: 3)])

        let json = String(decoding: store.files[Repository.FileName.slots] ?? Data(), as: UTF8.self)
        XCTAssertTrue(json.contains("2026-08-31T15:00:00Z"), "ISO8601 (UTC) で書かれていること: \(json)")
    }

    // MARK: - 壊れていても落ちない

    func testMissingFilesLoadAsEmptyData() {
        XCTAssertTrue(repository.loadSnapshots().isEmpty)
        XCTAssertTrue(repository.loadSlots().isEmpty)
        XCTAssertTrue(repository.loadGeocodeCache().isEmpty)
        XCTAssertEqual(repository.loadPreferences(), UserPreferences())
    }

    func testCorruptJsonLoadsAsEmptyData() {
        store.putRaw("{ this is not json", to: Repository.FileName.snapshots)
        store.putRaw("[[[", to: Repository.FileName.slots)
        store.putRaw("", to: Repository.FileName.geocode)
        store.putRaw("null", to: Repository.FileName.preferences)

        XCTAssertTrue(repository.loadSnapshots().isEmpty)
        XCTAssertTrue(repository.loadSlots().isEmpty)
        XCTAssertTrue(repository.loadGeocodeCache().isEmpty)
        XCTAssertEqual(repository.loadPreferences(), UserPreferences())
    }

    func testWellFormedJsonWithTheWrongShapeLoadsAsEmptyData() {
        store.putRaw(#"{"unexpected": true}"#, to: Repository.FileName.snapshots)

        XCTAssertTrue(repository.loadSnapshots().isEmpty)
    }

    func testUnreadableStoreLoadsAsEmptyData() {
        store.failReads = true

        XCTAssertTrue(repository.loadSnapshots().isEmpty)
        XCTAssertEqual(repository.loadPreferences(), UserPreferences())
    }

    func testSlotsWrittenBeforeReleasedSlotCountExistedStillDecode() {
        store.putRaw(
            #"[{"date":"2026-09-01T00:00:00Z","confirmedKeys":[],"slotLimit":3}]"#,
            to: Repository.FileName.slots
        )

        let loaded = repository.loadSlots()

        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.values.first?.releasedSlotCount, 0)
    }

    func testWriteFailureIsReportedAsPersistenceFailed() {
        store.failWrites = true

        XCTAssertThrowsError(try repository.savePreferences(UserPreferences())) { error in
            guard case CalendarLayerError.persistenceFailed = error else {
                return XCTFail("期待と違うエラー: \(error)")
            }
        }
    }
}
