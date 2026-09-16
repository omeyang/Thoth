# 多 Agent 对抗审查流程（7 阶段）

本文档定义 `/cr teams` 模式的多 Agent 对抗审查流程。通过审查员独立发现问题、验证员对抗质疑的方式，减少误报、提高发现的可信度。

---

## 核心理念

- **独立审查** — 审查员尽可能多地发现问题，不自我过滤
- **对抗质疑** — 验证员对每个发现进行 4 问质疑，过滤误报
- **置信度标注** — 最终报告中每个发现都有明确的可信度

---

## 依赖组件

| 组件 | 路径 | 用途 |
|------|------|------|
| code-reviewer Agent | `agents/code-reviewer/AGENT.md` | 代码审查（6 维度） |
| security-auditor Agent | `agents/security-auditor/AGENT.md` | 安全审计（6 维度） |
| code-checklist.md | `references/code-checklist.md` | A/B/C 检查清单 |
| judgment-matrix.md | `references/judgment-matrix.md` | 风险等级裁决 |
| checklist-evolution.md | `references/checklist-evolution.md` | 演化记录 |

---

## 7 阶段协调流程

### 阶段 1：准备

1. **确定范围** — 同 `local-review.md` 第 1 步（解析参数、获取 diff/文件）
2. **语言检测** — 扫描文件扩展名确定语言
3. **运行静态工具** — 按 `local-review.md` 工具矩阵执行，收集基线输出
4. **准备上下文包** — 汇总以下信息供后续阶段使用：
   - 变更的完整 diff 或文件内容
   - 工具扫描输出
   - 项目语言和框架信息

### 阶段 2：审查员审查

使用 Task 工具调用 code-reviewer Agent：

```
Task(
  subagent_type = "general-purpose",
  prompt = """
  读取 agents/code-reviewer/AGENT.md 获取你的审查指南。

  ## 特殊指令

  你是对抗审查流程中的"审查员"角色。你的任务是**尽可能多地发现候选问题**：
  - 不要自我过滤，宁可多报也不要漏报
  - 对每个发现标注你的初步判断（确定/可能/不确定）
  - 包含工具扫描的所有发现

  ## 审查范围

  <变更内容>

  ## 工具扫描基线

  <阶段 1 的工具输出>

  ## 输出

  按 code-reviewer 的输出格式，列出所有候选发现。每个发现额外标注：
  - **初步判断:** 确定 / 可能 / 不确定
  - **依据:** 为什么认为这是问题
  """
)
```

### 阶段 3：安全审计

与阶段 2 **并行**，使用 Task 工具调用 security-auditor Agent：

```
Task(
  subagent_type = "general-purpose",
  prompt = """
  读取 agents/security-auditor/AGENT.md 获取你的审计指南。

  ## 特殊指令

  你是对抗审查流程中的"安全审计员"角色。你的任务是从安全视角**尽可能多地发现候选漏洞和安全问题**：
  - 不要自我过滤
  - 对每个发现标注置信度
  - 关注 OWASP Top 10 和语言特定的安全问题

  ## 审计范围

  <变更内容>

  ## 输出

  按 security-auditor 的输出格式，列出所有候选安全发现。
  """
)
```

**并行执行:** 阶段 2 和阶段 3 必须在同一消息中并行发起两个 Task 调用。

### 阶段 4：验证员质疑

合并阶段 2 和阶段 3 的所有候选发现，对**每个发现**执行 4 问质疑：

| 问题 | 说明 | 通过条件 |
|------|------|---------|
| **Q1: 是否真实？** | 该问题是否确实存在于代码中？ | 能在代码中指出具体位置和触发条件 |
| **Q2: 有无具体路径？** | 是否有具体的触发/利用路径？ | 能描述从输入到问题触发的完整路径 |
| **Q3: 上下文是否已缓解？** | 现有代码是否已有防护措施？ | 无已存在的防护、校验或限制 |
| **Q4: 是否语言惯例？** | 是否是该语言的正常/推荐写法？ | 不是语言标准模式或社区惯例 |

**质疑执行方式:**

对每个候选发现：
1. 读取发现涉及的源代码文件（不仅仅是 diff，包含完整上下文）
2. 逐个回答 4 个问题
3. 记录每个问题的回答（通过/未通过 + 理由）

### 阶段 5：置信度标注

根据阶段 4 的质疑结果，对每个发现标注置信度：

| 通过问题数 | 置信度 | 说明 |
|-----------|--------|------|
| 4/4 | **Confirmed** | 确认问题，高可信度 |
| 3/4 | **Likely** | 很可能是问题，建议修复 |
| 1-2/4 | **Suspect** | 存疑，需人工判断 |
| 0/4 | **Rejected** | 误报，将被过滤 |

### 阶段 6：合并裁决

1. **过滤** — 移除所有 Rejected 项
2. **去重** — 审查员和安全审计员发现同一问题时，合并为一条：
   - 保留更详细的描述
   - 保留更高的置信度
   - 保留更高的风险等级
3. **风险标注** — 对每个发现参照 `references/judgment-matrix.md` 标注 Critical/High/Medium/Low
4. **排序** — 按 Critical → High → Medium → Low，同级内按 Confirmed → Likely → Suspect

### 阶段 7：报告 + 演化

#### 输出报告

```markdown
## 审查摘要

**审查模式:** teams（多 Agent 对抗审查）
**变更概述:** [一句话描述]
**检测语言:** [Go, Python, Shell]
**参与 Agent:** code-reviewer, security-auditor
**总体评价:** [通过 / 需要修改 / 需要重写]
**发现数:** Critical: N, High: N, Medium: N, Low: N
**置信度分布:** Confirmed: N, Likely: N, Suspect: N, Rejected: N

## Confirmed 发现

### [Critical] 标题
- **文件:** path/to/file:42
- **语言:** Go
- **来源:** code-reviewer / security-auditor / 两者
- **置信度:** Confirmed (4/4)
- **问题:** 具体描述
- **质疑记录:** Q1 ✓ Q2 ✓ Q3 ✓ Q4 ✓
- **建议:** 修复方案

## Likely 发现
(同上格式)

## Suspect 发现
(同上格式，标注需人工确认)

## 被拒绝的发现（参考）

简要列出 Rejected 项及拒绝理由，供复查：
- [发现标题] — 拒绝原因：[Q1-Q4 未通过的具体原因]

## 亮点
- [代码中做得好的地方]

## 建议
- [可选改进建议]
```

#### 演化记录

将 Rejected 项记录到 `references/checklist-evolution.md` 的误报记录表中：
- 如果 Rejected 项来自检查清单条目 → 考虑收窄该条目的适用条件
- 如果 Confirmed 项不在检查清单中 → 考虑新增条目

---

## 降级策略

如果 Task 调用失败（Agent 不可用、超时等），自动降级为 local-review 模式：
1. 告知用户降级原因
2. 按 `local-review.md` 的 5 步流程继续
3. 在报告中标注"[降级] 原计划 teams 模式，因 <原因> 降级为 local 模式"
