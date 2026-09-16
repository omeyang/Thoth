# 对抗审查工作流提取设计

| 字段 | 值 |
|---|---|
| 日期 | 2026-05-16 |
| 作者 | omeyang |
| 状态 | Draft（待 review） |
| 影响仓库 | `omeyang/Thoth`（新增），`omeyang/XKit`（迁移消费方） |
| 关联 MEMORY | `project_adversarial_review_fixed_pkgs.md`、`feedback_pre_push_checks.md` |

## 1. 背景与动机

XKit 项目自 2026-04 起累积了 266 轮"四路对抗审查"（Claude×2 + Codex×2 + 交叉对抗 + 合议），全部由 `scripts/adversarial-review.sh`（240 行 Bash）+ `scripts/adversarial-review-daily-check.sh`（37 行）实现。最近一个月修复率近 0、cron 已于 2026-05-16 全部移除，但这套四路合议方法论本身经过实战验证，应被抽离为可被任意 Go 项目复用的通用工具。

**关键观察**：原脚本深度耦合 XKit 专属事实——硬编码 `REPO`、`PKGS` 数组、`task pre-push`、`git checkout main`、日志路径——这些必须参数化才能"通用"。

**新触发模型**：XKit 后续不再做包级全扫描，改为 pre-commit hook 触发的**增量代码对抗审查**（基于 `git diff --cached`）。Thoth 因此需要同时提供 **diff-based** 与 **target-based** 双入口，共享同一个四路合议底层。

## 2. 目标与非目标

### 目标
- 在 `Thoth/workflows/adversarial-review/` 下提供完整工作流：WORKFLOW.md 方法论 + 可参数化 Bash 脚本 + Prompt 模板 + 示例配置 + pre-commit hook 模板
- 暴露双入口：`review-diff.sh`（增量审查，pre-commit 主消费者）、`review-target.sh`（全包扫描，手动 / 旧式补审）
- XKit 作为 reference impl，迁移完成后能用 pre-commit hook 跑增量对抗审查，**每次都留痕**到 `docs/adversarial-review-log.md`

### 非目标
- 不重写为 Go binary（保持 Thoth "脚本+模板+Markdown"形态）
- 不引入 SLOT-based 全包扫描入口（YAGNI；XKit 当前不再需要，未来真需要时再加）
- 不替 XKit 写 `installer/`、不入仓 `.git/hooks/pre-commit`（每个 dev 用 `scripts/install-hooks.sh` 自装）
- 不做"自动重试 LLM 调用"、Web 仪表盘、Slack 通知

## 3. 目录结构与职责

```
Thoth/workflows/adversarial-review/
├── WORKFLOW.md                          # 方法论 + 接入步骤 + 日志格式约定 + FP 库菜鸟法
├── scripts/
│   ├── review-diff.sh                   # 入口①：对 git diff 跑 1 轮四路合议
│   ├── review-target.sh                 # 入口②：对任意 scope 跑 1 轮四路合议（默认含修复阶段）
│   ├── daily-check.sh                   # 对账：可选，每日检查 N 条日志条目
│   ├── install-hooks.sh                 # 一键装 .git/hooks/pre-commit 到当前仓库
│   └── lib/
│       ├── quorum.sh                    # 四路合议底层（被入口 source）
│       ├── config.sh                    # YAML 配置加载（依赖 yq）
│       └── target_infer.sh              # 从 diff 推断 TARGET 名（review-diff 专用）
├── templates/
│   ├── codex-attack.md                  # Codex A 攻方 prompt
│   ├── codex-defend.md                  # Codex B 复核 prompt
│   ├── claude-orchestrator.md           # Claude 主编排器 prompt（含 CA/CB/CC 子代理嵌套 prompt）
│   ├── cross-codex-attacks-claude.md    # Codex 反攻 Claude prompt
│   └── log-entry.md                     # 日志条目模板（合议表格 + 元信息）
├── examples/
│   ├── adversarial-review.yaml.example  # 配置文件示范
│   ├── xkit-pre-commit.sh.example       # XKit pre-commit hook 示范
│   └── xkit-pkgs.yaml.example           # XKit 现状对应的配置（reference impl）
└── hooks/
    └── pre-commit.sh.tmpl               # 通用 pre-commit hook 模板（install-hooks.sh 复制源）
```

