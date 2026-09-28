import Foundation

/// 面板顶栏类型芯片。与冒号前缀一一对应；「全部」表示不加类型过滤。
public enum SearchTypeChip: String, Sendable, CaseIterable, Equatable {
    case all
    case text
    case image
    case favorite
    case secret

    public var title: String {
        switch self {
        case .all: "全部"
        case .text: "文本"
        case .image: "图片"
        case .favorite: "收藏"
        case .secret: "密钥"
        }
    }
}

/// 搜索查询：关键词 + 可选的 `:img` / `:text` / `:fav` / `:secret` 筛选前缀。
/// 前缀过滤（仅识别开头一个前缀，且必须是整个词——后面跟空白或结尾）：
///   `:img` / `:i`   → 只看图片
///   `:text` / `:t`  → 只看文本
///   `:fav` / `:f` / `fav` → 只看收藏
///   `:secret` / `:s` → 只看密钥
/// 其余部分为关键词（子串语义）。
/// 顶栏芯片与上述前缀等价：芯片只换类型过滤，不丢关键词。
public struct SearchQuery: Sendable, Equatable {
    public var keyword: String
    public var kindFilter: ClipItemKind?
    public var favoritesOnly: Bool
    /// 只看敏感条目（密钥/令牌）：对应 :secret / :s 前缀
    public var secretsOnly: Bool

    public init(keyword: String = "", kindFilter: ClipItemKind? = nil, favoritesOnly: Bool = false, secretsOnly: Bool = false) {
        self.keyword = keyword
        self.kindFilter = kindFilter
        self.favoritesOnly = favoritesOnly
        self.secretsOnly = secretsOnly
    }

    /// 已剥离前缀的关键词 + 芯片。不再解析 `keyword`，避免把正文里的 `fav` 当成前缀。
    public init(keyword: String, chip: SearchTypeChip) {
        switch chip {
        case .all:
            self.init(keyword: keyword)
        case .text:
            self.init(keyword: keyword, kindFilter: .text)
        case .image:
            self.init(keyword: keyword, kindFilter: .image)
        case .favorite:
            self.init(keyword: keyword, favoritesOnly: true)
        case .secret:
            self.init(keyword: keyword, secretsOnly: true)
        }
    }

    public init(parsing raw: String) {
        var q = raw.trimmingCharacters(in: .whitespaces)
        var kind: ClipItemKind? = nil
        var fav = false
        var secret = false
        let lower = q.lowercased()

        /// 前缀必须是整个词：后面是空白或结尾。否则 "favicon" 会被读成 "fav" + "icon"。
        func stripPrefix(_ prefixes: [String]) -> Bool {
            for p in prefixes where lower.hasPrefix(p) {
                let rest = q.dropFirst(p.count)
                guard rest.first?.isWhitespace ?? true else { continue }
                q = String(rest).trimmingCharacters(in: .whitespaces)
                return true
            }
            return false
        }

        if stripPrefix([":img", ":i"]) {
            kind = .image
        } else if stripPrefix([":text", ":t"]) {
            kind = .text
        } else if stripPrefix([":fav", ":f", "fav"]) {
            fav = true
        } else if stripPrefix([":secret", ":s"]) {
            secret = true
        }

        self.keyword = q
        self.kindFilter = kind
        self.favoritesOnly = fav
        self.secretsOnly = secret
    }

    public var isEmpty: Bool {
        keyword.isEmpty && kindFilter == nil && !favoritesOnly && !secretsOnly
    }

    public var typeChip: SearchTypeChip {
        if secretsOnly { return .secret }
        if favoritesOnly { return .favorite }
        switch kindFilter {
        case .image: return .image
        case .text: return .text
        case nil: return .all
        }
    }

    /// 搜索框变更：打了冒号前缀则以它为准并同步芯片；否则保留当前芯片，只更新关键词。
    public static func resolving(field raw: String, chip: SearchTypeChip) -> (query: SearchQuery, chip: SearchTypeChip) {
        let parsed = SearchQuery(parsing: raw)
        if parsed.kindFilter != nil || parsed.favoritesOnly || parsed.secretsOnly {
            return (parsed, parsed.typeChip)
        }
        return (SearchQuery(keyword: parsed.keyword, chip: chip), chip)
    }
}
