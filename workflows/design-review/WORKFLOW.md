# design-review 工作流（设计文档对抗审查）

> 状态：已实施（M1–M4 落地，含 bats 单元 / 集成 / golden / chaos 测试与每晚 cron 批处理）；本文档同时作为 spec 维护。
> 定位：与 `workflows/adversarial-review/` 同级、独立演进的 workflow。adversarial-review 审 git diff / 代码包；本工作流审 markdown 设计文档。
> 一句话：用 Claude×2 + Codex×2 共 4 个全建制"球队（team）" agent 对 markdown 设计文档做多轮交叉对抗审查，按既定原则过滤发现，min-N + 收敛判定 + max 上限自适应停轮，最终由汇总者（consolidator）产出补充文档 + diff 草案 + 人读报告，**由人合议后手动 git apply + commit**。

---

## 0. 与既有 workflow 的关系

| workflow | 用途 | 与本工作流关系 |
|---|---|---|
| `adversarial-review/` | git diff / 代码包审查 | 同级、独立；骨架可借鉴，prompt 全新 |
| `code-review/` | 单模型代码审查 | 不相关 |
| `reqloop/` `reqloop-lite/` | 需求迭代 | 上游可衔接：reqloop 产出需求 → 本工作流审设计 |
| `tdd/` | TDD 流程 | 下游可衔接：本工作流收敛 → tdd 写测试 + 实现 |
| `deploy/` | 部署流程 | 不相关 |

允许部分代码冗余（沉淀经验值得），效果优先于代码节俭。

---

## 1. 前置条件

| 工具 | 用途 | 检查命令 |
|---|---|---|
| `claude` CLI | Claude Code | `claude --version` |
| `codex` CLI | OpenAI Codex | `codex --version` |
| `yq` v4 | YAML 解析 | `yq --version` |
| `git` ≥ 2.30 | repo 检测 | `git version` |
| `flock` | 日志并发锁 | `which flock` |
| `envsubst` | 模板变量替换 | `which envsubst` |
| `timeout` | LLM 调用硬超时 | `which timeout` |
| `bats-core` | 测试 | `bats --version` |
| `shellcheck` | 静态扫描 | `shellcheck --version` |
| `jq` | JSON 处理 | `jq --version` |

环境变量：

```bash
export THOTH_HOME=/path/to/Thoth
export PATH=$THOTH_HOME/workflows/design-review/scripts:$PATH
# 可选：项目 profile（插件）根目录；不设则回退 ~/.config/thoth/profiles，再回退内置 profiles/（见 §3.8）
export THOTH_PROFILES=/path/to/private-profiles
```

---

## 2. 适用场景

- 重构期设计文档（如 `design/01-*.md` `design/02-*.md`）的交叉对抗审查
- ADR 评审前的多视角挑刺
- 跨仓库设计（如同时改业务服务 + 共享工具库 + 契约仓库）的一致性审查

不适用：
- 代码审查（用 `adversarial-review/`）
- 单文件文档拼写 / 格式检查（用 `make lint`）
- 需求收集 / 用户故事评审（用 `reqloop/`）

---

## 3. 工作原则（设计文档审查必须遵守）

工具的所有 agent 在产出发现前必须遵守下列原则。通用原则落 `templates/principles.md`；项目特有的内容（基线系统是谁、词表在哪、哪些旧文档不可信、控制权边界）写在项目 profile 的 `principles.md`，工具把它作为「项目原则」追加注入每个 prompt，优先级高于通用原则（但不得删除硬约束段任一条）。profile 机制见 §3.8。

### 3.1 硬约束

| # | 原则 |
|---|---|
| 1.1 | 判断基准优先级：真实业务场景 → 目标架构（背景文档已锁定的闭环 / 状态权威 / 契约）→ 基线系统已验证逻辑（refs 中 `基线-*` 层）→ 当前重构代码（仅作问题证据，不作正确性依据）|
| 1.2 | 不臆想：拿不准的事实（接口字段、消息 schema、数据形态）必须到 refs 中对应权威层核实；不得用代码对称性 / 命名相似推测 |
| 1.3 | 疑似 bug 默认线上正确：怀疑基线系统行为有 bug 必须走 suspected-bug 流程单独核实，不允许在重构设计中顺手"修掉" |
| 1.4 | 临时文件可以在 `/tmp/` 下创建；最终成果文档落在 `<supplement_dir>/201-{topic}-supplement.md`，产出 = 建议 + diff 草案，最终回流由人合议 |
| 1.5 | 不要为了设计而设计，提任何"应改"前先问 4 问：① 这个业务场景真实存在吗？② 能否用流程或前置避免？③ 老架构有没有？怎么处理的？能不能仿照？④ 是否自己臆想 / 脱离实际？|
| 1.6 | 高内聚、低耦合、单一职责、降低冗余；但**不要有设计洁癖、不要过度设计** |
| 1.7 | 考虑控制权是否在我们手中 —— 不要假设我们什么都能做（平台 API、客户环境、上游契约往往都不在我们手里）|

### 3.2 方法

| # | 原则 |
|---|---|
| 2.1 | 自顶向下：发现必须能放回闭环与状态权威 |
| 2.2 | 按状态语义切边界：不跨越单写者矩阵 / 边界 / 禁令 |
| 2.3 | 高内聚低耦合单一职责，降低冗余；不要洁癖、不要过度设计 |
| 2.4 | 不主动制造瓶颈：动手前考虑 性能 / 稳定性 / 健壮 / 可扩展 四维 |
| 2.5 | 策略与数值分离：数字必须标 "策略冻结值 / 参考起点 / 实测客观事实"；尽量不硬编码、不在设计阶段冻结具体值 |
| 2.6 | 改动前调研义务："应改文档"前必须指认：(a) 老代码行为 (b) 真实业务场景 (c) 非"抽象自洽" (d) 非"设计洁癖" (e) 非"臆想猜测" |
| 2.7 | 可参考开源社区、大厂、优秀设计案例、最佳实践；但**必须结合真实业务场景**产出适合的设计，禁止照搬 |

### 3.3 节奏

| # | 原则 |
|---|---|
| 3.1 | 不发明新名词 —— 中文 / 英文双写词必须在项目词表内（词表位置由项目原则或背景文档指明）|
| 3.2 | 设计期不做旧文档清理 —— 不建议"删旧 docs"；被审仓库里的旧设计文档不一定正确，项目原则会指明哪些不可作依据 |
| 3.3 | 不列 ADR 弃选陪衬 —— 对比表不强求"备选方案"行，结论 + 实证即可 |
| 3.4 | 不留 fallback 退路 —— 重构目标是替换而非并存，除非项目原则明确允许过渡期双跑 |

### 3.4 风格

| # | 原则 |
|---|---|
| 4.1 | 中文沟通 + 不创造新名词；必须英文时全程 "英文（中文）" 括注 |
| 4.2 | 指出问题必须具体到 (a) 是什么问题 (b) 在什么场景下出现 (c) 是否真实 (d) 老架构有没有、如何处理（如有）；禁止泛泛指责 |

