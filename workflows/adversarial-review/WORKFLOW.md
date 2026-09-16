# 对抗审查工作流（Adversarial Review）

四路对抗 + 交叉合议的代码审查流程：Claude×2 + Codex×2 + 跨阵营对抗 + 合议。可对 git diff（增量，pre-commit）或任意 scope（全包扫描）触发。

## 前置条件

| 工具 | 用途 | 检查命令 |
|------|------|---------|
| `claude` CLI | Claude Code | `claude --version` |
| `codex` CLI | OpenAI Codex | `codex --version` |
| `yq` v4 | YAML 解析 | `yq --version` |
| `git` ≥ 2.30 | diff / repo 检测 | `git version` |
| `flock` | 日志并发锁 | `which flock` |
| `envsubst` | 模板变量替换 | `which envsubst` |
| `timeout` | LLM 调用硬超时 | `which timeout` |
| `bats-core` | 测试 | `bats --version` |
| `shellcheck` | 静态扫描 | `shellcheck --version` |

## 适用场景

- pre-commit 增量代码审查（10-15 分钟，可阻断 commit）
- 手动跑某个包的全量审查（全流程含修复 + commit）
- pre-push 整 branch 增量审查（手动触发）

## 接入步骤

1. 复制配置范本到项目根：
   ```bash
   cp workflows/adversarial-review/examples/adversarial-review.yaml.example .adversarial-review.yaml
   # 编辑 verify.cmd / review.dimensions / log.file 等
   ```
2. 装 pre-commit hook：
   ```bash
   /path/to/Thoth/workflows/adversarial-review/scripts/install-hooks.sh
   ```
3. 把 `.adversarial-runs/` 加进 `.gitignore`
4. 设环境变量（推荐写进 ~/.zshrc）：
   ```bash
   export THOTH_HOME=/root/code/ai/github.com/omeyang/Thoth
   ```

## 流程定义

```
┌────────────────────────────────┐
│ 1. pre-commit / 手动触发        │
└──────────────┬─────────────────┘
               ▼
┌────────────────────────────────┐
│ 2. 加载 .adversarial-review.yaml │
│    依赖体检 / git 仓库验证       │
└──────────────┬─────────────────┘
               ▼
┌────────────────────────────────┐
│ 3. (review-diff)                │
│    git diff → skip_paths 过滤   │
│    → max_diff_lines → TARGET 推断│
│    全空 / 全 skip → exit 3      │
└──────────────┬─────────────────┘
               ▼
┌────────────────────────────────┐
│ 4. 阶段 1：Codex×2 后台并行扫描  │
└──────────────┬─────────────────┘
               ▼
┌────────────────────────────────┐
│ 5. 阶段 2：claude -p 主编排器    │
│    └ 阶段 A：Claude CA/CB 子代理  │
│    └ 阶段 B：wait Codex          │
│    └ 阶段 C：跨阵营对抗 (a/b/c)  │
│    └ 阶段 D：合议                │
│    └ 阶段 E：修复 (--no-fix 跳过) │
│    └ 阶段 F：commit (--no-commit 跳过) │
│    └ 阶段 G：写 verdict.json + log-entry.md │
└──────────────┬─────────────────┘
               ▼
┌────────────────────────────────┐
│ 6. flock 锁追加日志条目         │
└──────────────┬─────────────────┘
               ▼
┌────────────────────────────────┐
│ 7. 严重度阈值判定               │
│    >= fail_on_severity → exit 1 │
│    否则 → exit 0                 │
└────────────────────────────────┘
```

## 日志格式约定

每次成功跑都追加 `docs/adversarial-review-log.md`（路径由 `log.file` 配置）：

```markdown
## YYYY-MM-DD TARGET=<name>
- 触发：review-diff / review-target
- 原始发现：Claude攻=N 守=N / Codex A=N B=N
- 交叉对抗：Codex攻Claude → a=N b=N c=N；Claude攻Codex → a=N b=N c=N
- 合议：必修=N 存疑=N 舍弃=N
- 修复：commit <hash> 或 "无发现"
- 合议表格：
  | 编号 | 严重度 | 文件:行 | 根因 | 分类 | 来源数 | 对抗结果 |
  ...
```

## False Positive 库（建议每个项目维护）

每次审查后被舍弃的发现整理到项目自己的 MEMORY / docs/fp-patterns.md：

格式：
```markdown
- 包/文件 — 现象描述 — FP 理由（已文档化设计决策 / 公共 API 契约 / 已有防御 / 业内惯例）
```

后续审查 LLM 在阶段 D 合议时识别这些模式，不重复挑刺。

## 退出码

| 退出码 | 含义 |
|---|---|
| 0 | 通过（含 0 发现 + 留痕日志） |
| 1 | 发现 ≥ fail_on_severity 阈值，阻断 commit |
| 2 | 依赖缺失 / 配置错误 / LLM 失败 + strict_on_error=true |
| 3 | diff 为空 / 全 skip / 超 max_diff_lines（不写日志，不阻断） |
| 130 | SIGINT (Ctrl-C)，写 INTERRUPTED 条目 |

## 测试

```bash
make -C workflows/adversarial-review lint    # shellcheck
make -C workflows/adversarial-review test    # bats unit + integration
```
