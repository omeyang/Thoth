# 需求自验收任务（reqloop）

按 `workflows/reqloop/WORKFLOW.md` 执行「需求自验收闭环」。
完整阶段定义与取舍已在 WORKFLOW.md 中，本文件只作为任务入口。

## 调用方式

```
/reqloop <需求ID> [--adapter <名>] [--prd <路径>] [--env <环境>]
```

- `<需求ID>`：需求单 ID 或 PR 号，必填；适配器按 `id_patterns` 自动路由
- `--adapter`：可选，指定适配器（规则见 `workflows/reqloop/adapters/README.md`；`--lite` = `--adapter lite`）
- `--prd`：可选，附加 PRD 文档路径
- `--env`：可选，指定运行时校验环境（默认询问用户）

## 执行顺序（严格遵守 WORKFLOW.md）

0. **选适配器** — 按 `adapters/README.md` 选定并向用户报告，探活 `adapter.yaml.tools`
1. **gather** — `requirements` 槽位拉需求（可选附 PRD）
2. **collect-code** — `code` 槽位多仓库拉 MR / diff
3. **backspec** — 三源反推生成反讲文档 ★ **HARD GATE**：等待 `.reqloop/confirmed-{id}.md` 人工签字
4. **review** — `code-review-graph` 补全局 + `code-reviewer` Agent 审增量
5. **runtime** — `ci` 槽位在指定环境 build/test/lint + 业务边界覆盖矩阵
6. **e2e** — `e2e` 槽位回归
7. **report** — 汇总 + `defects` 槽位建缺陷 + 产出 `.reqloop/acceptance-{id}.md`

## 强约束（违反即中止）

完整约束定义见 `WORKFLOW.md` §核心设计取舍，以下为执行摘要（共 7 条）：

1. **阶段 3 硬门禁** — 未 confirm 严禁进入阶段 4a（校验 confirmed + schema + 差异处置）
2. **三源冲突不得调和** — 默认代码为准；命中安全关键词走**安全例外**（PRD 为准 + security-auditor）
3. **判定三元组强制** — 所有 AI 判定输出 `verdict + confidence + evidence`，`confidence: low` 不独立结论
4. **决策链 append-only** — 每条判定写 `.reqloop/decisions-{id}.jsonl`，含 `inputs_hash`，不得改写
5. **阶段 4b 隐式行为变更阻塞** — 未关联 REQ-ID 的反向调用链变更须人工确认
6. **阶段 5 不下"符合业务"结论** — 只出覆盖矩阵，❌/❓ 即标未闭环
7. **不跨范围 review** — 超出反讲范围的入 `out-of-scope`，不影响验收结论

## 产物约定

所有产物写入执行时工作目录下 `.reqloop/`，按需求 ID 隔离。
详细结构见 WORKFLOW.md「产物目录约定」章节。

## 断点续跑

当用户再次执行 `/reqloop <需求ID>`：

1. 扫描 `.reqloop/` 下已存在的产物文件
2. 检查每个产物的 frontmatter `stage_status` 字段判断完成度：
   - `stage_status: complete` → 该阶段已完成，跳过
   - `stage_status: in_progress` → 该阶段未完成（AI 被中断），**从此阶段重跑**
   - `stage_status` 缺失或文件不存在 → 该阶段未开始
3. 从第一个非 `complete` 的阶段开始执行
4. 若停在阶段 3 门禁，检查 confirm 状态决定放行或继续等待
5. 用户可显式指定从某阶段重跑：`/reqloop <需求ID> --from 4`（忽略 stage_status）
6. 续跑时 decisions.jsonl 通过 `idempotency_key` 去重，不产生重复行

**每个阶段写入产物时**：开始时写 `stage_status: in_progress`，全部完成后更新为 `stage_status: complete`。

## 交付总结格式（最终给用户）

简洁，不重复报告内容，只给导航：

```
reqloop {id} — {结论}

- Critical: N  运行时失败: N  e2e 失败: N  未闭环: N
- 报告: .reqloop/acceptance-{id}.md
- 缺陷: {缺陷ID 列表}
- 后续: [1-3 条建议]
```