### 3.5 参考仓库清单（由 refs.manifest 生成）

参考仓库清单不写死在工具里。项目在 `.design-review.yaml` 的 `refs.manifest` 段按权威分层列出仓库路径，
工具每次 run 开始时把它生成为 `<temp_dir>/<run-id>/refs-manifest.yaml`，注入每个 agent / 跨队对抗 prompt 的「参考仓库清单」段，
并把存在的目录经 `DR_ADD_DIRS` 透传给 `claude --add-dir`。

| tier | 含义 |
|---|---|
| `基线-功能权威` | 老系统源码，行为正确性的最终裁判 |
| `基线-契约权威-只读` / `基线-契约权威-可改需人审` | 跨服务契约（基础库 / proto / API 定义）|
| `契约权威-可改需人审` | 新架构的契约收口仓库 |
| `基础要求` | 工程规范手册（如 Maat）|
| `数据形态权威` | 真实数据导出，schema 真值 |
| `待审稿` | 设计文档本体，工具的输入 |
| `下级旁证-不作依据` | 旧文档，只能佐证不能作依据 |
| `仅作问题证据-不作正确性` | 当前重构代码，只用来举问题 |

占位示例见 `templates/refs-manifest.example.yaml`；真实清单属于项目私有信息，放在项目仓库的 yaml 或私有 profile 里。

### 3.6 审查范围（scope）

设计往往分阶段推进：同一仓库里，一部分区域已详细设计、另一部分仍「待补」。对**未设计区域**报承接缺口属过早噪声（对应设计还没写，提了也无法处理）。因此审查范围是**可指定的一等参数**，随阶段切换。

- 配置 `.design-review.yaml` 的 `scope` 段（见 §8）声明：
  - `focus`：本次聚焦的区域（如「调度模块」；以后切「计算模块」/「路由模块」只改这里）
  - `out_of_scope`：未设计 / 待补区域清单 —— agent **不得**把它们的承接缺口当本设计必修
- CLI `--scope FOCUS` 可临时覆盖 `focus`（见 §7）。
- `scope.focus` 非空时，工具把「本次审查范围」段注入**每个 agent prompt + 跨队对抗 prompt**，约束 agent 只审焦点区域自身的闭环 / 状态权威 / 与基线系统行为的承接。
- 配合 `target.exclude` 把跨区域的总览文档（如只审调度模块时排除跨全系统的 `00-overview.md`）剔除，双重保证不跑偏。

### 3.7 背景文档（background）与文档关系

设计文档常分层：顶层总览（系统闭环 / 状态权威 / 跨模块契约 / 设计准则 / 词表）+ 父级详设 + 多个子模块。**子模块通常故意不重复父级已锁定的内容**（如各 `01-x` 子模块明写「00 与 01 已锁定…本文件不重新定义」）。孤立审单篇子模块会把父级已承接的东西**误报为缺失**。

因此把顶层 / 父级文档作为**背景上下文**注入（区别于 §3.5 的外部参考仓库 refs，背景是被审仓库内部的权威上下文）：

- 配置 `.design-review.yaml` 的 `background` 段（见 §8）：
  - `docs[].path` + `docs[].role`：背景文档及其在系统中的角色
  - `relations`：**文档之间的关系说明**（谁是顶层 / 谁是父级 / 子模块如何细化 / 谁锁定了什么）
- `background.docs` 非空时，工具把「背景文档 + 文档关系」段注入每个 agent / 跨队对抗 prompt（自动跳过与当前待审文档相同的背景项）。
- prompt 指示 agent：**判断「缺失 / 越界」前先确认该点是否已在背景文档锁定 / 承接**；并按待审文档里的「父锚点」**按需**读相关章节（而非全文，控制 token）。

### 3.8 项目 profile（插件）

引擎、通用模板、通用原则在本仓库；**项目私有信息**（基线仓库、项目原则、角色模板里的项目细节、每晚 cron 审哪个仓库）放在仓库之外的 profile 目录，按需加载，本仓库因此可以公开。

布局（`<profile-root>/design-review/<name>/`）：

| 文件 | 作用 |
|---|---|
| `profile.env` | `cron-batch.sh` 旋钮：`REPO` / `REDESIGN_SUBDIR` / `PARENT_DOC` / `MAX_ROUNDS` / `WINDOW_END_HOUR` |
| `principles.md` | 项目原则；作为「项目原则」段追加注入每个 prompt，优先级高于通用 `templates/principles.md` |
| `agent-*.md` | 与 `templates/` 同名即覆盖该角色模板（如项目版的基线考古员）|
| `design-review.yaml.example` | （可选）该项目 `.design-review.yaml` 范本 |

选择与查找：

- 来源优先级：CLI `--profile` > 环境变量 `DR_PROFILE` > yaml 顶层 `profile:`；都没有 = 不用 profile。
- 名字按顺序找第一个存在的目录：`$THOTH_PROFILES/design-review/<name>` → `${XDG_CONFIG_HOME:-~/.config}/thoth/profiles/design-review/<name>` → `$THOTH_HOME/workflows/design-review/profiles/<name>`（内置，仅 `example`）。
- 含 `/` 或以 `~`、`$` 开头视为路径，支持 `$THOTH_PROFILES` / `$THOTH_HOME` / `~` 前缀展开。
- 命名了 profile 但找不到 → exit 2（配置错误），不静默退回内置。

角色模板解析优先级：yaml `roles.Rn.template`（相对路径先按 profile 目录、再按 design-review 目录）> profile 同名文件 > `templates/` 默认。profile 目录会一并加入 `DR_ADD_DIRS`。

私有 profile 建议单独放一个私有仓库，把仓库根设为 `$THOTH_PROFILES` 或软链到 `~/.config/thoth/profiles`。内置骨架见 `profiles/example/`。

---

## 4. 球队（team）模型

### 4.1 顶层结构

```
              ┌────────────────────────────────────────────┐
              │  原始文档 + principles + refs-manifest      │
              └──────────────┬─────────────────────────────┘
                             ▼
   ┌─────────────┬───────────────┬─────────────┬─────────────┐
   │ 球队 T1      │ 球队 T2        │ 球队 T3      │ 球队 T4      │
   │ (Claude)    │ (Codex)       │ (Claude)    │ (Codex)     │
   │ 立场=pro    │ 立场=con      │ 立场=neut   │ 立场=con    │
   └──────┬──────┴───────┬───────┴──────┬──────┴──────┬──────┘
          │ 4 支队并行   │              │             │
          │ 每队内部跑   │              │             │
          │ 完整 5+ 角色 │              │             │
          ▼              ▼              ▼             ▼
     teamreport-T1   teamreport-T2  teamreport-T3  teamreport-T4
          │              │              │             │
          └──────┬───────┴──────┬───────┴─────────────┘
                 ▼              ▼
            跨队对抗 (B) → 合议 (C) → 收敛判定 (D)
```

