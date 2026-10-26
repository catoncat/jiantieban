# 无界面 CLI：程序与脚本接口

状态：以下为 0.3.0 源码的接口约定；最终五项本地构建/测试已通过，详细证据与交互结果见 [MAC-VALIDATION.md](MAC-VALIDATION.md)。当前仍是未发布候选，真实目标 App 贴回待验。

CLI 是直接调用可执行文件的接口，不是快捷键 API，也不需要 `open -a` 包装。
无参数启动 GUI；带命令调用不打开面板、不注册热键、不抢焦点、不弹授权窗口。

```sh
BIN=/Applications/jiantieban.app/Contents/MacOS/jiantieban
"$BIN" list --json
"$BIN" search 'example' --kind text --page-size 20 --json
"$BIN" get 42
"$BIN" get 42 --raw
"$BIN" copy 42 --format plain
"$BIN" paste 42 --format plain
"$BIN" config get
"$BIN" doctor
```

## 命令与兼容

保留已有的扁平命令，不增加必须经过的 `history` 或 `clipboard` 子命令层。
旧命令不加 `--json` 时仍使用人类可读输出；脚本应显式选择 JSON，不解析表格/提示语。
兼容不表示保留原来的宽松解析：重复/不支持的选项、非法页码/ID、额外参数现在明确失败；`delete` 找不到记录返回非零，`clear` 必须显式加 `--yes`。

| 命令 | 参数 / 行为 |
| --- | --- |
| `list` | `[page] [--page N] [--page-size 1..1000] [--json]`；最近历史分页 |
| `search` | `query... [--page N] [--page-size 1..1000] [--kind text\|image] [--favorite] [--secret] [--json]`；保留 `:img` / `:text` / `:fav` / `:secret` 搜索前缀 |
| `get` | `ID\|--latest [--json\|--raw]`；默认 JSON。`--raw` 输出保存的文本/引用原始 UTF-8 字节，不额外补换行；不是图片二进制导出 |
| `copy` | `ID\|--latest [--format default\|plain\|original]`；只写剪贴板，不发粘贴事件，不要求辅助功能权限，不标记为已贴回 |
| `paste` | `ID\|--latest [--format default\|plain\|original]`；沿用首期贴回 JSON 契约，见下文 |
| `add-text` | `text...\|--stdin\|--literal remainder\|-- remainder`，可加 `--json`；literal/`--` 之后所有参数都是内容，因此 JSON 选项放在分隔符前 |
| `add-image` | `path [--json]`；显式写入图片历史，不代表复制到系统剪贴板 |
| `delete` | `ID [--json]` |
| `fav` | `ID [--set true\|false] [--json]`；不指定 `--set` 保留切换收藏；自动化宜使用幂等 `--set` |
| `clear` | `--yes [--json]`；缺少显式确认标志不清空历史。旧的裸 `clear` 调用须迁移 |
| `stats` | `[--json]` |
| `mark-secret` | `ID [name] [--json]`；沿用 jt 标记行为，不是获取真值接口 |
| `config` | `get [key]` / `set key value` / `reset key`；JSON 结果 |
| `doctor` | 只读诊断，JSON 结果；不是交互验收或自动修复 |
| `watch` | 长驻采集进程，Ctrl+C 退出；保留人类文本输出，不支持 `--json` / NDJSON 事件流；不是读取旧历史的必要条件 |
| `help` / `version` / `bench` | 前两者可加 `--json`；保留原有用途；`bench` 写合成历史，只在隔离数据目录使用 |

`secrets`、`annotate`、`resolve`、`unmark-secret` 仍只提示迁往 jt 的去向并以退出码 2 退出，不重新引入第二套密钥管理接口。
ID 是正整数形式的本地选择器，JSON 表示为字符串，避免调用语言整数精度损失。
它不是永久 ID：记录删除后可能重用，不能跨数据库引用，也不应长期缓存为内容身份。

## 机器输出

通用 JSON 命令成功在 stdout 输出一个对象；失败在 stderr 输出一个对象，非零退出。
不要将 stderr 合并进需解析的 stdout。成功退出码为 0；参数错误为 2；运行时失败为 1。

```json
{"schema_version":1,"ok":true,"command":"stats","result":{"items":3}}
```

