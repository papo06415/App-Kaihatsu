import Foundation

/// JSON での永続化。読み込み失敗（ファイル無し・JSON 破損）は空データとして扱い、決してクラッシュしない。
public struct Repository {
    public enum FileName {
        public static let snapshots = "snapshots.json"
        public static let slots = "slots.json"
        public static let geocode = "geocode.json"
        public static let preferences = "preferences.json"
    }

    private let store: FileStore

    public init(store: FileStore) {
        self.store = store
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// 読めない・壊れている場合は nil を返す。例外は投げない。
    private func loadOrNil<T: Decodable>(_ type: T.Type, from name: String) -> T? {
        guard let data = try? store.read(name) else { return nil }
        return try? Self.makeDecoder().decode(T.self, from: data)
    }

    private func save<T: Encodable>(_ value: T, to name: String) throws {
        do {
            let data = try Self.makeEncoder().encode(value)
            try store.write(data, to: name)
        } catch {
            throw CalendarLayerError.persistenceFailed("\(name): \(error)")
        }
    }

    // MARK: - スナップショット
    //
    // 辞書のキーが構造体（EventKey）なので JSONEncoder では直接エンコードできない。
    // EventSnapshot は自身の key を持っているので、配列として保存し読み込み時に辞書へ戻す。

    public func loadSnapshots() -> [EventKey: EventSnapshot] {
        guard let list = loadOrNil([EventSnapshot].self, from: FileName.snapshots) else { return [:] }
        return Dictionary(list.map { ($0.key, $0) }, uniquingKeysWith: { _, latest in latest })
    }

    public func saveSnapshots(_ snapshots: [EventKey: EventSnapshot]) throws {
        let list = snapshots.values.sorted { EventKey.isOrderedBefore($0.key, $1.key) }
        try save(list, to: FileName.snapshots)
    }

    // MARK: - 枠
    //
    // [Date: DailySlots] も同じ理由で配列として保存する（Date は JSON のキーになれない）。

    public func loadSlots() -> [Date: DailySlots] {
        guard let list = loadOrNil([DailySlots].self, from: FileName.slots) else { return [:] }
        return Dictionary(list.map { ($0.date, $0) }, uniquingKeysWith: { _, latest in latest })
    }

    public func saveSlots(_ slots: [Date: DailySlots]) throws {
        let list = slots.values.sorted { $0.date < $1.date }
        try save(list, to: FileName.slots)
    }

    // MARK: - ジオコーディングキャッシュ

    public func loadGeocodeCache() -> [String: GeocodeCacheEntry] {
        guard let list = loadOrNil([GeocodeCacheEntry].self, from: FileName.geocode) else { return [:] }
        return Dictionary(list.map { ($0.query, $0) }, uniquingKeysWith: { _, latest in latest })
    }

    public func saveGeocodeCache(_ cache: [String: GeocodeCacheEntry]) throws {
        let list = cache.values.sorted { $0.query < $1.query }
        try save(list, to: FileName.geocode)
    }

    // MARK: - 設定

    public func loadPreferences() -> UserPreferences {
        loadOrNil(UserPreferences.self, from: FileName.preferences) ?? UserPreferences()
    }

    public func savePreferences(_ preferences: UserPreferences) throws {
        try save(preferences, to: FileName.preferences)
    }
}
