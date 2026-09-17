# reqloop 工作流 — 需求自验收闭环

以 AI 编排多 skill，完成"需求 → 代码 → 反讲 → 验收"的系统性闭环。
区别于普通 code review：**先对齐需求，再审代码；以代码为准，但回写需求**。

## 适用场景

- 功能完成后、提测前的开发自验收
- PR 合入前的需求一致性检查
- 多仓库协同变更的需求闭环确认
- 需求单、PRD、实际实现疑似漂移时的裁决

## 不适用

- 纯重构（无需求变更）——用 `cr` skill
- TDD 前置设计——用 `tdd-go` skill
- 纯格式化 / lint 修复

## 前置条件

### 适配器槽位

与外部系统打交道的动作全部抽成 5 个槽位，由适配器包提供实现（契约与查找 / 选择规则见 [adapters/README.md](adapters/README.md)）。
Thoth 内置 `lite` 适配器；企业内部工具链（需求管理、代码托管、CI、测试平台、缺陷系统）的适配器放在私有插件仓库，通过 `$THOTH_PROFILES/reqloop/adapters/<name>/` 加载。

| 槽位 | 职责 | 内置 lite 实现 | 企业实现 |
|------|------|---------------|---------|
| `requirements` | 拉取需求单 + 验收标准 + 评论 | PR body / commit message / 用户粘贴 | 由适配器提供 |
| `code` | 采集关联代码变更（可跨仓库） | `git diff base..HEAD` / `gh pr diff` | 由适配器提供 |
| `ci` | 指定环境 build / test / lint | 本地命令（Makefile / go.mod / package.json 推断） | 由适配器提供 |
| `e2e` | 端到端回归 | 跳过 / 人工 / 本地脚本 | 由适配器提供 |
| `defects` | 失败项建缺陷并回写 | `gh issue create` 清单或 Markdown 清单 | 由适配器提供 |

### 公共工具

| 工具 | 用途 | 来源 |
|------|------|------|
| `code-review-graph` | 调用关系全局视角（阶段 4a / 4b） | https://github.com/tirth8205/code-review-graph |
| `ajv-cli`（可选） | 反讲 / 决策链 JSON Schema 校验 | npm |

### 组件依赖

| 组件 | 类型 | 必需 |
|------|------|------|
| `thoth:code-reviewer` | Agent 子代理 | 第 4 阶段 |
| `thoth:security-auditor` | Agent 子代理 | 涉及安全时 |

## 核心设计取舍（务必遵守）

### 1. 第 3 阶段是硬门禁（HARD GATE）

反讲文档未经开发人工 confirm 前，**禁止进入**第 4 阶段的代码 review。
否则后续 review 会基于错误前提，结论不可信。

门禁实现：工作流在 `.reqloop/confirmed-{issue_id}.md` 生成签字文件后放行。
该文件需开发手动编辑 `confirmed: true` 字段，AI 不得自行修改。

### 2. 三源冲突裁决规则（显式写死）

当「需求单」「PRD 文档」「实际代码」三者不一致：

- **默认以代码为准**（真实发生的事实）
- 在反讲文档中标红列出 diff，**不做任何调和**
- 人工选择处置：`改代码` / `改需求` / `保持（并备注原因）`
- AI 不允许擅自认定某方"应该是对的"

**安全例外（硬性覆盖默认规则）**：
冲突条目命中安全关键词时，**不走"代码为准"**，改为以 PRD 为准并阻塞验收，自动调起 `security-auditor`。
关键词定义在 `templates/security-keywords.yaml`（团队可扩展），匹配规则与处置流程见 `stages/03-backspec.md`。
**兜底规则**：AI 判定 `dimension: security` 且 `confidence: high` 时，即使未命中关键词也触发安全例外。

### 2b. 判定三元组（verdict + confidence + evidence）

阶段 3、4a、4b、5、6 的每一条 AI 判定都必须输出三元组：
- `verdict`：明确的结论标签（covered/violates/...）
- `confidence`：`high | medium | low`
- `evidence`：≥1 条可定位的证据（file:line / 测试用例 / CI 输出）

`confidence: low` 的判定**不得单独阻塞**也**不得单独通过**，统一路由到"需人工裁决"段。
填补业界 SDD 工具的推理级 traceability 空白。

### 2c. 决策链产物 (decisions.jsonl)

每条判定 append 一行到 `.reqloop/decisions-{id}.jsonl`，包含 `inputs_hash` 以支持
"需求/代码变化后决策自动作废"的重放机制。详见 `stages/DECISIONS.md`。

### 3. 第 5 阶段不下"符合业务"的结论

编译 / 测试 / lint 可由 AI 判定通过或失败。
但"符合真实业务边界"**不由 AI 下结论**，只输出覆盖矩阵：

