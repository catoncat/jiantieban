# Mac 本地验证记录：通用无界面 CLI

## 0.3.1 修复与实测更新

2026-10-26，**0.3.1 已完成本机修复、构建、测试和默认域 GUI 启动验证，尚未上传或发布**。以下为本次实际结果；后面的 0.3.0 记录保留当时状态，不代表当前版本或发布状态。

- 问题复现：0.3.0 已安装 bundle 的默认域 `config get` 返回 `preferences_unavailable`，GUI 启动 SIGTRAP；使用隔离 suite 则成功。`UserDefaults(suiteName:)` 对自身 bundle ID 返回 nil，原 GUI 强制解包导致崩溃。
- 最小修复涉及 `HeadlessSettings.swift`、`AppSettings.swift` 和 `test-headless-settings.py`：GUI 与 CLI 共用 resolver；选中域等于当前 bundle ID 时返回 `.standard`，其他域保留 suite 初始化结果，不以默认域吞掉失败。回归在唯一临时 bundle ID 与同名 suite 中读写、重置并验证 AppSettings，不写用户设置域。CLI 与两个 plist 版本字段均为 `0.3.1`。
- 最终五条命令均退出 0：

| 命令 | 0.3.1 实际结果 |
| --- | --- |
| `make test` | **173 passed, 0 failed** |
| `make bundle` | arm64 release CLI 与 App 构建成功 |
| `python3 Scripts/test-headless-cli.py` | paste 进程/JSON 失败路径通过 |
| `python3 Scripts/test-cli.py` | **98 processes** 通过 |
| `python3 Scripts/test-headless-settings.py` | 设置、诊断及同 bundle ID 偏好域回归通过 |

- ad-hoc 签名后，针对 App 二进制再次执行三个 Python 合同脚本，全部退出 0。
- 真实默认域下，独立 CLI 与 App CLI 的 `config get hardLimit` 均返回 `600`、退出 0、stderr 为空。
- 本机现有用户安装位置的 App 使用真实默认域、无环境变量覆盖，已正常持续运行超过 **2 分 20 秒**。升级前后仅核对历史数量、原有 ID 完整性与数据库健康：**464 → 464，原有 ID 缺失数 0，`quick_check=ok`**；未读取历史正文，未修改用户配置。

| 0.3.1 产物 | SHA256 |
| --- | --- |
| App zip | `839afc45a38847ca28276cf2cb7b217e4e7756bd968bad013474d8360b1bf0f5` |
| App executable | `db46be2b339ddb2b01a9b4b11e6db37472070d4cd037b6f4206d0decabea71bc` |

本次产物为 **arm64、ad-hoc 签名，未公证**；没有运行 GitHub CI。**macRs 尚待部署，真实目标 App 成功贴回仍未验收**，不能由正常启动或程序合同测试推定贴回成功。0.3.1 的源码和构建包尚未上传，Release 尚未发布。

## 0.3.0 历史记录

2026-10-26，在用户授权的 Mac 上完成 0.3.0 构建及最终五条命令验证。**本地 App 与独立 CLI 已可运行，写入本记录时远端发布未执行。** 没有运行 GitHub CI、创建/导入证书、公证或覆盖现有安装。用户已批准本次 App 的辅助功能权限，当前等待系统设置中的本机用户认证。

## 源码与工具链

- 基线：`95ba511ff7258284ef3e7e768f613d4c2d145106`。
- 父线程交付 patch SHA256：`e927e08b794299e82eeb8e5cf8c213583c6cc6e1a65a8a49322be90407fe3acb`。本机验证后成功应用到独立 worktree。
- 实现修复提交：`28378a168ec9f53deb4ead29a8201bf53e50e543`；随后将 CLI 及两个 plist 版本字段更新为 0.3.0 并完成全量复测。最终产品源码清单 `product-source-manifest.json` SHA256：`25d5d84efa5b8354597bc6f925bdd5e409f7004dd08d03a84d69fa8c6f626a4f`（Sources、Resources、Scripts、Package.swift、Makefile）。
- macOS 27.0.1 (26A434)，arm64；Apple Swift 6.4，macOS SDK 27.0，Command Line Tools；Python 3.9.6、GNU Make 3.81、Git 2.54.0。
- 仓库 AGENTS、CONTEXT、相关 ADR 已读取；此仓库没有 `.agents/skills`。未找到已有 jiantieban checkout，故在任务工作区建立 bare clone 和隔离 worktree，没有改动用户其他源码目录。
- 版本为 `0.3.0`，独立 CLI、bundle CLI 与两个 plist 版本字段一致。

## 最终五条命令

五条命令按下列顺序在最后一次产品源码变更后执行，全部退出码 0。日志位于本任务工作区 `logs/`，本地保留首轮失败及修复后记录；含个人路径的完整日志不对外发布。

| 命令 | 实际结果 | 日志 |
| --- | --- | --- |
| `make test` | **173 passed, 0 failed** | `release-0.3.0-make-test.log` |
| `make bundle` | release arm64 CLI 与 `.app` 组装成功 | `release-0.3.0-make-bundle.log` |
| `python3 Scripts/test-headless-cli.py` | paste 进程/JSON 失败路径通过 | `release-0.3.0-paste-contract.log` |
| `python3 Scripts/test-cli.py` | **98 processes** 通过 | `release-0.3.0-cli-contract.log` |
| `python3 Scripts/test-headless-settings.py` | 设置/只读诊断合同通过 | `release-0.3.0-settings-contract.log` |

默认沙箱曾禁止 Swift 缓存和测试偏好域写入；在已授权本地构建上下文运行后通过，不是缺少完整 Xcode。测试使用临时历史、UUID 偏好域和 fake jt，不使用真实密钥库。首期 153 项历史结果未作为本次证据。

