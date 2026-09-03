import Foundation

/// その日にサポート対象として確定した予定の枠。
public struct DailySlots: Codable, Equatable {
    /// その日の0時（注入された Calendar のタイムゾーン基準）。
    public let date: Date
    public var confirmedKeys: [EventKey]
    /// 第1段階の確定を実行した日時。未実行なら nil。
    public var confirmedAt: Date?
    /// 無料版は3、Premium は Int.max。
    public let slotLimit: Int
    /// 一度消費されたあと解放された枠の数。
    ///
    /// 仕様書に無い追加フィールド。「解放された枠に既存の枠外予定が繰り上がらない」
    /// というルールを起動をまたいで保つために必要（README の「判断に迷った箇所」を参照）。
    /// 既存データには存在しないため、デコード時は 0 として扱う。
    public var releasedSlotCount: Int

    public init(
        date: Date,
        confirmedKeys: [EventKey],
        confirmedAt: Date? = nil,
        slotLimit: Int,
        releasedSlotCount: Int = 0
    ) {
        self.date = date
        self.confirmedKeys = confirmedKeys
        self.confirmedAt = confirmedAt
        self.slotLimit = slotLimit
        self.releasedSlotCount = releasedSlotCount
    }

    private enum CodingKeys: String, CodingKey {
        case date, confirmedKeys, confirmedAt, slotLimit, releasedSlotCount
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        date = try c.decode(Date.self, forKey: .date)
        confirmedKeys = try c.decode([EventKey].self, forKey: .confirmedKeys)
        confirmedAt = try c.decodeIfPresent(Date.self, forKey: .confirmedAt)
        slotLimit = try c.decode(Int.self, forKey: .slotLimit)
        releasedSlotCount = try c.decodeIfPresent(Int.self, forKey: .releasedSlotCount) ?? 0
    }
}
