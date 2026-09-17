# Thoth：Go 后端 AI 编码工具箱

> 让 AI 编码助手按 Maat 的标准做事。

[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](./LICENSE)
[![Skills: 27](https://img.shields.io/badge/Skills-27-blue)](./skills/CATALOG.md)
[![Go: 1.24.6](https://img.shields.io/badge/Go-1.24.6-00ADD8)](#基线)
[![CI](https://github.com/omeyang/Thoth/actions/workflows/ci.yml/badge.svg)](https://github.com/omeyang/Thoth/actions/workflows/ci.yml)

Thoth 是一个 Claude Code / Codex 插件：27 个 Go 后端技能、5 个子代理、一组事件钩子，外加两个多 Agent 对抗审查工作流和项目模板。工程标准与 [Maat](https://github.com/omeyang/Maat) 保持一致：Maat 定义什么是正确，Thoth 把这些标准装进 AI 工具的日常工作流。

名字来源：托特（Thoth）是古埃及神话中的书记与智慧之神。在"称心仪式"中，玛特（Maat）的羽毛是衡量的标尺，托特负责记录裁决。

适用对象：用 Claude Code 或 Codex 做 Go 后端开发的个人与团队；需要把代码审查、设计评审、需求验收交给多 Agent 自动执行的项目。

## 安装

### Claude Code

```text
/plugin marketplace add omeyang/Thoth
/plugin install thoth@thoth
```

安装后技能以 `/thoth:<name>` 调用（如 `/thoth:cr`、`/thoth:reqloop`），子代理与钩子自动生效。本地开发用 `claude --plugin-dir /path/to/Thoth`。

### Codex

```bash
codex plugin marketplace add omeyang/Thoth
codex plugin add thoth@thoth
```

技能以 `$<name>` 调用（如 `$cr`）。插件自带的钩子在 Codex 里需要先在 `/hooks` 中审阅信任。子代理复制 `templates/codex-agents/*.toml` 到 `~/.codex/agents/`。

### 项目模板

```bash
cp Thoth/templates/CLAUDE.md your-project/CLAUDE.md          # Claude Code 项目指令
mkdir -p your-project/.claude/rules && cp Thoth/templates/rules-go.md your-project/.claude/rules/go.md
cp Thoth/templates/AGENTS.md your-project/AGENTS.md          # Codex 项目指令
cp Thoth/templates/codex-agents/*.toml ~/.codex/agents/       # Codex 子代理
cp Thoth/mcp/configs/go-backend-full.json your-project/.mcp.json
```

替换 `{{PLACEHOLDER}}` 后即可使用。

## 内容一览

| 目录 | 内容 |
|------|------|
| [skills/](./skills/CATALOG.md) | 27 个技能：Go 开发与运行时（golang-patterns、go-style、go-test、go-performance、go-runtime、algorithms）、中间件（kafka、pulsar、redis、mongodb、clickhouse、etcd、grpc、k8s、otel）、架构与韧性（design-patterns、backend-patterns、api-design、resilience、idempotency、multi-tenant）、流程（cr、tdd-go、deploy-k8s、reqloop、reqloop-lite）、图表导出 |
| [agents/](./docs/agents.md) | golang-pro、code-reviewer、security-auditor、db-specialist、k8s-devops |
| [hooks/](./hooks/README.md) | 会话上下文、危险命令拦截、凭证保护、提交信息检查、Go 格式化 / lint / 异步测试 |
| [mcp/](./mcp/README.md) | 项目级 `.mcp.json` 模板：GitHub、Kubernetes、MongoDB、Redis、ClickHouse、Kafka、OpenTelemetry |
| [templates/](./templates/) | `CLAUDE.md`、`.claude/rules/go.md`、`AGENTS.md`、Codex 子代理 TOML |
| [workflows/](./workflows/README.md) | adversarial-review（四路对抗审 diff，挂 pre-commit）、design-review（设计文档多轮对抗审查，cron 批处理） |
| [evals/](./evals/README.md) | `claude plugin eval` 触发用例 |
| [docs/](./docs/architecture.md) | 架构、路线图、命名规范、设计文档与实施计划 |

## 基线

- Go 固定 **go1.24.6**。技能里的示例、库版本、lint 配置都按这个工具链核实，不写多版本兼容说明。
- 库版本钉在 go1.24.6 可用的最新版，各技能正文写明。
- golangci-lint v2.8.0，配置为 v2 格式。

## 对抗审查工作流

```bash
export THOTH_HOME=/path/to/Thoth          # 建议写进 ~/.zshrc
cd your-repo
cp $THOTH_HOME/workflows/adversarial-review/examples/adversarial-review.yaml.example .adversarial-review.yaml
$THOTH_HOME/workflows/adversarial-review/scripts/install-hooks.sh
```

之后每次 `git commit` 都会对增量 diff 做 Claude×2 + Codex×2 的四路对抗审查。设计文档评审见 [design-review](./workflows/design-review/WORKFLOW.md)。

项目专属内容（design-review 的 profile、reqloop 的企业适配器）放在插件目录，按 `$THOTH_PROFILES` → `~/.config/thoth/profiles` → 内置目录的顺序查找，Thoth 本身不含任何项目或企业信息。

## 与 Maat 的关系

- [Maat](https://github.com/omeyang/Maat) 定义 Go 后端的命名、设计、测试、错误处理、性能与质量门禁标准。
- Thoth 的 `cr`、`go-style`、`go-test` 等技能与 `code-reviewer` 子代理按 Maat 的规则审查代码。
- `design-review` 的引用清单把 Maat 列为"基础要求"层。

## 维护

- 结构校验：`scripts/validate.sh`；插件清单：`claude plugin validate . --strict`
- 新增技能后：`scripts/gen-catalog.sh`
- Wiki 同步：`scripts/sync-wiki.sh`（[在线阅读](https://github.com/omeyang/Thoth/wiki)）
- 脚本工作流：`make -C workflows/<name> lint test`
- 贡献流程见 [CONTRIBUTING.md](./CONTRIBUTING.md)

## 许可

[MIT](./LICENSE)
