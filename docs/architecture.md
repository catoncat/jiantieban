# jiantieban 技术架构

macOS 原生剪贴板管理器：资源占用低，界面用系统 Liquid Glass。逐项实现状态见 [STATUS.md](STATUS.md)，产品边界见 [PRD](product/PRD.md)。

## 1. 选型

| 维度 | 选择 | 不选 | 理由 |
|---|---|---|---|
| 语言 | 纯 Swift 6 | Rust 核心 + FFI | 计算量是微秒级，FFI 只增复杂度 |
| UI | AppKit 为主，SwiftUI 只做设置页和首启 | 全 SwiftUI | `NSTableView` 自带虚拟化，长列表和长文本更省内存、更好控 |
| 视觉 | `NSGlassEffectView`；“兼容”风格用 `NSVisualEffectView` | 自绘毛玻璃 | 系统材质，自动适配深浅色 |
| 存储 | 系统 SQLite3 + FTS5（trigram），薄封装 | SwiftData、GRDB | FTS5 是按键即搜的核心；系统 libsqlite3 自带；零依赖 |
| 去重 | CryptoKit SHA256 | 第三方哈希库 | 剪贴板体量下无差别 |
| 全局热键 | Carbon `RegisterEventHotKey` | 快捷键库 | 零依赖 |
| 工具链 | Command Line Tools + SPM + Makefile | Xcode | CLT 足够编译、签名、公证 |
| 分发 | 不沙盒；开发用自签证书 | App Store | 读剪贴板 + 模拟 ⌘V 与沙盒冲突 |
| 最低系统 | macOS 26 | — | `NSGlassEffectView` 要求 26.0+ |
| 密钥 | 交给 [jt](https://github.com/catoncat/jt) | 本地自建加密 | 见 [ADR-0001](adr/0001-jt-is-the-secret-source-of-truth.md) |

没有第三方依赖，App 不调用任何网络 API。

## 2. 模块

```
Sources/
├── Core/              不 import AppKit：采集、存储、搜索、会话、键位、密钥转发
├── PastebackPlatform/ 系统剪贴板读写的薄适配
├── PanelLayout/       行展开等纯布局计算
├── jiantieban/        App + CLI（无参数启动 App，有参数走 CLI）
└── jiantieban-tests/  自研测试 harness（CLT 没有 XCTest），`make test` 运行
```

| 模块 | 职责 |
|---|---|
| `ClipboardMonitor` | 每 0.8s 比较 `NSPasteboard.changeCount`；自己写回时带 `rs.jiantieban.self` 类型，见到即忽略 |
| `IngestPipeline` | 文本截断到 12000 字符入库；图片原图 PNG 落盘、64px 缩略图（ImageIO）、SHA256 去重；隐私模式、自动排除疑似密钥；入库后按保留策略清理 |
| `OCRQueue` | Vision 识别图片文字，并发 1、排队上限 8（满了丢最旧），结果进搜索 |
| `Store` | `items` 表 + FTS5 trigram 虚表，WAL；文本按内容、图片按哈希唯一，重复复制只更新时间；保留时长 / 条数上限清理，收藏和贴回过的豁免 |
| `SearchQuery` | 解析 `:img` / `:text` / `:fav` / `:secret` 前缀；≥3 字符走 FTS5 短语匹配，更短走 LIKE；按最近复制时间倒序 |
| `PanelSession` / `ItemActions` | 面板状态机：筛选、选中、删除与撤销、标记密钥与撤销、密钥视图数据 |
| `Keymap` | 面板键位表与用户覆盖（只用 ⌘） |
| `PastebackCoordinator` / `Pasteback` | 写回剪贴板 → 恢复目标 App → 50ms 后 `CGEvent` 发 ⌘V；没有辅助功能权限时退到仅复制 |
| `SecretManager` / `SecretDetector` | 转发 jt（add / resolve / rm / mv / ls --json / status --json）；标记时识别密钥类型、生成命名建议 |
| `PanelController` | `NSPanel(.nonactivatingPanel)` + 玻璃 + `NSTableView`；一次查出全部结果，缩略图后台解码 + `NSCache` |
| `BrowserSourceCapture` | 复制后异步记下 Chrome（Apple Events）/ Helium（辅助功能）普通窗口的标题和 URL |
| `HotkeyCenter` / `StatusItemController` / `SettingsView` / `Onboarding*` | 热键、菜单栏、设置、首启 |

数据流：

```
剪贴板 ─0.8s 轮询→ ClipboardMonitor → IngestPipeline → Store(SQLite + images/)
                                                  └→ OCRQueue → Store
热键 → PanelController ─输入 150ms 节流→ Store.search → 列表
选中 → Pasteback → 目标 App
密钥标记 / 密钥视图 → SecretManager → jt
```

## 3. 数据

- 数据目录 `~/Library/Application Support/jiantieban`（`JIANTIEBAN_HOME` 可覆盖）：`jiantieban.db` 和 `images/`。
- 普通历史明文存储，不加密。
- 图片不进 SQLite，库里只存路径和缩略图。

## 4. 密钥与 jt 的边界

- jt 是密钥的唯一来源；真值只在 jt vault，本地库存 `jt://secret/<id>` 引用、名称和遮罩。
- 本地名称和遮罩只是展示缓存，读到 jt 列表时刷新（进密钥视图，或面板显示时发现 `vault.json` 修改时间变了）；jt 里已删的记录标为“密钥已删除”。
- 密钥视图直接读 `jt ls --json`，不写 `items` 表。
- 普通面板路径（打开、搜索、切普通筛选、移动、剪贴板变化）不启动 jt。
- App 从不执行 `jt sync`，只在密钥视图提示“有未同步的改动”。
- jt 可执行文件：`JT_BIN`，否则 `~/.local/bin/jt`，找不到再经 `/usr/bin/env` 查 PATH。
- 没装 jt 时剪贴板功能照常，只有密钥功能不可用。

## 5. 关键实现约束

1. 轮询而非事件：macOS 没有通用的剪贴板变更通知。
2. 面板必须 `.nonactivatingPanel`，否则唤起时抢走目标 App 焦点，贴回失败。
3. 列表文字用自定义 `FastLabelCell`，把截断展开检测的 expansion frame 置零；否则快速导航时每个新行都触发 CoreText 排版，滚动跟不上。
4. 签名身份要稳定：辅助功能授权跟签名走，`Scripts/sign.sh` 首次运行自动建自签证书 `jiantieban-dev`，之后重编译不用重新授权。
5. CLT 下 release 多 target 构建要逐个 `--product`（Makefile 已处理）。
6. 列表整表换内容不用 `reloadData`：它不复用 cell，每次新建一屏；按行增删 + `reloadData(forRowIndexes:)`，行视图的组标题留白随后单独刷新。
7. 主线程调 jt 时不用 `Process.waitUntilExit()`（它转嵌套 RunLoop，会插进别的界面代码），用 `terminationHandler` + 信号量。

## 6. 决策与不做

- 全部视图的搜索不混入 jt 记录：会破坏列表结构、容易引入 bug；密钥只在密钥视图里搜。
- 不做 iCloud 同步、跨平台、插件系统、富文本 / 文件复制。
- 不做本地加密数据库；敏感值交给 jt。

性能目标与实测见 [PERFORMANCE.md](PERFORMANCE.md)：常驻内存 < 50MB、空闲 CPU ≈ 0、10 万条高选择性检索 < 10ms。
