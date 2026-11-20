# Thoth

Thoth 是一套聚焦真实理解、业务证据与可执行决策的 Agent Skills 仓库。

## 核心 Skill

[`explain-business-visually`](skills/explain-business-visually/SKILL.md) 直接约束 AI 的工作方式，不需要安装命令行工具：

- **求实**：查找真实代码、调用方、文档、测试或日志，区分事实、推断与假设；
- **求是**：检查推理链，主动寻找反证，说明场景适配、代价和失效条件；
- **防幻觉**：不编造业务角色、事故、指标或执行结果，无法核验就明确标记；
- **真实场景**：核查数据流、函数调用链、接口顺序和真实调用方，确认改动影响谁；
- **假设比例**：外部接口不天然等于脏数据来源，无证据的极端假设不得主导方案决策；
- **理解验收**：先写 100 字无术语稿，最后用 teach-back 检查陌生读者是否真正理解。

## 安装与使用

把 `skills/explain-business-visually/` 整个目录导入支持 Agent Skills 的客户端，然后直接提出业务问题，例如：

```text
请使用 explain-business-visually 分析这次重构风险。
先找支持证据和反面证据，确认它是不是现实业务问题，再给出决策说明。
```

Skill 内的 `references/` 与 `templates/` 会指导取证、推理、表达和验收；不需要运行脚本或生成固定 JSON。

## 视觉 Skill

[`ui-craft`](skills/ui-craft/SKILL.md) 独立负责视觉方向、响应式、交互、无障碍与真实画面验收。它与业务图解分工不同，不合并规则。

## 仓库结构

```text
skills/       可安装的 Skill、参考方法、模板与示例
.github/      Markdown 结构与链接检查、泄漏扫描
```

## 许可

MIT，见 [LICENSE](LICENSE)。
