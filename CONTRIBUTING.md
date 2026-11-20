# 贡献指南

## 当前边界

Thoth 只维护 `explain-business-visually` 与 `ui-craft`。不要重新引入旧的 Go 技能、代理、Hook、MCP 模板或脚本工作流；新机制必须对应一个明确的读者失败模式或视觉验证缺口。

## 修改原则

- 业务事实必须有实际读取过的来源；推断和假设明确标记。
- 不为通过审计而增加字段、示例、动画或文档。
- 修改共享 HTML 卫生层时，同时运行两个技能的测试和独立包检查。
- 修改页面后实测桌面与 375px；有控件时走键盘和减少动态效果路径。
- 自动检查不能代替独立 teach-back 盲测，未执行就写“未验证”。

## 提交前

```bash
scripts/gen-catalog.sh
scripts/validate.sh
python3 -m unittest discover -s scripts/tests -p 'test_*.py' -v
shellcheck scripts/*.sh
python3 scripts/package-skill.py explain-business-visually
python3 scripts/package-skill.py ui-craft
```

如果修改了 fixture，再运行每个 `evals/explain-business-visually/fixtures/*/` 的 `audit_explainer.py`。更新 `verification.md` 时只记录实际执行结果。

## 提交信息

使用 Conventional Commits，例如：

```text
refactor: 按理解目标重建仓库
fix(explainer): 修正首屏术语检测
test: 增加故障复盘 fixture
```

PR 需说明内容变化、删除的旧能力、实际验证和仍需人工验收的事项。
