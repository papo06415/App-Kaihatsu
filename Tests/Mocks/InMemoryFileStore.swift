import Foundation
@testable import CatCore

/// テスト用の FileStore。辞書で保持する。
final class InMemoryFileStore: FileStore {
    enum StoreError: Error {
        case writeRefused
        case readRefused
    }

    private(set) var files: [String: Data] = [:]
    /// true にすると write が必ず失敗する。
    var failWrites = false
    /// true にすると read が必ず失敗する。
    var failReads = false

    init(files: [String: Data] = [:]) {
        self.files = files
    }

    func read(_ name: String) throws -> Data? {
        if failReads { throw StoreError.readRefused }
        return files[name]
    }

    func write(_ data: Data, to name: String) throws {
        if failWrites { throw StoreError.writeRefused }
        files[name] = data
    }

    func delete(_ name: String) throws {
        files.removeValue(forKey: name)
    }

    /// 壊れた JSON を仕込む。
    func putRaw(_ string: String, to name: String) {
        files[name] = Data(string.utf8)
    }
}
