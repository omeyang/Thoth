# Code Review 工作流

结构化的代码审查流程，结合自动化工具和人工审查。

## 前置条件

### 工具

| 工具 | 用途 | 检查命令 |
|------|------|---------|
| `go` ≥ 1.21 | 编译和测试 | `go version` |
| `golangci-lint` | 代码质量检查 | `golangci-lint version` |
| `govulncheck` | 依赖漏洞扫描（可选） | `govulncheck -version` |
| `git` | diff 获取 | `git version` |

### 组件依赖

| 组件 | 路径 | 必需 |
|------|------|------|
| `code-reviewer` Agent | `agents/code-reviewer/AGENT.md` | 是 |
| `security-auditor` Agent | `agents/security-auditor/AGENT.md` | 安全审查时必需 |
| `go-lint.sh` Hook | `hooks/scripts/go-lint.sh` | 推荐 |

## 适用场景

- PR 审查
- 功能完成后的自查
- 重构前后的对比审查

## 流程定义

```
┌─────────────────────────────────────────────────┐
│  1. 自动化检查                                    │
│     • golangci-lint run ./...                     │
│     • go vet ./...                                │
│     • go test -race -cover ./...                  │
│     • govulncheck ./... (安全审计时)               │
└──────────────────────┬──────────────────────────┘
                       ▼
┌─────────────────────────────────────────────────┐
│  2. 变更概览                                      │
│     • git diff --stat 了解变更范围                  │
│     • 逐文件通读，理解变更意图                      │
│     • 确认变更与 PR 描述一致                        │
└──────────────────────┬──────────────────────────┘
                       ▼
┌─────────────────────────────────────────────────┐
│  3. 深度审查 (6 维度)                              │
│     • Critical: 正确性 → 安全性                    │
│     • High:     性能                              │
│     • Medium:   惯用法 → 可观测性 → 测试            │
└──────────────────────┬──────────────────────────┘
                       ▼
┌─────────────────────────────────────────────────┐
│  4. 输出报告                                      │
│     • 结构化格式（参考 code-reviewer Agent）        │
│     • 每个问题附带修复建议                          │
│     • 标注亮点                                     │
└──────────────────────┬──────────────────────────┘
                       ▼
              ┌────────────────┐
              │  有 Critical?   │
              └────┬─────┬─────┘
                   │ 是  │ 否
                   ▼     ▼
              Request    Approve
              Changes
```

## 使用的组件

| 组件 | 类型 | 用途 |
|------|------|------|
| `code-reviewer` | Agent | 审查执行主体 |
| `security-auditor` | Agent | 安全维度深度审查 |
| `code-review.md` | Prompt | 任务指令 |
| `go-lint.sh` | Hook | 自动 lint 前置 |

## Agent 调用方式

Code Review 工作流分两个阶段：先由 `code-reviewer` 做全维度审查，再由 `security-auditor` 做安全深度审查。两个 Agent 可并行调用。

### 阶段 1: 代码审查（code-reviewer Agent）

```
Task(
  subagent_type = "general-purpose",
  prompt = """
  <agents/code-reviewer/AGENT.md 全文>

  ## 任务

  审查以下变更代码。

  - 变更范围: <git diff 输出 或 文件列表>
  - 项目根目录: /path/to/project (含 go.mod)

  ## 执行步骤
  1. 运行 golangci-lint run ./... 和 go vet ./...
  2. 运行 go test -cover ./...
  3. 按 6 维度（正确性/安全/性能/惯用法/可观测性/测试）逐项审查
  4. 输出结构化审查报告
  """
)
```

### 阶段 2: 安全审计（security-auditor Agent，可选）

对外暴露 API 或处理用户输入的变更，应追加安全审计：

```
Task(
  subagent_type = "general-purpose",
  prompt = """
  <agents/security-auditor/AGENT.md 全文>

  ## 任务

  对以下代码进行安全审计。

  - 审计范围: pkg/api/ 和 pkg/middleware/
  - 审计深度: standard
  - 上下文: 对外暴露 HTTP API，处理用户输入

  ## 执行步骤
  1. 运行 govulncheck ./...
  2. 运行 golangci-lint run --enable-all（关注 gosec）
  3. 按 6 个安全维度逐项检查
  4. 输出安全审计报告
  """
)
```

### 并行调用（推荐）

两个 Agent 互不依赖，可同时发起：

```
# 在同一消息中并行调用
Task(code-reviewer) → 输出审查报告
Task(security-auditor) → 输出安全报告

# 合并两份报告，统一反馈给开发者
```

### PR 审查快捷调用

```
Task(
  subagent_type = "general-purpose",
  prompt = """
  <agents/code-reviewer/AGENT.md 全文>

  ## 任务

  审查 PR #<number> 的变更。

  ## 执行步骤
  1. 运行: gh pr diff <number>
  2. 运行: gh pr view <number> 了解 PR 描述
  3. 按 6 维度审查 diff 中的所有变更
  4. 输出结构化审查报告
  """
)
```

## 审查检查清单

### 必查项 (Must)
- [ ] 无编译错误
- [ ] 无 golangci-lint 错误
- [ ] 测试覆盖率未下降
- [ ] 无硬编码凭证
- [ ] 错误处理完整（无被忽略的 error）
- [ ] Context 正确传播

### 应查项 (Should)
- [ ] 命名清晰，遵循 Go 惯用法
- [ ] 新增公开 API 有文档注释
- [ ] 日志和 Trace 覆盖关键路径
- [ ] 无不必要的内存分配

### 可查项 (Nice to Have)
- [ ] 测试用例涵盖边界条件
- [ ] 性能敏感路径有 benchmark
- [ ] 代码复杂度合理（无过长函数）
