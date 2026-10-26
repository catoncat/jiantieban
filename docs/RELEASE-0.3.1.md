# jiantieban 0.3.1

发行说明草稿；0.3.1 尚未上传或发布。

修复 0.3.0 App 使用默认偏好域启动时崩溃的问题：Foundation 不允许把自身 bundle ID 当作 `UserDefaults` suite，原代码强制解包导致 SIGTRAP。GUI 与 CLI 现在共享偏好域选择逻辑，自身 bundle 域使用 `.standard`，其他域保留 suite 行为。新增唯一临时 bundle ID 的回归测试，不写入用户设置域。

最终五项本地构建/测试全部通过：**173 passed、0 failed**，历史 CLI 合同 **98 个进程调用**；ad-hoc 签名后三个 Python 合同测试再次通过。独立 CLI 和 App CLI 的默认域读取均正常，本机现有用户安装位置的 App 已正常持续运行超过 2 分 20 秒；历史核对为 464 → 464、原有记录 ID 无缺失、数据库 `quick_check=ok`，未改用户配置。

macOS 15+、Apple Silicon arm64；**ad-hoc 签名，未做 Developer ID 签名或公证**。全程没有运行 GitHub CI。macRs 部署与真实目标 App 成功贴回仍待验证。详细证据及产物摘要见 [MAC-VALIDATION.md](MAC-VALIDATION.md)。