**与 Thoth 现有约定对齐**：
- `WORKFLOW.md` 顶层 — 跟 `workflows/code-review/`、`workflows/tdd/` 同
- `templates/` 子目录 — 跟 `workflows/reqloop/templates/` 同
- `scripts/lib/` — 由本工作流首倡（合理且必要，否则 quorum 逻辑只能复制粘贴）
- 不引入 go.mod（保持 Thoth 非 Go-binary 形态）

**核心隔离决策**：
- `quorum.sh` 是黑盒底层（输入 TARGET + WORKDIR + LOG_DIR → 输出"合议结果 JSON + 日志条目片段"）
- `target_infer.sh` 只服务 review-diff，单独文件避免污染 quorum.sh
- Prompt 完全外置到 `templates/`，脚本里只做模板变量替换（envsubst 或 sed）

## 4. 入口契约

### 4.1 `scripts/review-diff.sh`

```
review-diff.sh [--ref=<git-ref>] [--scope=<auto|files|deepest-common>] [--config=<path>]

参数：
  --ref         git 差异基线，默认 --cached（staged 改动）；可传 HEAD~1..HEAD / origin/main..HEAD
  --scope       TARGET 推断策略：
                  auto (默认)         先 deepest-common，无公共父则 fallback files
                  deepest-common      diff 涉及文件的最深公共目录名
                  files               用文件列表前 3 项缩写
  --config      .adversarial-review.yaml 路径，默认 $PWD/.adversarial-review.yaml

行为：默认 --no-fix（pre-commit 不应自动改代码）
```

### 4.2 `scripts/review-target.sh`

```
review-target.sh <target-name> [--workdir=<path>] [--config=<path>] [--no-fix] [--no-commit]

参数：
  <target-name>     必填，目标包/模块名（如 xsemaphore）
  --workdir         待审查代码路径，缺省由 config.search_dirs 自动 find
  --no-fix          只跑合议、不进入修复阶段（适合 CI/只读审查）
  --no-commit       跑完修复但不 commit/push

行为：默认走完合议+修复+commit+push 全流程（与原 XKit 脚本兼容）
```

### 4.3 退出码（两入口共用）

| 退出码 | 含义 | 阻断 commit | 写 log 文件 |
|---|---|---|---|
| 0 | 跑完，无 ≥ `fail_on_severity` 真问题（含 0 发现）| 否 | **是**（"留痕"条目） |
| 1 | 发现 ≥ `fail_on_severity` 真问题 | 是 | 是（合议表格）|
| 2 | 依赖缺失 / 配置错误 / LLM 失败 + strict_on_error=true | 是 | 视情况 |
| 3 | diff 空 / 全 skip_paths / 超 max_diff_lines | 否 | 否 |
| 130 | SIGINT（用户 Ctrl-C） | 是 | 是（INTERRUPTED 条目） |

### 4.4 `scripts/lib/quorum.sh` 内部接口

```bash
# Source 后可调用：
quorum_run TARGET WORKDIR LOG_DIR
  # 副作用：写 6 个原始/对抗 .md 文件到 LOG_DIR
  # stdout：一行 JSON，结构如下
  # {"findings":{"claude_attack":N,"claude_defend":N,"codex_a":N,"codex_b":N},
  #  "cross":{"codex_attacks_claude":{"a":N,"b":N,"c":N},
  #           "claude_attacks_codex":{"a":N,"b":N,"c":N}},
  #  "verdict":{"must_fix":N,"disputed":N,"discarded":N},
  #  "log_entry_path":"...","highest_severity":"high|medium|none"}

quorum_apply_fixes WORKDIR LOG_DIR
  # 读 quorum_run 留下的 disputed/must_fix 列表，调 Claude 跑修复 + 验证命令
  # 退出码反映"修复是否成功"
```