每支球队 = 一份完整、自洽、全面的审查意见。它的内部要求与汇总最终产物等价（区别仅在视角差异，由立场 + 模型多样性产生）。

### 4.2 单支球队 T_k 内部结构（11 人足球队类比）

```
球队 T_k（一个 top-level agent，可以用 Claude 也可以用 Codex）
   │
   ├─ 进场：top-level agent 读 原始文档 + principles + refs-manifest + 本队立场
   │
   ├─ 队内 self-review（top-level agent 在内部 dispatch 5+ sub-agent 并行）
   │   每个 sub-agent 是该角色的"全表扫描器"，不是只看一面
   │
   │   ├─ R1 · 基线考古员  ── 跑遍 refs 中 `基线-*` 层仓库验老码真实行为（项目 profile 可换成项目版）
   │   ├─ R2 · 业务场景挫锐手 ── 列举 ≥5 个生产场景（多租户 SaaS + 私有化 + 极端故障）验消化能力
   │   ├─ R3 · 闭环推理裁判 ── 守 §3.2 准则 + 单写者矩阵 + 词表 / 中英括注 / 数字标注
   │   ├─ R4 · 实施风险评估师 ── 拼成 Go 代码能不能跑 / 哪里 panic / cycle / 基础库真有这能力吗
   │   ├─ R5 · 控制权审视员 ── 每条发现"控制权在我们这吗"（平台 API / 监控栈 / 上游契约）
   │   └─ ... 项目可在 yaml 中加 R6/R7（如安全审查员、性能审视员）
   │
   ├─ 队内合议（top-level agent 自己整合 5+ 角色输出）
   │   每条发现按硬性 self-check 模板填表
   │   任何字段填 "TBD / 大概 / 可能" → 队内驳回，不出队
   │
   └─ 输出 teamreport-R{N}-T{k}.yaml
        - 本队作为整体的审查意见（一份完整自洽报告）
        - 含：必修 N 条 / 存疑 M 条 / 已论证不必动 K 条
        - 每条带 5 角色谁主张 + 谁驳回 + 队内合议结论
```

### 4.3 为什么是 4 支队

| 配置 | 缺陷 |
|---|---|
| 1 支 | 无对抗，仅"一家完整之言" |
| 2 支 | 2-2 撕扯无法仲裁 |
| **4 支** | 多数仲裁可解（3:1 / 4:0）；Claude×2 + Codex×2 平衡偏置；可承受 1 支缺席 |
| 6+ | 边际收益递减 + token 成本陡涨 |

### 4.4 工具 + 立场分配

| 球队 | 工具 | 立场（每轮独立抽，不固定）|
|---|---|---|
| T1 | Claude | pro（赞成）/ con（反对）/ neutral（中立）随机 |
| T2 | Codex | 同上 |
| T3 | Claude | 同上 |
| T4 | Codex | 同上 |

保证条件：同一轮内 4 队立场不能全部一致；若随机后撞了，强制扰动 1 个，保证每轮至少 1 个 con 队"恶意"挑刺。

立场注入到队内全部角色（5 sub-agent 都按本队立场跑），不在队内角色之间分立场——避免队内自撕，对抗强度交给跨队阶段。

### 4.5 主编排器 + 第 5 个独立 agent（consolidator）

除了 T1-T4 之外，还有两个 Claude 进程承担"流程控制"职责，**不参与球队对抗**：

| 角色 | 工具 | 职责 | 出现阶段 |
|---|---|---|---|
| 主编排器（orchestrator）| Claude | 调度 5 阶段串接、立场随机抽（守 §4.4 保证条件）、子 agent 派发、token 预算监督、收敛判定结果落盘 | 全程 |
| 汇总者（consolidator）| Claude | 收敛 / 强停后跑一次，按 §5.4 产出 3 份最终产物 | Final 阶段 |

两者推荐用 Claude（写中文 patch + 守词表 / 中英括注更顺手）。Orchestrator template = `templates/orchestrator.md`；Consolidator template = `templates/consolidator.md`。

跨队对抗（阶段 B）与合议（阶段 C）的 sub-agent 也由主编排器 dispatch，模板 = `templates/cross-attack.md` / `templates/consensus.md`。

### 4.6 子 agent 孵化预算（默认值，yaml 可改，未实测前不冻结）

| 项 | 默认 | 标注 |
|---|---|---|
| 每队内部 sub-agent 数 | 5（R1-R5）| 策略冻结值 |
| 单 sub-agent 最多 token | 30000 | 参考起点 |
| 单队单轮 token 预算 | 200000 | 参考起点 |
| 4 队单轮全局 token 预算 | 800000 | 参考起点 |
| 多轮全局 token 上限 | 4000000 | 参考起点 |

token 预算降级顺序：超额时按 R5 → R4 → R3 跳角色。

### 4.7 发现自检模板（所有 agent 共享，缺字段即降级 / 舍弃）

```yaml
finding:
  id: <短 id>
  severity: P0 | P1 | P2 | P3
  source_agent: T1 | T2 | T3 | T4
  source_role: R1 | R2 | R3 | R4 | R5
  confidence: High | Medium | Speculative

  # 来自原则 1.5（不为设计而设计 4 问）
  q1_real_scenario: "<是 / 否；如是，具体到 file:line 或真实租户行为>"
  q2_avoidable_by_process: "<是 / 否；如是，提议什么前置流程>"
  q3_old_arch_handling: "<基线老码 file:line + 处理方式 / 或'无对应'>"
  q4_not_hallucinated: "<排除臆想的证据>"

  # 来自原则 1.7（控制权）
  control_in_our_hands: "<是 / 否；如否，说明谁的控制权>"

  # 来自原则 4.2（场景化）
  concrete_scenario: "<在哪个业务路径 / 哪类租户 / 哪种故障下出现>"

  # 来自原则 2.5（数字分类）
  numbers_tagged:
    - {value: "30s", tag: "参考起点 / 策略冻结值 / 实测客观事实"}

  # 来自原则 2.6（改动论据）
  evidence:
    - "<基线仓库 file:line>"
    - "<契约仓库 file:line>"
    - "<数据导出形态证据>"

  proposed_action: "<只描述建议；patch 草案由汇总者产>"
```

---

## 5. 多轮对抗数据流

### 5.1 单轮内部 5 阶段

