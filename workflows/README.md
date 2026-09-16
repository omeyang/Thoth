# workflows

可组合的编排流程，协调技能包、代理、钩子和 MCP。

## 目录结构

```
workflows/
├── README.md
├── tdd/                     # 测试驱动开发
│   └── WORKFLOW.md
├── code-review/             # 结构化代码审查
│   └── WORKFLOW.md
├── deploy/                  # Kubernetes 部署
│   └── WORKFLOW.md
├── adversarial-review/      # 四路对抗 + 交叉合议的代码审查
│   ├── WORKFLOW.md
│   ├── scripts/             # review-diff / review-target / install-hooks 等
│   ├── hooks/               # pre-commit 模板
│   ├── templates/           # 审查者 / 裁判提示词模板
│   ├── examples/            # .adversarial-review.yaml 示例
│   └── tests/               # bats 单元 + 集成测试
├── design-review/           # 设计文档多轮对抗审查
│   ├── WORKFLOW.md
│   ├── scripts/             # 主入口、投票 / 收敛库、lint-doc、cron-batch
│   ├── templates/           # 队伍角色、裁判、汇总者模板
│   ├── examples/            # .design-review.yaml 示例
│   ├── profiles/            # 内置示例 profile；真实项目预设放插件目录
│   └── tests/               # bats 单元 / 集成 / golden / chaos 测试
├── reqloop/                 # 需求自验收闭环
│   ├── WORKFLOW.md
│   ├── LITE.md              # 轻量模式说明
│   ├── stages/              # 7 阶段详细指令
│   ├── templates/           # 反讲文档 / 验收报告模板
│   ├── adapters/            # 适配器契约 + 内置 lite 适配器；企业适配器放插件目录
│   └── dist/                # 安装器使用的 SKILL.md / command.md
└── reqloop-lite/            # 轻量版入口（SKILL.md + command.md + manifest.json）
```

## 工作流清单

| 工作流 | 用途 | 核心组件 |
|--------|------|---------|
| `tdd` | 测试驱动开发 | go-test Skill + golang-pro Agent + 格式化 Hook |
| `code-review` | 结构化代码审查 | code-reviewer Agent + security-auditor Agent |
| `deploy` | K8s 部署上线 | k8s-devops Agent + k8s-go Skill + MCP |
| `adversarial-review` | Claude×2 + Codex×2 四路对抗审 git diff 或任意 scope，可挂 pre-commit | claude / codex CLI + yq + bats |
| `design-review` | 4 支 Agent 队伍多轮交叉对抗审 Markdown 设计文档，min-N + 收敛判定停轮，汇总者产出补充文档与 diff 草案 | claude / codex CLI + envsubst + flock + bats |
| `reqloop` | 需求自验收闭环（反讲 + 验收）| 需求源 / 代码源 / CI / e2e / 缺陷回写五个适配器槽位 + code-review-graph |
| `reqloop-lite` | 无企业 ALM 依赖的需求验收 | git + 本地测试命令 + 可选 gh |

## 设计原则

- **声明式**: 用流程图描述步骤，而非命令式脚本
- **可观测**: 每个步骤有明确的输入/输出和成功/失败标准
- **可组合**: 工作流引用 Skills、Agents、Hooks、MCP，不重复实现
- **可回退**: 关键步骤有回滚方案

## 编写规范

每个 WORKFLOW.md 必须包含：

1. **前置条件** — 工具版本要求 + 组件依赖列表（Agent/Skill/Hook/MCP）
2. **适用场景** — 何时使用此工作流
3. **流程定义** — ASCII 流程图 + 步骤说明
4. **Agent 调用方式** — 展示如何通过 Task 工具调用子 Agent，包括：
   - 完整的 prompt 模板（含 AGENT.md 引用 + 任务描述 + 约束）
   - 多 Agent 串联或并行的示例
   - 不同场景的调用变体
5. **使用的组件** — 组件清单表

脚本型工作流（adversarial-review、design-review）另需：

- `Makefile` 提供 `lint`（shellcheck）与 `test`（bats）入口
- 环境变量统一用 `THOTH_HOME` 定位仓库根目录
- 项目 / 企业专属内容不进仓库：按 `$THOTH_PROFILES` → `~/.config/thoth/profiles` → 内置目录的顺序加载 profile / adapter 插件

## 组件交互

```
Workflow (编排)
    ├── Agent (执行主体)
    │     └── Skill (领域知识)
    ├── Hook (自动化守护)
    │     ├── PreToolUse  (拦截)
    │     └── PostToolUse (反馈)
    └── MCP (外部工具)
          ├── Kubernetes
          ├── Database
          └── GitHub
```