### 4.5 模板变量约定

统一 `{{VAR}}` 替换，由各脚本通过 envsubst 或 sed 注入：

| 变量 | 含义 | 出现位置 |
|---|---|---|
| `{{TARGET}}` | 目标名 | 所有模板 |
| `{{WORKDIR}}` | 代码根 | codex/claude prompt |
| `{{DIFF_BLOCK}}` | git diff 全文（仅 review-diff） | codex-attack / claude-orchestrator |
| `{{DIMENSIONS}}` | 审查维度清单（YAML 可覆盖）| codex-attack / claude-orchestrator |
| `{{SEVERITY_DEF}}` | FG-H/FG-M/FG-L 定义 | codex-attack / codex-defend |
| `{{VERIFY_CMD}}` | 修复后验证命令（XKit=`task pre-push`） | claude-orchestrator 阶段 E |
| `{{COMMIT_PREFIX}}` | commit 风格前缀（XKit=`fix({{TARGET}})`） | claude-orchestrator 阶段 F |
| `{{LOG_FILE}}` | 日志追加路径 | claude-orchestrator 阶段 G |

## 5. YAML 配置（`.adversarial-review.yaml`）

```yaml
repo:
  root: .
  search_dirs: [pkg, cmd, internal]
  search_maxdepth: 3

llm:
  claude_model: claude-opus-4-7
  codex_command: codex
  parallel_codex: true

review:
  dimensions:
    - "nil/typed-nil/零值契约"
    - "并发安全（mutex 边界/goroutine 泄漏/线性化缺口/atomic 顺序）"
    - "错误处理（%w / errors.Join 双 cause / 错误链）"
    - "context 传播与 nil 防御"
    - "资源清理（Close 幂等/cleanup goroutine 退出）"
    - "API 契约"
    - "跨平台 build tag"
  max_findings_per_source: 8

diff:
  default_ref: "--cached"
  scope_strategy: auto                  # auto | deepest-common | files
  max_diff_lines: 500
  skip_paths:
    - "*.md"
    - "docs/**"
    - "**/testdata/**"
  auto_stash_unstaged: false            # 检测到 partial staging 时仅警告，不自动 stash

verify:
  cmd: "task pre-push"
  timeout_seconds: 600

commit:
  prefix_template: "fix({{TARGET}})"
  push_after_fix: false

log:
  file: docs/adversarial-review-log.md
  run_dir: .adversarial-runs

policy:
  fail_on_severity: high                # high | medium | never
  strict_on_error: false

daily_check:
  enabled: false
  expected_entries: 15
```

## 6. 数据流（review-diff 跑一次 pre-commit）

```
1. pre-commit hook 触发 → 检查 merge/rebase/cherry-pick 标记，命中则 exit 0
2. 检查 AIREVIEW_RUNNING==1（重入保护），命中则 exit 0
3. review-diff.sh：config_load .adversarial-review.yaml
4. git diff --cached --name-only 列出 staged 文件
     ├─ 全在 skip_paths 下？  → exit 3（不写日志）
     ├─ diff_lines > max_diff_lines？ → 提示走 review-target，exit 3
     └─ 否则继续
5. target_infer：scope=auto → deepest-common 找出 TARGET（如 xsemaphore）
6. mkdir .adversarial-runs/ + export AIREVIEW_RUNNING=1 + 启动 quorum_run
     │
     ├─ 阶段 1：codex exec ×2 后台并行
     │           输出 → codex-A-<TARGET>-<TS>.md, codex-B-<TARGET>-<TS>.md
     │
     ├─ 阶段 2：claude -p 启动主编排器
     │   ├─ 阶段 A：并行 Agent 工具调 CA(攻方) + CB(守方)
     │   ├─ 阶段 B：wait Codex PID + Read 输出
     │   ├─ 阶段 C：交叉对抗
     │   │   ├─ codex exec "对 Claude 发现逐条判 a/b/c"
     │   │   └─ Agent CC(Claude 反攻)
     │   ├─ 阶段 D：合议 → must_fix/disputed/discarded
     │   └─ 阶段 G：追加 log_entry 片段（review-diff 默认 --no-fix，不修复）
     │
     ▼
7. quorum_run echo JSON：{"verdict":..., "highest_severity": "..."}
8. review-diff 判 policy.fail_on_severity：
     ├─ highest >= 阈值 → exit 1
     └─ 否则 → exit 0
```

