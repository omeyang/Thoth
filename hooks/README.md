# hooks

用于验证、策略检查和自动化的事件驱动扩展点。

## 目录结构

```
hooks/
├── README.md
├── scripts/             # 可复用的 hook 脚本
│   ├── go-format.sh     # Go 文件自动格式化 (goimports + gofmt)
│   ├── go-lint.sh       # Go 文件自动 lint (golangci-lint)
│   ├── go-test-async.sh # 异步运行受影响包的测试
│   ├── block-dangerous.sh # 拦截高风险命令
│   ├── session-context.sh # 会话启动上下文注入
│   └── commit-lint.sh   # Conventional Commits 格式检查
└── configs/             # settings.json 配置模板
    ├── settings.json         # 完整配置（推荐）
    └── settings-minimal.json # 最小配置（仅格式化+安全）
```

## 快速开始

### 1. 复制脚本到目标项目

```bash
# 在目标项目根目录下
mkdir -p .claude/hooks
cp /path/to/Thoth/hooks/scripts/*.sh .claude/hooks/
chmod +x .claude/hooks/*.sh
```

### 2. 配置 settings.json

```bash
# 使用完整配置
cp /path/to/Thoth/hooks/configs/settings.json .claude/settings.json

# 或最小配置
cp /path/to/Thoth/hooks/configs/settings-minimal.json .claude/settings.json
```

## Hook 事件参考

| 事件 | 触发时机 | 可阻止？ | 用途 |
|------|---------|---------|------|
| `SessionStart` | 会话启动/恢复 | 否 | 注入上下文 |
| `PreToolUse` | 工具执行前 | 是 | 拦截危险操作 |
| `PostToolUse` | 工具执行后 | 否（仅反馈） | 格式化、lint、测试 |
| `Stop` | Claude 完成回复 | 是 | 验证完成度 |

## 脚本说明

### go-format.sh (PostToolUse)

在 `Edit`/`Write` 操作后自动执行 `goimports`（回退到 `gofmt`）。静默运行，不阻断工作流。

**前置依赖:** `goimports`（`go install golang.org/x/tools/cmd/goimports@latest`）

### go-lint.sh (PostToolUse)

在 `Edit`/`Write` 操作后执行 `golangci-lint`。发现问题时以 exit 2 返回，将错误信息回传给 Claude 自行修复。

**前置依赖:** `golangci-lint`（`go install github.com/golangci/golangci-lint/cmd/golangci-lint@latest`）

### go-test-async.sh (PostToolUse, async)

异步运行受影响包的测试（`go test -race`），不阻断 Claude 的编辑流程。测试结果通过 `systemMessage` 回传。

### block-dangerous.sh (PreToolUse)

拦截以下高风险操作：
- `rm -rf` 递归强制删除
- 生产环境 `kubectl delete/drain/cordon`
- 数据库 `DROP/FLUSH` 操作
- `git push --force` 到 main/master
- `git reset --hard`
- 系统目录修改
- `docker system prune -a`

### session-context.sh (SessionStart)

会话启动时自动注入：
- Git 分支、状态、最近提交
- Kubernetes 当前 context 和 namespace
- Go 版本和模块信息
- Docker 运行中的容器

### commit-lint.sh (PreToolUse)

检查 `git commit -m` 的消息是否遵循 Conventional Commits 规范。

## 退出码约定

| 退出码 | 含义 |
|--------|------|
| 0 | 成功/放行 |
| 1 | 非阻塞错误（仅记录日志） |
| 2 | 阻塞错误（stderr 回传给 Claude） |

## 自定义

所有脚本都可独立使用。根据项目需求选择合适的脚本组合：

- **纯 Go 项目:** go-format + go-lint + go-test-async + block-dangerous
- **Go + K8s 项目:** 全部脚本
- **非 Go 项目:** block-dangerous + session-context（通用安全基线）
