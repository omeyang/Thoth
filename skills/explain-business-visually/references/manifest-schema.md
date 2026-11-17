# content.json 内容契约

`content.json` 是页面内容的审计输入，只记录实际使用的事实、场景和演示。不得为填字段编造内容。

## 顶层字段

| 字段 | 要求 |
| --- | --- |
| `audience` | 目标读者及其已有背景，非空字符串 |
| `question` | 本页回答的一个核心问题，非空字符串 |
| `scenario` | 当前真实场景对象，见下表 |
| `evidence` | 至少一条证据，ID 唯一 |
| `confusions` | 至少一个易混淆场景对照 |
| `examples` | 至少两个具体示例，或正确/错误一对示例 |
| `history` | 历史差异；无历史时明确 `applicable=false` 并说明原因 |
| `impacts` | 至少一个实际影响对象与后果 |
| `decision` | 是否需要人工决策及具体问题；不需要时明确 `needed=false` |
| `visual` | 演示步骤、控件和减少动态效果支持 |
| `claims` | 页面关键事实/风险/推断及其证据 |
| `banned_terms` | 本页禁止未解释使用的内部术语，可为空数组 |

## scenario

- `actor`：实际角色，例如“租户 A”；
- `trigger`：具体触发原因；
- `preconditions`：发生前必须成立的条件数组；
- `event`：实际发生的事件；
- `outcome`：可观察结果；
- `owner`：状态推进或处理责任方。

## evidence

每条包含：

- `id`：唯一证据 ID；
- `source`：实际读取过的文件、URL、日志或运行记录；
- `fact`：该来源实际支持的事实；
- `status`：`observed`、`verified` 或 `documented`。

不得引用未读取的来源。示例和 claims 只能通过已有证据 ID 引用。

## confusions

每项包含 `scenario`、`same`、`different`、`handling`：场景名称、相同表象、关键差异、正确处理路径。

## examples

每项包含 `name`、`actor`、`event`、`result`、`evidence`。`evidence` 至少引用一个已有 ID；若例子为假设，另加 `label="风险示例"` 或 `label="假设示例"`。

## history

- `applicable=true` 时，`before`、`why_no_issue`、`changed` 均非空；
- 无历史时，`applicable=false`，并用 `reason` 说明为什么没有历史可比。

## impacts

每项包含 `area`、`effect`、`scope`，分别说明影响对象、后果和范围。

## decision

- `needed=true` 时，必须有 `question`、至少两个 `options`、`owner`；`options` 每项写 `name` 和 `consequence`；
- `missing_evidence` 数组列出仍需补充的证据，可为空；
- `needed=false` 时用 `reason` 说明为什么不需要人工决策。

## visual

- `steps`：至少两个演示步骤；
- `controls`：至少包含 `play`、`pause`、`previous`、`next`、`reset`；
- `reduced_motion`：必须为 true；
- `animation`：是否实际使用动画，布尔值。

## claims

每项包含：

- `text`：页面实际关键结论；
- `evidence`：至少一个已有证据 ID；
- `kind`：`fact`、`risk`、`inference` 或 `hypothesis`；
- `label`：非事实结论必须明确标为 `风险示例`、`推断` 或 `假设`。

## 禁止占位符

不接受 `XX`、`YY`、`TODO`、`TBD`、尖括号占位符等未替换内容。真实未知项必须写入 `decision.missing_evidence`，而不是留在正文占位。
