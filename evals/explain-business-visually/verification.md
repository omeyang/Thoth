# v2 实际验证记录

日期：2026-11-20。远程仓库：`/root/code/ai/github.com/omeyang/Thoth`。

## 自动检查

- `python3 -m unittest discover -s scripts/tests -p 'test_*.py' -v`：17 项通过。
- `scripts/validate.sh`：2 个核心技能通过，旧架构目录确认不存在。
- `python3 skills/ui-craft/scripts/audit_ui.py --path skills/ui-craft/assets/technical-explainer.html --strict`：0 errors，0 warnings。
- 三个 `evals/explain-business-visually/fixtures/*/`：六字段契约与共享 HTML 卫生审计全部通过。
- 两个技能的 `.zip` / `.skill`：打包成功；业务图解独立包包含共享审计模块与 templates。
- `shellcheck scripts/*.sh` 与 `git diff --check`：通过。

## 真实浏览器

使用远程 `chromium-browser --headless --no-sandbox --disable-gpu --hide-scrollbars --run-all-compositor-stages-before-draw`，分别以 `1280,1000` 和 `375,900` 打开三个 fixture 的 `file://` 页面并截图。六张截图均已实际查看：

| fixture | 桌面 | 375px | 观察 |
| --- | --- | --- | --- |
| refactor-risk | 已查看 | 已查看 | 结论、前提、三步过程与单变量对比可读，无可见溢出/遮挡 |
| incident-review | 已查看 | 已查看 | 错误归因、反证和三步时间线层级清楚，无可见溢出/遮挡 |
| decision | 已查看 | 已查看 | 约束与两个选项的代价、可逆性可读，无可见溢出/遮挡 |

三个 fixture 都是静态页面，没有按钮、链接或动画，因此没有播放器、键盘控件或减少动态效果交互可走查。

## 尚未验收

- 未运行 axe-core，不能声称无 serious/critical 问题。
- 未由未看源码的独立读者完成 teach-back，不能声称 ≥ 4/5 或 v2 内容评分优于 v1。
- fixture 是假设场景，只验证技能和审计机制，不证明任何真实业务事实。
