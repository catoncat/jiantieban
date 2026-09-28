# jiantieban 性能

## 目标

| 指标 | 目标 |
|---|---|
| 常驻内存 | < 50 MB |
| 空闲 CPU | ≈ 0%（< 0.5%） |
| 内存增长 | 连续复制 1 小时无线性增长 |
| 检索 | 10 万条、高选择性查询 < 10 ms |
| 滚动 | 快速键盘导航时满帧，主线程无长栈 |

## 现状

- release 构建后台监听时常驻内存约 20–30 MB，空闲 CPU 为 0。
- `make bench`（10 万条）：高选择性查询几毫秒内，无命中查询低于 0.1 ms；宽泛的中文查询约 30 ms，受 trigram 倒排合并限制。默认 600 条的真实规模下所有查询都在 1 ms 以内。
- 面板一次查出全部结果，`NSTableView` 只渲染可见行；缩略图后台解码并缓存。
- 快速导航卡顿的根因是 NSTextField 的截断展开检测触发 CoreText 排版，已用 `FastLabelCell` 去掉。
- 切换筛选（release，约 700 条）：一次约 50–75 ms，原来 160–240 ms。原因是 `reloadData` 不把可见行的 cell 放回复用池，每次新建一屏 cell 和行视图；改为按行增删 + 原位重载。进密钥视图约 10–30 ms（`jt ls` 本身约 10 ms），原来 90–190 ms，大头是每条记录新建 `ISO8601DateFormatter`。
- debug 构建 `leaks` 只报系统框架里的循环引用，没有发现应用层泄漏。

## 方法

- 用 `JIANTIEBAN_HOME` 指向临时目录，不碰真实数据。
- 内存 / CPU：`make measure PID=<pid>`（`footprint` + `sample`）。
- 检索：`make bench`，每条查询 20 次采样取 avg / p95。
- 面板交互：`_debug-panel` 指向真实数据的副本（图片目录也要复制，不能软链到真实目录——删除会删到真文件），临时埋点量 render / layout / display / `CATransaction.flush`，看 `sample` 调用树。
- 泄漏：debug 构建跑 `leaks`，排除系统框架后看应用层。

## 待补

- 面板打开时快速导航的 CPU / 内存
- 连续复制 1 小时的内存曲线
- 与同类剪贴板工具同机对比