**关键时序约束**：
- 阶段 1 与阶段 2-A 真正并行（Codex 后台 + Claude 子代理）→ 节约 ~50% wall-clock
- 阶段 C 必须串行（合议需 4 份 findings 全到位）
- 修复阶段在 review-diff 默认禁用 → pre-commit 总时长 ≈ 8-12 分钟

## 7. 关键设计决策（ADR-style）

### 7.1 review-diff TARGET 推断策略

**决定**：默认 `auto` = 先 `deepest-common`，失败 fallback `files`，再失败用 `commit-<short-sha>`

- 单包 diff → 该包名（最常见）
- 跨包 diff → 公共父=`pkg` 时回退到 `files` 拼接前 3 个 basename
- 根目录改动 / 无公共父 → `commit-<git short sha>`

**理由**：项目通常以包/模块为审查单位；跨包用 hash 标识避免乱填 TARGET 名。

### 7.2 失败策略

**决定**：YAML `fail_on_severity` 默认 `high`，`strict_on_error` 默认 `false`

- `high`：FG-H 才阻断；FG-M 仅警告 + 留日志（历史 266 轮 FG-M 70%+ 是 FP）
- `medium`：严格团队选项
- `never`：试用期 / 仅留痕
- `strict_on_error: false`：LLM 调用失败不阻断 commit（避免限流/网络波动误伤）

### 7.3 diff scope 默认

**决定**：`--cached`（staged）

- pre-commit hook 只关心进入下一个 commit 的内容
- 工作区未 staged 改动不应影响审查
- pre-push 场景用 `--ref=origin/main..HEAD` 显式传入

### 7.4 每次跑都写日志（即使 0 发现）

**决定**：review-diff/review-target 跑成功后都写日志条目（最简形式："## DATE TARGET=xxx — OK 留痕"）

**理由**：用户明确要求"证明 hook 跑过了"。空 diff / skip_paths / 重入保护这三种"未真正跑"的情况不写。

### 7.5 Partial staging 默认仅警告

**决定**：`auto_stash_unstaged: false`

- 检测到 staged 文件有未 staged 改动时，仅打印警告告知"LLM 看到的 diff 与 commit 后实际可能不一致"
- 用户开 `true` 时才走 `git stash push --keep-index --include-untracked` + trap EXIT 恢复
- **理由**：自动 stash 失败（merge 冲突态）可能搞乱用户工作；安全 > 智能。

### 7.6 日志并发追加用 flock

**决定**：`flock -w 30 "$LOG_FILE.lock" -c '...'`

- 多个 git commit 并行（rebase / 多窗口）会同时写日志，必须独占
- 抢锁 30s 超时则写到 `.adversarial-runs/late-log-<TS>.md`，下次 review-target 跑时尝试合并

### 7.7 Timeout 总闸

**决定**：`quorum_run` 外层 `timeout 1200`（20 分钟），Codex 后台 `timeout 600`（10 分钟）

**理由**：原脚本无超时保护，曾出现 Codex 卡死 stdin 读取（MEMORY 多次"截断无输出"印证）。

### 7.8 重入保护

**决定**：入口检测 `AIREVIEW_RUNNING==1` 立即 exit 0

**理由**：review-target 修复阶段会触发 `git commit`，那个 commit 也走 pre-commit，**会陷入无限递归**。