错误使用同一基础字段及稳定 `code`、面向人的 `message`，不含成功 `result`。
消费方按 `code` 分支，不匹配提示文字；容忍额外字段，不依赖对象字段顺序。
`schema_version` 是协议版本，不是 App 发布版本。通用 envelope 内的时间字段采用 UTC ISO 8601，ID 字段采用字符串；兼容的 `paste` 旧契约仍保留原来的数字 ID。

- `get` 的 `result` 是所选记录；图片返回路径/元数据，不读出图片字节，也不保证该路径当前仍存在。`get --raw` 对图片返回 `format_unavailable`。
- `list` / `search` 的 `result` 有 `items`、`total`、`page`、`page_size`、`has_more`。多次调用的分页不是一个冻结快照；并发采集/删除可使跨页结果移动、重复或漏项。
- `add-text` 的 `result` 有 `item`、`inserted`、`truncated`；这仅描述本次入库结果，不能证明旧记录从未截断。写入/变更命令（`add-text` / `add-image` / `fav` / `mark-secret`）的 `item` 仅含 `id`、`kind`、`is_favorite`、`is_secret`、`was_pasted`，不回显正文、引用 token、来源或图片路径；需要内容时显式调用 `get`。
- `add-text --stdin` 保留输入字节对应的 UTF-8 文本（包括结尾换行，随后仍应用配置的字符截断）；stdin 上限为 16 MiB 字节，超限返回 `input_too_large`、退出码 1；非 UTF-8 输入以 `invalid_encoding`、退出码 1 失败。位置参数按空格连接，不能代替精确多行 stdin 输入。
- `get --raw` 是明确的例外：成功 stdout 是正文，不是 JSON。正文可能含敏感信息；只在需要内容的调用中使用。
- `fav` 不加 `--set` 是切换操作，重试会再次翻转；自动化应优先使用 `--set true` / `--set false`，但仍须注意其他进程并发修改。
- `mark-secret` 的 jt 写入与本地历史不是跨库事务。如果 jt 已完成但历史记录随后被删除或替换，本地更新返回 `conflict` 或 `item_not_found`，不会覆盖新记录；jt 中已创建的记录会保留。调用方应检查 jt 状态，不自动重试或删除密钥记录。
- `delete` / `clear` 的数据库变更与图片清理不是一个文件系统事务；清理为尽力执行。`clear` 返回 `cleared:true`、`image_cleanup_candidates`（候选文件数）、`image_cleanup:"best_effort"`，不证明每个文件已经删除。
- `copy` 使用通用 envelope，`result` 为 `id`（字符串）、`status:"copied"`、`format`、`clipboard_changed:true`；成功只证明此次写入完成，不保证之后没有其他程序改写，也不表示发出了粘贴事件。失败也不能一律推断剪贴板未变化；写入失败的错误顶层包含 `clipboard_changed`，只报告观察到的剪贴板所有权变化，不证明变化由本进程造成；不能盲目重试。
- 首期 `paste` 的扁平 JSON 保持兼容，不强行套入通用 envelope。`event_sent` 仅表示发出按键事件，不表示目标 App 已接受；`retained:false` 不能作为重试贴回的理由。完整失败状态见 [HEADLESS-PASTE.md](HEADLESS-PASTE.md)。

## 实际保存的内容与格式

历史只存文本和图片，不是任意剪贴板类型的无损存档。
文本保存的是纯文本，默认最多 **12000 个 Swift Character**（不是 UTF-8 字节）；配置变化不能恢复以前丢弃的后缀。
`get`、`copy`、`paste` 只能读取已保存的内容。文本 `original` 返回 `format_unavailable`，不会凭空恢复 RTF、HTML 或字体。
原有 `plainTextPaste` 偏好关闭后也不能恢复富文本，因此不把这个无实际格式恢复作用的键暴露给 `config`。

图片 `default` 按图片/文件贴回偏好写入；`plain` 不可用；`original` 是已存的图片内容，不承诺恢复源文件或原始剪贴板的全部表示。
引用记录各种格式只输出/写入 `jt://secret/...` 引用，绝不因格式选择自动调用 `jt resolve`。
普通文本本来就可能包含敏感信息；JSON 不是加密或脱敏机制，调用方应保护输出。`list` / `search --json` 也包含完整已存文本和来源元数据，不是只输出 80 字符的旧文本预览。

