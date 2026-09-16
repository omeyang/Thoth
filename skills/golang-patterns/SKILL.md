---
name: golang-patterns
description: "Go 惯用模式专家 - 简洁设计、零值可用、接口设计、错误处理、并发模式、内存优化、项目布局。适用：编写新 Go 代码、代码审查、重构优化、性能调优、项目结构设计。不适用：非 Go 语言项目、纯业务逻辑讨论（无 Go 模式需求）、底层系统编程（CGO/汇编）。触发词：Go pattern, idiomatic Go, error handling, concurrency, goroutine, channel, interface, option pattern, sync.Pool, 惯用法, 模式, 并发, 错误处理"
user-invocable: true
allowed-tools: Bash, Read, Write, Edit, Grep, Glob
---

# Go 惯用模式专家

应用 Go 惯用模式编写或审查代码：$ARGUMENTS

---

## 核心原则

### 1. 简洁胜于聪明

Go 代码应该一目了然，不需要思考两次。

```go
// Y: 清晰直接
func GetUser(id string) (*User, error) {
    user, err := db.FindUser(id)
    if err != nil {
        return nil, fmt.Errorf("get user %s: %w", id, err)
    }
    return user, nil
}
```

### 2. 零值可用

设计类型使其零值立即可用，无需初始化。`sync.Mutex` 零值可用，`bytes.Buffer` 零值可用，但 `map` 零值是 nil 会 panic。

### 3. 接收接口，返回具体类型

函数接收 `io.Reader` 等接口参数，返回 `*Result` 等具体类型。不要不必要地返回接口。

---

## 错误处理模式

- **%w 包装**：`fmt.Errorf("load config %s: %w", path, err)` - 保留错误链
- **自定义错误类型**：`ValidationError{Field, Message}` 实现 `error` 接口
- **哨兵错误**：`var ErrNotFound = errors.New("resource not found")`
- **errors.Is / errors.As**：检查特定错误值或错误类型
- **永不忽略错误**：除非明确注释原因

---

## 并发模式

- **Worker Pool**：N 个 goroutine 从 jobs channel 读取，结果写入 results channel
- **Context 取消和超时**：`context.WithTimeout` + `http.NewRequestWithContext`
- **优雅关闭**：`signal.Notify(quit, SIGINT, SIGTERM)` + `server.Shutdown(ctx)`
- **errgroup 协调并发**：`errgroup.WithContext` 并行获取，任一失败则全部取消
- **避免 Goroutine 泄漏**：使用缓冲 channel + select ctx.Done()

---

## 接口设计

- **小而专注**：单方法接口（Reader, Writer, Closer），按需组合
- **在使用方定义**：消费方包定义所需接口，实现方不需知道
- **可选行为的类型断言**：`if f, ok := w.(Flusher); ok { f.Flush() }`

---

## 结构体设计

- **函数选项模式**：`type Option func(*Server)` + `WithTimeout(d)` + `WithLogger(l)`
- **嵌入实现组合**：嵌入 `*Logger` 让 Server 获得 `Log` 方法

---

## 内存和性能

- **预分配切片**：`make([]Result, 0, len(items))`
- **sync.Pool**：频繁分配的对象（如 bytes.Buffer）复用
- **避免循环中的字符串拼接**：使用 `strings.Builder` 或 `strings.Join`

---

## 项目布局

```
myproject/
├── cmd/myapp/main.go       # 入口点
├── internal/
│   ├── handler/             # HTTP handlers
│   ├── service/             # 业务逻辑
│   ├── repository/          # 数据访问
│   └── config/              # 配置
├── pkg/client/              # 公开 API 客户端
├── api/v1/                  # API 定义
├── testdata/                # 测试数据
├── go.mod
└── Makefile
```

---

## Go 工具命令

```bash
go build ./...              # 构建
go test ./... -race -cover  # 测试（竞态检测+覆盖率）
go vet ./...                # 静态分析
golangci-lint run           # Lint
go mod tidy                 # 模块整理
goimports -w .              # 格式化
```

---

## 速查表：Go 惯用法

| 惯用法 | 描述 |
|--------|------|
| 接收接口，返回具体类型 | 函数接收接口参数，返回具体类型 |
| 错误是值 | 把错误当作一等值处理，不是异常 |
| 不要通过共享内存来通信 | 使用 channel 协调 goroutine |
| 零值可用 | 类型无需显式初始化就能工作 |
| 少量复制优于少量依赖 | 避免不必要的外部依赖 |
| 清晰优于聪明 | 优先考虑可读性 |
| gofmt 是所有人的朋友 | 始终用 gofmt/goimports 格式化 |
| 尽早返回 | 先处理错误，保持主路径不缩进 |

---

## 反模式避免

- 长函数中的裸返回（返回值不清晰）
- 用 `panic` 控制流程（应使用 error）
- 在结构体中存储 context（应作为第一个参数）
- 混用值接收者和指针接收者（选择一种保持一致）

**记住**：Go 代码应该以最好的方式保持无聊 - 可预测、一致、易于理解。有疑问时，保持简单。

## 参考资料

- [完整代码示例](references/examples.md) - 错误处理、并发模式、接口设计、结构体设计、内存优化的完整 Go 实现
