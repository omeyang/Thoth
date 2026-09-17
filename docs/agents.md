# agents

Thoth 插件自带的 5 个子代理（subagent）。安装插件后 Claude Code 会自动装载，可被自动委派，也可在对话里用 `@thoth:<name>` 显式调用。

| 子代理 | 用途 | 预载技能 |
|-------|------|---------|
| `golang-pro` | Go 功能实现、并发、微服务架构 | golang-patterns、go-style、go-test、resilience-go、otel-go |
| `code-reviewer` | 6 维度代码审查（正确性/安全/性能/惯用法/可观测性/测试） | go-style、golang-patterns、go-test、cr |
| `security-auditor` | Go 后端漏洞发现、OWASP 审查、依赖扫描 | backend-patterns、api-design-go、resilience-go |
| `db-specialist` | MongoDB / ClickHouse / Redis 的 Schema 设计与查询优化 | mongodb-go、clickhouse-go、redis-go |
| `k8s-devops` | K8s 排查、Helm 部署、Docker 构建、CI/CD | k8s-go、deploy-k8s |

## 文件格式

每个子代理是 `agents/<name>.md` 一个文件，frontmatter 使用 Claude Code 原生字段：

```yaml
---
name: code-reviewer
description: 一句话描述，Claude 据此决定何时委派
tools: Read, Grep, Glob, Bash        # 允许的工具，逗号分隔
skills: [go-style, go-test]          # 启动时预载的 Thoth 技能
---
```

正文固定包含：身份、工作流程、专业领域、输入契约、输出契约、错误处理。

## 组合使用

复杂任务按序组合：`golang-pro` 实现 → `code-reviewer` 审查 → `security-auditor` 审计 → `k8s-devops` 部署。`tdd-go`、`deploy-k8s`、`cr` 三个技能内置了这些组合方式。

## Codex

Codex 的子代理是 TOML 文件，插件不能直接携带。`templates/codex-agents/<name>.toml` 由同一份正文生成，复制到 `~/.codex/agents/`（个人）或项目 `.codex/agents/` 即可：

```bash
cp Thoth/templates/codex-agents/*.toml ~/.codex/agents/
```