```
| 业务场景 | 代码路径 | 测试覆盖 | 数据覆盖 | 环境覆盖 |
|---------|---------|---------|---------|---------|
```

四列任一为 ❌ 即视为未闭环，需人工决策。

## 流程定义

```
┌──────────────────────────────────────────────────────┐
│  1. 需求采集 (gather)                                  │
│     requirements 适配器拉需求单                        │
│     → 附加 PRD（若存在）                                │
│     产物: .reqloop/req-{id}.md                        │
└────────────────────────┬─────────────────────────────┘
                         ▼
┌──────────────────────────────────────────────────────┐
│  2. 代码采集 (collect-code)                            │
│     code 适配器拉多仓库 MR / commit / diff              │
│     产物: .reqloop/code-{id}/ (按仓库归档)              │
└────────────────────────┬─────────────────────────────┘
                         ▼
┌──────────────────────────────────────────────────────┐
│  3. 反讲需求 (backspec)  ★ HARD GATE                   │
│     三源反推 → 生成反讲文档 → 人工 confirm             │
│     产物: .reqloop/backspec-{id}.md                    │
│     门禁: .reqloop/confirmed-{id}.md (confirmed:true) │
└────────────────────────┬─────────────────────────────┘
                         ▼ (未 confirm 则中止)
┌──────────────────────────────────────────────────────┐
│  4a. 代码审查 (review)                                  │
│     code-review-graph 全局视角 + 增量 diff             │
│     依赖调用关系约束范围，避免跑偏                       │
│     产物: .reqloop/review-{id}.md                      │
└────────────────────────┬─────────────────────────────┘
                         ▼
┌──────────────────────────────────────────────────────┐
│  4b. 负向影响分析 (impact-radius)                       │
│     反向调用链 + 隐式行为变更清单                        │
│     产物: .reqloop/impact-{id}.md                      │
└────────────────────────┬─────────────────────────────┘
                         ▼
┌──────────────────────────────────────────────────────┐
│  5. 运行时校验 (runtime)                               │
│     ci 适配器在指定环境 build / test / lint             │
│     输出业务边界覆盖矩阵（AI 不下"符合业务"结论）         │
│     产物: .reqloop/runtime-{id}.md                     │
└────────────────────────┬─────────────────────────────┘
                         ▼
┌──────────────────────────────────────────────────────┐
│  6. 端到端回归 (e2e)                                   │
│     e2e 适配器执行自动化回归                            │
│     产物: .reqloop/e2e-{id}.md (含报告链接)             │
└────────────────────────┬─────────────────────────────┘
                         ▼
┌──────────────────────────────────────────────────────┐
│  7. 验收报告 (report)                                  │
│     汇总 1-6 产物                                       │
│     失败项 → defects 适配器创建缺陷                     │
│     产物: .reqloop/acceptance-{id}.md                  │
└──────────────────────────────────────────────────────┘
```

## 产物目录约定

所有产物写入执行时的工作目录下 `.reqloop/`，按需求 ID 隔离：

```
.reqloop/
├── req-{id}.md             # 阶段 1 输出
├── code-{id}/              # 阶段 2 输出（按仓库归档 diff）
├── backspec-{id}.md        # 阶段 3 输出（反讲文档）
├── confirmed-{id}.md       # 阶段 3 门禁（人工签字）
├── review-{id}.md          # 阶段 4 输出
├── impact-{id}.md          # 阶段 4b 负向影响分析
├── runtime-{id}.md         # 阶段 5 输出（含覆盖矩阵）
├── e2e-{id}.md             # 阶段 6 输出
├── decisions-{id}.jsonl   # 决策链（append-only，跨阶段）
├── security-{id}.md       # 安全例外触发时的 auditor 报告
└── acceptance-{id}.md     # 阶段 7 最终报告
```

## 阶段详细指令

见 `stages/` 目录：

- [01-gather.md](stages/01-gather.md) — 需求采集
- [02-collect-code.md](stages/02-collect-code.md) — 代码采集
- [03-backspec.md](stages/03-backspec.md) — 反讲需求（硬门禁）
- [04-review.md](stages/04-review.md) — 代码审查
- [04b-impact-radius.md](stages/04b-impact-radius.md) — 负向影响分析
- [05-runtime.md](stages/05-runtime.md) — 运行时校验
- [06-e2e.md](stages/06-e2e.md) — 端到端回归
- [07-report.md](stages/07-report.md) — 验收报告
- [08-export.md](stages/08-export.md) — OSLC/ReqIF 生态导出（可选）
- [DECISIONS.md](stages/DECISIONS.md) — 决策链产物契约（跨阶段）

## 轻量模式

