# skills

Thoth 插件的技能。完整列表见 [CATALOG.md](CATALOG.md)（由 `scripts/gen-catalog.sh` 生成）。

## 结构

```text
skills/<name>/
├── SKILL.md          # 必需，≤ 500 行：决策、要点、检查清单
└── references/       # 完整代码示例与长篇资料，按需读取
```

## frontmatter

```yaml
---
name: kafka-go                       # 与目录名一致
description: "<能力>. 适用：<场景>. 不适用：<反模式>. 触发词：<关键词>"   # ≤ 1024 字符
argument-hint: "<可选>"
---
```

## 规则

- 单一基线 go1.24.6；库版本在技能正文写明，取该工具链可用的最新版。
- 示例只用上游库，不引用私有库。
- 中文正文，英文标识符。
- 新增或删除技能后运行 `scripts/gen-catalog.sh`，并通过 `scripts/validate.sh`。
