# content.json 六字段审计契约

清单只记录页面实际使用的内容，不是填表目标。顶层只强制 `question`、`one_sentence`、`evidence`、`claims`、`decision`、`teachback` 六项；`banned_terms` 与 `visual` 按需出现。

## 六个核心字段

- `question`：本页回答的一个核心问题，非空字符串。
- `one_sentence`：不超过 100 字的无术语复述；不得包含 `banned_terms`。
- `evidence`：至少一条。每项含唯一 `id`、实际读取过的 `source`、该来源支持的 `fact`，以及 `status=observed|verified|documented`。
- `claims`：至少一条。每项含 `text` 与 `kind=fact|inference|hypothesis`；事实必须有 `evidence` 引用，推断/假设可没有引用；所有引用 ID 必须存在。
- `decision`：`needed=true` 时含 `question`、`owner`、至少两个 `options`；每项选项写 `name`、`consequence`、`cost` 和布尔值 `reversible`。`needed=false` 时用 `reason` 说明。
- `teachback`：至少三题，每题含 `question`、`answer`、`misconception`；正式盲测应覆盖概念、对比、反例、决策、边界五类。

## 可选字段

`banned_terms` 是首屏不得出现、除非已在首屏定义的术语数组。用 `<dfn>术语</dfn>` 或带 `title` 的 `<abbr>` 定义。首屏优先用 `data-first-screen` 标记，否则审计器读取第一个 `<section>`；`one_sentence` 中始终禁止这些术语。

无动画时可省略 `visual`。有动画时：

```json
{
  "visual": {
    "animation": true,
    "reduced_motion": true,
    "controls": ["pause", "previous", "next", "reset"],
    "steps": [
      {"id": "before", "caption": "因为…所以…", "state": {"status": "old"}},
      {"id": "after", "caption": "因为…所以…", "state": {"status": "new"}, "final": true}
    ]
  }
}
```

每个 step 的 `id` 必须对应页面 `[data-step]`，`state` 非空且相邻步骤有变化，至少一个 `final=true`。播放不是必需控件；静态页面不得因缺少 `examples`、`history`、`impacts` 或播放器而失败。

真实未知写入 `decision.missing_evidence` 或标为假设，不使用 `XX`、`YY`、`TODO`、`TBD` 等占位符。审计只能证明契约与页面自洽，不能证明读者已经理解。