```
[轮 N 开始]
   │
   ├─ 阶段 A：4 支球队并行（每队内 5+ sub-agent 跑队内 self-review）
   │    输入：原始文档 + principles.md + refs-manifest + 本队立场
   │           + （R≥2 时）上一轮 all teamreports + cross-attack + consensus
   │    输出：teamreport-R{N}-T{1..4}.yaml （每队一份，已通过队内合议）
   │
   ├─ 阶段 B：跨队对抗（cross-attack sub-agent 主持，机器化做 4-vote 矩阵）
   │    输入：4 份 teamreport
   │    动作：把每条发现去重 / 归并到 cross-finding-id 后，
   │          请每队对每条非本队发现表态（赞同 / 反驳 / 已涵盖 / 应舍弃）
   │    输出：cross-attack-R{N}.yaml （含 4×N 投票矩阵）
   │
   ├─ 阶段 C：合议（consensus sub-agent）
   │    输入：cross-attack-R{N}.yaml
   │    动作：按 4-vote 规则分类
   │          - 4-0 / 3-1 → 必修
   │          - 2-2 → 存疑
   │          - 1-3 / 0-4 → 舍弃
   │    输出：consensus-R{N}.yaml
   │
   ├─ 阶段 D：收敛判定（脚本层做，不调 LLM）
   │    计算 Δ vs R{N-1}
   │    判定 CONVERGED / NOT_CONVERGED
   │
   └─ 阶段 E：下一轮 OR Final
```

### 5.2 收敛判定精确度量

| Δ 指标 | 含义 |
|---|---|
| `Δfindings_new` | 本轮 consensus 出现、上轮没有的 cross-finding-id 数 |
| `Δfindings_refuted` | 上轮"必修"或"存疑"，本轮变"舍弃"的数量 |
| `Δclassification_changed` | 分类变化（必修↔存疑↔舍弃）总数 |
| `Δvote_changed` | 同 cross-finding-id 上 4-vote 矩阵中票数变化总和 |

判定规则：

| 条件 | 动作 |
|---|---|
| `round < min_rounds`（默认 2）| 强制继续，不算收敛 |
| `round ≥ max_rounds`（默认 5）| 强制停，进 Final，标 `force_stopped=true` |
| 4 个 Δ 全 0 且 `round ≥ min_rounds` | CONVERGED，进 Final |
| `Δvote_changed > 0` 但 `Δclassification_changed == 0` 持续 3 轮 | "票数抖但分类稳"，进 Final，标 `stable_but_voting=true` |
| `Δclassification_changed > 0` 持续 3 轮 | "分类撕扯无解"，把撕扯项打存疑入产物，进 Final，标 `unresolved_dispute=true` |
| 其他 | NOT_CONVERGED，下一轮 |

### 5.3 跨轮球队记忆传递

R{N+1} 球队进场时读到的"历史包"：

```
必读：
  - 原始文档（与 R1 同）
  - principles.md（不变）
  - refs-manifest（不变）
  - 本队立场（重新抽，可能翻转）

  + 上一轮材料：
    - all teamreports-R{N}-T{1..4}.yaml   ← 看到所有兄弟队完整意见
    - cross-attack-R{N}.yaml              ← 看到自己被怎么投了 / 怎么投别人
    - consensus-R{N}.yaml                 ← 看到本队哪些发现被采纳 / 哪些被驳

球队任务（R{N+1}）：
  ① 对自己上轮的发现重新评估：被驳的能否补证据救？被驳服了主动撤
  ② 对兄弟队上轮的发现重新评估：之前赞同的现在还赞同吗？
  ③ 找上轮 4 队全部漏掉的新发现
```

### 5.4 Final 阶段产物（收敛或强停后跑 1 次）

由 §4.5 中的汇总者（consolidator，第 5 个独立 Claude agent，**不在 T1-T4 内**）执行：

| 产物 | 路径 | 内容 |
|---|---|---|
| 补充文档 | `<supplement_dir>/201-{topic}-supplement.md`（原则 1.4 落点）| 必修项分组（按 P0-P3）+ 每条带合议结论 + 4 问表 + 控制权 + 场景 + 老码 file:line + 对抗履历摘要；中文为主，英文必括注 |
| patch 草案 | `<patch_and_report_dir>/suggested-patch.diff` | 对被审文档的 unified diff；仅含必修；存疑不出 patch |
| 人读报告 | `<patch_and_report_dir>/review-report.md` | 跑了 N 轮 / 是否强停 / 收敛曲线 / 必修存疑舍弃三表 / 4 队对抗摘要 / token 用量 |

### 5.5 中间产物落点

```
/tmp/design-review-runs/<run-id>/    ← 中间产物（一次 run 一个 dir）
  ├─ R1/
  │   ├─ teamreport-T1.yaml
  │   ├─ teamreport-T2.yaml
  │   ├─ teamreport-T3.yaml
  │   ├─ teamreport-T4.yaml
  │   ├─ cross-attack.yaml
  │   └─ consensus.yaml
  ├─ R2/ ...
  ├─ Rfinal/
  └─ run.log

<repo>/<supplement_dir>/              ← 最终成果（人合议后落）
  └─ 201-{topic}-supplement.md

<repo>/<patch_and_report_dir>/        ← 最近一份产物镜像（gitignore）
  ├─ suggested-patch.diff
  └─ review-report.md
```

### 5.6 失败语义

| 故障 | 影响 | 处理 |
|---|---|---|
| 某球队 CLI 调用失败 | 该轮该队缺席 | 其他 3 队继续；缺席 ≥ 2 队 → exit 2，本轮作废 |
| 队内某 sub-agent 失败 | 该角色视角缺席 | 队内合议标注"R{x} 角色缺席"；不影响出队 |
| LLM 单调用超时 | 该调用缺席 | 重试 1 次；仍失败按上一条处理 |
| 单轮全局 token 超预算 | 自动降级 | 按 R5→R4→R3 顺序跳角色；记 warn 日志 |
| 收敛 stuck（3 轮 `Δvote_changed > 0` + `Δclassification_changed == 0`）| 视为已稳 | 进 Final，标 `stable_but_voting=true` |
| 收敛撕扯（3 轮 `Δclassification_changed > 0`）| 视为分歧无法消除 | 撕扯项打"存疑"入产物，进 Final，标 `unresolved_dispute=true` |
| `201-{topic}-supplement.md` 已存在 | 不覆盖 | 追加 `-r{run-seq}` 后缀 |
| 用户 Ctrl-C | 写 INTERRUPTED 日志 | 已完成轮材料保留 `/tmp/.../R{N}/`，exit 130 |
| `verify.cmd` 失败 | 阻断 Final 出产物 | 报错；可加 `--skip-verify` 跳 |

---

## 6. 目录结构