企业外 / 开源 / 单仓库场景用内置 `lite` 适配器（`--lite` 等价于 `--adapter lite`），见 [LITE.md](LITE.md) 与 [adapters/lite/](adapters/lite/)。
核心能力（反讲硬门禁、判定三元组、决策链、负向影响分析）不降级。

## 适配器

- 契约、目录结构、查找顺序与选择规则：[adapters/README.md](adapters/README.md)
- 内置实现：[adapters/lite/](adapters/lite/)
- 编写企业适配器：复制 `adapters/lite/` 到 `$THOTH_PROFILES/reqloop/adapters/<name>/`，改 `adapter.yaml` 的 `id_patterns` 让需求 ID 自动路由

## 模板与 Schema

- [backspec.md](templates/backspec.md) — 反讲文档模板
- [backspec-schema.json](templates/backspec-schema.json) — 反讲 §1 YAML 的 JSON Schema（阶段 3 门禁硬校验）
- [decisions-schema.json](templates/decisions-schema.json) — decisions.jsonl 单行 JSON Schema
- [acceptance-report.md](templates/acceptance-report.md) — 最终验收报告模板

## 增量重验 (`/reqloop revalidate`)

当需求单或代码在验收过程中发生变更（这是常态），全量重跑浪费且打断节奏。
`/reqloop revalidate <id>` 利用 `decisions.jsonl` 的 `inputs_hash` 实现增量重验：

1. **计算当前输入哈希**
   - 重新拉取需求单文本 → 计算 `req_text` hash
   - 重新拉取代码 diff → 计算 `code_diff` hash
   - 若有 PRD → 计算 `prd_section` hash

2. **比对 decisions.jsonl 中每行的 `inputs_hash`**
   - hash 匹配 → 决策仍有效，保留
   - hash 不匹配 → 决策已作废，标记为 `invalidated`

3. **确定需重跑的最小阶段集**
   - 若阶段 3 相关决策作废 → 从阶段 3 重跑（需重新 confirm）
   - 若仅阶段 4a/4b 决策作废 → 从阶段 4a 重跑（阶段 3 confirm 保留）
   - 若仅阶段 5/6 决策作废 → 从阶段 5 重跑

4. **执行增量流水线**
   - 仅重跑受影响阶段，保留未作废的产物
   - 作废的决策行不删除，新决策 append 后覆盖（由 `idempotency_key` 去重逻辑处理）
   - 阶段 7 report 始终重新生成

5. **交付**
   ```
   reqloop revalidate {id} — 增量重验完成
   - 作废决策: N 条（阶段 3: X, 阶段 4: Y, ...）
   - 重跑阶段: [列表]
   - 新结论: {通过 / 有条件通过 / 不通过}
   ```

## 多需求并行验收 (`/reqloop batch`)

版本迭代通常包含多个需求，`/reqloop batch <id1,id2,...>` 提供并行执行和聚合视图：

1. **并行执行**：对每个 id 独立执行完整流水线（产物隔离在各自 `.reqloop/` 子目录）
2. **冲突检测**：同一文件被多个需求修改时，在聚合报告中标注 `⚠️ cross-req-conflict`
3. **聚合报告**：生成 `.reqloop/batch-{version}.md`，包含：
   - 各需求结论汇总表
   - 跨需求冲突清单
   - 版本级通过/不通过判定（任一需求不通过 → 版本不通过）
   - 合并的决策链统计

也可用版本号触发：`/reqloop batch --release v1.2.0`（从 git tag 范围推断需求列表）。

## 度量与反馈 (`/reqloop stats`)

聚合历史 `decisions.jsonl`，输出 AI 判定质量度量：

```
/reqloop stats [--dir <path>] [--since <date>]
```

输出：
- **AI 判定准确率**：`1 - (human_override 次数 / 总判定数)` × 100%
- **各阶段 low-confidence 比例**：发现哪些阶段 AI 最不确定
- **最常被 override 的规则/阶段**：定位需要改进的提示词
- **平均每需求判定数 / 决策链长度**：衡量流程复杂度趋势

此数据用于持续改进 reqloop 的提示词、规则和阈值。

## 调用方式（示例）

```
用户: /reqloop PRJ-12345

AI: 适配器：<name>（$THOTH_PROFILES/reqloop/adapters/<name>，按 id_patterns 命中）
    阶段 1 / 7 — 需求采集
    [requirements 槽位拉取 PRJ-12345]
    → 已写入 .reqloop/req-PRJ-12345.md
    是否附加 PRD 文档？(y/N)
...
阶段 3 / 7 — 反讲需求
    [生成反讲文档]
    → 已写入 .reqloop/backspec-PRJ-12345.md
    ⛔ HARD GATE: 请人工 review 反讲文档，
       在 .reqloop/confirmed-PRJ-12345.md 中填写 confirmed: true 后继续。
```
