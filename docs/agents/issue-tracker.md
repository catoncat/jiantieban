# Issue tracker: Local Markdown

本项目的 specs 和 tickets 存放在 `.scratch/`。

## Conventions

- 每个 feature 使用一个目录：`.scratch/<feature-slug>/`
- Spec 文件为 `.scratch/<feature-slug>/spec.md`
- 每个 ticket 独立成文件：`.scratch/<feature-slug>/issues/<NN>-<slug>.md`
- Ticket 按依赖顺序从 `01` 编号，不使用单一汇总文件
- `Status:` 写在 ticket 顶部附近
- 评论追加到文件底部的 `## Comments`

## Publish

当 skill 要求发布 ticket 时，创建对应的 `.scratch/<feature-slug>/issues/` 文件。

## Fetch

读取用户给出的 ticket 路径或编号对应的文件。
