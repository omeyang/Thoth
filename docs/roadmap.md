# 路线图

## 第一阶段：基础建设（已完成）

- [x] 建立目录契约和命名规范
- [x] 技能包迁移到 `skills/`
- [x] 架构文档和贡献指南

## 第二阶段：运行时（已完成）

- [x] Hook 脚本（go-format, go-lint, go-test-async, block-dangerous, session-context, commit-lint）
- [x] Hook 配置模板（完整版 + 最小版）
- [x] MCP 服务器配置模板（K8s, MongoDB, ClickHouse, Redis, Kafka, OTel, GitHub）
- [x] Agent 定义（golang-pro, code-reviewer, k8s-devops, db-specialist, security-auditor）
- [x] 工作流定义（TDD, Code Review, Deploy）
- [x] Prompt 模板（CLAUDE.md 模板, 任务提示词, 代码片段）

## 第三阶段：审查与验收工作流（已完成）

- [x] `cr` 代码审查技能（local / pr / teams 三种模式）
- [x] `go-performance`、`go-runtime` 技能（Go 1.25.9+ 基线）
- [x] `diagram-png-export` 跨项目图表 PNG 导出技能
- [x] `adversarial-review`：四路对抗 + 交叉合议，pre-commit 增量审查
- [x] `design-review`：设计文档多轮对抗审查，含每晚 cron 批处理
- [x] `reqloop` 需求自验收闭环与 `reqloop-lite` 轻量版
- [x] reqloop 零依赖安装器（claude-code / codex / costrict / costrict-cli）
- [x] 仓库更名为 Thoth，工程标准统一引用 Maat
- [x] 项目预设（design-review profile）与企业适配器（reqloop adapter）抽离为插件目录，仓库开源

## 第四阶段：可靠性

- [ ] 添加评估套件和回归检查
- [ ] 添加 CI 结构和文档验证
- [ ] Hook 脚本单元测试
- [ ] 端到端示例项目

## 第五阶段：扩展

- [ ] Policies 模块（安全策略、权限边界）
- [ ] Integrations 模块（GitHub Actions、Slack 通知）
- [ ] 更多技能包（前端、DevOps、SRE）
- [ ] 多语言支持（Python、Rust）
