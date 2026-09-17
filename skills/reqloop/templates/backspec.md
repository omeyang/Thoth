---
id: {需求 ID}
stage_status: complete | in_progress
generated_at: {ISO8601}
schema_version: 2
sources:
  requirement: .reqloop/req-{id}.md
  code: .reqloop/code-{id}/INDEX.md
  prd: {路径 或 none}
confirmed: false          # 门禁字段，AI 禁止修改
security_sensitive: false # 命中安全关键词时 AI 置 true，冲突裁决走安全例外
---

# 反讲需求 — {需求 ID}

> 本文档由 reqloop 基于「需求单 + PRD + 实际代码」三源反推生成。
> **默认裁决原则：代码为准。** 但当 `security_sensitive: true` 时走安全例外（见 §5）。
> AI 不做调和，所有差异交给人工处置。

## 1. 结构化需求条目（machine-checkable）

> 采用 EARS 语法（Easy Approach to Requirements Syntax）。所有条目以 YAML 形式列出，
> 阶段 3 门禁脚本会校验：每条 requirement 必须有 code_anchors 或明确 status=missing；
> 每段 code diff 必须被至少一条 requirement 引用（否则归入 §3 额外项）。

```yaml
requirements:
  - id: REQ-001
    ears: "WHEN <trigger> AND <precondition>, THE <system> SHALL <response>"
    source:
      type: tracker | PRD | inferred-from-code   # 允许值由适配器 adapter.yaml.source_types 决定
      ref: AC-3            # 需求单验收条目编号，inferred 时为 null
      hash: sha256:xxxx    # 原始文本哈希，防需求漂移
    code_anchors:
      - { repo: repo-a, file: pkg/foo/bar.go, lines: "42-68", commit: abc1234 }
    test_anchors:
      - { repo: repo-a, file: pkg/foo/bar_test.go, case: TestBarHappyPath }
    status: covered | partial | missing | conflict | extra
    confidence: high | medium | low
    confidence_reason: "代码与 AC 文字一致，有对应单测" | "..."

  - id: REQ-002
    ...
```

### EARS 语法速查

| 模式 | 模板 |
|------|------|
| Ubiquitous | `THE <system> SHALL <response>` |
| Event-driven | `WHEN <trigger>, THE <system> SHALL <response>` |
| State-driven | `WHILE <state>, THE <system> SHALL <response>` |
| Optional | `WHERE <feature>, THE <system> SHALL <response>` |
| Unwanted | `IF <condition>, THEN THE <system> SHALL <response>` |

## 2. 代码实际做了什么（供人工对照）

逐 MR / 逐逻辑块的白话描述，**每条必须引用上面的 REQ-ID**。

### repo-a / MR-123
- 新增 `X` 接口（→ REQ-001），入参 `A/B`，行为：...
- 修改 `Y` 函数（→ REQ-002）：原先 ...，现在 ...

## 3. 三源差异（需人工处置）

### 🔴 缺失项（status: missing）

#### REQ-00X：{需求描述}
- 需求来源：tracker AC-3 / PRD §2.1
- 代码现状：无对应实现
- **人工处置**：[ ] 补代码  [ ] 延后  [ ] 需求作废
- **决定人 / 时间**：

### 🟡 额外项（status: extra，无对应 REQ）

#### 代码位置：repo-b/bar.go:88
- 行为描述：新增缓存层
- 可能影响：性能 / 副作用
- **人工处置**：[ ] 补需求  [ ] 删代码  [ ] 保持（附理由）
- **决定人 / 时间**：

### 🟠 偏差项（status: conflict）

#### REQ-00Y：{需求描述}
- 需求行为：...
- 代码行为：...
- **人工处置**：[ ] 改代码  [ ] 改需求  [ ] 保持（附理由）
- **决定人 / 时间**：

## 4. 已 confirm 的业务场景清单（供阶段 5/6 使用）

```yaml
scenarios:
  - id: SCN-01
    name: 高额订单风控触发
    maps_to: [REQ-001]
    data_fixture: fixtures/high_value_order.json
    env: staging
  - id: SCN-02
    ...
```

## 5. 安全例外裁决记录（仅当 security_sensitive: true）

命中关键词：{auth | 鉴权 | 审计 | 限流 | PII | 幂等 | 加密 | ...}

| REQ-ID | PRD 要求 | 代码现状 | 裁决 | 证据 |
|--------|---------|---------|------|------|
| REQ-00Z | 写入审计日志 | 缺失 | 以 PRD 为准，阻塞验收 | security-auditor 报告 `.reqloop/security-{id}.md` |

---

**人工 confirm 步骤**

1. 逐条填写 §3 的处置决定
2. 补全 §1 中 `status=partial` 条目的缺失细节（必要时追加 REQ）
3. 确认 §4 业务场景清单
4. 编辑 `.reqloop/confirmed-{id}.md`：填 `confirmed: true`、`confirmed_by`、`confirmed_at`
5. 重新调起 `/reqloop {id}` 继续

**机器校验规则（阶段 3 门禁自动跑）**

- 每条 `requirements[].status` ∈ {covered, partial, missing, conflict, extra}
- `covered` 必须有 ≥1 个 `code_anchors`
- 所有 diff hunks 必须至少被一条 requirement 引用（未引用 → 必须列入 §3 🟡）
- `confidence: low` 的条目必须有 `confidence_reason`
- `security_sensitive: true` 时 §5 表格不得为空
