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
    /// 支援を送信済みのまま予定が消えたため、返せなくなった枠の数。
    ///
    /// 支援を送ってしまった枠は、その予定がカレンダーから消えても再利用しない。
    /// 送信済みの通知は取り消せないので、1日の上限を消費したものとして数える必要がある。
    /// 支援を送る前に消えた予定の枠はここに数えず、そのまま次の予定に回す。
    public var supportSentSlotCount: Int

    public init(
        date: Date,
        confirmedKeys: [EventKey],
        confirmedAt: Date? = nil,
        slotLimit: Int,
        supportSentSlotCount: Int = 0
    ) {
        self.date = date
        self.confirmedKeys = confirmedKeys
        self.confirmedAt = confirmedAt
        self.slotLimit = slotLimit
        self.supportSentSlotCount = supportSentSlotCount
    }

    private enum CodingKeys: String, CodingKey {
        case date, confirmedKeys, confirmedAt, slotLimit, supportSentSlotCount
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        date = try container.decode(Date.self, forKey: .date)
        confirmedKeys = try container.decode([EventKey].self, forKey: .confirmedKeys)
        confirmedAt = try container.decodeIfPresent(Date.self, forKey: .confirmedAt)
        slotLimit = try container.decode(Int.self, forKey: .slotLimit)
        supportSentSlotCount = try container.decodeIfPresent(Int.self, forKey: .supportSentSlotCount) ?? 0
    }
}
