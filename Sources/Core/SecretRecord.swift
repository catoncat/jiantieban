import Foundation

/// jt 里的一条密钥记录（`jt ls --json` 的一项）。密钥视图的行模型：
/// 和剪贴板记录是两回事——没有剪贴板 id，不写进 items 表（ADR-0001）。
public struct SecretRecord: Equatable, Sendable {
    /// jt 的记录 id（引用里 `jt://secret/` 后面那段）
    public let id: String
    public let reference: String
    public var name: String
    /// jt 生成的遮罩（前 2 + * + 后 4），只为认出是哪一条
    public let preview: String
    /// 旧 vault 条目没有时间
    public let createdAt: Date?
    public var updatedAt: Date?

    public init(id: String, reference: String, name: String, preview: String, createdAt: Date? = nil, updatedAt: Date? = nil) {
        self.id = id
        self.reference = reference
        self.name = name
        self.preview = preview
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// 命名空间：名称里第一个 `/` 之前的部分。没有 `/`（或以 `/` 开头）的不属于任何组。
    public var namespace: String? {
        guard let slash = name.firstIndex(of: "/"), slash != name.startIndex else { return nil }
        return String(name[..<slash])
    }

    /// 组标题：命名空间，或"未分组"。
    public var groupTitle: String { namespace ?? SecretRecords.ungroupedTitle }

    /// 行标题：组标题已经写了命名空间，这里只显示后半段；引擎默认名（`jiantieban/<数字>`）当作没起名。
    public var displayTitle: String {
        if SecretNaming.isDefault(name) { return "未命名密钥" }
        guard let namespace else { return name }
        let key = name.dropFirst(namespace.count + 1)
        return key.isEmpty ? name : String(key)
    }

    /// 用户真正起过的名字；引擎默认名当作没起名（改名框留空，显示占位）。
    public var userFacingName: String? { SecretNaming.isDefault(name) ? nil : name }

    public var displayPreview: String { SecretMask.compact(preview) }
}

public enum SecretRecords {
    public static let ungroupedTitle = "未分组"

    /// 解析 `jt ls --json`。
    public static func decode(_ data: Data) throws -> [SecretRecord] {
        try JSONDecoder().decode([Entry].self, from: data).map { entry in
            SecretRecord(id: entry.id, reference: entry.ref, name: entry.name, preview: entry.preview,
                         createdAt: entry.created_at.flatMap(parseDate), updatedAt: entry.updated_at.flatMap(parseDate))
        }
    }

    /// 按命名空间分组（组按名字排，未分组放最后），组内按名称排；同名不会出现（jt 保证），最后按 id 兜底保证稳定。
    public static func sorted(_ records: [SecretRecord]) -> [SecretRecord] {
        records.sorted { a, b in
            let (na, nb) = (a.namespace, b.namespace)
            if (na == nil) != (nb == nil) { return nb == nil }
            if let na, let nb, na != nb {
                let order = na.caseInsensitiveCompare(nb)
                if order != .orderedSame { return order == .orderedAscending }
                return na < nb
            }
            let order = a.name.caseInsensitiveCompare(b.name)
            if order != .orderedSame { return order == .orderedAscending }
            return a.name != b.name ? a.name < b.name : a.id < b.id
        }
    }

    /// 搜索只看名称（含命名空间），不分大小写；空格隔开的每个词都要出现。
    public static func filter(_ records: [SecretRecord], keyword: String) -> [SecretRecord] {
        let words = keyword.split(whereSeparator: \.isWhitespace).map { $0.lowercased() }
        guard !words.isEmpty else { return records }
        return records.filter { record in
            let name = record.name.lowercased()
            return words.allSatisfy { name.contains($0) }
        }
    }

    /// 已排好序的列表里，第 index 行上方要不要画组标题：每组第一行画，其余不画。
    public static func groupHeader(at index: Int, in records: [SecretRecord]) -> String? {
        guard records.indices.contains(index) else { return nil }
        let title = records[index].groupTitle
        return index == 0 || records[index - 1].groupTitle != title ? title : nil
    }

    private struct Entry: Decodable {
        let id: String
        let ref: String
        let name: String
        let preview: String
        let created_at: String?
        let updated_at: String?
    }

    /// 不用 ISO8601DateFormatter()：每条记录新建两个 formatter，90 条就要几十毫秒（进密钥视图时卡在主线程）
    private static func parseDate(_ text: String) -> Date? {
        try? Date(text, strategy: .iso8601)
    }
}