```
Thoth/workflows/design-review/
├─ WORKFLOW.md                       # 本文档（spec）
├─ Makefile                          # lint / test 入口
├─ scripts/
│  ├─ review-design.sh               # 主入口（CLI 层）
│  ├─ cron-batch.sh                  # 每晚批量 dispatcher（读 profile.env）
│  ├─ install-hooks.sh               # 装到项目 .git/hooks
│  ├─ daily-check.sh                 # cron 巡检（可选）
│  ├─ lint-doc.sh                    # 文档自洽 lint（mermaid/词表/内链/中英括注）
│  ├─ adapters/                      # claude / codex headless 适配器
│  └─ lib/                           # config / profile / phases / vote / judge / finalize …
├─ profiles/
│  ├─ README.md                      # §3.8 profile 布局与查找顺序
│  └─ example/                       # 可复制的 profile 骨架（profile.env + principles.md）
├─ templates/
│  ├─ orchestrator.md                # 主编排器 prompt（Claude 跑）
│  ├─ agent-legacy-archeologist.md   # R1（通用版；项目 profile 可同名覆盖）
│  ├─ agent-business-pessimist.md    # R2
│  ├─ agent-closure-judge.md         # R3
│  ├─ agent-impl-risk.md             # R4
│  ├─ agent-control-audit.md         # R5
│  ├─ stance-pro.md                  # 立场注入片段（赞成）
│  ├─ stance-con.md                  # 立场注入片段（反对）
│  ├─ stance-neutral.md              # 立场注入片段（中立）
│  ├─ cross-attack.md                # 跨阵营互击模板
│  ├─ consensus.md                   # 合议 sub-agent prompt
│  ├─ consolidator.md                # Final 汇总 agent prompt
│  ├─ principles.md                  # §3 通用工作原则
│  ├─ refs-manifest.example.yaml     # §3.5 参考仓库清单占位示例
│  └─ log-entry.md                   # 日志条目模板
├─ examples/
│  └─ design-review.yaml.example     # 项目配置范本（占位路径）
├─ hooks/
│  └─ pre-commit.sh.tmpl             # 可选 pre-commit
└─ tests/
   ├─ test_helper.bash
   ├─ unit/                          # bats 单元
   ├─ integration/                   # mock 集成
   ├─ golden/                        # 黄金对照
   ├─ prompt-regression/             # prompt 回归
   ├─ smoke/                         # 真实 LLM smoke
   ├─ chaos/                         # 混沌注入
   ├─ fixtures/                      # 测试夹具
   └─ mocks/                         # mock LLM
```

---

## 7. CLI 参数

```bash
review-design.sh [OPTIONS] [TARGET]
```

| 类别 | 参数 | 默认 | 说明 |
|---|---|---|---|
| 目标 | `TARGET` | yaml `target.default` | 被审文档路径（单个 md / 逗号分隔多个 / 目录通配）|
| 目标 | `--target FILES` | 同上 | 等价位置参数，可多次 |
| 轮次 | `--min-rounds N` | 2 | 覆盖 yaml `rounds.min` |
| 轮次 | `--max-rounds N` | 5 | 覆盖 yaml `rounds.max` |
| 轮次 | `--rounds N` | — | 等价 min=max=N |
| 模型 | `--claude-model M` | yaml | 当轮用什么 Claude 模型 |
| 模型 | `--codex-cmd CMD` | yaml | codex CLI 名 |
| 角色 | `--enable-roles R1,R3,R5` | 全 | 显式只跑指定角色 |
| 角色 | `--add-role NAME=PATH` | 无 | 临时加 R6/R7，不改 yaml |
| 跳步 | `--skip-verify` | false | 跳文档自洽 lint |
| 跳步 | `--no-patch` | false | 不出 suggested-patch.diff |
| 跳步 | `--no-supplement` | false | 不出 201-*-supplement.md |
| 断点 | `--resume RUN-ID` | 无 | 从 `/tmp/.../<RUN-ID>/` 续跑 |
| 断点 | `--dry-run` | false | 不调 LLM，打印计划 |
| 日志 | `--verbose` `-v` | false | 打印每个 sub-agent 调用 |
| 日志 | `--quiet` `-q` | false | 仅错误 |
| 日志 | `--run-id ID` | `YYYYmmdd-HHMMSS-<rand4>` | 覆盖 RUN-ID |
| 配置 | `--config PATH` | `.design-review.yaml` | 自定义配置 |
| 配置 | `--profile NAME\|PATH` | yaml `profile` / 环境变量 `DR_PROFILE` | 项目 profile（§3.8）|
| 配置 | `--principles PATH` | yaml 或内置 | 覆盖原则文件 |
| 配置 | `--refs PATH` | yaml | 覆盖参考仓库清单 |
| 范围 | `--scope FOCUS` | yaml `scope.focus` | 本次审查焦点（如 "调度模块"），注入每个 prompt |
| 元 | `--version` `--help` | — | 标准 |

---

## 8. yaml 配置 `.design-review.yaml`

```yaml
# 项目 profile（§3.8）：名字或路径；空 = 不用 profile。CLI --profile / 环境变量 DR_PROFILE 可覆盖。
profile: ""

target:
  default: "design/*.md"
  exclude:
    - "design/90-*.md"
    - "design/91-*.md"

# 审查范围（§3.6）：focus 非空则注入每个 prompt；out_of_scope 区域的承接缺口不计必修。
# 随阶段切换：现在审「调度 Pod」，以后改 focus 即可（或 CLI --scope 覆盖）。
scope:
  focus: "调度模块"
  out_of_scope:
    - "路由模块详细设计（待补）"
    - "计算模块详细设计（待补）"
  note: ""

# 背景文档（§3.7）：非审查目标，作为权威上下文注入每个 prompt。
# relations 说明文档关系——子模块不重复父级已锁定内容，孤立审会误报缺失。
background:
  docs:
    - path: "design/00-overview.md"
      role: "系统顶层：闭环 / 状态权威 / 跨模块契约 / 设计准则 / 词表"
    - path: "design/01-core.md"
      role: "调度模块详设入口；01-* 子模块的父文档"
  relations: |
    - 00 = 系统顶层（§9 调度模块章节）；01-core = 调度模块详设入口；01-a~01-i = 子模块（纯细化，引父级）。
    - 审子模块前先按「父锚点」读 00 + 01-core；判断缺失前确认是否已在父级承接。

llm:
  claude_model: ""     # 留空 = 继承 claude 自身默认模型
  codex_command: codex
  claude_bin: claude
  codex_bin: codex
  call_timeout_seconds: 1200
  call_retry: 1

teams:
  T1: {tool: claude}
  T2: {tool: codex}
  T3: {tool: claude}
  T4: {tool: codex}

orchestrator:
  tool: claude                      # 主编排器（推荐 Claude）
  template: templates/orchestrator.md

consolidator:
  tool: claude                      # Final 汇总者（推荐 Claude）
  template: templates/consolidator.md

rounds:
  min: 2
  max: 5
  stuck_threshold_rounds: 3
  dispute_threshold_rounds: 3

# roles.Rn.template：相对路径先按 profile 目录、再按 design-review 目录解析；不写则 profile 同名文件覆盖 templates/ 默认
roles:
  R1: {name: legacy-archeologist, template: templates/agent-legacy-archeologist.md, enabled: true}
  R2: {name: business-pessimist,  template: templates/agent-business-pessimist.md,  enabled: true}
  R3: {name: closure-judge,       template: templates/agent-closure-judge.md,       enabled: true}
  R4: {name: impl-risk,           template: templates/agent-impl-risk.md,           enabled: true}
  R5: {name: control-audit,       template: templates/agent-control-audit.md,       enabled: true}

stance:
  values: [pro, con, neutral]
  enforce_at_least_one_con: true

principles:
  file: ""                          # 不写用内置 templates/principles.md；项目原则走 profile 的 principles.md（§3.8）
  override:
    - id: "2.5"
      append: "本项目协调服务 lease TTL 必须按私有化慢盘场景留 2x 余量"

# 参考仓库清单（§3.5）：真实路径属于项目私有信息，写在项目仓库的本文件里，不要提交到公开仓库
refs:
  manifest:
    - {path: /path/to/legacy-service,          tier: "基线-功能权威"}
    - {path: /path/to/legacy-gateway,          tier: "基线-功能权威"}
    - {path: /path/to/legacy-base-lib,         tier: "基线-契约权威-只读"}
    - {path: /path/to/shared-toolkit,          tier: "基线-契约权威-可改需人审"}
    - {path: /path/to/contract-registry,       tier: "契约权威-可改需人审"}
    - {path: /path/to/Maat,                    tier: "基础要求"}
    - {path: /path/to/data-export,             tier: "数据形态权威"}
    - {path: /path/to/project/docs,            tier: "下级旁证-不作依据"}
    - {path: /path/to/project,                 tier: "仅作问题证据-不作正确性"}

budget:
  tokens_per_subagent: 30000
  tokens_per_team_round: 200000
  tokens_per_round_total: 800000
  tokens_per_run_total: 4000000
  degrade_role_order: [R5, R4, R3]

verify:
  enabled: true
  cmd: "scripts/lint-doc.sh"
  timeout_seconds: 120

output:
  supplement_dir: "design"
  supplement_pattern: "201-{topic}-supplement.md"
  patch_and_report_dir: "design/.design-runs"
  temp_dir: "/tmp/design-review-runs"

logging:
  file: "docs/design-review-log.md"
  daily_check_enabled: false

policy:
  fail_on_severity: P1
  strict_on_error: false
```

