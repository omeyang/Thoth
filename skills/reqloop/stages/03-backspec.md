# 阶段 3 — 反讲需求 (backspec)  ★ HARD GATE

## 目标

根据阶段 1（需求声明）+ 阶段 2（代码事实）**反向推导**真正发生的需求，
生成"反讲文档"供开发人工 confirm。这是全流程最关键的一步。

## 核心原则

### 原则 1：代码为准（含安全例外）

当三源（需求单 / PRD / 代码）不一致时，**默认以代码为准**。
原因：需求单和 PRD 可能过期，代码是真实发生的事实。

**安全例外（硬性覆盖默认规则）**：
若需求单 / PRD 的冲突条目命中安全关键词，**不走"代码为准"**，改为以 PRD 为准并阻塞验收，同时调起 `security-auditor` Agent 生成 `.reqloop/security-{id}.md`。

关键词来源：`templates/security-keywords.yaml`（团队可按需扩展，无需修改本文件）。
匹配方式：大小写不敏感，子串匹配。

**兜底规则**：即使未命中关键词列表，当 AI 判定 `dimension: security` 且 `confidence: high` 时，也触发安全例外流程。

命中时：
1. 反讲文档 frontmatter `security_sensitive: true`
2. 在反讲文档 §5 填写裁决记录表（见模板）
3. 该条 requirement 的 `status` 固定为 `conflict`，`confidence` 固定为 `high`
4. 人工即使 confirm 该条，阶段 7 仍须判定"不通过"直到代码修复

### 原则 2：AI 不做调和

发现 diff 时：
- ✅ 允许：在反讲文档中**标红列出**三方差异
- ❌ 禁止：AI 擅自判断"应该是哪个对"
- ❌ 禁止：AI 自行改写需求表述以掩盖不一致
- 裁决权交给开发人工

### 原则 3：硬门禁

未获得 `.reqloop/confirmed-{id}.md` 人工签字**禁止**进入阶段 4。

## 步骤

1. **从代码反推行为**
   - 遍历 `.reqloop/code-{id}/` 所有 diff
   - 对每个 MR 产出"这段代码实际做了什么"的白话描述
   - 粒度：一个逻辑变更块一条（不是一行一条）

2. **对齐需求条目**
   - 将代码行为逐条映射到需求单 / PRD 的验收标准
   - 建立「需求条目 ↔ 代码行为」的映射表（见模板）

3. **标记三类差异**

   | 类型 | 含义 | 处置建议（仅建议，不裁决）|
   |------|------|------|
   | 🔴 缺失 | 需求要求了但代码没实现 | 补代码 / 确认延后 |
   | 🟡 额外 | 代码实现了但需求没提 | 补需求 / 删代码 |
   | 🟠 偏差 | 双方都有但行为不一致 | 对齐任一方 |

4. **填充反讲文档**
   - 使用 `templates/backspec.md` 模板
   - 写入 `.reqloop/backspec-{id}.md`

5. **生成人工签字文件**
   - 创建 `.reqloop/confirmed-{id}.md`，初始内容：
     ```markdown
     ---
     id: {id}
     confirmed: false
     confirmed_by:
     confirmed_at:
     ---

     # 人工 confirm 指引

     请 review `.reqloop/backspec-{id}.md`，然后：
     1. 对每条 🔴🟡🟠 差异，在反讲文档中填写处置决定
     2. 将上方 frontmatter 的 confirmed 改为 true
     3. 填写 confirmed_by 和 confirmed_at
     4. 重新运行 /reqloop {id} 或让 AI 继续
     ```

6. **中止并等待**
   - 明确告知用户：**已中止，等待人工 confirm**
   - 不继续阶段 4

## 恢复进入阶段 4a 的判定（机器校验）

AI 再次被调起时执行以下校验，**任一不满足立即中止**：

1. `.reqloop/confirmed-{id}.md` 中 `confirmed: true` 且 `confirmed_by` 非空
2. 反讲文档 §1 结构化 YAML 通过 `templates/backspec-schema.json` 校验（JSON Schema Draft 2020-12）：
   - 每条 `requirements[].status` ∈ {covered, partial, missing, conflict, extra}
   - `status: covered` 必须有 ≥1 `code_anchors`
   - `confidence: low` 必须有 `confidence_reason`
   - `source.hash` 必须匹配 `^sha256:[a-f0-9]{8,64}$`
3. 所有阶段 2 采集到的 diff hunks 至少被一条 requirement 的 `code_anchors` 引用
   （未引用 hunks 必须以 `status: extra` 列入 §3 🟡，由人工处置）
4. 反讲文档 §3 所有 🔴🟡🟠 差异均有处置决定
5. 若 `security_sensitive: true`，§5 裁决表非空，且 security-auditor 报告存在

校验失败 → 输出具体违规条目（含 schema 路径和实际值），不放行。

**校验工具**：优先用 `ajv-cli`（`ajv validate -s templates/backspec-schema.json -d backspec-{id}.yaml`），
不可用时 AI 逐条检查 schema 约束并列出通过/失败条目。

## 失败处理

- 代码与需求单完全无法映射 → 警告后仍生成反讲文档，让人工判断是否走错了需求
- 无阶段 2 产物 → 中止，要求先完成阶段 2
