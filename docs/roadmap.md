# 路线图

## 已完成

### 基础建设与运行时（2026-04）

- 目录契约、命名规范、架构文档
- 23 个 Go 技能，Hook 脚本，MCP 模板，5 个子代理，CLAUDE.md 模板

### 审查与验收工作流（2026-05 至 2026-09）

- `cr` 技能（local / pr / teams）
- `adversarial-review`：四路对抗 + 交叉合议，pre-commit 增量审查，bats 全覆盖
- `design-review`：设计文档多轮对抗审查，每晚 cron 批处理
- `reqloop` / `reqloop-lite` 需求自验收闭环
- 仓库更名 Thoth，工程标准统一引用 Maat；profile / adapter 抽离为插件目录

### 现代化改造（2026-09-17）

- 分发方式改为插件：仓库根即 Claude Code 插件与市场，另附 Codex 插件清单；删除软链接安装与 installer
- Go 基线固定 go1.24.6，全部技能与库版本按该工具链核实钉住
- 技能示例与 XKit 解耦，只用上游库
- 子代理改为原生 `agents/<name>.md` 格式并预载技能
- 插件级 `hooks.json`，新增 `protect-secrets`
- MCP 模板换用 GitHub、Redis、MongoDB 官方服务器
- `tdd` / `deploy` 由文档改为技能；`code-review` 并入 `cr`
- `scripts/validate.sh`、`gen-catalog.sh`、`sync-wiki.sh` 与 GitHub Actions CI
- `evals/` 技能触发用例
- GitHub Wiki 由仓库文档生成

## 进行中

- 为每个技能补齐 `claude plugin eval` 的行为类用例（目前只有触发类）
- Codex 子代理定义（等 Codex 插件 `agents/` 格式稳定）

## 候选

- `design-review` / `adversarial-review` 的 Claude 侧改用 `--json-schema` 结构化输出，去掉 YAML 围栏剥离
- 端到端示例项目
- 更多中间件技能（PostgreSQL / pgx、NATS）
