# hooks

Thoth 插件自带的事件钩子。安装插件后自动生效，无需复制脚本或改 settings.json。定义在 [hooks.json](./hooks.json)，脚本在 [scripts/](./scripts/)。

## 钩子清单

| 事件 | 匹配 | 脚本 | 作用 |
|------|------|------|------|
| `SessionStart` | — | `session-context.sh` | 注入 Git 分支/状态、K8s context、Go 版本、Docker 容器 |
| `PreToolUse` | `Bash` | `block-dangerous.sh` | 拦截 `rm -rf`、生产 `kubectl delete`、`DROP/FLUSH`、force push 到 main、`git reset --hard`、系统目录改动、`docker system prune -a` |
| `PreToolUse` | `Bash(git commit*)` | `commit-lint.sh` | 检查 Conventional Commits 格式 |
| `PreToolUse` | `Read/Edit/Write/Bash` | `protect-secrets.sh` | 拦截 `.env`、`*.pem`、`id_rsa`、`credentials.json` 以及 `~/.aws` `~/.ssh` `~/.kube` 等凭证读写；放行 `.env.example` |
| `PostToolUse` | `Edit/Write` | `go-format.sh` | `.go` 文件执行 `goimports`（无则 `gofmt`） |
| `PostToolUse` | `Edit/Write` | `go-lint.sh` | 对所在包执行 `golangci-lint run`，有问题以 exit 2 回传 |
| `PostToolUse` | `Edit/Write` | `go-test-async.sh` | 异步 `go test -race` 所在包，结果通过 `systemMessage` 回传 |

非 Go 文件的编辑不会触发格式化、lint 与测试，三个脚本在文件扩展名不是 `.go` 时直接退出。

## 退出码约定

| 退出码 | 含义 |
|--------|------|
| 0 | 放行；stdout 里的 JSON 会被解析 |
| 2 | 阻止；stderr 回传给模型说明原因 |
| 其他 | 非阻塞错误，仅记录 |

## 前置依赖

- `jq`（所有脚本解析 stdin JSON）
- `goimports`：`go install golang.org/x/tools/cmd/goimports@v0.42.0`
- `golangci-lint` v2.8.0：`go install github.com/golangci/golangci-lint/v2/cmd/golangci-lint@v2.8.0`

## Codex

Codex 的钩子（`~/.codex/hooks.json` 或仓库 `.codex/hooks.json`）使用同样的 stdin JSON 与退出码语义，脚本可以直接复用，事件名相同（`SessionStart`、`PreToolUse`、`PostToolUse`）。