`--latest` 不代表任意正在前台显示的内容。`get` / `copy` 的 `--latest` 只选择已入库的最新记录，不等待当前剪贴板被采集。
`paste --latest` 则等待/校验当前剪贴板与采集历史，必要时返回 `history_not_current`，不会误贴旧记录。
采集依赖 App 或 `watch`；这些命令不绕过隐私策略自行补采集。明确 ID 不需要采集进程运行。
获取已存历史和向前台 App 发事件是不同操作，不应把 `get` 当作“复制当前选区”。

## 配置

默认偏好域是 `rs.jiantieban`。`JIANTIEBAN_HOME` 只改变历史目录，不隔离偏好。
测试可显式设置 `JIANTIEBAN_PREFERENCES_SUITE` 为独立偏好域；所有需要共享设置的进程必须使用相同域。
`config set` / `reset` 持久化后返回 `restart_required:true`：重启已运行的 GUI / `watch` 才能保证采用新值。
这不是跨进程即时同步 API；`get` 读取持久化设置，不是运行中 GUI 的实时状态。
`watch` 启动时读取保存的隐私策略；`privacyMode=true` 时不启动采集 monitor，不读取剪贴板 snapshot。改变该偏好后仍需重启 `watch` 才能保证生效。
若旧设置值不符合允许类型/范围，`config get` 返回 `preferences_invalid`；可显式 `config reset key` 恢复默认值，不会悄悄把坏值报告为有效设置。

| 可写键 | 允许值 | 默认 |
| --- | --- | --- |
| `retentionPreset` | `24h` / `7d` / `30d` / `forever` | `24h` |
| `hardLimit` | 整数 100–5000 | 600 |
| `maxSaveLength` | 整数 1000–50000 | 12000 |
| `favoritesPermanent` | JSON `true` / `false` | `true` |
| `imagePasteAsFile` | JSON `true` / `false` | `false` |
| `ocrLanguages` | 非空、无重复的 JSON 数组，元素仅 `zh-Hans`、`zh-Hant`、`en-US` | 三者 |

```sh
"$BIN" config set imagePasteAsFile true
"$BIN" config set ocrLanguages '["zh-Hans","en-US"]'
"$BIN" config reset imagePasteAsFile
```

不接受任意 defaults 键写入；不通过此接口改热键、隐私开关、疑似密钥排除、登录项、辅助功能或自动化权限。
保留策略仍有原有的收藏/已贴回豁免，`forever` 沿用既有策略含义，不提供新的绝对存储保证。

## 诊断、验证与发行

`doctor` 只报告当前进程可观察到的平台、路径/数据库是否存在、偏好域和辅助功能授权状态。
不打开/创建/迁移数据库、不写剪贴板、不调用 jt、不申请权限。
`capture_status:unknown` 和 `interactive_session_status:not_checked` 就是未验证，不能解读为采集进程健康或真实交互可用。
辅助功能状态也不证明目标 App 会接受一次粘贴。

本次工作不增加导入/导出、自动更新或后台服务管理。现有数据库无需为 CLI 换库，GUI、热键和 jt 引用语义不因此改变。
源码当前版本为 `0.3.0`；最终本地测试为 173 passed、0 failed，历史 CLI 合同为 98 个进程调用，五项命令均退出 0。bundle 的 ad-hoc 签名严格验证通过，未做 Developer ID 签名或公证，仍未发布。详细证据与待验项见 [MAC-VALIDATION.md](MAC-VALIDATION.md)；已获本次上传和发布明确授权，实际远端结果待记录，步骤见 [LOCAL-RELEASE.md](LOCAL-RELEASE.md)。
按用户要求，不新增或依赖 CI；由 Codex 在已授权且具备 Swift/macOS 工具链的 Mac 上依次运行：

```sh
make test
make bundle
python3 Scripts/test-headless-cli.py
python3 Scripts/test-cli.py
python3 Scripts/test-headless-settings.py
```

执行后记录准确 commit、工具链、每条命令退出码和失败日志；任一项未执行就标为未验证，不能把这些命令列表当作已通过结果。
`make bundle` 不执行分发签名；以上命令不替代真实目标 App 的交互验收，也不申请辅助功能权限。
首期 paste 的历史 153 项测试/CI 结果只说明当时的提交，不证明当前通用 CLI 改造已经编译或通过测试。
以 [ACCEPTANCE.md](ACCEPTANCE.md) 区分程序测试与需授权 Mac 的人工验收，
以 [DISTRIBUTION.md](DISTRIBUTION.md) 区分本地未做分发签名的构建、自签开发构建及 Developer ID 签名/公证发行。
