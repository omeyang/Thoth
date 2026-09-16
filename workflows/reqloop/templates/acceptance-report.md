---
id: {需求 ID}
generated_at: {ISO8601}
schema_version: 2
conclusion: pass | conditional | fail
incomplete: false
resolved_by:                    # 有条件通过升级为通过时填写
resolved_at:
security_sensitive: false
stages:
  gather: ok | missing
  collect_code: ok | missing
  backspec: confirmed | unconfirmed
  review: ok | blocked
  impact_radius: ok | has_implicit_change | partial_graph
  runtime: ok | partial | failed
  e2e: ok | partial | skipped
counts:
  critical: 0
  high: 0
  low_confidence: 0             # 需人工裁决的决策数
  implicit_behavior_changes: 0  # 阶段 4b 隐式行为变更数
  coverage_gaps: 0
artifacts:
  decisions: .reqloop/decisions-{id}.jsonl
  security: .reqloop/security-{id}.md   # 仅 security_sensitive 时存在
---

# 验收报告 — {需求 ID}

## 结论

**{通过 / 有条件通过 / 不通过}**

- Critical 问题数：N
- 运行时失败数：N
- e2e 失败数：N
- 覆盖矩阵未闭环项：N
- 隐式行为变更未签字：N
- 低置信度待裁决：N

## 反讲文档确认摘要

- 反讲文档：`.reqloop/backspec-{id}.md`
- confirm 人：
- confirm 时间：
- 🔴 缺失已处置：N 项
- 🟡 额外已处置：N 项
- 🟠 偏差已处置：N 项

## 代码审查摘要

产物：`.reqloop/review-{id}.md`

| 优先级 | 数量 |
|--------|------|
| Critical | N |
| High | N |
| Medium | N |

关键问题 Top 3：
1. ...
2. ...
3. ...

## 负向影响分析摘要

产物：`.reqloop/impact-{id}.md`

- 变更符号数：N
- 反向调用路径总数：N
- 行为变更 / 签名兼容 / 已覆盖 / 未知：N / N / N / N
- ⚠️ 隐式行为变更（未关联需求）：N 项
  - {符号 @ 路径} — 处置：...

> 隐式行为变更 > 0 时，本次验收最高只能判"有条件通过"。

## 运行时校验摘要

产物：`.reqloop/runtime-{id}.md`

- 环境：{用户指定}
- build / test / lint：✅✅✅ 或 ❌...
- 业务边界覆盖矩阵未闭环项：
  - 场景 X：缺 ...
  - 场景 Y：缺 ...

## 端到端回归摘要

产物：`.reqloop/e2e-{id}.md`

- 平台：{平台}（由 e2e 适配器决定；skipped / manual 时说明原因）
- 总 / 通过 / 失败：N / X / Y
- 失败用例 → 业务场景：
  - 用例 A → 场景 X
  - ...

## 失败项对应缺陷

| 缺陷 ID | 标题 | 来源阶段 |
|---------|------|---------|
| {缺陷ID} | [reqloop/{id}] ... | review / runtime / e2e |

## 后续动作建议

- [ ] 修复 Critical 问题
- [ ] 补齐覆盖矩阵缺口
- [ ] 失败用例定位与修复
- [ ] 修复后重跑 `/reqloop {id}`

## 决策链摘要

来源：`.reqloop/decisions-{id}.jsonl`

| 阶段 | 判定总数 | high | medium | low | 人工 override |
|------|---------|------|--------|-----|--------------|
| backspec | N | N | N | N | N |
| review | N | N | N | N | N |
| impact-radius | N | N | N | N | N |
| runtime | N | N | N | N | N |
| e2e | N | N | N | N | N |

> `low` 列非零时，本次验收最高只能判"有条件通过"。
> `human_override` 列记录的是人工修正 AI 判定的次数。
> 使用 `/reqloop stats` 跨需求聚合此数据，持续改进提示词与规则。

## 安全例外（仅当 security_sensitive: true）

- 触发关键词：{...}
- security-auditor 报告：`.reqloop/security-{id}.md`
- 未修复的安全冲突数：N（>0 则强制 `conclusion: fail`）

## 产物索引

- 需求原文：`.reqloop/req-{id}.md`
- 代码归档：`.reqloop/code-{id}/`
- 反讲文档：`.reqloop/backspec-{id}.md`
- 人工签字：`.reqloop/confirmed-{id}.md`
- 代码审查：`.reqloop/review-{id}.md`
- 负向影响：`.reqloop/impact-{id}.md`
- 运行时报告：`.reqloop/runtime-{id}.md`
- e2e 报告：`.reqloop/e2e-{id}.md`
- 决策链：`.reqloop/decisions-{id}.jsonl`
- 安全报告：`.reqloop/security-{id}.md`（若有）