## 8. 错误信息格式

所有 exit ≥ 1 必须 stderr 输出统一格式：

```
✗ adversarial-review: <category>
  reason: <人类可读理由>
  fix:    <用户该做什么>
  log:    <runlog 路径>
```

**理由**：原脚本失败信息很碎（`FATAL: ...`、写到 LOG_FILE、stderr 自由格式），用户排查跨多文件。统一三段（reason / fix / log）强制每次都给出可行动信息。

## 9. SIGINT / 中断处理

- 主入口 `trap 'cleanup_on_signal' INT TERM`
- cleanup 内容：kill 所有后台 Codex PID、**不删** `.adversarial-runs/` 中间文件（保留排查）、追加 INTERRUPTED 日志条目（带 staged 文件列表 + 已完成阶段）
- 用户 Ctrl-C 时能立刻收到"已中断，commit 未提交"提示而非僵尸进程

## 10. 测试策略

### 10.1 测试金字塔

| 层 | 工具 | 速度 | 覆盖 |
|---|---|---|---|
| 0 静态扫描 | `shellcheck -e SC1091` | 秒级 | 所有 .sh |
| 1 单元 | `bats-core` | ms 级/用例 | `lib/*.sh` 纯函数 |
| 2 集成 | `bats-core` + mock claude/codex 二进制 | 秒级/用例 | 入口脚本所有退出码路径 |
| 3 回归 | 手工触发，调真 LLM | 分钟级 | 黄金 case 端到端 |

### 10.2 单元测试用例

| 测试文件 | 覆盖 |
|---|---|
| `tests/unit/target_infer.bats` | deepest-common（单包/跨包/根目录）/ files / commit-sha fallback / 特殊字符 sanitize |
| `tests/unit/config.bats` | config_load 默认值 / config_get 缺失键回退 / 字段类型错抛出 |
| `tests/unit/severity.bats` | high > medium > low 比较 / fail_on_severity 阈值判断 |
| `tests/unit/skip_paths.bats` | glob 匹配（`*_test.go` / `docs/**` / `**/testdata/**`） |
| `tests/unit/diff_sizing.bats` | max_diff_lines 触发 fallback |

### 10.3 集成测试用例

Mock LLM 范式：

```bash
# tests/fixtures/bin/claude
#!/usr/bin/env bash
case "$AIREVIEW_FIXTURE" in
  empty)      echo "无发现" ;;
  one-high)   cat "$BATS_TEST_DIRNAME/../fixtures/claude-one-high.md" ;;
  timeout)    sleep 1300 ;;
  fail-1)     exit 1 ;;
  *)          echo "MOCK MISSING FIXTURE: $AIREVIEW_FIXTURE" >&2; exit 99 ;;
esac
```

测试列表：

| 测试文件 | 覆盖 |
|---|---|
| `tests/integration/review-diff-empty.bats` | 空 diff → exit 3，不写日志 |
| `tests/integration/review-diff-skipped.bats` | 全 \*.md 改动 → exit 3 |
| `tests/integration/review-diff-clean.bats` | mock 全返"无发现" → exit 0 + 日志写"OK 留痕"条目 |
| `tests/integration/review-diff-finds-high.bats` | mock 返回 FG-H → exit 1 + 合议表格 |
| `tests/integration/review-diff-llm-fail.bats` | mock 退 1，strict=false → exit 0 + FAILED 条目 |
| `tests/integration/review-diff-llm-fail-strict.bats` | strict=true → exit 2 |
| `tests/integration/review-diff-reentrant.bats` | AIREVIEW_RUNNING=1 → exit 0 |
| `tests/integration/review-diff-timeout.bats` | mock sleep 1300s → 1200s timeout 触发 |
| `tests/integration/flock-concurrent.bats` | 两个 review-diff 并发 → late-log 路径触发 |
| `tests/integration/sigint-cleanup.bats` | SIGINT 后保留中间文件 + INTERRUPTED 条目 |

