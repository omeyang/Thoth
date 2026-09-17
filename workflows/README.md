# workflows

两个脚本型工作流。它们不是插件的一部分，通过 `THOTH_HOME` 定位仓库，由 pre-commit 或 cron 调用，直接驱动 `claude` 与 `codex` 两个 CLI。

| 工作流 | 用途 | 形态 |
|--------|------|------|
| [adversarial-review](./adversarial-review/WORKFLOW.md) | Claude×2 + Codex×2 四路对抗 + 交叉合议，审 git diff（pre-commit 增量）或任意 scope | 脚本 + pre-commit hook + bats |
| [design-review](./design-review/WORKFLOW.md) | 4 支 Agent 队伍多轮交叉对抗审 Markdown 设计文档，收敛后产出补充文档、diff 草案与报告 | 脚本 + cron 批处理 + profile 插件 + bats |

流程型的 TDD、部署、需求验收已经是技能：`tdd-go`、`deploy-k8s`、`reqloop`、`reqloop-lite`；单模型代码审查在 `cr` 技能里。

## 约定

- `Makefile` 提供 `lint`（shellcheck）与 `test`（bats）。
- 环境变量 `THOTH_HOME` 指向仓库根。
- 项目与企业专属内容按 `$THOTH_PROFILES` → `~/.config/thoth/profiles` → 内置目录加载，不进仓库。
- 前置工具：`claude`、`codex`、`yq` v4、`jq`、`envsubst`、`flock`、`timeout`、`bats-core`、`shellcheck`。
