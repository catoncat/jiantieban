# 通用 CLI 的本地验证与发布路径

这份说明是操作路径，不是发布成功记录。当前源码版本为 **0.3.0**，最终五项本地构建/测试全部通过：173 passed、0 failed，历史 CLI 合同 98 个进程调用；bundle 的 ad-hoc 签名严格验证通过。当前仍是未发布候选，尚未创建 tag 或 Release。详细证据、产物校验值及剩余阻塞以 [MAC-VALIDATION.md](MAC-VALIDATION.md) 为准，真实交互结果按 [ACCEPTANCE.md](ACCEPTANCE.md) 逐项记录。

## 当前准备与边界

- 基线为 `95ba511ff7258284ef3e7e768f613d4c2d145106`，在隔离工作树应用父线程交付的 patch，没有覆盖用户已有工作。
- 原始交付 patch 的 SHA256 为 `e927e08b794299e82eeb8e5cf8c213583c6cc6e1a65a8a49322be90407fe3acb`；后续本地修复属于新的源码状态，不能沿用这个值证明最终构建。
- 按用户要求全部在已授权 Mac 本地构建、测试，不运行 GitHub CI。本地候选删除 `.github/workflows/macos.yml`；未上传的删除不能被描述为远端 workflow 已删除。
- `make bundle` 只构建并组装 `build/jiantieban.app`，不执行 Developer ID 分发签名。编译器可能给可执行文件附加 ad-hoc 签名，这不等于 Developer ID 签名或公证。
- 本机检查得到有效代码签名 identity 数量为 **0**，因此尚不能执行 Developer ID 签名。创建或导入持久签名身份仍需用户逐次确认。本次最终 App 的辅助功能授权已获用户明确批准，当前待用户完成系统密码认证；真实成功贴回尚未验收。
- 不直接运行 `make app`、`make sign` 或 `Scripts/sign.sh`：现有脚本在缺少 `jiantieban-dev` 时会创建自签身份，并用 `security import -A` 导入私钥及证书。自签开发身份也不能替代对外分发的 Developer ID。
- 完整源码此前通过 GitHub `create_tree` 上传曾因缺少明确 payload/destination 批准而被拒，该操作未完成。现已取得新的明确用户授权：向 `catoncat/jiantieban` 上传本次最终源码、测试、文档和构建包，并在不运行 CI 的情况下发布。实际上传结果仍待记录；若新的操作被拒，停止该操作并报告，不通过替换工具绕过拒绝。

## 1. 固定最终源码并完成本地验证

在隔离工作树根目录执行。先记录基线、未提交差异和新增文件；仅记录 `HEAD` 不足以标识带 patch 的工作树。最终报告应包含源码清单或完整差异的校验值、工具链、命令退出码与日志路径。

```sh
git rev-parse HEAD
git status --short
git diff --check
swift --version
xcrun --show-sdk-version
sw_vers
python3 --version
make test
make bundle
python3 Scripts/test-headless-cli.py
python3 Scripts/test-cli.py
python3 Scripts/test-headless-settings.py
```

全部检查必须针对最后一次源码变更后的版本。失败时先修复再运行受影响的检查，并在发布前完成上述完整序列；不能用首期 paste 的历史 153 项测试结果替代当前候选的测试。

确认独立二进制与 bundle 内二进制、plist 版本一致，记录产物摘要：

```sh
.build/release/jiantieban version --json
build/jiantieban.app/Contents/MacOS/jiantieban version --json
/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' build/jiantieban.app/Contents/Info.plist
/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' build/jiantieban.app/Contents/Info.plist
cmp .build/release/jiantieban build/jiantieban.app/Contents/MacOS/jiantieban
shasum -a 256 .build/release/jiantieban build/jiantieban.app/Contents/MacOS/jiantieban
```

真实 Mac 验收使用临时历史目录、唯一的 `JIANTIEBAN_PREFERENCES_SUITE` 和无害文本；`JIANTIEBAN_HOME` 单独使用不会隔离偏好。保护用户真实快捷键、剪贴板、密钥库和工作文档，真实 `copy`/`paste` 使用受控测试会话。本次 App 的 AX 授权已获批准，仍待用户完成系统密码认证；其他新增 TCC 操作需逐次确认。程序测试或 `event_sent` 不证明目标 App 接受了文本。未执行项继续留空。

## 2. 发行版本与最终验证

发行版本已确定为 `0.3.0`，`Resources/Info.plist` 的两个版本字段及 `Sources/jiantieban/HeadlessCLICommand.swift` 的 `version` 已同步，版本变更后的第 1 步五项命令均退出 0。任何后续产品源码变更仍需重新完成相应验证并记录最终状态。

保持 bundle id `rs.jiantieban`、剪贴板自写标记 `rs.jiantieban.self` 和现有数据位置兼容。版本变更后重新执行第 1 步，记录最终源码状态。release notes 至少说明新增命令、JSON 的适用范围、`clear --yes` 的兼容变化、文本截断/图片格式限制、ID 可重用、设置重启生效和真实交互待验项。

## 3. 可选：准备 Developer ID 并签名

先展示将创建/导入的身份、目标钥匙串与用途，再逐次取得用户确认；没有批准时保持阻塞，不调用现有自签导入脚本。用户安全提供 Developer ID 身份后，用下面的只读命令确认该身份实际存在：

```sh
security find-identity -v -p codesigning
```

下列命令中的占位值必须替换为已验证、获准使用的真实 Developer ID Application identity。它们只对最终验证过的 bundle 执行：

