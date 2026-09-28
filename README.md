# jiantieban

macOS 原生剪贴板管理器：常驻内存几十 MB、空闲不占 CPU、毫秒级搜索，界面用系统 Liquid Glass。也可以作为 [jt](https://github.com/catoncat/jt) 密钥库的原生界面，把密钥以引用的形式交给 Agent，明文不进对话。

## 功能

- 记录复制过的文本和图片；图片里的文字经 OCR 后可搜
- ⇧⌘V 唤出面板，键盘完成全部操作：搜索、筛选（文本 / 图片 / 收藏 / 密钥）、收藏、删除与撤销、⌘1–9 快速贴回
- 一键贴回到当前 App（需要辅助功能权限）；不授权时退到仅复制，由你按 ⌘V
- 保留策略可调（默认 24 小时 / 600 条）；收藏和贴回过的记录永久保留
- 可选记录 Chrome / Helium 页面来源，展开后可回到原页面
- 隐私模式、自动排除疑似密钥
- 密钥（需要 jt）：把一条记录标记为密钥，真值交给 jt，面板贴出 `jt://secret/<id>` 引用；密钥视图列出 jt 里的全部记录，可贴引用、贴明文、改名、删除
- 命令行：`jiantieban help`

## 要求

- macOS 26 或更高
- 从源码构建：Xcode 或 Command Line Tools（Swift 6.2）

## 构建

```bash
make app     # 构建 release、组装并签名 build/jiantieban.app
open build/jiantieban.app
```

首次签名会在钥匙串里创建自签证书 `jiantieban-dev`，之后重新编译不用再授权辅助功能。

其他目标：`make build`（release 二进制）、`make test`、`make bench`（10 万条检索测速，数据写在 `/tmp`）、`make run`、`make clean`。

## 与 jt 的关系

密钥功能由 [jt](https://github.com/catoncat/jt) 提供：真值只保存在 jt 的 vault 里，jiantieban 调用 jt 的命令完成标记、列出、贴明文、改名和删除，从不执行 `jt sync`。App 默认调用 `~/.local/bin/jt`，可用环境变量 `JT_BIN` 指定。

没装 jt 时剪贴板功能完全正常，只是密钥功能不可用。

## Agent Skill

`skills/jiantieban-secret/SKILL.md`：让 Agent 在见到 `jt://secret/` 引用时用 `jt resolve <引用> --exec <命令>` 消费真值（只注入子进程环境变量），并按你给出的名称用 `jt mv` 命名。把这个目录放进你所用 Agent 的 skills 目录即可。

## 隐私

- 普通历史以明文存在本机 SQLite 里：`~/Library/Application Support/jiantieban`（`jiantieban.db` 和 `images/`），可用 `JIANTIEBAN_HOME` 改位置。
- 密钥真值只在 jt 里，本地只存引用、名称和遮罩。
- App 不联网、不上传。浏览器来源（页面标题和 URL）只存在本机，可在设置里关闭。

## 文档

- [架构](docs/architecture.md) · [产品](docs/product/PRD.md) · [实现状态](docs/STATUS.md) · [界面规则](docs/DESIGN.md)
- [领域词汇](CONTEXT.md) · [决策记录](docs/adr/)

## License

MIT，见 [LICENSE](LICENSE)。
