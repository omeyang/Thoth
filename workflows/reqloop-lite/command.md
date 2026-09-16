---
description: 轻量需求自验收 — 无需企业 ALM / CI，仅需 git + test runner
argument-hint: <id或PR号> [--prd <路径>] [--base <ref>] [--test-cmd <命令>] [--interactive]
---

执行 reqloop-lite 轻量需求自验收工作流。等价于 `/reqloop <id> --adapter lite`（`--lite`）。

## 参数

- `<id或PR号>`：任意唯一标识（`PR-42` / `issue-123` / 自定义）
- `--prd <路径>`：本地 PRD 文件
- `--base <ref>`：diff 基线（默认 `main`）
- `--test-cmd <命令>`：自定义验证命令（默认从 Makefile/go.mod/package.json 推断）
- `--interactive`：跳过 zero-config 推断，逐项交互获取输入

## 子命令

与 reqloop 完整版一致：`gather | backspec | review | verify | report | export`

## 执行规则

完全复用 `../reqloop/` 的阶段定义，外部系统动作按 `../reqloop/adapters/lite/` 的槽位文件执行，行为差异见 `../reqloop/LITE.md`。
所有硬性约束（阶段 3 硬门禁、三元组、决策链 append-only、安全例外、隐式行为变更阻塞）照常生效。

## 最终交付格式

```
reqloop-lite {id} — {通过 / 有条件通过 / 不通过}
- Critical: N  本地测试失败: N  未闭环: N
- 隐式行为变更: N  低置信度待裁决: N
- 报告: .reqloop/acceptance-{id}.md
- 决策链: .reqloop/decisions-{id}.jsonl
- 待创建 issue: N（gh issue create 命令已生成）
```
