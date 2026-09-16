---
name: reqloop-lite
description: 轻量版需求自验收 — 反向 spec-driven 验收（code → spec 裁决），不依赖企业 ALM / CI / 内部工具。仅需 git + 语言 test runner。保留核心能力：EARS 结构化反讲 + 人工 confirm 硬门禁 + 判定三元组 + 决策链 + 负向影响分析 + 安全例外。适合开源项目、单仓库团队、外部协作场景。触发：用户提供 PR 描述 / issue 正文希望做需求验收，或 `/reqloop-lite <id>`。
version: 0.2.1
---

# reqloop-lite — 轻量需求自验收

## 定位

reqloop 通过适配器接入需求管理 / 代码托管 / CI / 测试平台 / 缺陷系统。
本 skill 固定使用内置 `lite` 适配器（等价于 `/reqloop <id> --adapter lite`），**核心能力不降级**，适合：

- 开源项目的 PR 验收
- 小团队 / 单仓库场景
- 无 ALM 系统（Spira / DOORS / Jama）的企业
- 与 GitHub Issues / PR 一体化工作流

## 核心能力（与完整版一致）

1. **EARS 结构化反讲** + 人工 confirm 硬门禁
2. **三源冲突裁决**（默认代码为准；安全关键词走 PRD 为准例外）
3. **判定三元组**：verdict + confidence + evidence
4. **决策链 decisions.jsonl**（append-only + inputs_hash，支持重放）
5. **负向影响分析**（反向调用链 + 隐式行为变更阻塞）

## 降级部分

| 能力 | Lite 实现 |
|------|---------|
| 需求来源 | PR 描述 / issue 正文 / PRD 文件路径（用户提供）|
| 代码采集 | 当前 git 仓库 `git diff base..HEAD` 或 `gh pr view` |
| CI 触发 | 本地 `go test` / `make test` / 用户命令 |
| e2e 回归 | 跳过或人工贴结果 |
| 缺陷回写 | `gh issue create` 或本地 Markdown 清单 |
| 依赖图 | `go list -deps` / tree-sitter（深度 ≤2）|
| Monorepo 跨模块 | 完全支持（Go workspace / Nx / 目录级拆分）|
| 跨仓库影响 | 标记 `unknown`，提示升级到完整版 |

## 依赖

**必需**：`git`
**推荐**：`gh` CLI、语言对应 test runner、ripgrep
**可选**：tree-sitter（多语言依赖图）、`go list`（Go 项目）

## 使用

```
/reqloop-lite <id 或 PR 号>
```

默认 zero-config：自动从 PR body / commit message 推断需求描述，从 Makefile / go.mod / package.json 推断验证命令。
推断结果展示确认后直接执行。用 `--interactive` 强制逐项交互。详见 `../reqloop/LITE.md`。

## 与完整版的关系

本 skill 复用 `../reqloop/` 的流程定义、阶段文件、模板。**不重复维护**：

- 主流程：`../reqloop/WORKFLOW.md`
- 阶段指令：`../reqloop/stages/*.md`
- 适配器槽位实现：`../reqloop/adapters/lite/`（5 个槽位文件）
- 轻量模式约定：`../reqloop/LITE.md`
- 决策链契约：`../reqloop/stages/DECISIONS.md`

执行时**先读 `../reqloop/LITE.md`**，再读 `../reqloop/WORKFLOW.md`；各阶段中标注「执行适配器 X 槽位」的步骤按 `../reqloop/adapters/lite/X.md` 执行。

## 相对业界的差异化

- 正向 SDD（Spec Kit / Kiro / Tessl）全部"spec → code"，无反向验收开源工具
- 本 skill 是**目前唯一能跑在开源项目上的反向 SDD 验收闭环**
- 填补业界公认空白：推理级 traceability（decisions.jsonl）、隐式行为变更检测
