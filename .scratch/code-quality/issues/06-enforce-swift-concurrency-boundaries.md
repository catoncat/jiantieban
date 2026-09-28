# 06 — 给并发边界补回归测试

**What to build:** 并发边界本身已经收紧：OCR 识别语言读写加锁，缩略图后台解码、缓存和视图更新在主 actor，release 构建没有本项目的并发警告，剩下的 `@unchecked Sendable`（`OCRQueue`、`DataBox`、`SendableBox`）都注明了同步依据。还缺能在回归时变红的测试。

**Blocked by:** None — can start immediately.

**Status:** ready-for-agent

- [ ] 测试覆盖 OCR 任务运行期间修改识别语言：不崩溃，任务用的是一份完整的语言列表。
- [ ] 测试覆盖同一路径的缩略图在解码中被多个请求者要：每个请求者都收到结果（`ThumbnailCache` 目前在 App target，可能需要先把等待者逻辑挪到可测试的模块）。