```sh
codesign --force --options runtime --timestamp --sign 'Developer ID Application: <姓名> (<TEAMID>)' build/jiantieban.app
codesign --verify --deep --strict --verbose=2 build/jiantieban.app
codesign --display --verbose=4 build/jiantieban.app
```

确认签名 authority、TeamIdentifier、hardened runtime 和时间戳；保存验证结果。签名后不要再运行 `make bundle` 覆盖它；源码或 bundle 内容一旦改变，重新构建、验证、签名。

## 4. 可选：公证、盖章与最终压缩包

先由用户通过安全终端交互提供 Apple Developer 凭据。创建/更新钥匙串 profile 也必须展示具体目标并取得确认；不把密码/API 私钥放进源码、参数、日志或对话。`store-credentials` 的凭据参数留空时会交互提示：

```sh
xcrun notarytool store-credentials jiantieban-notary
```

在允许提交这个已签名 bundle 后执行：

```sh
ditto -c -k --keepParent build/jiantieban.app build/jiantieban-notary.zip
xcrun notarytool submit build/jiantieban-notary.zip --keychain-profile jiantieban-notary --wait --output-format json
```

记录 submission id 和最终 `Accepted` 状态。命令超时不代表提交失败；先按已返回 id 查询，不重复上传。被拒时读取对应公证日志、修复具体问题并重新验证，不能标记通过。

```sh
xcrun notarytool info '<submission-id>' --keychain-profile jiantieban-notary --output-format json
xcrun notarytool log '<submission-id>' --keychain-profile jiantieban-notary build/notary-log.json
```

仅在公证接受后盖章并验证。`JTB_RELEASE_VERSION` 须取第 2 步确定且重新测试过的版本，以下从最终 bundle 读取它：

```sh
xcrun stapler staple build/jiantieban.app
xcrun stapler validate build/jiantieban.app
codesign --verify --deep --strict --verbose=2 build/jiantieban.app
spctl --assess --type execute --verbose=4 build/jiantieban.app
JTB_RELEASE_VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' build/jiantieban.app/Contents/Info.plist)
ditto -c -k --keepParent build/jiantieban.app "build/jiantieban-${JTB_RELEASE_VERSION}-macos-arm64.zip"
shasum -a 256 "build/jiantieban-${JTB_RELEASE_VERSION}-macos-arm64.zip" > "build/jiantieban-${JTB_RELEASE_VERSION}-macos-arm64.zip.sha256"
```

本机是 arm64；未经另行构建与测试，不称为 universal 或 Intel 产物。最终 Release 应使用盖章后重新打包的 zip，不上传盖章前的 `jiantieban-notary.zip`。

## 5. 按已获授权上传并确认远端 commit

本次最终源码、测试、文档和构建包向 `catoncat/jiantieban` 上传及无 CI 发布已获新的明确授权。记录可审阅的最终源码差异、文件清单及 SHA256、基线 commit 和确切目标分支，再执行获准操作；实际结果尚待记录。既有拒绝不能通过替换工具绕过，任何新的拒绝应单独报告。

上传或合并完成后读取并记录实际远端 commit，核对其源码与本地测试状态一致。只有确认该 commit 已存在于远端，才能把它作为 Release target。当前准备未上传新源码、未创建 tag、未创建 Release；issue [#8](https://github.com/catoncat/jiantieban/issues/8) 是既有后续跟踪，不是发布完成证明。

## 6. 发布精确产物

本次上传和发布已获明确授权；待远端 commit 确认、最终测试/验收及实际签名状态记录后继续。GitHub Release 不强制 Developer ID 或公证：本次 ad-hoc 候选可跳过第 3–4 步并使用已验证 zip，清楚标注未公证，不绕过 Gatekeeper/TCC。以下命令展示选择 Developer ID 分发时的产物命名；发布 ad-hoc 候选时必须使用其真实文件名。先审阅 release notes、版本、目标仓库/commit 和两个 asset 的校验值；任何新的远端操作被拒时记录目标及原因并停下该操作，不更换工具重试。

以下是待执行命令，`JTB_RELEASE_COMMIT` 必须替换成第 5 步验证过的完整远端 SHA。`build/release-notes.md` 必须先写好真实结果。先创建 draft，检查资产后再发布；draft 本身也会向 GitHub 上传资产：

```sh
JTB_RELEASE_COMMIT='<已核对的完整远端 commit SHA>'
gh release create "v${JTB_RELEASE_VERSION}" \
  "build/jiantieban-${JTB_RELEASE_VERSION}-macos-arm64.zip" \
  "build/jiantieban-${JTB_RELEASE_VERSION}-macos-arm64.zip.sha256" \
  --repo catoncat/jiantieban --target "$JTB_RELEASE_COMMIT" \
  --title "jiantieban ${JTB_RELEASE_VERSION}" --notes-file build/release-notes.md --draft
gh release view "v${JTB_RELEASE_VERSION}" --repo catoncat/jiantieban
gh release edit "v${JTB_RELEASE_VERSION}" --repo catoncat/jiantieban --draft=false
```

`create` 在 tag 不存在时会按指定 target 创建 tag，因此不能省略 `--target`。若 tag/Release 已存在，先检查它的 commit 和状态，不覆盖旧资产或重跑创建。发布后验证公开 Release URL、tag 对应 commit、资产名/大小/校验值，并在本机隔离目录解压验证签名与 Gatekeeper；只有这些实际结果确认后才能报告发布完成。
