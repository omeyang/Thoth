# 阶段 4b — 负向影响分析 (impact-radius)

## 动机

前序阶段只验收"应该发生的"（正向需求）。漏掉的是"不应该发生什么"：
- 变更函数被哪些上游路径调用？
- 修改的数据结构被哪些消费者读取？
- 配置/常量变动的静默传播范围？

这些路径**不在需求单里**，但一旦破坏就是线上事故。业界 SDD 工具（Spec Kit / Kiro）
只关心"需求 → 代码"正向链，几乎不做反向辐射分析 —— 这是反向验收能补上的空白。

## 前置

- 阶段 4 已产出 `.reqloop/review-{id}.md`
- `code-review-graph` 已生成的依赖图（阶段 4 步骤 1 产物）

## 目标

对每个变更符号（函数 / 方法 / 公开类型 / 常量 / 配置键），产出：
1. 反向调用链（深度 ≤3）
2. 每条路径的"影响性质"判定：行为改变 / 仅签名兼容 / 已被测试覆盖
3. 未被任何测试或需求覆盖的路径 → 强制进入"需人工确认无影响"清单

## 步骤

1. **枚举变更符号**
   - 从阶段 2 的 diff 解析出新增/修改/删除的 exported 符号
   - 包含：函数签名、struct 字段、常量、配置键、proto message
   - 内部私有符号（小写开头且无反射引用）可跳过

2. **生成反向调用链**
   - 从 `code-review-graph` 查询每个符号的 inbound 引用
   - 深度限制：默认 3（可配置）；超过 3 层的路径聚合为"间接影响"
   - 跨仓库依赖：通过 `go.mod` / `package.json` 反查 downstream repo

3. **分类影响性质**

   对每条反向路径执行三元判定：

   | 分类 | 判据 | 处置 |
   |------|------|------|
   | `behavior-change` | 调用方实际依赖的语义/返回值/副作用发生变化 | 必须有对应测试或人工确认 |
   | `signature-compat` | 仅签名微调，语义不变（如新增可选参数）| 仅需编译验证 |
   | `covered` | 路径被现有测试覆盖且通过 | 自动放行 |
   | `unknown` | AI 无法判定 | **进入人工确认清单** |

4. **交叉需求映射**
   - 每条 `behavior-change` 必须关联到反讲文档中的一条 REQ-ID
   - 无法关联 → 说明这是"隐式变更"，在报告中标 `⚠️ implicit-behavior-change`
   - 所有 `⚠️` 条目默认阻塞验收，除非人工确认无影响

5. **写入决策链**
   - 每条判定 append 一行到 `.reqloop/decisions-{id}.jsonl`
   - `stage: "impact-radius"`（阶段 4b），字段与决策链契约一致

## 产物

`.reqloop/impact-{id}.md`：

```markdown
---
id: {id}
stage_status: complete | in_progress
schema_version: 1
based_on_confirmed: true
counts:
  changed_symbols: N
  callers_total: N
  behavior_change: N
  signature_compat: N
  covered: N
  unknown: N
  implicit_behavior_change: N   # ⚠️ 条目数
---

## 结构化影响项

```yaml
impacts:
  - symbol: { repo: repo-a, file: pkg/foo/bar.go, name: ProcessOrder, kind: func }
    change_type: signature | semantics | deletion | new
    callers:
      - { repo: repo-b, file: svc/checkout.go, lines: "88-92", depth: 1,
          classification: behavior-change,
          req_id: REQ-001,            # null 时该条为 implicit-behavior-change
          test_coverage: [{ file: checkout_test.go, case: TestCheckoutFlow }],
          confidence: high | medium | low,
          reasoning: "..." }
      - ...
```

## 隐式行为变更（⚠️ 阻塞）

1. repo-b/svc/checkout.go:88 调用 ProcessOrder，新行为未在反讲文档声明
   - 人工处置：[ ] 补需求  [ ] 确认无影响  [ ] 回滚
   - 决定人 / 时间：

## 未知影响（需人工确认）

1. repo-c/consumer.go:12 — 通过反射调用，AI 无法静态判定

## 已覆盖路径（自动放行）

（折叠列表，供审计）
```

## 门禁规则

- `implicit_behavior_change > 0` → 阶段 7 最高"有条件通过"，必须逐条人工签字
- `unknown > 阈值（默认 5）` → 建议扩展依赖图工具或增加测试，警告但不强制
- 跨仓库 `behavior-change` 无对应消费方测试 → 建议在阶段 6 补 e2e 用例

## 失败处理

- 依赖图生成失败 → 降级为"仅分析当前仓库"，报告中标注 `partial_graph: true`
- 跨语言边界（Go 调 Python / 前后端）→ 标注 `cross-language-boundary`，列出边界点供人工