### 10.4 端到端黄金 case

不在常规 CI 跑，由 Thoth 维护者改动 review-diff / review-target 时手工触发：

**黄金 case 1：XKit doFallback typed-nil bug 回归**
- 重放 commit `2596b30^..2596b30` 的修复前代码
- 跑 review-diff → 期望命中 FG-H、合议表格至少 1 条 "必修"
- 这是 MEMORY 有据可查的"对抗审查（ultrareview 形式）抓到的真 bug"

**黄金 case 2：空发现回归**
- 跑当前 main HEAD 的 xkeylock 包（MEMORY 显示 5 轮全 0 真问题）
- 期望 exit 0 + 日志条目"无发现"

### 10.5 验收清单（提取实施后）

1. ☐ `make lint` shellcheck 全过
2. ☐ `bats tests/unit/` 全过
3. ☐ `bats tests/integration/` 全过
4. ☐ XKit 复制示例配置 + 装 pre-commit → 做一次空 commit，~8-12 分钟后 exit 0 + 日志多一条"留痕"
5. ☐ 黄金 case 1：XKit doFallback 修复前 diff → review-diff exit 1
6. ☐ 黄金 case 2：xkeylock 现状 → review-target exit 0

### 10.6 不做的事 (YAGNI)

- ❌ Bash 覆盖率（bashcov 维护成本高，列举主要分支足够）
- ❌ CI 跑真 LLM 端到端（贵 + 非确定性）
- ❌ Docker 测试环境（bash + git + bats 都裸装）

## 11. XKit 接入范本

### 11.1 `.adversarial-review.yaml` 入仓内容

见第 5 节示例 YAML，原样可用。

### 11.2 `.git/hooks/pre-commit` 内容（不入仓，靠 install-hooks.sh 装）

```bash
#!/usr/bin/env bash
set -euo pipefail
THOTH="${THOTH_HOME:-/root/code/ai/github.com/omeyang/Thoth}"
REVIEW_SCRIPT="$THOTH/workflows/adversarial-review/scripts/review-diff.sh"

# 跳过 merge/rebase/cherry-pick
if [[ -f .git/MERGE_HEAD || -d .git/rebase-merge || -d .git/rebase-apply || -f .git/CHERRY_PICK_HEAD ]]; then
  exit 0
fi
# 重入保护
if [[ "${AIREVIEW_RUNNING:-}" == "1" ]]; then
  exit 0
fi
exec "$REVIEW_SCRIPT"
```

### 11.3 XKit 仓库清理

| 操作 | 文件 |
|---|---|
| 删 | `scripts/adversarial-review.sh` |
| 删 | `scripts/adversarial-review-daily-check.sh` |
| 留 | `scripts/sync-1.23-branch.sh`（与对抗审查无关，XKit 业务）|
| 留 | `docs/adversarial-review-log.md`（同文件继续追加，4617 行历史 + FP 库具体 case 是宝贵资产）|
| 新增 | `.adversarial-review.yaml` |
| `.gitignore` 加 | `.adversarial-runs/` |
| **不入仓** | `.git/hooks/pre-commit`（由 `scripts/install-hooks.sh` 装）|
| MEMORY 更新 | `project_adversarial_review_fixed_pkgs.md` 改为指向 Thoth + 接入说明 |

### 11.4 触发与运行示例

```bash
# 1) 日常 commit — 自动触发
git add pkg/distributed/xsemaphore/redis.go
git commit -m "fix(xsemaphore): adjust retry logic"
# pre-commit 跑 ~8-12 分钟 → 0 真问题 → commit 成功，docs/adversarial-review-log.md 多一条"OK 留痕"

# 2) 紧急跳过审查
git commit --no-verify -m "fix: urgent"

# 3) 手动审查某个包
/root/code/ai/github.com/omeyang/Thoth/workflows/adversarial-review/scripts/review-target.sh xsemaphore

# 4) Pre-push 整 branch 审查
/root/.../scripts/review-diff.sh --ref=origin/main..HEAD --no-fix
```

