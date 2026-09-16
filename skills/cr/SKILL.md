---
name: cr
description: "代码审查专家 - 三种模式：local（本地快速审查）、pr（PR 差异审查）、teams（多 Agent 对抗审查）。覆盖 Go/Python/Shell，A/B/C 优先级检查清单，风险矩阵驱动修复决策。适用：代码审查、PR Review、安全扫描、质量把关。不适用：纯格式化（用 formatter）、架构设计（用 design-patterns）。触发词：cr, code review, 代码审查, review, 审查, pr review"
user-invocable: true
allowed-tools: Bash, Read, Write, Edit, Grep, Glob, Task
---

# 代码审查专家

执行代码审查：$ARGUMENTS

---

## 模式路由

根据 `$ARGUMENTS` 确定审查模式，按以下决策树**从上到下首次匹配**执行：

### 1. 诊断模式

**条件:** `$ARGUMENTS` 包含 `diagnosis` 或 `诊断`

**动作:** 读取 `references/diagnosis.md`，按诊断指南执行。

### 2. PR 审查模式

**条件:** `$ARGUMENTS` 匹配以下任一：
- PR 编号：`#123`、`PR 456`、`pr-789`
- GitHub URL：包含 `github.com` 且含 `/pull/`

**动作:** 提取 PR 编号，读取 `references/pr-review.md`，按 PR 审查流程执行。

### 3. 多 Agent 对抗审查模式

**条件:** `$ARGUMENTS` 包含 `teams`、`对抗`、`adversarial`

**动作:** 读取 `references/teams-review.md`，按 7 阶段对抗流程执行。

### 4. 本地审查模式

**条件:** 以下任一：
- `$ARGUMENTS` 包含 `local`
- `$ARGUMENTS` 包含文件路径（含 `/` 或 `.go`/`.py`/`.sh` 扩展名）
- `$ARGUMENTS` 包含目录路径

**动作:** 读取 `references/local-review.md`，按 5 步本地审查流程执行。

### 5. 自动检测（无明确参数）

**条件:** 上述均不匹配

**动作:**
1. 运行 `git status --porcelain`
2. 有未提交变更 → 进入**本地审查模式**，范围为当前变更
3. 无变更 → 提示用户选择模式：
   - `/cr local <path>` — 审查指定文件/目录
   - `/cr #123` — 审查 PR
   - `/cr teams` — 多 Agent 对抗审查

---

## 通用规则

### 语言检测

扫描目标路径，按文件扩展名和项目配置自动检测：
- **Go:** `.go` 文件 或 `go.mod` 存在
- **Python:** `.py` 文件 或 `pyproject.toml`/`setup.py`/`requirements.txt` 存在
- **Shell:** `.sh`/`.bash` 文件

多语言项目同时应用所有检测到的语言规则。

### 检查清单引用

所有模式均使用以下共享检查清单（位于 `references/` 目录）：
- `code-checklist.md` — A/B/C 优先级代码检查清单（Go/Python/Shell）
- `doc-checklist.md` — 文档审查清单
- `judgment-matrix.md` — 风险等级 + 自动修复阈值

### 报告格式

所有模式的输出报告遵循统一格式（兼容 `agents/code-reviewer/AGENT.md` 输出）：

```markdown
## 审查摘要

**审查模式:** [local / pr / teams]
**变更概述:** [一句话描述]
**检测语言:** [Go, Python, Shell]
**总体评价:** [通过 / 需要修改 / 需要重写]
**发现数:** Critical: N, High: N, Medium: N, Low: N

## 发现

### [Critical] 标题
- **文件:** path/to/file:42
- **语言:** Go
- **问题:** 具体描述
- **建议:** 修复方案 + 代码示例
- **风险等级:** Critical — 参照 judgment-matrix.md

## 亮点
- [代码中做得好的地方]

## 建议
- [可选改进建议，非阻塞]
```

### 审查完成后

每次审查完成后，检查是否有误报/漏报值得记录，按 `references/checklist-evolution.md` 协议更新。