---

## 9. 退出码

**严重度排序约定**：`P0 > P1 > P2 > P3`（P0 最严重，类比"阻塞级 / 必须修"；P3 最轻，类比"建议级"）。

`fail_on_severity` 比较语义：**存在严重度 ≥ 该阈值的必修发现即触发 exit 1**。例如 `fail_on_severity: P1` 意为"出现 P0 或 P1 必修发现即失败"；`fail_on_severity: P0` 仅 P0 触发；`fail_on_severity: never` 不因严重度失败。

| 码 | 含义 |
|---|---|
| 0 | 通过：所有必修发现严重度严格弱于 `fail_on_severity`（如阈值 P1 时仅含 P2/P3）|
| 1 | 存在 ≥ `fail_on_severity` 的必修发现 |
| 2 | 依赖缺失 / 配置错误 / ≥2 队缺席 / verify.cmd 失败（除非 `--skip-verify`）|
| 3 | TARGET 空 / 全 skip / 不是有效 md |
| 4 | 强停（force_stopped）且 `strict_on_error=true` |
| 5 | 撕扯无解（unresolved_dispute）且 `strict_on_error=true` |
| 130 | SIGINT 中断 |

---

## 10. 日志格式

每次成功跑追加 `docs/design-review-log.md`（路径由 `logging.file` 配）：

```markdown
## 2026-05-27 14:32:11 TARGET=design/01-core.md RUN=20260527-143211-x4f2

- 轮次：跑了 3 轮 / min=2 / max=5 / 结果=CONVERGED
- 4 队立场：T1=pro T2=con T3=neutral T4=con
- 队内角色：R1-R5 全启用，无 fallback 降级
- 4 队产出：T1=12 T2=15 T3=10 T4=14 条原始发现（去重后 28 条 cross-finding）
- 跨队 4-vote 分布：4-0=8 / 3-1=6 / 2-2=4 / 1-3=7 / 0-4=3
- 合议：必修=14 (P0=2 P1=6 P2=5 P3=1) / 存疑=4 / 舍弃=10
- 产出文件：
  - design/201-core-supplement.md
  - design/.design-runs/suggested-patch.diff (含 14 项)
  - design/.design-runs/review-report.md
- token 用量：约 2.3M (T1=580k T2=620k T3=540k T4=560k)
- 退出码：0
- 备注：—
```

---

## 11. 测试策略

