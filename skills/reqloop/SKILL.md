---
name: reqloop
description: "需求自验收闭环 - 以多 skill 编排完成需求 → 代码 → 反讲 → 验收：先对齐需求再审代码，以代码为准（安全例外除外）并回写需求；EARS 结构化反讲 + 人工 confirm 硬门禁 + 判定三元组 + 决策链 + 负向影响分析；需求管理 / 代码托管 / CI / 测试平台 / 缺陷系统通过适配器接入，内置 lite 适配器只需 git。适用：用户要求需求自验收、反讲需求、验收某个需求，或提供需求 ID / PR 号希望做闭环验收；支持 --adapter <name>，--lite 等价于 --adapter lite。不适用：无需求单的纯代码审查（用 cr）、正向 spec → code 的需求编写、只跑测试不做需求对齐。触发词：reqloop, 需求自验收, 自验收, 反讲, 反讲需求, 验收需求, 需求验收, EARS, backspec, 需求闭环"
argument-hint: "<需求ID|PR号> [gather|backspec|review|verify|report|resolve|revalidate|batch|stats|export] [--adapter <name>|--lite]"
---

# reqloop — 需求自验收闭环

## 能做什么

按流水线完成需求自验收：

1. **gather** — `requirements` 适配器拉需求单（可选附 PRD）
2. **collect-code** — `code` 适配器拉多仓库 MR / commit / diff
3. **backspec** — 三源反推生成 EARS 结构化反讲文档 ★ 人工 confirm 硬门禁
4. **review** — 全局依赖视角 + 三元组判定（verdict + confidence + evidence）
5. **impact-radius**（4b）— 反向调用链 + 隐式行为变更阻塞
6. **runtime** — `ci` 适配器在指定环境 build/test/lint + 业务边界覆盖矩阵
7. **e2e** — `e2e` 适配器跑端到端回归
8. **report** — `defects` 适配器建缺陷 + 最终验收报告
9. **export**（可选）— 导出 OSLC / ReqIF / CSV / Xray，对接 DOORS / Spira / Jama / Jira

## 触发方式

- 用户说"自验收 <需求ID>"、"反讲这个需求"、"验收 <需求ID>"、"/reqloop <id>" 时调用
- 子命令：`/reqloop {gather|backspec|review|verify|report|resolve|revalidate|batch|stats|export} <id>`
- 适配器：`--adapter <name>`；未指定时按 `adapters/README.md` 的规则选择（`.reqloop.yaml` → 需求 ID 自动匹配 → lite）
- 轻量模式：`/reqloop <id> --lite`（内置 lite 适配器，无 CI / ALM 依赖）

## 执行约束（硬性，违反即中止）

> **权威来源**：`WORKFLOW.md` §核心设计取舍。以下为速查摘要（共 7 条），冲突时以 WORKFLOW.md 为准。

1. **阶段 3 硬门禁** — 未 confirm 严禁进入阶段 4a（confirmed + `backspec-schema.json` 校验 + 差异处置）
2. **三源冲突不得调和** — 默认代码为准；命中安全关键词走**安全例外**（PRD 为准 + security-auditor）
3. **判定三元组强制** — `verdict + confidence + evidence`，`confidence: low` 不独立结论
4. **决策链 append-only** — 写 `decisions-{id}.jsonl`（通过 `decisions-schema.json` 校验），含幂等键去重
5. **阶段 4b 隐式行为变更阻塞** — 未关联 REQ-ID 的反向调用链变更须人工确认
6. **阶段 5 不下"符合业务"结论** — 只出覆盖矩阵，❌/❓ 即标未闭环
7. **不跨范围 review** — 超出反讲的入 `out-of-scope`，不影响结论

## 详细指令

执行时**必须先读 `WORKFLOW.md`**，选定适配器，再按阶段读 `stages/*.md` 与适配器槽位文件：

- `WORKFLOW.md` — 主流程与核心取舍
- `adapters/README.md` — 适配器契约、查找顺序与选择规则；`adapters/lite/` 为内置实现
- `stages/01-gather.md` ~ `stages/07-report.md` — 主流水线
- `stages/04b-impact-radius.md` — 负向影响分析
- `stages/08-export.md` — OSLC/ReqIF 导出（可选）
- `stages/DECISIONS.md` — 决策链产物契约（跨阶段共用）
- `templates/backspec.md` — EARS 反讲模板
- `templates/acceptance-report.md` — 最终报告模板
- `LITE.md` — 轻量模式差异说明

## 产物约定

所有产物写入执行时工作目录下 `.reqloop/`，按需求 ID 隔离：

```
.reqloop/
├── req-{id}.md
├── code-{id}/
├── backspec-{id}.md           # EARS 结构化
├── confirmed-{id}.md          # 人工签字
├── review-{id}.md             # 三元组 findings
├── impact-{id}.md             # 负向影响
├── runtime-{id}.md
├── e2e-{id}.md
├── decisions-{id}.jsonl       # 决策链（append-only）
├── security-{id}.md           # 安全例外触发时
├── export/                    # OSLC/ReqIF/CSV（可选）
└── acceptance-{id}.md
```

断点续跑：再次调起时扫描已存在产物，从最后完成阶段的下一阶段开始。

## 相对业界工具的差异化

- **Spec Kit / Kiro / Tessl** 是正向 SDD（spec → code）；reqloop 是**反向验收**（code → spec 裁决）
- 填补业界公认空白：**推理级 traceability**（decisions.jsonl + inputs_hash）
- **隐式行为变更检测**：正向 SDD 工具无法发现，反向验收天然产出
