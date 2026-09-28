import Foundation

/// 剪贴板条目类型：text / image
public enum ClipItemKind: String, Codable, Sendable {
    case text
    case image
}

/// 复制时浏览器前台页面的线索；只记录普通窗口，不能证明剪贴板一定由该页面写入。
public struct BrowserSource: Sendable, Equatable {
    public var bundleID: String
    public var title: String
    public var url: String

    public init(bundleID: String, title: String, url: String) {
        self.bundleID = bundleID
        self.title = title
        self.url = url
    }
}

/// 一条剪贴板历史记录
public struct ClipItem: Sendable, Equatable {
    public var id: Int64
    public var kind: ClipItemKind
    /// 文本内容（image 类型为 "[图片]" 占位）
    public var content: String
    /// 图片原图路径（仅 image）
    public var imagePath: String?
    /// 缩略图路径（仅 image）
    public var thumbPath: String?
    /// 图片 SHA256（仅 image，用于去重）
    public var imageHash: String?
    /// OCR 识别文本（仅 image，参与搜索）
    public var ocrText: String?
    public var isFavorite: Bool
    /// 从本 App 成功发起过贴回：不受历史时长/条数清理限制（仅复制不算）。
    public var wasPasted: Bool
    /// 最近一次复制时的浏览器页面；重复内容只保留最近来源。
    public var browserSource: BrowserSource?
    /// 是否为敏感值（密钥/令牌）。命中后 content 存的是占位符 token，而非明文
    public var isSecret: Bool
    /// 占位符 token（如 jt://secret/8xk2），敏感条目才有；真值在内存保险库，不在本结构
    public var secretToken: String?
    /// 敏感类型 rawValue（SecretType），用于展示与 agent 侧类型判断
    public var secretType: String?
    /// 密钥记录的人可读名称 / 备注（明文存储）
    public var secretName: String?
    /// 密钥记录的遮罩预览（明文存储），如 `sk-••••••••3fA2`
    public var maskedPreview: String?
    /// 引用指向的 jt 记录已经删了（展示缓存，jt 列表刷新时更新）：只剩删除可做
    public var secretMissing: Bool
    /// 最近一次复制时间（去重时刷新）
    public var lastCopiedAt: Date
    public var createdAt: Date

    public init(
        id: Int64 = 0,
        kind: ClipItemKind,
        content: String,
        imagePath: String? = nil,
        thumbPath: String? = nil,
        imageHash: String? = nil,
        ocrText: String? = nil,
        isFavorite: Bool = false,
        wasPasted: Bool = false,
        browserSource: BrowserSource? = nil,
        isSecret: Bool = false,
        secretToken: String? = nil,
        secretType: String? = nil,
        secretName: String? = nil,
        maskedPreview: String? = nil,
        secretMissing: Bool = false,
        lastCopiedAt: Date = Date(),
        createdAt: Date = Date()
    ) {
        self.id = id
        self.kind = kind
        self.content = content
        self.imagePath = imagePath
        self.thumbPath = thumbPath
        self.imageHash = imageHash
        self.ocrText = ocrText
        self.isFavorite = isFavorite
        self.wasPasted = wasPasted
        self.browserSource = browserSource
        self.isSecret = isSecret
        self.secretToken = secretToken
        self.secretType = secretType
        self.secretName = secretName
        self.maskedPreview = maskedPreview
        self.secretMissing = secretMissing
        self.lastCopiedAt = lastCopiedAt
        self.createdAt = createdAt
    }
}
