# Thoth

Thoth 现在是一套聚焦“真实理解与可执行决策”的 Agent Skills 仓库，不再是 Go 技能、代理、钩子和工作流的综合插件。

核心目标：没参与过一件事的人，读完说明页后能用自己的话复述问题、比较选项并说出结论何时失效。页面、字段和动画都只是实现这个目标的工具。

## 两个技能

| 技能 | 职责 |
| --- | --- |
| [`explain-business-visually`](skills/explain-business-visually/SKILL.md) | 事实核查、100 字费曼稿、理解机制、决策适配、teach-back 盲测 |
| [`ui-craft`](skills/ui-craft/SKILL.md) | 视觉方向、语义 tokens、响应式、交互、无障碍与真实画面验收 |

两者不合并：前者管“内容对不对、读者懂不懂”，后者管“形式是否清楚、交互是否可用”。HTML 卫生检查由 `ui-craft/scripts/html_hygiene.py` 统一提供。

## 使用

把 `skills/<name>/` 导入支持 Agent Skills 的客户端，或构建独立安装包：

```bash
python3 scripts/package-skill.py explain-business-visually
python3 scripts/package-skill.py ui-craft
```

产物写入 `dist/<name>.zip` 与 `dist/<name>.skill`。业务图解安装包会自动携带共享审计模块，不需要另外安装 `ui-craft`。

业务图解的入口流程只有四步：

1. 定一个核心问题、读者与证据边界；
2. 先写 100 字无术语费曼稿并确认；
3. 按读者卡点选择实例、时序、近误对比或其他机制；
4. 做静态审计、真实浏览器验收和独立 teach-back 盲测。

没有动画的页面不需要播放器。自动审计通过不等于读者已经理解。

## 仓库结构

```text
skills/       两个技能及其实际使用的参考、脚本、模板和示例
evals/        技能触发用例、三个内容 fixture、基线与验收记录
scripts/      结构校验、目录生成、可复现打包和单元测试
docs/         当前架构与决策记录
.github/      CI 与泄漏扫描
```

## 验证

```bash
scripts/validate.sh
python3 -m unittest discover -s scripts/tests -p 'test_*.py' -v
shellcheck scripts/*.sh
```

详细验证范围和未验收项见 [`evals/explain-business-visually/verification.md`](evals/explain-business-visually/verification.md)。

## 许可

MIT，见 [LICENSE](LICENSE)。
