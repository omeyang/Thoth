# /cr 技能诊断指南

当 `/cr` 技能运行异常时，使用本文档进行诊断和修复。

---

## 症状诊断表

### 模式检测问题

| 症状 | 可能原因 | 诊断步骤 | 修复方案 |
|------|---------|---------|---------|
| PR 编号未识别为 PR 模式 | 参数格式不匹配 | 检查 `$ARGUMENTS` 是否包含 `#\d+` 或 GitHub URL | 确保使用 `#123` 或完整 PR URL 格式 |
| 总是进入 local 模式 | 路径关键词误匹配 | 检查参数是否意外包含 `/` 或文件扩展名 | 明确使用 `teams` 或 `#N` 关键词 |
| 自动检测选择了错误模式 | git status 状态判断有误 | 运行 `git status --porcelain` 确认状态 | 手动指定模式：`/cr local`、`/cr #N`、`/cr teams` |

### 审查质量问题

| 症状 | 可能原因 | 诊断步骤 | 修复方案 |
|------|---------|---------|---------|
| 大量误报 | 检查清单条目过于严格 | 查看 Rejected 发现的检查项 ID | 按 `checklist-evolution.md` 记录并收窄条件 |
| 明显问题未发现 | 检查清单缺少条目 | 对比问题与 `code-checklist.md` | 按 `checklist-evolution.md` 新增条目 |
| 语言未检测到 | 文件扩展名不在检测列表中 | 检查目标路径中的文件类型 | 确认文件使用标准扩展名（`.go`/`.py`/`.sh`） |
| 风险等级不合理 | 上下文豁免未应用或误用 | 对照 `judgment-matrix.md` 的豁免规则 | 调整豁免规则或报告修正 |

### 工具执行问题

| 症状 | 可能原因 | 诊断步骤 | 修复方案 |
|------|---------|---------|---------|
| 工具报告"未安装" | 工具不在 PATH 中 | 运行对应的可用性检查命令 | 安装工具或调整 PATH |
| golangci-lint 超时 | 项目过大或配置过重 | 检查 `.golangci.yml` 和项目大小 | 添加 `--timeout` 参数或限制检查范围 |
| gh CLI 认证失败 | 未登录或 Token 过期 | 运行 `gh auth status` | 运行 `gh auth login` 重新认证 |
| teams 模式 Agent 失败 | Task 调用超时或 Agent 错误 | 检查 Task 返回的错误信息 | 降级为 local 模式（自动） |

---

## 工具可用性快速检查

运行以下命令验证所有工具的可用状态：

### Go 工具链

```bash
echo "=== Go 工具链 ==="
echo -n "go:            "; go version 2>/dev/null || echo "NOT FOUND"
echo -n "gofmt:         "; which gofmt 2>/dev/null || echo "NOT FOUND"
echo -n "golangci-lint: "; golangci-lint version 2>/dev/null || echo "NOT FOUND"
echo -n "go vet:        "; go vet --help >/dev/null 2>&1 && echo "OK" || echo "NOT FOUND"
echo -n "govulncheck:   "; govulncheck -version 2>/dev/null || echo "NOT FOUND"
```

### Python 工具链

```bash
echo "=== Python 工具链 ==="
echo -n "python:  "; python3 --version 2>/dev/null || echo "NOT FOUND"
echo -n "ruff:    "; ruff version 2>/dev/null || echo "NOT FOUND"
echo -n "mypy:    "; mypy --version 2>/dev/null || echo "NOT FOUND"
```

### Shell 工具链

```bash
echo "=== Shell 工具链 ==="
echo -n "shellcheck: "; shellcheck --version 2>/dev/null | head -2 || echo "NOT FOUND"
echo -n "bash:       "; bash --version 2>/dev/null | head -1 || echo "NOT FOUND"
```

### 通用工具

```bash
echo "=== 通用工具 ==="
echo -n "git: "; git version 2>/dev/null || echo "NOT FOUND"
echo -n "gh:  "; gh version 2>/dev/null | head -1 || echo "NOT FOUND"
echo -n "gh auth: "; gh auth status 2>/dev/null | head -2 || echo "NOT AUTHENTICATED"
```

---

## 完整诊断流程

执行 `/cr diagnosis` 时按以下步骤进行：

1. **环境检查** — 运行上述工具可用性检查命令
2. **配置检查** — 验证引用文件存在：
   ```bash
   ls skills/cr/references/*.md
   ls agents/code-reviewer/AGENT.md
   ls agents/security-auditor/AGENT.md
   ```
3. **Git 状态检查** — 确认 git 仓库状态正常：
   ```bash
   git status
   git remote -v
   ```
4. **输出诊断报告**：
   ```markdown
   ## /cr 诊断报告

   ### 工具状态
   | 工具 | 状态 | 版本 |
   |------|------|------|
   | go | ✓/✗ | vX.Y.Z |
   | ... | ... | ... |

   ### 配置文件
   | 文件 | 状态 |
   |------|------|
   | references/code-checklist.md | ✓/✗ |
   | ... | ... |

   ### 建议
   - [需要安装或修复的工具]
   - [需要处理的配置问题]
   ```