首次实际测试为 162 通过、2 失败；修复 WAL 并发初始化锁竞争，以及图片清理测试夹具未使用托管目录的问题。随后补齐与 CLI 并发直接相关的记录身份校验：jt 标记/改名/撤销、面板缓存与撤销、异步 OCR、延迟贴回保留、引用缓存同步均避免误更新复用的 ID。隐私模式下 watch 不启动读取快照的 monitor。

编译仍有非阻断警告：CLT 的缺失 linker search path、旧 PanelController 的捕获警告，以及 OCR 回调忽略 `try?` 返回值。测试中的模拟磁盘满/fake jt 错误是预期失败路径输出；最终测试失败数为 0。

## 本机验收与签名后验证

- 版本号更新前的同一实现通过 `swift Scripts/test-mac-acceptance.swift`：**30 processes、193 个观察样本、0 跳过**。独立 CLI 和 bundle 的 doctor 不创建数据目录；同一独立偏好域跨进程 set/get/reset 生效；隐私 watch 无窗口、不抢焦点、剪贴板 changeCount 不变、SIGINT 正常结束且历史为空。
- 同一验收检查通过 Unicode stdin 截断、raw 保存前缀、UTC 时间、最小变更元数据、旧命令退出码、clear 确认保护、缺失图片 copy 失败路径。
- 授权前，独立 CLI 与 bundle 的 `doctor` 均报告 `accessibility_trusted=false`。对有效临时记录执行 paste 均返回 `accessibility_required`，未写剪贴板、未发按键、未弹授权窗口。
- 本地 ad-hoc 签名后，针对 bundle 二进制再次运行三个 Python 脚本，全通过（history 合同仍为 98 processes）。
- 以现有 `_debug-panel` 入口显示临时无害文本：观察到 640×134 面板，进程正常存活；测试结束关闭，剪贴板 changeCount 不变。该入口禁用采集和全局热键，不代表无参数首启、真实热键或欢迎流程已验收。脚本及日志包含在本地证据包。
- 命名 NSPasteboard 的真实 AppKit 写入、图片写入进程退出后的可读性由单元测试覆盖；不能等同于真实 general pasteboard copy 或目标 App 接收 paste。

窗口/焦点是采样观察，不能排除采样间隔内短暂 UI。paste smoke 的空历史 `--latest` 会读取系统快照，但不输出内容、不写入、不发按键；额外 Mac 验收脚本只观察 changeCount，没有读取内容。没有触发用于测试的新 general clipboard 写入。

## 可用本地产物

以下为 0.3.0 最终分发产物。本地任务的 `artifacts/release-0.3.0/` 保存同名文件；个人绝对路径不写入公开报告。

| 产物 | 位置 | SHA256 |
| --- | --- | --- |
| 独立 CLI 包 | `jiantieban-0.3.0-cli-macos-arm64.tar.gz` | `70e2f0ed19b6c9e1d62689be001689abf381ed005054efe4588cfd69dde35d54` |
| 独立 CLI executable | 包内 `jiantieban` | `f08e3ed45785aab07bee147db4d3feb03893b9ce0aaa806b9f902ca32393cccd` |
| App 内 executable | `build/jiantieban.app/Contents/MacOS/jiantieban` | `99923eaf25b1a87fedecfa83a3a17fd38f229b67d79f8be8bd4b7d14b996719f` |
| App 压缩包 | `jiantieban-0.3.0-macos-arm64.zip` | `9f0a04457077de92f23a4052ae1e36d46442aaba6d99cfba39d8c72d7e8130cc` |

app 使用 `codesign --force --sign -` 本地 ad-hoc 签名；`codesign --verify --deep --strict --verbose=2` 通过，bundle id 为 `rs.jiantieban`，资源已封装。未创建持久身份或写入钥匙串。bundle 与独立 CLI 的字节摘要不同来自重新签名。**没有 Developer ID、TeamIdentifier 或公证，不能声称已获 Apple 分发认证。GitHub 可以发布准确标注的 ad-hoc 候选包，Developer ID/公证并非 GitHub Release 的必要条件。** 当前本地可运行；复制到其他 Mac 的 Gatekeeper 接受情况未验证。

## 真正剩余的关卡

1. **真实成功贴回待验**：用户已批准本次 App 的辅助功能权限；当前在正常系统设置等待本机认证。将使用本地空白输入框、无害文本和内存剪贴板备份；不能用 `event_sent` 或模拟测试替代实际接收。独立 CLI 不自动扩大授权。
2. **可选的 Developer ID 签名、公证路径**：只读查询得到有效 codesigning identity 为 0。缺少具体 Developer ID Application 身份与公证凭据。下一操作应明确证书及目标钥匙串后逐次批准创建/导入；不得运行自动 `security import -A` 的 `make app/sign`。本地 ad-hoc 候选不依赖这些操作。
3. **远端源码与发行准备中**：用户已明确批准最终源码、测试、文档及构建包上传 `catoncat/jiantieban` 并无 CI 发布。此前缺少 payload/destination 的已知未执行 `create_tree` 可凭新授权重试一次；仍拒绝则停止，不换工具绕过。远端 main 检查仍为指定基线，Actions 历史 3 次。本次最终树删除 workflow，提交使用 `[skip ci]`，发布后核验没有新运行。ad-hoc 分发须明确标注，不能绕过 Gatekeeper/TCC。

全套普通 GUI、真实快捷键、输入法/多屏/浏览器来源、实时正常采集与一小时性能验收仍未执行；这不阻止已验证的本地无头 CLI 使用，但不能宣称完整产品发布验收已完成。既有 [issue #8](https://github.com/catoncat/jiantieban/issues/8) 和本地发布关卡 ticket 继续跟踪；本任务没有新建远端 issue。
