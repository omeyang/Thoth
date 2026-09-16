# Thoth：AI 编码工具箱

> 让 AI 编码助手按 Maat 的标准做事。

[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](./LICENSE)
[![Skills: 23](https://img.shields.io/badge/Skills-23-blue)](./skills/CATALOG.md)
[![Workflows: 7](https://img.shields.io/badge/Workflows-7-orange)](./workflows/README.md)

Thoth 是面向 Claude Code、Codex 等 AI 编码工具的构建块仓库：技能包、Agent 定义、Hook 脚本、MCP 配置模板、提示词模板，以及多 Agent 对抗审查与需求验收工作流。内容以 Go 后端开发为主，工程标准与 [Maat](https://github.com/omeyang/Maat) 保持一致：Maat 定义什么是正确，Thoth 把这些标准装进 AI 工具的日常工作流。

名字来源：托特（Thoth）是古埃及神话中的书记与智慧之神。在"称心仪式"中，玛特（Maat）的羽毛是衡量的标尺，托特负责记录裁决。两个仓库的分工正是如此：Maat 是标尺，Thoth 是执行与记录的工具。

适用对象：

- 使用 Claude Code / Codex 做 Go 后端开发的个人与团队
- 需要把代码审查、设计评审、需求验收交给多 Agent 自动执行的项目
- 想复用一套技能包、Hook 与 CLAUDE.md 模板初始化新项目的团队

## 内容一览

| 目录 | 内容 | 规模 |
|------|------|------|
| [skills/](./skills/CATALOG.md) | Claude Code 技能包：Go 开发与运行时（golang-patterns、go-style、go-test、go-performance、go-runtime）、中间件（Kafka、Pulsar、Redis、MongoDB、ClickHouse、etcd、gRPC、K8s、OTel）、架构与审查（design-patterns、backend-patterns、cr）、图表导出（diagram-png-export） | 23 个 |
| [agents/](./agents/README.md) | 角色化 Agent 定义：golang-pro、code-reviewer、k8s-devops、db-specialist、security-auditor | 5 个 |
| [hooks/](./hooks/README.md) | Claude Code Hook 脚本（格式化、lint、异步测试、危险命令拦截、会话上下文、提交信息检查）与 settings.json 模板 | 6 脚本 + 2 配置 |
| [mcp/](./mcp/README.md) | `.mcp.json` 配置模板（K8s、MongoDB、ClickHouse、Redis、Kafka、OTel、GitHub）与服务器清单 | 3 个模板 |
| [workflows/](./workflows/README.md) | tdd、code-review、deploy、adversarial-review、design-review、reqloop、reqloop-lite | 7 个 |
| [prompts/](./prompts/README.md) | CLAUDE.md 模板、任务提示词、代码片段 | 7 个 |
| [installer/](./installer/README.md) | reqloop 零依赖安装器，支持 claude-code / codex / costrict / costrict-cli | npm 包 `thoth-reqloop` |
| [docs/](./docs/architecture.md) | 架构、命名规范、路线图，以及各工作流的设计文档与实施计划 | — |
| policies/ · evaluations/ · integrations/ · examples/ | 预留目录，目前只有约定说明 | — |

## 仓库结构

```text
Thoth/
├── skills/              # 23 个技能包，每个目录一个 SKILL.md
├── agents/              # 5 个 AGENT.md
├── hooks/
│   ├── scripts/         # go-format, go-lint, go-test-async, block-dangerous, session-context, commit-lint
│   └── configs/         # settings.json（完整）/ settings-minimal.json（最小）
├── mcp/
│   ├── configs/         # go-backend-full, go-backend-minimal, observability
│   └── servers/         # MCP 服务器参考清单
├── workflows/
│   ├── tdd/ code-review/ deploy/         # 单文件 WORKFLOW.md
│   ├── adversarial-review/               # 四路对抗 + 交叉合议的代码审查，可挂 pre-commit
│   ├── design-review/                    # 设计文档多轮对抗审查，含每晚 cron 批处理与 profiles/ 内置示例
│   ├── reqloop/                          # 需求自验收闭环（7 阶段），adapters/lite 为内置适配器
│   └── reqloop-lite/                     # 无企业 ALM 依赖的轻量版
├── prompts/
│   ├── system/          # CLAUDE.md 模板
│   ├── task/            # 审查 / 排查 / 实现任务提示词
│   └── snippets/        # 错误处理 / 并发代码片段
├── installer/           # reqloop 安装器（Node ≥ 18，零依赖）
└── docs/                # 架构、命名规范、路线图、specs、plans
```

## 快速开始

### 把技能包装进 Claude Code

技能包以软链接方式接入，仓库更新后无需重装：

```bash
git clone git@github.com:omeyang/Thoth.git
cd Thoth
mkdir -p ~/.claude/skills
for s in skills/*/; do
  ln -sfn "$PWD/$s" ~/.claude/skills/"$(basename "$s")"
done
```

Codex 只需要 `diagram-png-export`：

```bash
ln -sfn "$PWD/skills/diagram-png-export" ~/.codex/skills/diagram-png-export
```

### 为 Go 项目配置 Hook、MCP 与 CLAUDE.md

```bash
# 1. Hook 脚本与配置
mkdir -p .claude/hooks
cp Thoth/hooks/scripts/*.sh .claude/hooks/
chmod +x .claude/hooks/*.sh
cp Thoth/hooks/configs/settings.json .claude/settings.json

# 2. MCP 服务器
cp Thoth/mcp/configs/go-backend-full.json .mcp.json

# 3. CLAUDE.md
cp Thoth/prompts/system/CLAUDE.md.tmpl CLAUDE.md
# 替换 {{PLACEHOLDER}} 为实际值
```

### 给仓库挂上对抗审查

```bash
export THOTH_HOME=/path/to/Thoth          # 建议写进 ~/.zshrc
cd your-repo
cp $THOTH_HOME/workflows/adversarial-review/examples/adversarial-review.yaml.example .adversarial-review.yaml
$THOTH_HOME/workflows/adversarial-review/scripts/install-hooks.sh
```

之后每次 `git commit` 都会对增量 diff 做 Claude×2 + Codex×2 的四路对抗审查。详见 [adversarial-review](./workflows/adversarial-review/WORKFLOW.md)。

### 安装 reqloop 需求验收闭环

```bash
cd Thoth/installer
node bin/install.mjs install claude-code   # 或 codex / costrict / costrict-cli / all
node bin/install.mjs doctor
```

安装后在 AI 工具里用 `/reqloop <需求ID>` 调起；没有企业 ALM 的项目用 `/reqloop <id> --lite`。

## 工作流一览

| 工作流 | 用途 | 形态 |
|--------|------|------|
| `tdd` | RED-GREEN-REFACTOR 测试驱动开发 | WORKFLOW.md |
| `code-review` | 结构化代码审查 | WORKFLOW.md |
| `deploy` | Kubernetes 部署上线 | WORKFLOW.md |
| `adversarial-review` | 四路对抗 + 交叉合议的代码审查，审 git diff 或任意 scope | 脚本 + pre-commit hook + bats 测试 |
| `design-review` | 4 支 Agent 队伍多轮交叉对抗审 Markdown 设计文档，收敛后产出补充文档、diff 草案与报告；项目预设走 profile 插件 | 脚本 + cron 批处理 + bats 测试 |
| `reqloop` | 需求 → 代码 → 反讲 → 验收的 7 阶段闭环；企业工具走 adapter 插件 | SKILL + 阶段指令 + 模板 + 适配器 |
| `reqloop-lite` | 仅依赖 git 与测试命令的轻量验收 | SKILL + command |

## 项目预设与企业适配器（插件目录）

Thoth 本身不含任何项目或企业专属信息。需要按项目定制的内容通过插件目录加载，找不到时一切走内置通用件：

| 工作流 | 插件形态 | 目录 | 内置回退 |
|--------|----------|------|----------|
| `design-review` | 项目预设（profile）：`profile.env`、`principles.md` 追加原则、同名角色模板覆盖 | `<root>/design-review/<name>/` | `workflows/design-review/profiles/example/` |
| `reqloop` | 企业适配器（adapter）：需求源 / 代码源 / CI / e2e / 缺陷回写五个槽位 | `<root>/reqloop/adapters/<name>/` | `workflows/reqloop/adapters/lite/` |

插件根目录 `<root>` 按 `$THOTH_PROFILES`、`~/.config/thoth/profiles`、Thoth 内置目录的顺序查找。把私有仓库软链到 `~/.config/thoth/profiles` 即可，Thoth 侧不需要任何改动：

```bash
ln -sfn /path/to/your-private-profiles ~/.config/thoth/profiles
```

design-review 在目标仓库的 `.design-review.yaml` 里写 `profile: <name>`；reqloop 用 `--adapter <name>`，或由适配器声明的需求 ID 模式自动选中。

## 与 Maat 的关系

- [Maat](https://github.com/omeyang/Maat) 定义 Go 后端的命名、设计、测试、错误处理、性能与质量门禁标准。
- Thoth 的 `cr`、`go-style`、`go-test` 等技能与 `code-reviewer` Agent 按 Maat 的规则审查代码。
- `design-review` 的引用清单把 Maat 列为"基础要求"层，设计文档必须满足它才能进入评审。

## 原则

- 保持模块小而可组合，每个目录可独立使用
- 优先显式契约而非隐式行为
- 每个可复用组件都附带使用示例
- 工作流用流程图与阶段说明描述，脚本只做编排

## 维护

- 目录约定见 [docs/architecture.md](./docs/architecture.md)，命名见 [docs/naming-conventions.md](./docs/naming-conventions.md)，进展见 [docs/roadmap.md](./docs/roadmap.md)
- 提交信息遵循 Conventional Commits，与 `hooks/scripts/commit-lint.sh` 的检查一致
- 修改 `adversarial-review` 或 `design-review` 后运行 `make -C workflows/<name> lint test`
- 贡献流程见 [CONTRIBUTING.md](./CONTRIBUTING.md)

## 许可

[MIT](./LICENSE)
