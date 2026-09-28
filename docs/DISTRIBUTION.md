# jiantieban 分发

现状：本地构建、自签签名、占位图标可用；Developer ID、公证、发布未做，暂不发布。

## 现有工具

- `make app`：组装并签名 `build/jiantieban.app`（带 `Resources/AppIcon.icns`）
- `make sign`：用自签证书 `jiantieban-dev` 签名，只为开发期辅助功能授权稳定；对外分发必须换 Developer ID
- `Scripts/generate-icon.swift`：生成 1024×1024 占位 PNG
- `Scripts/make-icon.sh <1024.png> [输出.icns]`：生成 `.icns`

## 发布清单

### 1. 仓库

- [ ] 从全新仓库发布：把当前代码压成一个初始提交，不带开发期历史（`git archive HEAD` 导出只含已跟踪文件；被全局 gitignore 的 `.scratch/ux-iterate/` 等不会带过去，`.scratch/` 其余内容按需取舍）
- [ ] 确认仓库里没有个人路径、真实密钥名或引用
- bundle id 保持 `rs.jiantieban`（自写剪贴板标记 `rs.jiantieban.self` 同理）：改了会丢已有用户的设置和辅助功能授权

### 2. 图标

- [ ] 用正式 1024×1024 PNG 替换占位图：`Scripts/make-icon.sh icon.png Resources/AppIcon.icns`
- [ ] `make app` 后确认 Finder / Dock 显示正确

### 3. Developer ID 签名

- [ ] 在 Apple Developer 创建 Developer ID Application 证书并导入钥匙串
- [ ] `codesign --force --options runtime --sign "Developer ID Application: <名字> (<TEAMID>)" build/jiantieban.app`
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
- [ ] `make test`、`make app`，跑一遍 [ACCEPTANCE.md](ACCEPTANCE.md)
- [ ] 打 zip 或 dmg，`gh release create v<版本> build/jiantieban.zip`，附 release notes

## 不做

- Mac App Store（沙盒与读剪贴板、模拟贴回冲突）
- 自动更新器
- 付费 / 授权系统
