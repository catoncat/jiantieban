import Foundation

/// 检测到的敏感值类别。rawValue 同时作为占位符的语义标签与存储的类型字段。
public enum SecretType: String, Sendable, Codable {
    case openaiKey = "openai-api-key"
    case anthropicKey = "anthropic-api-key"
    case githubPat = "github-pat"
    case awsAccessKey = "aws-access-key"
    case gcpApiKey = "gcp-api-key"
    case googleApiKey = "google-api-key"
    case stripeKey = "stripe-key"
    case slackToken = "slack-token"
    case jwt = "jwt"
    case pemPrivateKey = "pem-private-key"
    case bearerToken = "bearer-token"
    case connectionString = "connection-string"
    case genericEnv = "env-secret"
    case other = "secret"

    /// 给人/agent 看的短标签
    public var label: String {
        switch self {
        case .openaiKey: return "OpenAI Key"
        case .anthropicKey: return "Anthropic Key"
        case .githubPat: return "GitHub Token"
        case .awsAccessKey: return "AWS Key"
        case .gcpApiKey: return "GCP Key"
        case .googleApiKey: return "Google Key"
        case .stripeKey: return "Stripe Key"
        case .slackToken: return "Slack Token"
        case .jwt: return "JWT"
        case .pemPrivateKey: return "PEM 私钥"
        case .bearerToken: return "Bearer Token"
        case .connectionString: return "连接串"
        case .genericEnv: return "Env 密钥"
        case .other: return "密钥"
        }
    }
}

/// 敏感文本检测：保守规则，只在高置信模式命中才视为密钥。
/// 与 Grafana sanitizer（gitleaks 规则集）思路一致，但本地、轻量、不依赖网络。
public enum SecretDetector {
    public static func detect(_ text: String) -> SecretType? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }

        // 已知前缀：整段必须是一个完整的令牌（无空白、字符集和长度对得上）。
        // 只看开头会把 "sk-learn 是 Python 库" 这种普通句子认成 OpenAI Key。
        // 更具体的前缀排在前面：sk-ant- 也以 sk- 开头。
        for (pattern, type) in tokenRules where t.range(of: pattern, options: .regularExpression) != nil {
            return type
        }

        // PEM 私钥块
        if t.contains("-----BEGIN") && t.contains("PRIVATE KEY") { return .pemPrivateKey }

        // Bearer 令牌
        if matches(t, #"(?i)Bearer\s+[A-Za-z0-9._\-]{16,}"#) { return .bearerToken }

        // 连接串
        if matches(t, #"(?i)\b(mongodb(\+srv)?|postgres(ql)?|mysql|redis|amqp|mongodb)://"#) { return .connectionString }

        // env 赋值类：KEYWORD(含 password/secret/token/key)=值
        if matches(t, #"(?ix)^\s*\w*(PASSWORD|SECRET|TOKEN|API_?KEY|ACCESS_?KEY|PRIVATE_?KEY|CLIENT_?SECRET|PASSWD)\w*\s*=\s*\S.+"#) {
            return .genericEnv
        }

        return nil
    }

    private static let tokenRules: [(String, SecretType)] = [
        (#"^sk-ant-[A-Za-z0-9_\-]{20,}$"#, .anthropicKey),
        (#"^sk-[A-Za-z0-9_\-]{20,}$"#, .openaiKey),
        (#"^(ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{16,}$"#, .githubPat),
        (#"^(AKIA|ASIA)[A-Z0-9]{16}$"#, .awsAccessKey),
        (#"^AIza[A-Za-z0-9_\-]{20,}$"#, .gcpApiKey),
        (#"^ya29\.[A-Za-z0-9_\-]{20,}$"#, .googleApiKey),
        (#"^xox[bpar]-[A-Za-z0-9\-]{10,}$"#, .slackToken),
        (#"^(sk_live|sk_test|rk_live)_[A-Za-z0-9]{10,}$"#, .stripeKey),
        // JWT：三段 base64url，以 eyJ 开头
        (#"^eyJ[A-Za-z0-9_\-]+\.[A-Za-z0-9_\-]+\.[A-Za-z0-9_\-]*$"#, .jwt),
    ]

    private static func matches(_ text: String, _ pattern: String) -> Bool {
        text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }
}
