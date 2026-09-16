# 贡献指南

## 提交 PR 前

- 将更改放入正确的顶级目录，目录约定见 [docs/architecture.md](docs/architecture.md)
- 为新模块更新或添加 `README.md`；新增技能包时同步更新 `skills/CATALOG.md`
- 当行为变更时，添加或更新示例和/或评估用例
- 修改脚本型工作流后运行 `make -C workflows/<name> lint test`
- 保持更改小而聚焦

## 提交信息

遵循 Conventional Commits，与 `hooks/scripts/commit-lint.sh` 的检查一致：

```text
feat(design-review): 每队 5 角色扇出
fix(adversarial-review): render_template 漏拼 .md 后缀
docs: 更新技能目录
```

## PR 检查清单

- [ ] 目的和范围清晰
- [ ] 文档已更新
- [ ] 测试与 lint 通过（如适用）
- [ ] 包含风险和回滚说明（如适用）
