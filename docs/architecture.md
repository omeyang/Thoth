# 架构

Thoth 是一个插件仓库：仓库根目录同时是 Claude Code 插件（`.claude-plugin/`）和 Codex 插件（`.codex-plugin/`），两者共用同一批组件。

| 目录 | 角色 | 装载方式 |
|------|------|---------|
| `skills/` | 27 个技能，每目录一个 `SKILL.md`，长示例放 `references/` | 插件自动装载，`/thoth:<name>`（Codex `$<name>`） |
| `agents/` | 5 个子代理，`agents/<name>.md` | Claude Code 插件自动装载；Codex 见 `templates/AGENTS.md` |
| `hooks/` | `hooks.json` + 7 个脚本 | 插件自动装载；Codex 复用脚本 |
| `mcp/` | 项目级 `.mcp.json` 模板 | 复制到目标项目 |
| `templates/` | `CLAUDE.md`、`.claude/rules/go.md`、`AGENTS.md` 模板 | 复制到目标项目 |
| `workflows/` | 两个脚本型工作流：adversarial-review、design-review | `THOTH_HOME` 定位，pre-commit / cron 调用 |
| `evals/` | `claude plugin eval` 用例 | 本地或 CI 手动运行 |
| `scripts/` | `validate.sh`、`gen-catalog.sh`、`sync-wiki.sh` | 维护者运行 |
| `docs/` | 架构、路线图、命名规范、设计文档与实施计划 | 阅读；`sync-wiki.sh` 同步到 Wiki |

## 边界

- **工程标准不在本仓库定义。** [Maat](https://github.com/omeyang/Maat) 是唯一的标准来源，技能与工作流只引用、不复制。
- **项目与企业专属内容不在本仓库。** design-review 的 profile 与 reqloop 的 adapter 按 `$THOTH_PROFILES` → `~/.config/thoth/profiles` → 内置目录的顺序加载，仓库只保留通用引擎与 lite 适配器。
- **单一基线。** Go 固定 go1.24.6，库版本钉在该工具链可用的最新版；不写多版本兼容说明。
- **只支持两个宿主。** Claude Code 与 Codex。没有软链接安装、没有 installer、没有其他 IDE 适配。

## 组件关系

```
插件（skills + agents + hooks）
    ├── 技能：领域知识与流程，可被模型自动选用或用户显式调用
    ├── 子代理：角色化执行体，frontmatter 用 skills: 预载技能
    └── 钩子：会话上下文、危险命令与凭证拦截、Go 格式化 / lint / 测试
脚本工作流（workflows/）
    ├── adversarial-review：Claude×2 + Codex×2 审 diff，挂 pre-commit
    └── design-review：4 队多轮对抗审设计文档，cron 批处理
项目模板（mcp/ templates/）：复制到目标仓库
```

## 设计目标

- 跨宿主：同一份技能同时服务 Claude Code 与 Codex（agentskills.io 规范）。
- 最小耦合：每个目录可独立阅读与使用；工作流通过路径引用组件。
- 可验证：`scripts/validate.sh` 校验结构，`claude plugin validate --strict` 校验清单，bats + shellcheck 校验脚本，evals 校验技能触发。
