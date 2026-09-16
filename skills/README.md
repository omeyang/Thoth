# skills

用于代理编码工作流的可复用技能包。

## 使用方式

- 完整列表见 [CATALOG.md](CATALOG.md)。
- 技能包以软链接方式接入 Claude Code：`ln -sfn "$PWD/skills/<name>" ~/.claude/skills/<name>`，仓库更新后无需重装。
- 跨项目图表附件交付使用 [diagram-png-export](diagram-png-export/README.md)，默认生成白底、4 倍分辨率、完整无裁切的 PNG；Codex 通过 `~/.codex/skills/diagram-png-export` 软链接共用同一份。

## 建议的模块结构

```text
skills/<skill-name>/
├── SKILL.md
├── scripts/
├── assets/
└── references/
```

## 规则

- 每个目录一个技能包。
- `SKILL.md` 为必需文件。
- 仅包含工作流所需的引用。
- 保持前置字段（`name`、`description`、`user-invocable`）一致。
- 新增或删除技能包时同步更新 `CATALOG.md` 的总数与表格。
