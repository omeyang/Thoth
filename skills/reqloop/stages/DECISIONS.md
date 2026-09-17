# 决策链产物 (decisions.jsonl)

## 目的

填补业界 SDD 工具（Spec Kit / Kiro / Tessl）的共同空白：**推理级 traceability**。
Spec Kit 能告诉你"哪条需求对应哪段代码"，但说不清"AI 为什么这样判定"。
反向验收天然同时持有"代码事实"和"需求意图"，有条件产出完整决策链。

## 位置

`.reqloop/decisions-{id}.jsonl` —— 每行一个 JSON 对象，append-only，不回填不改写。

## 字段契约

```json
{
  "ts": "2026-04-13T10:23:45Z",
  "stage": "backspec | review | impact-radius | runtime | e2e | report",
  "decision_id": "D-0001",
  "idempotency_key": "review-REQ-001-F-001",
  "req_id": "REQ-001",
  "finding_id": "F-001",
  "code_anchor": { "repo": "repo-a", "file": "pkg/foo/bar.go", "lines": "42-50", "commit": "abc1234" },
  "verdict": "covered | partial | missing | conflict | violates | compliant",
  "confidence": "high | medium | low",
  "reasoning": "一句话说明判定链路",
  "inputs_hash": {
    "req_text": "sha256:...",
    "code_diff": "sha256:...",
    "prd_section": "sha256:..."
  },
  "model": "claude-opus-4-6",
  "human_override": null
}
```

### 新增字段：`idempotency_key`

格式：`{stage}-{req_id}-{finding_id}`（finding_id 为 null 时用 `none`，如 `backspec-REQ-001-none`）。
用于断点续跑时判定去重，同一 `idempotency_key` 只允许存在一行（不含 human_override 行）。

## 写入规则

- 阶段 3、4a、4b、5、6 的**每一条**判定都必须追加一行
- `inputs_hash` 让未来可以重放：若需求文本/代码哈希变化，决策自动作废
- 人工在 confirm 或后续 review 阶段可以 override，写入 `human_override: { by, at, new_verdict, reason }`，**不覆盖原行，追加新行**

## 断点续跑去重

断点续跑（`/reqloop <id>` 或 `--from N`）时，写入新决策前**必须**执行去重检查：

1. 读取已有 `decisions-{id}.jsonl`
2. 提取所有非 `human_override` 行的 `idempotency_key` 集合
3. 对待写入行，若其 `idempotency_key` 已存在 → **跳过**，不重复写入
4. `decision_id` 从文件现有最大编号 +1 开始递增（而非固定从 `D-0001` 开始）

这保证同一判定不因中断重启而产生重复行，同时保持 append-only 语义。

## 消费场景

1. **阶段 7 最终报告**：统计每阶段 verdict/confidence 分布
2. **需求漂移审计**：跨迭代对比同一 REQ-ID 的决策历史
3. **AI 判定回溯**：出现争议时查 reasoning + inputs_hash，而非"AI 当时怎么想的"
4. **回写缺陷系统**：`defects` 适配器建缺陷时附决策链 `decision_id` + `inputs_hash`，形成签名链

## Schema 校验

每行写入前必须通过 `templates/decisions-schema.json`（JSON Schema Draft 2020-12）校验。
校验工具：优先用 `ajv-cli`（逐行校验），不可用时 AI 逐字段比对 schema 约束。
不通过 schema 的行视为无效决策，不得写入。

## 禁止事项

- AI 不得删除或改写已写入行（仅允许 append）
- 未填 `inputs_hash` 的行视为无效决策
- `confidence: low` 的决策不得单独支撑"通过"结论