| 层 | 触发 | 范围 | 单次成本 | 信号 |
|---|---|---|---|---|
| L1 lint | 每 commit | shellcheck + yaml schema + markdown lint | <10s | 静态错 |
| L2 单元 bats | 每 commit | 单脚本单函数 | <30s | 算法正确性 |
| L3 mock 集成 | 每 PR | 跨进程 + mock LLM | <2min | 流程完整性 |
| L4 黄金对照 | 每 PR | 固定 fixture 跑固定结果 | <2min | 端到端可重现 |
| L5 prompt 回归 | 改 templates/* | 同 fixture 跑前后版 | <5min | prompt 副作用 |
| L6 真实 LLM smoke | 每天 / 发版前 | 真跑一篇真实设计文档 | 5-15min + token | 真实可跑性 |
| L7 混沌注入 | 每周 / 发版前 | 故意 kill / 超 token / 撕扯 | <5min | 失败语义 |

详细 case 列表与夹具结构在实施阶段按 §6 目录树落地。

### 11.1 mock LLM 协议

```bash
$DESIGN_REVIEW_CLAUDE_BIN \
    --team T1 --stance pro --round 1 --case <case-name> \
    --input /tmp/.../R1/T1-input.yaml \
    > /tmp/.../R1/teamreport-T1.yaml

# mock 内部按 ${case}-${team}-${stance}-R${round}.yaml 查表返回
```

注入方式：环境变量 `DESIGN_REVIEW_CLAUDE_BIN` / `DESIGN_REVIEW_CODEX_BIN` 在 test_helper.bash 中设；生产路径默认 `claude` / `codex`。

### 11.2 关键测试 case

| Case | 输入 | 期望 |
|---|---|---|
| empty-doc | 0 字节 md | exit 3，不写日志 |
| perfect-doc | 无瑕疵 fixture | R1 收敛，0 必修，patch 空 |
| known-flaws | 含 3 处已知瑕疵 | R1 或 R2 收敛，3 必修，patch 含 3 处 |
| dispute | 1 处主观瑕疵 pro/con 撕 | 2-2 进存疑，标 unresolved |
| stuck-vote | 1 处票数抖分类稳 | 3 轮后 stable_but_voting=true |
| force-stop | mock 永不收敛 | max=5 强停，force_stopped=true |
| agent-absent-1 | T2 调用失败 | T2 缺席，其他 3 队继续 |
| agent-absent-2 | T2 + T4 都失败 | exit 2 |
| token-overflow | mock 塞超长输出 | 触发 R5→R4 降级 + warn 日志 |
| ctrl-c | 测试中 SIGINT | exit 130，中间产物保留 |

### 11.3 黄金对照与 prompt 回归

```
make -C workflows/design-review test-golden       # 跑
make -C workflows/design-review accept-golden     # 输出合规时刷新 expected/（必须人审 diff 再 commit）
make -C workflows/design-review prompt-regression # 改 templates/* 后必跑
```

prompt 改动的合理差异需写进 `tests/prompt-regression/allowlist.yaml`，无 allowlist 解释的差异 → CI 失败。

---

## 12. 接入步骤

```bash
# 1. 确认 Thoth 在位 + 环境变量
export THOTH_HOME=/path/to/Thoth
export PATH=$THOTH_HOME/workflows/design-review/scripts:$PATH

# 2. 项目根落配置
cd /path/to/project
cp $THOTH_HOME/workflows/design-review/examples/design-review.yaml.example .design-review.yaml
# 编辑：target / refs / scope / background / output 默认值

# 3. （可选）项目 profile：项目私有的角色模板覆盖 + 项目原则 + cron 旋钮（§3.8）
#    建议放在单独的私有仓库，根目录设为 $THOTH_PROFILES 或软链到 ~/.config/thoth/profiles
cp -r $THOTH_HOME/workflows/design-review/profiles/example \
      $THOTH_PROFILES/design-review/my-project
#    然后在 .design-review.yaml 写 profile: my-project

# 4. gitignore 中间产物
cat >> .gitignore <<EOF
design/.design-runs/
EOF

# 5. （可选）装 pre-commit hook
$THOTH_HOME/workflows/design-review/scripts/install-hooks.sh

# 6. 先 dry-run 看计划（不调 LLM、不耗 token；输出含 profile= 行，确认 profile 已定位）
review-design.sh design/01-core.md --dry-run --verbose

# 7. 真跑（调 claude/codex headless，耗 token）
#    工具名 claude/codex 自动经 scripts/adapters/*-agent.sh 转成
#    `claude -p --permission-mode bypassPermissions` / `codex exec --dangerously-bypass-...`
#    yaml 里 llm.claude_bin / codex_bin = 真二进制名（默认 claude / codex）
review-design.sh design/01-core.md --rounds 2 --verbose

# 8. （可选）只验适配器接线，不跑整轮：make test-smoke（极小 prompt，单次 token 很低）
make -C $THOTH_HOME/workflows/design-review test-smoke

# 9. （可选）每晚批量：profile.env 填 REPO / REDESIGN_SUBDIR 后挂 cron
#    0 20-23,0-7 * * * /usr/bin/zsh -lc '$THOTH_HOME/workflows/design-review/scripts/cron-batch.sh my-project'
$THOTH_HOME/workflows/design-review/scripts/cron-batch.sh my-project --plan
```

> **适配器协议**：`scripts/adapters/{claude,codex}-agent.sh` 与 `tests/mocks/mock-*.sh` 实现同一套
> `--team/--stance/--round/--case/--input` 接口，可互换。真 CLI 读不到被审仓库工作树外的 refs/templates/profile
> 时，review-design.sh 已把这些目录经 `DR_ADD_DIRS` 透传给 `claude --add-dir`。

---

## 13. 不覆盖事项（显式记下）

| 不覆盖 | 理由 |
|---|---|
| 真实 LLM 输出质量 | 主观、不可重现；L6 smoke 仅断言"能跑" |
| token 计费准确性 | 由 CLI 自己上报，工具仅 best-effort 统计 |
| 跨工具 Claude vs Codex 公平性 | 承认风格差异，靠球队模型对冲 |
| 中文断词 / NLP 质量 | 不在范围 |
| 代码审查 | 用 `adversarial-review/` |
| 多语言文档 | 仅中文 + 英文括注 |

---

## 实施进度

- [x] M1 骨架 + mock 基础设施（2026-05-27）
  - Makefile / .shellcheckrc / test_helper.bash
  - scripts/lib/{errors,log,args,config}.sh
  - scripts/review-design.sh（CLI + 配置 + --dry-run）
  - templates/{principles.md, refs-manifest.example.yaml}
  - examples/design-review.yaml.example
  - tests/mocks/{mock-claude.sh, mock-codex.sh}
  - 单元测试 42 用例全过；shellcheck 0 warn
- [x] M2 算法层（2026-05-27）
  - scripts/lib/vote.sh — classify_votes / tally_votes / classify_cross_finding / merge_findings
  - scripts/lib/converge.sh — compute_deltas / decide_convergence / update_stuck_dispute_counters
  - scripts/lib/stance.sh — sample_stance / shuffle_team_stances / enforce_con
  - scripts/lib/finding.sh — validate_finding / count_vague_words / downgrade_confidence
  - scripts/lib/failure.sh — count_absent_teams / should_abort_round / next_role_to_drop / degrade_roles
  - 单元测试新增 65 用例（vote 13 / converge 11 / stance 10 / finding 11 / failure 17 / smoke 3）
  - 全套累计 107 用例，跨函数 smoke 跑通 happy + dispute + degrade 三路径
- [x] M3 跨阶段编排（2026-05-27）
  - scripts/lib/agent.sh — call_team_agent（timeout + retry + mock 协议）
  - scripts/lib/state.sh — state_init/get/set/increment（state.yaml 持久化）
  - scripts/lib/phases.sh — run_phase_a/b/c/d（5 阶段函数）
  - scripts/lib/budget.sh — estimate_round_tokens / check_and_degrade
  - scripts/lib/finalize.sh — write_supplement_md / write_review_report / write_suggested_patch / finalize_run
  - scripts/lib/orchestrator.sh — run_one_round / run_design_review
  - scripts/review-design.sh — 接入 orchestrator（移除 M1/M2 占位 die）
  - 单元测试新增约 44 用例（agent 7 / state 8 / phases 6 / budget 8 / finalize 8 / orchestrator 6 / dry_run +1）
  - 集成测试新增 6 用例（end-to-end mock LLM：perfect / known-flaws / agent-absent / patch / report / max）
  - 全套累计 151 单元 + 6 集成 = 157 用例，lint 0 warn
- [x] M4 横切 + prompt 模板（2026-05-27）
  - scripts/lint-doc.sh — L2 内链 + L5 含糊词
  - templates/agent-{legacy-archeologist,business-pessimist,closure-judge,impl-risk,control-audit}.md — 5 角色 prompt
  - templates/stance-{pro,con,neutral}.md — 3 立场片段
  - templates/{orchestrator,consolidator}.md — 流程控制 prompt
  - templates/{cross-attack,consensus,log-entry}.md — 中间产物模板
  - scripts/lib/agent.sh — 加 build_prompt_file（拼角色+立场+引用+历史包+输出指令）
  - scripts/lib/phases.sh — run_phase_a 用 build_prompt_file 拼 prompt 后调 LLM
  - scripts/lib/finalize.sh — finalize_run 末尾追加 log entry 到 docs/design-review-log.md
  - 单元测试新增 11 用例（lint-doc 6 / agent build_prompt 3 / phases prompt 1 / finalize log 1）
  - 全套累计 162 单元 + 6 集成 = 168 用例，lint 0 warn
  - 13 个 prompt 模板全部 lint-doc 通过（warn 数 0-3 内可接受）
- [~] M5 接入示例最小集（2026-05-28，部分）
  - 首个真实项目接入范本（refs 8 项 + exclude 4 项辅助文档；后迁入私有 profile）
  - templates/pre-commit.sh.tmpl — pre-commit 模板：staged redesign/*.md 跑 lint-doc，断链阻断
  - scripts/install-hooks.sh — hook 安装器：幂等 / --force / --uninstall / --dry-run
  - scripts/lib/config.sh — 补 target.exclude 加载（M1 遗留 bug）
  - scripts/review-design.sh — 默认 glob target 接 exclude 过滤；dry-run 末行文案修正
  - 单元测试新增 13 用例（install-hooks 11 / config exclude 2）；累计 175 单元 + 6 集成 = 181 用例
  - 首个真实项目落 .design-review.yaml + .gitignore <patch_and_report_dir> + docs/design-review-log.md 占位
- [x] M5 真 LLM CLI 适配器（2026-05-28）
  - scripts/adapters/claude-agent.sh — mock 协议 → `claude -p --permission-mode bypassPermissions`，剥 yaml 围栏
  - scripts/adapters/codex-agent.sh — mock 协议 → `codex exec --dangerously-bypass-approvals-and-sandbox --output-last-message`
  - scripts/lib/agent.sh — _resolve_bin fallback 默认指向适配器（测试 mock 仍优先）；新增 _adapters_dir
  - scripts/review-design.sh — 导出 DR_ADAPTERS_DIR / DR_*_MODEL_EFFECTIVE / DR_ADD_DIRS（refs+templates 透传 --add-dir）
  - tests/smoke/run.sh — L6 真 LLM smoke：claude + codex 适配器各回可解析 yaml（make test-smoke，耗 token）
  - 真跑验证：claude / codex 适配器各跑通，返回 team=SMOKE 的合法 yaml
- [x] M5 真 LLM 跨队对抗（phase B）+ 两个真跑暴露的 bug（2026-05-28）
  - scripts/lib/agent.sh — build_prompt_file 加 team 身份块（修：4 队曾全自报 team:T1，照抄 schema 示例）
  - scripts/lib/agent.sh — build_cross_attack_prompt：拼跨队投票 prompt（角色+身份+待投 cross-findings+证据路径）
  - scripts/lib/agent.sh — build_prompt_file / build_cross_attack_prompt 补 `local t`（修：内层 for t 泄漏污染调用方 $t，致只有 T4 生效）
  - scripts/lib/phases.sh — run_cross_attack + _apply_cross_votes：每队对 unknown 票真调 LLM 投票，yq -i 写回
  - scripts/lib/phases.sh — run_phase_c total≠4 兜底标「存疑」而非静默丢弃
  - scripts/lib/budget.sh — estimate_round_tokens 计入 xattack-vote-*.yaml
  - tests/mocks/mock-{claude,codex}.sh — 加 `${case}-${team}` 查表层（stance 无关，支撑 split 测试）
  - 单元测试新增 5 用例（agent identity 2 / phases cross-attack 3）+ 集成新增 1（split）；累计 180 单元 + 7 集成 = 187 用例
  - 真跑验证：真实父级详设文档单轮真审查 → 3 条必修（cf-001/002/003），4 队真投票全 agree，token 8985
- [x] M5 审查范围（scope）+ 背景文档（background）+ 文档关系（2026-05-28，§3.6 / §3.7）
  - scope：focus + out_of_scope，注入 prompt 约束「审什么 / 不报未设计区域」；CLI --scope 覆盖
  - background：docs[].{path,role} + relations，把系统总览 / 父级设计作为权威上下文注入；判断「缺失」前先核父级是否已承接（解子模块不重复父级、孤立审误报问题）
  - config.sh / args.sh / review-design.sh / agent.sh（_emit_scope_block + _emit_background_block）全链路接入
  - 项目配置：scope.focus=调度模块、exclude 跨系统 00-overview、background=00+父级详设+relations
  - 单元测试新增 10 用例（config scope 2 / config bg 2 / agent scope 2 / agent bg 2 / args scope 2）；累计 190 单元 + 7 集成 = 197 用例
  - 验证：dry-run 显示 scope/background；mock 跑出的 01-b-gray prompt 含背景+关系+范围三段
- [ ] M5 测试夹具补齐（golden / chaos / prompt-regression；smoke 已落 run.sh）
- [ ] M5 lint-doc L1/L3/L4 增强
- [ ] M5 consolidator 真 LLM 模式
- [x] M5 每队 5 sub-agent（2026-06-01）
  - phases.sh：`run_phase_a` 由单 R1 扩成 R1-R5 五角色扇出（`_role_template` / `_enabled_roles`）+ 队内合议 `merge_role_reports`（去重 + 真实身份），并发封顶 `DR_MAX_PARALLEL`（默认 8）；`--enable-roles` 生效
  - errors.sh：新增 `_yaml_dq`（YAML 双引号标量转义）；修 vote.sh / phases.sh / judge.sh 三处手工发射 canonical_text 未转义 → 富集真实文本含 `"` 时 cross-attack.yaml 非法的 bug
  - finalize.sh：报告 + 补充文档新增「待核实（NEEDS-INFO）」第 4 类——双裁判分歧的发现原先算了却不输出、显示 0/0/0 埋掉，现全部露出
  - 测试新增 test_roles.bats（11）+ test_errors/_vote/_finalize/_phases 增改；累计 233 单元 + 7 集成全绿，lint 0 warn
  - 真 LLM 验证：某子模块文档单轮 → 27 条 cross-finding 全露出（旧版仅 R1、0 可见），含 2 条 P0 控制权冲突
- [x] M6 项目 profile（插件）层（2026-09-16，§3.8）
  - scripts/lib/profile.sh：resolve_profile_dir（THOTH_PROFILES → ~/.config/thoth/profiles → 内置 profiles/）/ resolve_template / resolve_role_template_path
  - config.sh 解析 `profile:` 与 `roles.Rn.template`；args.sh 加 `--profile`；review-design.sh 定位 profile、生成 run 目录 refs-manifest.yaml、透传 DR_PROFILE_DIR / DR_REFS_MANIFEST
  - agent.sh：prompt 引用生成的 refs-manifest + 「项目原则」段；phases.sh：R1 改名 legacy-archeologist，角色模板按 yaml > profile > 默认解析
  - cron-batch.sh：项目旋钮改读 profile.env（REPO / REDESIGN_SUBDIR / PARENT_DOC / MAX_ROUNDS / WINDOW_END_HOUR）
  - templates/ 与 examples/ 全部去项目化；项目私有内容迁入外部 profile；内置 profiles/example 骨架
  - 测试新增 test_profile.bats（24）；累计 257 单元 + 7 集成全绿，lint 0 warn
- [ ] finalize 日志「启用角色」字段空（enabled_roles state 未初始化，cosmetic）
