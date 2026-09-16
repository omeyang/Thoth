# PR 审查流程

本文档定义 `/cr #<N>` 模式的完整 PR 审查流程。

---

## 前置条件

- **gh CLI** 可用且已认证：`gh auth status`
- **git** 仓库上下文：当前目录在目标仓库内

如果 `gh` 不可用，提示用户安装并认证后重试。

---

## 流程

### 第 1 步：获取 PR 信息

并行执行以下命令获取 PR 完整上下文：

```bash
# PR 元信息
gh pr view <N> --json number,title,body,author,baseRefName,headRefName,additions,deletions,changedFiles,labels,reviewDecision,state

# PR 差异
gh pr diff <N>

# CI 检查状态
gh pr checks <N>
```

提取并记录：
- PR 编号、标题、作者、描述
- base 分支和 head 分支
- 变更统计（additions/deletions/changedFiles）
- CI 状态（通过/失败/进行中）
- 现有 labels 和 review decision

### 第 2 步：范围分析

1. **解析 diff** — 提取变更文件列表
2. **语言检测** — 扫描变更文件扩展名，确定涉及的语言（Go/Python/Shell）
3. **文件数量控制** — 变更文件超过 50 个时：
   - 按变更行数降序排序
   - 取 Top 10 重点审查
   - 其余标注"[未审查] 优先级较低"
4. **识别关键文件** — 标记以下高优先级文件（即使变更量小也优先审查）：
   - 认证/授权相关（`auth`、`rbac`、`permission`）
   - 数据库迁移（`migration`、`schema`）
   - 配置文件（`.yaml`、`.toml`、`.env`）
   - CI/CD 配置（`.github/workflows/`、`Dockerfile`、`Makefile`）

### 第 3 步：审查执行

#### 3a. 工具扫描

checkout PR 分支并运行语言对应的工具（参照 `local-review.md` 工具矩阵）：

```bash
# 切换到 PR 分支
gh pr checkout <N>

# 按语言执行工具
# Go: gofmt -l / golangci-lint run / go vet
# Python: ruff format --check / ruff check / mypy
# Shell: shellcheck / bash -n
```

**注意:** 审查完成后恢复原分支：`git checkout -`

#### 3b. 检查清单审查

读取 `references/code-checklist.md`，按 A → B → C 优先级检查变更代码（同 local-review.md 第 3 步）。

#### 3c. PR 特有检查

除代码检查清单外，额外检查以下 PR 特有项：

**PR 描述质量:**
- [ ] 标题简洁且有意义（不超过 72 字符）
- [ ] 描述说明了变更原因和方案
- [ ] 关联了相关 Issue（如有）

**变更完整性:**
- [ ] 包含对应的测试变更
- [ ] 数据库变更包含迁移脚本
- [ ] API 变更更新了文档
- [ ] Breaking changes 有明确标注

**向后兼容:**
- [ ] 公开 API 签名未破坏性变更（或已标注 Breaking）
- [ ] 配置项变更有默认值兼容
- [ ] 数据库迁移可回滚

### 第 4 步：CI 集成

将 CI 检查结果纳入审查：

1. **CI 失败** → 相关项升级为 **Critical** 级别发现
2. **CI 进行中** → 标注"CI 尚未完成，建议等待结果"
3. **CI 通过** → 记录在报告中作为正面信号

CI 失败的具体项记录为：
```markdown
### [Critical] CI 检查失败: <check-name>
- **来源:** gh pr checks
- **状态:** 失败
- **问题:** [检查项名称] 未通过
- **建议:** 修复 CI 失败后重新审查
```

### 第 5 步：输出报告

扩展 local-review 的报告格式，增加 PR 元信息：

```markdown
## 审查摘要

**审查模式:** pr
**PR:** #<N> — <title>
**作者:** @<author>
**分支:** <head> → <base>
**变更统计:** +<additions> -<deletions>，<changedFiles> 个文件
**CI 状态:** [✓ 通过 / ✗ 失败 / ⏳ 进行中]
**检测语言:** [Go, Python, Shell]
**工具状态:** [✓ gofmt] [✓ golangci-lint] [✗ shellcheck 未安装]
**总体评价:** [通过 / 需要修改 / 需要重写]
**发现数:** Critical: N, High: N, Medium: N, Low: N

## PR 描述审查
- 标题: [✓ / ✗ 问题描述]
- 描述: [✓ / ✗ 问题描述]
- 测试: [✓ / ✗ 问题描述]
- Breaking Changes: [无 / 有，已标注 / 有，未标注]

## 发现
(按 Critical → High → Medium → Low 排序，格式同 local-review)

## 亮点
- [做得好的地方]

## 建议
- [可选改进建议]
```

**决策建议:**
- 存在 Critical（含 CI 失败）→ Request Changes
- 存在 High 但无 Critical → Request Changes
- 仅 Medium/Low → Approve（附 Comment）
- 无发现 → Approve
