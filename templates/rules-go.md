---
paths:
  - "**/*.go"
  - "go.mod"
---

# Go 代码规则

放到目标项目 `.claude/rules/go.md`。只在读写 Go 文件时加载，正文保持简短；细则由 Thoth 技能（`go-style`、`go-test`、`golang-patterns`）提供。

## 版本

- 工具链 go1.24.6。可用：Swiss map、`weak`、`runtime.AddCleanup`、`os.Root`、`for b.Loop()`、泛型类型别名、`iter`/`slices`/`maps`、`math/rand/v2`。
- 不用 1.25+ API：`sync.WaitGroup.Go`、`T.Output`、`testing/synctest` 正式版、`encoding/json/v2`。

## 代码

- 接口在使用方定义，小接口（1 到 3 个方法）；接受接口，返回具体类型。
- `context.Context` 是第一个参数，不放进 struct。
- 错误：跨包 `fmt.Errorf("op: %w", err)`；判断用 `errors.Is` / `errors.As`；不忽略 error。
- 构造函数返回 `error`，不 `panic`；超过 2 个可选参数用函数选项。
- 并发：goroutine 生命周期绑定 ctx；发送方关闭 channel；fan-out 用 `errgroup`；共享状态用 `sync.Mutex` 或 `atomic`。
- 日志用 `slog`，携带 `trace_id`；指标与追踪走 OpenTelemetry。

## 测试

- 表驱动 + `t.Run` + `t.Parallel()`；基准用 `for b.Loop()`。
- 外部依赖通过接口 mock（`go.uber.org/mock`）；集成测试用 build tag `integration`。
- 提交前 `go test -race -count=1 ./...` 与 `golangci-lint run ./...` 必须通过。
