import Foundation

/// 密钥引擎默认名：标记时没给名字就用 `jiantieban/<id>`，列表把它当作"没起名"。
/// 生成和识别放在一起：改格式只改这里，列表不会突然露出引擎内部名字。
/// 密钥遮罩：只为认出是哪一条，不还原长度。
public enum SecretMask {
    /// 固定 前 2 + 6 个 • + 后 4；8 个字符以内全遮。
    public static func fixed(_ value: String) -> String {
        let chars = Array(value.replacingOccurrences(of: "\n", with: " "))
        guard chars.count > 8 else { return String(repeating: "•", count: min(chars.count, 6)) }
        return String(chars.prefix(2)) + "••••••" + String(chars.suffix(4))
    }

    /// 旧数据里的 * / • 连串压到最多 6 个，统一显示成 •。
    public static func compact(_ preview: String) -> String {
        var out = ""
        var run = 0
        for ch in preview {
            if ch == "*" || ch == "•" {
                run += 1
                if run <= 6 { out.append("•") }
            } else {
                run = 0
                out.append(ch)
            }
        }
        return out
    }
}

public enum SecretNaming {
    private static let defaultPrefix = "jiantieban/"

    public static func defaultName(forItemID id: Int64) -> String {
        defaultPrefix + String(id)
    }

    public static func isDefault(_ name: String) -> Bool {
        name.hasPrefix(defaultPrefix) && name.dropFirst(defaultPrefix.count).allSatisfy(\.isNumber)
    }

    /// 命名推荐：`<命名空间>/<KEY>`，和 jt 的 `myapp/OPENAI_API_KEY` 这种写法一致（ADR-0001 / 05）。
    /// KEY 按识别到的类型给；认不出只给 `<命名空间>/`；命名空间也没有（jt 为空或读不到）就只给 KEY；两样都没有返回 nil。
    public static func suggestion(forPlaintext text: String, namespace: String?) -> String? {
        compose(namespace: namespace, key: key(forPlaintext: text))
    }

    /// 只知道类型（已标记、明文已交给 jt）时的推荐。
    public static func suggestion(for type: SecretType?, namespace: String?) -> String? {
        compose(namespace: namespace, key: type.flatMap(key(for:)))
    }

    /// 预填的推荐整体选中：回车接受、直接打字整体替换。只有 `<命名空间>/` 时光标停在末尾，接着打 KEY。
    public static func selectsWholeSuggestion(_ suggestion: String) -> Bool {
        !suggestion.hasSuffix("/")
    }

    /// 最近用过的命名空间：jt 里 updated_at 最新的那条起过名、带命名空间的记录。
    /// 引擎默认名（`jiantieban/<数字>`，刚标记还没起名的）和没有时间戳的旧条目不算；同一时刻的按名称取第一个，结果稳定。
    public static func recentNamespace(in records: [SecretRecord]) -> String? {
        records
            .compactMap { record -> (Date, String, String)? in
                guard !isDefault(record.name), let namespace = record.namespace, let updated = record.updatedAt else { return nil }
                return (updated, record.name, namespace)
            }
            .min { a, b in a.0 != b.0 ? a.0 > b.0 : a.1 < b.1 }?
            .2
    }

    /// 明文能看出的 KEY：env 赋值用变量名，连接串按协议（DATABASE_URL / REDIS_URL…），其余按类型。
    static func key(forPlaintext text: String) -> String? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let type = SecretDetector.detect(t) else { return nil }
        switch type {
        case .genericEnv:
            return assignedVariable(t)
        case .connectionString:
            if let variable = assignedVariable(t) { return variable } // APP_DATABASE_URL=postgres://… 比猜的准
            let scheme = t.range(of: #"(?i)\b(mongodb(\+srv)?|postgres(ql)?|mysql|redis|amqp)://"#, options: .regularExpression)
                .map { t[$0].lowercased() } ?? ""
            return scheme.hasPrefix("mongodb") ? "MONGODB_URI"
                : scheme.hasPrefix("redis") ? "REDIS_URL"
                : scheme.hasPrefix("amqp") ? "AMQP_URL" : "DATABASE_URL"
        default:
            return key(for: type)
        }
    }

    static func key(for type: SecretType) -> String? {
        switch type {
        case .openaiKey: return "OPENAI_API_KEY"
        case .anthropicKey: return "ANTHROPIC_API_KEY"
        case .githubPat: return "GITHUB_TOKEN"
        case .awsAccessKey: return "AWS_ACCESS_KEY_ID"
        case .gcpApiKey: return "GOOGLE_API_KEY"
        case .googleApiKey: return "GOOGLE_ACCESS_TOKEN"
        case .slackToken: return "SLACK_TOKEN"
        case .stripeKey: return "STRIPE_SECRET_KEY"
        case .pemPrivateKey: return "PRIVATE_KEY"
        case .connectionString: return "DATABASE_URL"
        // 看不出是哪家的：只给命名空间，KEY 让人自己写
        case .jwt, .bearerToken, .genericEnv, .other: return nil
        }
    }

    /// `NAME=value` 里的 NAME；不像环境变量名就 nil。
    private static func assignedVariable(_ text: String) -> String? {
        guard let equals = text.firstIndex(of: "=") else { return nil }
        let name = text[..<equals].trimmingCharacters(in: .whitespaces)
        return name.range(of: #"^[A-Za-z_][A-Za-z0-9_]*$"#, options: .regularExpression) != nil ? name : nil
    }

    private static func compose(namespace: String?, key: String?) -> String? {
        switch (namespace, key) {
        case let (namespace?, key?): return namespace + "/" + key
        case let (namespace?, nil): return namespace + "/"
        case let (nil, key?): return key
        case (nil, nil): return nil
        }
    }
}

extension ClipItem {
    /// 用户真正起过的名字；引擎默认名当作没起名。
    public var userFacingSecretName: String? {
        guard let name = secretName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return nil }
        return SecretNaming.isDefault(name) ? nil : name
    }

    /// 列表里的一行标题：图片 → OCR 文字或"图片"；密钥 → 名字 / 遮罩 / "未命名密钥"；文本 → 压成一行的内容。
    public var displayTitle: String {
        switch kind {
        case .image:
            let ocr = ocrText?
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return ocr.isEmpty ? "图片" : ocr
        case .text:
            if isSecret {
                if let name = userFacingSecretName { return name }
                if let preview = maskedPreview, !preview.isEmpty { return SecretMask.compact(preview) }
                return "未命名密钥"
            }
            return content
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}
