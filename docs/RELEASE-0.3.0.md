# jiantieban 0.3.0

发行说明草稿；尚未发布。本次向 `catoncat/jiantieban` 上传最终源码、测试、文档和构建包并无 CI 发布已获明确授权，实际上传结果仍待记录。此版本把剪贴板历史接口扩展为可由任意程序或脚本组合调用的无界面 CLI。

## 新增与改进

- `get ID|--latest` 读取历史，`--raw` 输出实际保存的 UTF-8 文本或密钥引用，不额外补换行。
- `copy` 只写剪贴板，不发粘贴事件、不要求辅助功能权限、不标记为已贴回；`paste` 保留原有 JSON 契约和安全检查。
- 历史读取、写入和变更支持 JSON；ID 使用字符串，时间采用 UTC ISO 8601。变更结果仅返回最小元数据，不回显正文。
- `add-text --stdin` 显式读取 UTF-8 输入，支持多行、emoji 和 NUL；上限 16 MiB，仍应用配置的保存长度限制。
- `config get/set/reset` 只开放允许的设置；`doctor` 只读诊断，不创建数据库或请求权限。设置变更需重启已有进程以确保生效。
- `watch` 尊重保存的隐私策略；隐私模式下不启动读取剪贴板快照的 monitor。并发存储事务及记录身份校验避免误更新被复用的历史 ID。

## 兼容变化与边界

- 清空历史必须使用 `clear --yes`。重复或未知选项、非法 ID/页码和额外参数明确失败；删除不存在的记录返回非零。
- `get` / `copy` 的 `--latest` 仅选择已入库历史；`paste --latest` 保留新鲜度等待。`event_sent` 不证明目标 App 已接受内容。
- 文本只能读取实际保存的前缀，不能恢复被截断后缀或 RTF/HTML；图片 `get --raw` 不可用。密钥引用不会自动解析为真值。
- 历史 ID 可能重用，不是永久引用；`JIANTIEBAN_HOME` 仅隔离历史，测试偏好须另设 `JIANTIEBAN_PREFERENCES_SUITE`。

完整命令及输出约定见 [HEADLESS-CLI.md](HEADLESS-CLI.md)。

## 平台、验证与签名

支持 macOS 15+，当前构建目标为 Apple Silicon **arm64**。候选包使用 **ad-hoc 签名并已通过严格签名验证，未做 Developer ID 签名或 Apple 公证**；其他 Mac 的 Gatekeeper 接受情况尚未验证。

全部构建和测试在已授权 Mac 本地执行，没有运行 GitHub CI。0.3.0 最终五项命令均退出 0：**173 项测试、0 失败**，bundle 构建成功，历史 CLI 合同通过 **98 个进程调用**，paste 失败路径、设置和只读诊断测试通过。详细证据及产物校验值见 [MAC-VALIDATION.md](MAC-VALIDATION.md)。

**真实目标 App 成功贴回仍待验收**；本次 App 的辅助功能授权已获用户批准，当前待用户完成系统密码认证，不能声称文本或图片已被目标 App 接收。全套 GUI、热键、浏览器来源、多屏和长时间性能验收也未完成。实际结果与发布状态应在上传最终产物前更新。
