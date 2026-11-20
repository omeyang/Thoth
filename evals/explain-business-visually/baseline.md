# v1 基线与 v2 验收边界

基线提交：`7ef67a9`。现有可打开样例是 `skills/ui-craft/assets/technical-explainer.html`；业务图解目录没有现成页面与 `content.json`，因此不能伪造一份 v1 清单来补跑内容审计。

## 已实际执行

```text
python skills/ui-craft/scripts/audit_ui.py --path skills/ui-craft/assets/technical-explainer.html --strict --json
结果：1 个文件，0 errors，0 warnings。
```

这只证明旧样例通过当时的静态 HTML 卫生检查，不证明读者能复述或决策。

## 未执行 / 不得宣称通过

- v1 业务图解内容审计：缺少配套页面与清单，未运行。
- 独立 teach-back 盲测：需要未看源码的读者，当前记录不是盲测结果。
- v1 与 v2 的分数比较：没有有效盲测分数，不写“v2 明显更好”。
- 桌面、375px、axe-core 与减少动态效果：以重写后实际浏览器运行记录为准，未运行时保持未验证。

v2 的三个 fixture 用于回归六字段契约和静态门禁，不能替代上述读者与浏览器验收。
