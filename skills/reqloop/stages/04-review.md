# 阶段 4 — 代码审查 (review)

## 前置

必须先通过阶段 3 的人工签字门禁。
Review 基于**已 confirm 的反讲文档**作为"正确需求"，不再回头看原始需求单。

## 目标

在已对齐的需求前提下，审查代码质量、正确性、安全、一致性。
**重点**：通过 code-review-graph 补全局视角 + 依赖关系约束范围，避免只看 diff 跑偏。

## 步骤

1. **构建依赖视图**
   - 对每个仓库运行 `code-review-graph`
   - 产出：本次变更文件 ↔ 调用方 / 被调用方 的关系图
   - 产物归档到 `.reqloop/review-{id}/graph-{repo}.svg`（或文本形式）

2. **确定 review 范围**
   - 核心范围：阶段 2 采集的增量 diff
   - 扩展范围：graph 中与变更文件一阶相邻的文件（不读全文，只读签名 / 接口）
   - **禁止**：无限扩展到全仓库，容易跑偏

3. **多维度审查**

   使用 `code-reviewer` Agent，维度（沿用 Thoth 标准）：

   | 维度 | 优先级 | 重点 |
   |------|--------|------|
   | 正确性 | Critical | 是否实现反讲文档中已 confirm 的行为 |
   | 安全性 | Critical | 注入、越权、敏感信息 |
   | 一致性 | High | 与一阶依赖的接口契约是否兼容 |
   | 性能 | High | 新增热路径 / N+1 / 锁粒度 |
   | 惯用法 | Medium | Go 或相应语言的 idiom |
   | 可观测性 | Medium | 日志、metrics、trace |
   | 测试 | Medium | 是否有对应单测 |

4. **安全维度触发条件**
   - 涉及鉴权、加解密、外部输入、SQL/命令拼接 → 追加 `security-auditor` Agent

5. **增量约束**
   - 每条 review 意见必须能定位到具体行 `file:line`
   - 禁止"全文重构"类建议（超出本次需求范围）
   - 超出范围的建议单独归入 `out-of-scope` 段落，不纳入验收结论

6. **判定三元组（强制）**

   每条 finding 必须输出 `verdict + confidence + evidence`，单独自由文本叙述一律拒收：

   ```yaml
   findings:
     - id: F-001
       req_id: REQ-001          # 关联反讲文档中的需求条目
       location: { repo: repo-a, file: pkg/foo/bar.go, lines: "42-50" }
       dimension: correctness | security | consistency | performance | idiom | observability | test
       severity: critical | high | medium | low
       verdict: violates | unclear | compliant-with-concern
       confidence: high | medium | low
       evidence:
         - "反讲文档 REQ-001 要求金额>1000触发风控，但此处仅校验>10000"
         - "无对应单测覆盖边界值 1001"
       reasoning: "代码字面行为与 EARS 条件不一致，可直接比对"
       suggested_fix: "将阈值常量 10000 改为 1000，并补 TestRiskCheckBoundary"
   ```

7. **低置信度路由规则**

   - `confidence: low` 的 finding **不得**独立形成阻塞结论
   - 全部 `confidence: low` 条目汇总到 `review-{id}.md` 的 `## 需人工裁决` 段
   - 该段非空时，阶段 7 最终结论最高只能是 "有条件通过"

## 产物

`.reqloop/review-{id}.md`（frontmatter + 结构化 findings + 人工可读摘要）：

```markdown
---
id: {id}
stage_status: complete | in_progress
based_on_confirmed: true
graph_generated: true
counts:
  critical: N
  high: N
  medium: N
  low_confidence: N   # 需人工裁决的条目数
---

## 结构化 findings
（按第 6 步 YAML 格式输出，供脚本聚合）

## Critical（verdict=violates & confidence∈{high,medium}）
- [ ] F-001 repo-a/foo.go:42 — REQ-001 阈值不一致

## High
...

## 需人工裁决（confidence=low）
- F-007 repo-b/baz.go:88 — 疑似并发问题，证据不足

## Out-of-scope 建议（不影响验收）
...

## 亮点
...

## 结论
- Critical: N / High: N / 需人工裁决: N
- 阻塞验收: yes | no | conditional
```

## 门禁规则

- `critical > 0` 且 confidence∈{high,medium} → 阶段 7 必为"不通过"
- `high > 3` → 建议"有条件通过"
- `low_confidence > 0` → 结论最高"有条件通过"，必须人工裁决后才能升级为"通过"
- 安全例外（反讲文档 `security_sensitive: true` 且 §5 未全部修复）→ 直接"不通过"
