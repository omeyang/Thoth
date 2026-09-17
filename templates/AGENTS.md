# {{PROJECT_NAME}}

Codex 项目指令。Codex 逐级读取仓库根到当前目录的 `AGENTS.md`，总量上限 32 KiB，正文保持简短。

## 任务入口

| 任务 | 命令 |
|------|------|
| 构建 | `go build ./...` |
| 测试 | `go test -race -count=1 ./...` |
| Lint | `golangci-lint run ./...`（v2.8.0） |

## 硬约束

- Go 版本固定 go1.24.6；不使用 1.25+ API。
- 工程标准以 [Maat](https://github.com/omeyang/Maat) 为准。
- 提交信息遵循 Conventional Commits。
- 不读写 `.env`、`*.pem`、`id_rsa`、`credentials.json`。

## 技能

Thoth 插件提供 Go 后端技能（`$cr`、`$go-test`、`$kafka-go` 等）。遇到中间件、性能、审查任务先调用对应技能，再动手。
