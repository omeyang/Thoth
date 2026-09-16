# 架构

Thoth 采用分层、可复用的构建块组织：

1. `prompts/`、`policies/` 定义行为约束。
2. `skills/`、`hooks/`、`integrations/` 提供能力。
3. `mcp/`、`agents/` 封装运行时组件。
4. `workflows/` 编排多步骤执行流程，`installer/` 把工作流装进各类 AI 编码工具。
5. `evaluations/` 验证质量和回归安全性。
6. `examples/` 展示实际组合方式。

项目专属内容不在本仓库：design-review 的项目预设（profile）与 reqloop 的企业适配器（adapter）按 `$THOTH_PROFILES` → `~/.config/thoth/profiles` → 内置目录的顺序加载，本仓库只保留通用引擎、通用模板与 lite 适配器。

工程标准不在本仓库定义。[Maat](https://github.com/omeyang/Maat) 是唯一的标准来源，技能与工作流只引用、不复制。

设计目标：

- 跨工具兼容：同一份技能或工作流可装进 Claude Code、Codex、costrict
- 模块间最小耦合：每个目录可独立使用，工作流通过路径引用组件
- 组件可测试、可版本化：脚本型工作流自带 bats 测试与 shellcheck 门禁
