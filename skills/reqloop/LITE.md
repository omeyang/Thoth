# reqloop-lite — 轻量验收模式

## 定位

企业外 / 开源项目 / 单仓库团队：没有需求管理系统、CI 平台、自动化测试平台，但同样需要 AI 做需求验收闭环。
Lite 模式 = 主流水线 + 内置 `lite` 适配器（[adapters/lite/](adapters/lite/)），5 个槽位的具体做法见该目录下的槽位文件。

触发方式：`/reqloop <id> --lite`、`/reqloop lite <id>`、`/reqloop-lite <id>`，三者等价于 `--adapter lite`。

核心能力**不降级**：EARS 反讲 + 硬门禁 + 判定三元组 + 决策链 + 负向影响分析 + 安全例外全部保留。

## 与企业适配器的差异

| 能力 | 企业适配器 | lite |
|------|-----------|------|
| 需求来源 | 需求管理系统按 ID 拉取 | PR 描述 / commit message / issue / 用户粘贴（+ 可选 PRD 文件） |
| 代码采集 | 多仓库 MR / diff | 当前 git 仓库 `git diff base..HEAD` / `gh pr diff` |
| CI | 平台指定环境 | 本地 `make test` / `go test` / 用户自定义命令 |
| e2e | 测试平台 | **跳过或人工执行**（或本地脚本） |
| 缺陷回写 | 缺陷系统 | `gh issue create` 命令清单 + 本地 Markdown 清单 |
| 依赖图 | code-review-graph | code-review-graph 不可用时退化为 `go list -deps` / tree-sitter |
| 跨仓库 | 支持 | 不支持（标记 `cross_repo: unsupported`） |

## 零配置推断与确认

Lite 优先自动推断所有输入，**仅在推断失败时才交互询问**（推断策略详见各槽位文件）：

| 输入项 | 推断来源 | 推断失败时 |
|--------|---------|-----------|
| 需求描述 | PR body → commit message → issue | 请用户粘贴 |
| 代码范围 | 分支 upstream diff → `gh pr diff` | 请用户选择 |
| 验证命令 | Makefile / go.mod / package.json / Cargo.toml | 请用户输入 |
| e2e | 默认跳过（结论最高"有条件通过"）| — |

**推断结果须在执行前一次性展示确认**，不逐条问：

```
/reqloop PR-42 --lite

AI: 适配器：lite（内置）
  需求描述: [PR #42 body 摘要前 3 行...]
  代码范围: git diff main..HEAD (12 files changed)
  验证命令: go test ./... && go vet ./... && golangci-lint run
  e2e: 跳过
  > 确认 (Y/n) 或输入修改项编号:
```

`--interactive` 强制逐项交互；`.reqloop.yaml` 的 `base` / `test_cmd` 可固定这些值（见 `adapters/README.md`）。

## Monorepo / 跨模块

- **Go workspace / Nx / Turborepo / 目录级 monorepo**：单仓多模块，lite **完全支持**，按模块归档 diff，模块间影响分析（阶段 4b）正常执行
- **真正的跨仓库**（不同 git remote）：lite 不支持，提示改用企业适配器

## 阶段行为差异

| 阶段 | 差异 |
|------|------|
| 1-2 采集 | 合并为一步；`req-{id}.md` 由推断文本 + git log 生成，`code-{id}/` 按模块拆 diff |
| 3 反讲 | **不变**。这是 lite 的核心价值——没有企业工具链，反讲门禁依然生效 |
| 4a review | code-review-graph 不可用时改用 `go list -deps` + 简易 importer 生成一阶调用关系；跨语言项目标 `partial_graph: true` |
| 4b 影响分析 | 深度限制 2（企业适配器默认 3）；跨仓库影响标 `unknown` |
| 5 runtime | 本地执行验证命令，覆盖矩阵照常生成 |
| 6 e2e | 跳过时矩阵 e2e 列固定 `skipped`，结论最高"有条件通过" |
| 7 report | 缺陷回写改为 `gh issue create` 清单（用户确认后执行）或本地清单 |
| 8 export | 不变——lite 用户最需要 OSLC / ReqIF / CSV 回流到 ALM |

## 依赖清单

**必需**：`git`、语言对应的 test runner（用户提供命令即可）
**可选增强**：`gh`（PR 采集与 issue 回写）、`tree-sitter`（多语言反向调用链）、`go list`（Go 依赖分析）、`ripgrep`（锚点定位）

## 开源分发

lite 适配器不含任何企业工具引用，`reqloop-lite` 是插件内的独立 skill：入口 `../reqloop-lite/SKILL.md`，复用本目录的 `stages/`、`templates/`、`adapters/lite/`。
业界 Spec Kit / Kiro 都做"正向"（spec → code），没有等价的反向验收开源工具，这是 Thoth 对外最有差异化的素材。