### 11.5 第一次接入的冒烟步骤

1. `cd XKit && cp /path/to/Thoth/workflows/adversarial-review/examples/xkit-pkgs.yaml.example .adversarial-review.yaml`
2. `/path/to/Thoth/workflows/adversarial-review/scripts/install-hooks.sh`（装 pre-commit）
3. `touch test-trigger.go && git add test-trigger.go && git commit -m "test: trigger adversarial review"`
4. 等 ~10 分钟 → 期望 exit 0 + `docs/adversarial-review-log.md` 多一条"OK 留痕"
5. 验收通过即 `git reset HEAD~1 && rm test-trigger.go`

## 12. 第一个 PR / Commit 范围

### 12.1 Thoth 仓库

单 PR / 单 commit：
- 新增 `workflows/adversarial-review/` 全套（WORKFLOW.md + scripts/ + templates/ + examples/ + hooks/）
- 新增 `tests/unit/` + `tests/integration/` + `tests/fixtures/`
- 新增 `docs/specs/2026-05-16-adversarial-review-extraction-design.md`（本 spec）
- 更新 Thoth 顶层 `README.md` 加 `workflows/adversarial-review/` 条目
- 不动其他 workflows / agents / skills

### 12.2 XKit 仓库

2 commit（一个 PR）：
- commit 1: `docs(adversarial-review): 接入 Thoth 通用对抗审查`
  - 新增 `.adversarial-review.yaml`
  - 更新 `.gitignore` 加 `.adversarial-runs/`
  - 更新 MEMORY `project_adversarial_review_fixed_pkgs.md` 指向 Thoth
- commit 2: `chore: 移除已迁移至 Thoth 的 scripts/adversarial-review*.sh`
  - 删两个旧脚本

## 13. 不在本次范围的后续工作

- SLOT-based 全包扫描入口（如未来真需要"每天扫 N 个包"模式再加 `review-slot.sh`）
- 多语言支持（当前只设计 Go 维度；未来要审 Python/Rust 时扩 `review.dimensions` 模板）
- 与 Thoth 现有 `workflows/code-review/` 的整合（两者方法论不同，可并列存在）
- GitHub Actions / GitLab CI 集成示例（用户先用本地 pre-commit，跑顺了再说）
- Web 报告 / Slack 通知

## 14. 附录：原工具到新工具映射

| 原 XKit `scripts/adversarial-review.sh` | 新 Thoth 位置 |
|---|---|
| `REPO=/root/.../XKit` 硬编码 | `.adversarial-review.yaml: repo.root` + 自动 `git rev-parse --show-toplevel` |
| `PKGS=(...)` 数组 | 已弃用（XKit 不再需要）；其他项目可改用 `review-target.sh <name>` 多次调用 |
| `SLOT` 调度参数 | 已弃用（cron 移除）|
| `PKG_DIR=$(find ...)` | `review-target.sh` 内置同逻辑，受 `repo.search_dirs / search_maxdepth` 控制 |
| 阶段 1 `codex exec` ×2 | `scripts/lib/quorum.sh` 阶段 1，prompt 来自 `templates/codex-{attack,defend}.md` |
| 阶段 2 `claude -p` 主编排 | 同上阶段 2，prompt 来自 `templates/claude-orchestrator.md` |
| 阶段 C 交叉对抗 | 同上阶段 C，prompt 来自 `templates/cross-codex-attacks-claude.md` |
| 阶段 G `>> $LOG_FILE` | `quorum.sh` 用 `flock` 包裹追加，模板 `templates/log-entry.md` |
| `task pre-push` 硬编码 | `.adversarial-review.yaml: verify.cmd` |
| `git push origin main` | `commit.push_after_fix` 控制（XKit 默认 false） |
| 失败补 FAILED 日志 | `quorum.sh` 内 trap + 统一错误格式 |
