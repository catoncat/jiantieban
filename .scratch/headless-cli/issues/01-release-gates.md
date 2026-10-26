# 通用 CLI 的签名、真实贴回与远端发布

Status: in-progress

关联：GitHub [issue #8](https://github.com/catoncat/jiantieban/issues/8)。本 ticket 是本地发布关卡，不代表新远端 issue 或 Release 已建立。

## 已准备

- 指定基线上的完整 CLI patch 和 Mac 本地修复。
- 本地构建与测试证据见 [MAC-VALIDATION](../../../docs/MAC-VALIDATION.md)。
- 可执行发布步骤见 [LOCAL-RELEASE](../../../docs/LOCAL-RELEASE.md)。
- 用户明确不使用 GitHub CI；候选源码删除自动 workflow。

## 待完成

- 0.3.0 版本已同步并完成最终五条命令：173 项测试、98 次 CLI 调用、bundle 构建全部通过。
- 在受控测试会话验证目标 App 真实接收文本/图片，以及修饰键、前台切换和并发取消；避免覆盖用户剪贴板或工作。新增 TCC 权限逐次确认。
- 本次 App 的辅助功能授权已获批准，待系统设置本机认证。独立 CLI 不扩大授权。
- 本次采用已验证的 ad-hoc arm64 产物；Developer ID 签名/公证是可选后续项，不是本次 GitHub Release 的前置条件。禁止自动创建/导入证书。
- 最终源码、测试、文档和构建包上传 catoncat/jiantieban 并无 CI 发布已获新明确授权；按原 create_tree 操作重试已知未执行的上传，仍拒绝则停止，不换工具绕过。
- 远端 commit 与本地通过版本一致后，建立对应 tag/Release、上传精确产物并核验。

## 验收

仅在真实成功后记录 Release URL、远端 commit、版本、产物 SHA256、签名 authority、notarization submission 和最终接受状态。
