# lite · defects 槽位

## 输入

- 阶段 7 汇总出的失败项：Critical finding、runtime 失败、e2e 失败用例

## 步骤

1. **生成缺陷清单**（Markdown，写入 `.reqloop/acceptance-{id}.md` 的「失败项对应缺陷」表）：
   - 标题前缀 `[reqloop/{id}]`
   - 正文：现象、证据（review / runtime / e2e 产物路径）、反讲文档中的对应业务场景、决策链 `decision_id`
2. **可选回写 GitHub**：仓库是 GitHub 且 `gh` 可用时，为每条生成 `gh issue create --title ... --body-file ...` 命令，**展示给用户确认后**再执行；执行成功把 issue 号写回表格
3. 非 GitHub 或用户拒绝 → 只保留本地清单，缺陷 ID 列写 `pending`

## 输出字段

- 缺陷 ID：`issue-<N>` 或 `pending`
- 缺陷标题、来源阶段

## 失败处理

- `gh issue create` 失败 → 该条标 `pending`，报告「缺陷待补建」段列出应建清单
