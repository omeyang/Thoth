# 本地审查流程（单 Agent 5 步）

本文档定义 `/cr local` 模式的完整审查流程。

---

## 语言检测

扫描目标路径的文件扩展名和项目配置，确定涉及的语言：

| 信号 | 语言 |
|------|------|
| `.go` 文件 或 `go.mod` | Go |
| `.py` 文件 或 `pyproject.toml` / `setup.py` / `requirements.txt` | Python |
| `.sh` / `.bash` 文件 | Shell |

多语言项目同时应用所有检测到的语言规则。

---

## 工具矩阵

按检测到的语言，执行对应的自动化工具。工具不可用时跳过并在报告中标注。

| 语言 | 格式检查 | 静态分析 | 类型/安全 |
|------|---------|---------|----------|
| Go | `gofmt -l` | `golangci-lint run` | `go vet` |
| Python | `ruff format --check` | `ruff check` | `mypy`（如有 mypy 配置） |
| Shell | — | `shellcheck` | `bash -n`（语法检查） |

**工具可用性检查:** 执行前先用 `which <tool>` 验证工具存在。不可用时在报告中标注"[工具不可用] <tool> 未安装，跳过自动检查"。

---

## 5 步审查流程

### 第 1 步：确定范围

根据 `$ARGUMENTS` 解析审查范围：

| 参数形式 | 范围确定方式 |
|---------|------------|
| 空参数 + `git status` 有变更 | `git diff HEAD`（未提交的变更） |
| 空参数 + 无变更 | `git diff $(git merge-base origin/main HEAD)..HEAD`（当前分支所有变更） |
| 文件路径（如 `pkg/auth/handler.go`） | 读取指定文件 |
| 目录路径（如 `pkg/auth/`） | 读取目录下所有源代码文件 |
| commit hash（如 `abc1234`） | `git show <hash>`（单个提交的变更） |
| commit 范围（如 `abc..def`） | `git diff <range>`（范围内的变更） |

**文件数量限制:** 变更文件超过 50 个时，按变更行数降序取 Top 20，其余文件标注"[未审查] 文件过多，优先审查变更量最大的文件"。

执行操作：
1. 确定范围后，获取完整 diff 或文件内容
2. 统计涉及的文件列表和变更行数
3. 扫描文件扩展名，执行语言检测

### 第 2 步：工具扫描

按语言检测结果执行工具矩阵中的对应工具：

1. **检查工具可用性** — 对每个工具执行 `which <tool>`
2. **执行可用工具** — 收集所有输出，标记每个发现的来源工具
3. **记录不可用工具** — 在报告中明确标注

Go 项目执行示例：
```bash
# 格式检查
gofmt -l ./...
# 静态分析（在 go.mod 所在目录执行）
golangci-lint run ./...
# 类型检查
go vet ./...
```

Python 项目执行示例：
```bash
# 格式检查
ruff format --check .
# 静态分析
ruff check .
# 类型检查（如有配置）
mypy .
```

Shell 项目执行示例：
```bash
# 静态分析（对每个 .sh 文件）
shellcheck *.sh
# 语法检查
bash -n script.sh
```

### 第 3 步：检查清单审查

读取 `references/code-checklist.md`，按 **A → B → C** 优先级逐项检查变更代码。

执行方式：
1. 加载检查清单中与检测语言匹配的所有条目
2. **A 级（阻塞）** — 逐项严格检查，必须覆盖每一条
3. **B 级（重要）** — 逐项检查，记录所有发现
4. **C 级（建议）** — 快速扫描，记录明显问题

每个发现必须包含：
- **文件:行号** — 精确位置
- **代码片段** — 相关代码上下文（3-5 行）
- **问题描述** — 违反了哪条检查项
- **修复建议** — 具体的修复方案或代码示例

如果变更涉及文档文件（`.md`、`README`、`doc.go`、docstring），同时参照 `references/doc-checklist.md` 检查。

### 第 4 步：风险裁决

对第 2 步和第 3 步的所有发现，参照 `references/judgment-matrix.md` 进行风险等级标注：

1. **查找默认等级** — 在 judgment-matrix.md 的语言风险映射表中查找该问题的默认等级
2. **检查上下文豁免** — 是否满足降级条件（如测试文件、CLI 工具、内部代码等）
3. **最终标注** — Critical / High / Medium / Low

**去重规则:** 工具扫描和检查清单发现同一问题时，合并为一条，保留更高风险等级。

### 第 5 步：输出报告

按 SKILL.md 中定义的统一报告格式输出，补充以下信息：

```markdown
## 审查摘要

**审查模式:** local
**变更概述:** [一句话描述变更目的]
**审查范围:** [文件列表或 diff 来源]
**检测语言:** [Go, Python, Shell]
**工具状态:** [✓ gofmt] [✓ golangci-lint] [✗ mypy 未安装]
**总体评价:** [通过 / 需要修改 / 需要重写]
**发现数:** Critical: N, High: N, Medium: N, Low: N

## 发现
(按 Critical → High → Medium → Low 排序)

### [Critical] 标题
- **文件:** path/to/file:42
- **语言:** Go
- **来源:** golangci-lint / checklist-A3
- **问题:** 具体描述
- **建议:** 修复方案 + 代码示例
- **风险等级:** Critical — [judgment-matrix.md 中的依据]

## 亮点
- [代码中做得好的地方，至少列出 1 项]

## 建议
- [可选改进建议，非阻塞]

## 工具输出摘要
- gofmt: [N 个文件需要格式化]
- golangci-lint: [N 个问题]
- go vet: [通过 / N 个问题]
```

**决策建议:**
- 存在 Critical → 总体评价"需要重写"或"需要修改"
- 存在 High 但无 Critical → "需要修改"
- 仅 Medium/Low → "通过"（附建议）

**演化触发:** 报告输出后，检查是否有发现值得记录到 `references/checklist-evolution.md`（新发现的模式、工具误报等）。
