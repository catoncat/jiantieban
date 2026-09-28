# jiantieban 实现状态

图例：✅ 已实现 · 🧪 已实现、待真机验收 · ⬜ 未做

## 1. 已实现

| 范围 | 状态 | 内容 |
|---|---|---|
| 采集 | ✅ | 0.8s 轮询；文本（截断 12000 字符）、图片（原图落盘 + 64px 缩略图 + SHA256 去重）；OCR（Vision，串行，队列上限 8） |
| 存储 / 搜索 | ✅ | SQLite WAL + FTS5 trigram，短词退化 LIKE；`:text` `:img` `:fav` `:secret` 前缀；保留时长 / 条数上限，收藏和贴回过的豁免 |
| 面板 | ✅ | 非激活 NSPanel + Liquid Glass（可选兼容风格）；键盘全集与可自定义键位；筛选 chip；⌘1–9；停留自动展开；删除 / 标记撤销；右键菜单；打开面板时输入法切 ABC、关闭时恢复 |
| 贴回 | ✅ | 一键贴回 / 仅复制两种模式，实时跟随辅助功能权限；图片可贴为图片或文件 |
| 浏览器来源 | 🧪 | Chrome（Apple Events）/ Helium（辅助功能）普通窗口的标题和 URL；实际复制往返与 Chrome 授权待验 |
| 密钥 | ✅ | 标记 + 命名建议 + ⌘Z 撤销；粘贴为密钥；密钥视图读 `jt ls --json`；引用记录跟随 jt；未同步提示；普通路径零 jt 调用；从不 `jt sync` |
| CLI / Skill | ✅ | `jiantieban help` 列出的剪贴板命令 + `mark-secret`；旧密钥命令只给去向；`skills/jiantieban-secret` |
| 设置 | ✅ | 通用 / 快捷键 / 历史 / 贴回 / 隐私 / 外观 / 高级 七页；快捷键录键真机交互待验 🧪 |
| 首启 / 菜单栏 | ✅ | 欢迎页 + 启用一键贴回页；菜单栏显示当前贴回模式 |
| 构建 | ✅ | CLT + SPM + Makefile；自签证书签名；占位图标；`make test` / `make bench` / `make measure` |

验收步骤见 [ACCEPTANCE.md](ACCEPTANCE.md)，性能见 [PERFORMANCE.md](PERFORMANCE.md)。

## 2. 待做

- ⬜ Developer ID 签名、公证、首次发布（[DISTRIBUTION.md](DISTRIBUTION.md)）
- ⬜ 正式 App 图标
- ⬜ 并发边界回归测试（`.scratch/code-quality/issues/06`）
- ⬜ 性能补测：面板打开时快速导航、连续复制 1 小时内存、debug `leaks` 排除系统框架

## 3. 已知缺口

- 不识别 `concealed` / `transient` 剪贴板类型，也没有“忽略应用”清单；密码管理器复制的内容会进历史（可开“自动排除疑似密钥”或隐私模式）。
- 贴回过的记录永久保留，没有总量上限。
- 没有自动更新。
- 没有 CI。
- 默认热键 ⌘⇧V 可能与其他工具冲突。
- 界面只有中文；Finder 显示名是“剪贴板”，与菜单、CLI 里的 jiantieban 不一致。
- 浏览器来源只支持 Chrome 和 Helium。
- 本地有引用记录时，每次启动后第一次打开面板会在主线程同步跑一次 `jt status` 找 vault 位置（要跑 git），卡 0.3–1 秒。

## 4. 待决策

- jt 未安装 / 找不到时的检测与引导
- GUI App 不继承 shell 的 PATH 和 jt 环境变量（`JT_HOME` 等），jt 路径怎么配
- jt 若提供 `set`（替换值），App 是否接入
- `jiantieban-secret` Skill 是否迁到 jt 仓库
- 何时删掉 CLI 里旧密钥命令的去向提示
- 对外介绍页文案（旧稿不准，已删）
