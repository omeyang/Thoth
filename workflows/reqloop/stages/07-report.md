# 阶段 7 — 验收报告 (report)

## 目标

汇总阶段 1-6 的所有产物，产出一份**可归档、可追溯**的验收报告。
失败项自动在缺陷系统建单。

## 步骤

1. **汇总输入**
   - 阶段 1: 需求原文
   - 阶段 3: 已 confirm 的反讲文档
   - 阶段 4a: review 结论（Critical / High / low_confidence 数量）
   - 阶段 4b: 负向影响分析（implicit_behavior_change / unknown 数量）
   - 阶段 5: CI 结果 + 业务边界覆盖矩阵
   - 阶段 6: e2e 结果
   - 跨阶段: decisions.jsonl 决策链统计

2. **计算验收结论**

   按以下优先级**从上到下**匹配，首个命中即为最终结论（不跳级）：

   | 优先级 | 情况 | 结论 |
   |--------|------|------|
   | 1 | 安全例外（`security_sensitive: true` 且 §5 未全部修复）| **不通过** |
   | 2 | 阶段 4a Critical > 0 且 confidence∈{high, medium} | **不通过** |
   | 3 | 阶段 5 build/test/lint 任一失败 | **不通过** |
   | 4 | 阶段 6 有失败且映射到已 confirm 场景 | **不通过** |
   | 5 | 阶段 4b `implicit_behavior_change > 0` 且未全部人工签字 | **有条件通过** |
   | 6 | 阶段 4a `low_confidence > 0`（决策链中存在未裁决的低置信度判定）| **有条件通过** |
   | 7 | 覆盖矩阵有 ❌ 或 ❓ | **有条件通过**（需人工决策）|
   | 8 | 阶段 6 跳过（`platform: skipped`）| **有条件通过** |
   | 9 | 全部绿 | **通过** |

3. **失败项建缺陷**（执行适配器 `defects.md` 槽位）
   - 为每个 Critical / 失败用例创建缺陷（lite 适配器：`gh issue create` 命令清单或本地 Markdown 清单）
   - 缺陷标题前缀 `[reqloop/{id}]` 便于聚合
   - 正文含：现象、证据链接（review / CI / e2e 产物路径）、反讲文档中的对应业务场景、决策链 `decision_id`
   - 缺陷 ID（前缀由 `adapter.yaml.defect_id_prefix` 决定）写回验收报告

4. **填充最终报告**
   - 使用 `templates/acceptance-report.md` 模板
   - 写入 `.reqloop/acceptance-{id}.md`

5. **总结交付**
   - 简洁告知用户：结论 + 关键未闭环项 + 缺陷 ID 列表
   - 不重复报告内容，只给导航

## 产物

`.reqloop/acceptance-{id}.md` — 见模板。

## 后续动作

- **通过**：建议用户将报告链接附到 MR / 需求单评论
- **不通过**：缺陷已建，等下次迭代后重跑 `/reqloop {id}`
- **有条件通过**：通过 `/reqloop resolve <id>` 解除条件（见下方）

## 有条件通过 → 通过：升级闭环 (`/reqloop resolve`)

当结论为"有条件通过"时，`/reqloop resolve <id>` 执行以下闭环：

1. **读取未解决条件清单**
   - 从 `acceptance-{id}.md` frontmatter 提取触发"有条件通过"的原因集
   - 常见来源：`implicit_behavior_change`、`low_confidence`、`coverage_gaps`、`e2e_skipped`

2. **逐条验证条件是否已解除**

   | 条件来源 | 解除判据 |
   |---------|---------|
   | `implicit_behavior_change` | `impact-{id}.md` 中每条 ⚠️ 均有人工签字（处置 + 决定人 + 时间）|
   | `low_confidence` | `decisions-{id}.jsonl` 中所有 `confidence: low` 行均有对应 `human_override` 行 |
   | `coverage_gaps` | `runtime-{id}.md` 覆盖矩阵中无 ❌ 或 ❓（已补测试或人工确认无需覆盖）|
   | `e2e_skipped` | 用户确认可接受无 e2e（在 resolve 交互中签字）|

3. **升级或维持**
   - 全部条件解除 → 更新 `acceptance-{id}.md` frontmatter `conclusion: pass`，追加 `resolved_by` + `resolved_at`
   - 仍有未解除条件 → 列出剩余条件，不升级
   - 每次 resolve 判定追加一行到 `decisions-{id}.jsonl`（`stage: "report"`, `verdict: "resolved" | "still-conditional"`）

## 失败处理

- 建缺陷失败（权限 / 平台不可达）→ 报告中标注"缺陷待补建"，列出应建缺陷清单（缺陷 ID 填 `pending`）
- 阶段 1-6 有缺失 → 报告照常生成但标注 `incomplete: true`
