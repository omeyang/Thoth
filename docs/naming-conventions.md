# 命名规范

- 目录与技能名用小写短横线（lowercase-kebab-case），1 到 64 个字符，与 `SKILL.md` 的 `name` 完全一致。
- 面向 Go 的技能以 `-go` 结尾（`kafka-go`、`redis-go`），语言无关的不加后缀（`cr`、`design-patterns`）。
- 子代理文件 `agents/<name>.md`，`name` 与文件名一致。
- Hook 脚本 `hooks/scripts/<动作>.sh`，动词开头（`block-dangerous`、`protect-secrets`、`go-format`）。
- 脚本工作流目录 `workflows/<name>/`，入口 `WORKFLOW.md`，脚本在 `scripts/`，模板在 `templates/`，测试在 `tests/`。
- 每个顶级目录带 `README.md`。
- 文档中文，标识符英文；中文与英文、数字之间留一个空格。
