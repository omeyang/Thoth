# 贡献指南

## 提交 PR 前

- 目录约定见 [docs/architecture.md](docs/architecture.md)，命名见 [docs/naming-conventions.md](docs/naming-conventions.md)。
- 新增或删除技能后运行 `scripts/gen-catalog.sh` 重新生成 `skills/CATALOG.md`。
- 运行 `scripts/validate.sh` 与 `claude plugin validate . --strict`。
- 修改 `hooks/scripts/` 或 `scripts/` 后运行 `shellcheck`。
- 修改 `workflows/adversarial-review` 或 `workflows/design-review` 后运行 `make -C workflows/<name> lint test`。
- 技能内容遵守单一基线：go1.24.6，库版本以技能里写明的版本为准，不引用私有库。
- 本地验证插件：`claude --plugin-dir .`，在会话里确认 `/thoth:<skill>` 可见。

## 提交信息

Conventional Commits，与 `hooks/scripts/commit-lint.sh` 的检查一致：

```text
feat(design-review): 每队 5 角色扇出
fix(kafka-go): DLQ 示例补齐 header 传播
docs: 更新技能目录
```

## PR 检查清单

- [ ] 目的和范围清晰
- [ ] 文档已更新（README、CATALOG、对应目录 README）
- [ ] `scripts/validate.sh` 通过
- [ ] 脚本型改动的 lint 与 bats 通过
