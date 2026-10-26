# jiantieban 分发

现状：源码已在 [catoncat/jiantieban](https://github.com/catoncat/jiantieban) 开源（MIT）。当前 0.3.0 候选已通过最终五项本地构建/测试及 ad-hoc 签名严格验证，尚未发布；证据见 [MAC-VALIDATION.md](MAC-VALIDATION.md)，步骤见 [LOCAL-RELEASE.md](LOCAL-RELEASE.md)。本次向该仓库上传最终源码、测试、文档和构建包并无 CI 发布已获用户明确授权，实际上传结果仍待记录。Developer ID 签名、公证尚未完成。

## 现有工具

- `make bundle`：组装 `build/jiantieban.app`（带 `Resources/AppIcon.icns`），不执行分发签名
- `make app` / `make sign`：现有自签脚本在缺少 `jiantieban-dev` 时会创建身份并执行 `security import -A`；不要直接运行。持久身份创建/导入需用户逐次确认；自签只用于开发期辅助功能授权稳定。本次可发布明确标注的 ad-hoc 候选包，不能称为 Developer ID 签名或已公证产物
- `Scripts/generate-icon.swift`：生成 1024×1024 占位 PNG
- `Scripts/make-icon.sh <1024.png> [输出.icns]`：生成 `.icns`

## 发布清单

### 1. 仓库

- [x] 从全新仓库发布：开发期历史压成一个初始提交，不公开
- [ ] 每次推送前确认没有个人路径、真实密钥名或引用
- bundle id 保持 `rs.jiantieban`（自写剪贴板标记 `rs.jiantieban.self` 同理）：改了会丢已有用户的设置和辅助功能授权

### 2. 图标

- [ ] 用正式 1024×1024 PNG 替换占位图：`Scripts/make-icon.sh icon.png Resources/AppIcon.icns`
- [ ] 最终 bundle 确认 Finder / Dock 显示正确

### 3. Developer ID 签名

- [ ] 在 Apple Developer 创建 Developer ID Application 证书并导入钥匙串
- [ ] 按 [本地发布路径](LOCAL-RELEASE.md#3-准备-developer-id-并签名) 批准并准备身份；`codesign --force --options runtime --timestamp --sign "Developer ID Application: <名字> (<TEAMID>)" build/jiantieban.app`
- [ ] `codesign --verify --deep --strict --verbose=2 build/jiantieban.app`

### 4. 公证

- [ ] 配置 notarytool 钥匙串 profile（交互输入凭据，不写进脚本或文件）：
  ```bash
  xcrun notarytool store-credentials "jiantieban-notary" --apple-id "<Apple ID>" --team-id "<TEAMID>"
  ```
- [ ] 打包并提交：
  ```bash
  ditto -c -k --keepParent build/jiantieban.app build/jiantieban.zip
  xcrun notarytool submit build/jiantieban.zip --keychain-profile "jiantieban-notary" --wait
  ```
- [ ] 盖章并验证：
  ```bash
  xcrun stapler staple build/jiantieban.app
  spctl --assess --type execute --verbose=4 build/jiantieban.app
  ```

### 5. 发布

- [ ] 更新 `Resources/Info.plist` 的 `CFBundleShortVersionString` / `CFBundleVersion`
- [ ] 完成 [本地发布路径](LOCAL-RELEASE.md) 的五项本地构建/测试，并按 [ACCEPTANCE.md](ACCEPTANCE.md) 记录真实结果
- [ ] 按新获明确授权上传最终源码并确认远端 commit 与测试源码一致；使用已验证的 ad-hoc 候选 zip 和校验值创建指定 commit 的 Release，附真实签名状态与 release notes

## 不做

- Mac App Store（沙盒与读剪贴板、模拟贴回冲突）
- 自动更新器
- 付费 / 授权系统


## CLI 兼容与版本说明

- 当前源码版本为 `0.3.0`：`Resources/Info.plist` 的两个版本字段与 CLI `version` 已同步。版本变更本身不是已发布结果；tag 和 Release 尚待实际创建。
- release notes 必须列出 `clear --yes` 等行为变化，以及新命令和 `--json` 的适用范围。机器输出的协议约定见 [HEADLESS-CLI.md](HEADLESS-CLI.md)，不能仅靠 App 版本推断字段。
- 保持 `rs.jiantieban`、`rs.jiantieban.self`、数据库位置和现有设置键兼容；`JIANTIEBAN_HOME` 仅隔离历史，不隔离偏好设置。历史 ID 是当前本地库的临时选择器，删除后可能重用，不是可跨库或永久保存的标识。
- 本次通用 CLI 的本地编译、测试和真实交互结果以 [MAC-VALIDATION.md](MAC-VALIDATION.md) 为准。按用户要求，不新增或依赖 CI，也不承诺 CI 下载产物；未执行的验证继续标为待验。
- `make bundle` 仅组装本地构建，不执行分发签名。必须分别记录测试 commit、实际签名/公证结果与人工验收结果；不能用其中一项替代其他项，也不能把未执行的构建流程称为发行产物。
