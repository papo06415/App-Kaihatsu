import Foundation

/// 保存先ディレクトリの取得も Apple 依存（Application Support は Linux に存在しない）なので
/// ファイル入出力ごと抽象化する。
public protocol FileStore {
    func read(_ name: String) throws -> Data?
    func write(_ data: Data, to name: String) throws
    func delete(_ name: String) throws
}
