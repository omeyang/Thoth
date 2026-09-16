# agents

可复用的 Agent 规范和面向角色的执行剧本。

## 目录结构

```
agents/
├── README.md
├── golang-pro/          # Go 全栈开发专家
│   └── AGENT.md
├── code-reviewer/       # 代码审查专家
│   └── AGENT.md
├── k8s-devops/          # Kubernetes 与 DevOps 专家
│   └── AGENT.md
├── db-specialist/       # 数据库专家（MongoDB/ClickHouse/Redis）
│   └── AGENT.md
└── security-auditor/    # 安全审计专家
    └── AGENT.md
```

## Agent 清单

| Agent | 用途 | 适用场景 |
|-------|------|---------|
| `golang-pro` | Go 全栈开发 | 功能实现、架构设计、并发编程 |
| `code-reviewer` | 代码审查 | PR 审查、代码质量把关 |
| `k8s-devops` | K8s 运维 | 部署、调试、基础设施管理 |
| `db-specialist` | 数据库 | Schema 设计、查询优化、数据架构 |
| `security-auditor` | 安全审计 | 漏洞发现、安全加固、合规检查 |

## 使用方式

Agent 定义可通过以下方式集成到 Claude Code 工作流中:

### 1. 作为 Task 子代理的 System Prompt

```
将 AGENT.md 的内容作为 Task 工具的 prompt 前缀，
引导子代理以特定角色完成任务。
```

### 2. 作为 CLAUDE.md 的引用

```markdown
# CLAUDE.md
对于代码审查，参考 agents/code-reviewer/AGENT.md 中的审查维度和流程。
```

### 3. 组合使用

复杂任务可以按序组合多个 Agent:
1. `golang-pro` → 实现功能
2. `code-reviewer` → 审查代码
3. `security-auditor` → 安全审计
4. `k8s-devops` → 部署上线

## 编写规范

每个 AGENT.md 必须包含:

### YAML Frontmatter（必需）

```yaml
---
name: agent-name          # kebab-case，用于引用
description: 一句话描述     # Claude Code 用此选择 agent
tools:                     # 声明需要的工具
  - Bash
  - Read
  - Grep
---
```

### 标准章节（必需）

- **身份**: Agent 的角色定位和核心原则
- **工作流程**: 标准化的执行步骤
- **专业领域**: 详细的领域知识和代码模板
- **输入契约**: 明确接收什么（代码路径/diff/文件列表）
- **输出契约**: 明确产出什么（报告格式/代码修改）
- **错误处理**: 工具不可用、超时、权限错误时的降级策略
- **相关技能**: 指向 `skills/` 中的关联技能包
