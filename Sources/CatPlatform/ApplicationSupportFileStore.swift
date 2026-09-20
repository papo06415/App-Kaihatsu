#if canImport(EventKit)
import Foundation
import CatCore

/// Application Support 配下にファイルを置く FileStore。
///
/// Caches は使わない。OS に削除されると編集回数や座標キャッシュが失われるため。
public struct ApplicationSupportFileStore: FileStore {
    private let directory: URL
    private let fileManager: FileManager

    public init(
        subdirectory: String = "CatCalendarLayer",
        fileManager: FileManager = .default
    ) throws {
        self.fileManager = fileManager
        let base = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        directory = base.appendingPathComponent(subdirectory, isDirectory: true)
        if !fileManager.fileExists(atPath: directory.path) {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    private func url(for name: String) -> URL {
        directory.appendingPathComponent(name, isDirectory: false)
    }

    public func read(_ name: String) throws -> Data? {
        let url = url(for: name)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        return try Data(contentsOf: url)
    }

    public func write(_ data: Data, to name: String) throws {
        // 書き込み途中でプロセスが落ちてもファイルが壊れないようにアトミックに置き換える。
        try data.write(to: url(for: name), options: .atomic)
    }

    public func delete(_ name: String) throws {
        let url = url(for: name)
        guard fileManager.fileExists(atPath: url.path) else { return }
        try fileManager.removeItem(at: url)
    }
}
#endif
