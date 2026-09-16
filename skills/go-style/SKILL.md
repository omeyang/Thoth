---
name: go-style
description: "Go 代码规范与后端开发专家 - 接口设计(使用方定义)、并发安全(goroutine退出策略)、错误处理(%w包装)、命名规范、HTTP服务(handler/路由/中间件/JSON helper)、项目结构(cmd/internal/pkg)、API设计(函数选项/Context)、golangci-lint配置。适用：代码审查、Go惯用法重构、HTTP后端开发、API设计、项目结构规划。不适用：非Go语言项目、前端开发、纯算法实现(应使用algorithms技能)。触发词：go style, 代码规范, code review, 代码审查, http handler, 中间件, middleware, 项目结构, 命名规范, golangci-lint, 惯用法, idiomatic go"
user-invocable: true
allowed-tools: Bash, Read, Write, Edit, Grep, Glob
---

# Go 代码规范与后端开发专家

审查或编写符合 Go 惯用法的代码：$ARGUMENTS

---

## 第一部分：代码审查检查清单

### 1. 接口设计

```go
// ✅ 正确：接口在使用方定义
// consumer/service.go
type UserFetcher interface {
    FetchUser(ctx context.Context, id string) (*User, error)
}

// ❌ 错误：接口在实现方定义
// provider/user.go
type UserService interface { ... } // 不要这样
```

**原则**：
- 接口应在**使用方**定义，而非实现方
- 函数应返回**具体类型**，而非接口（便于扩展）

### 2. 并发安全

```go
// ❌ 危险：无退出策略的 goroutine
go func() {
    for {
        doWork() // 永远不会退出！
    }
}()

// ✅ 正确：有明确退出机制
go func() {
    for {
        select {
        case <-ctx.Done():
            return // 有退出路径
        case task := <-tasks:
            doWork(task)
        }
    }
}()
```

**检查点**：
- 每个 `go func()` 必须有退出策略（context 或 channel）
- `sync.Mutex` 持有时间是否过长？
- Channel 用于**协调/信号**，Mutex 用于**数据访问**

### 3. 错误处理

```go
// ✅ 正确：使用 %w 包装错误
return fmt.Errorf("parse config: %w", err)

// ✅ 正确：错误字符串小写，无标点
var ErrNotFound = errors.New("user not found")

// ❌ 错误
var ErrNotFound = errors.New("User not found.") // 大写+标点
```

**原则**：
- 使用 `%w` 包装错误以保留错误链
- 错误字符串小写，无结尾标点
- **不要 panic**，除非是不可恢复的启动错误

### 4. 命名规范

```go
// ✅ 正确
var userID string       // 驼峰命名
func ServeHTTP()        // 缩写全大写
func (s *Server) Run()  // 接收者 1-2 字母

// ❌ 错误
var user_id string      // 下划线
func ServeHttp()        // 缩写不一致
func (server *Server) Run() // 接收者名太长
```

### 5. 复杂度控制

- **清晰 > 聪明**：如果需要思考两次才能理解，就太复杂了
- **避免反射**：除非编写序列化库
- **避免过度抽象**：三行相似代码比过早抽象更好

---

## 第二部分：HTTP 服务开发模式

### 1. Handler 签名模式

标准 `http.Handler` 是 void 返回，导致重复的错误处理。

```go
// 定义返回 error 的 handler 类型
type Handler func(w http.ResponseWriter, r *http.Request) error

func (h Handler) ServeHTTP(w http.ResponseWriter, r *http.Request) {
    if err := h(w, r); err != nil {
        // 集中式错误处理
        var apiErr *APIError
        if errors.As(err, &apiErr) {
            http.Error(w, apiErr.Message, apiErr.Code)
            return
        }
        http.Error(w, "Internal Server Error", 500)
    }
}
```

### 2. 依赖注入

使用结构体持有依赖，不使用全局变量。

```go
type Server struct {
    db     *sql.DB
    cache  *redis.Client
    logger *slog.Logger
}

func NewServer(db *sql.DB, cache *redis.Client, logger *slog.Logger) *Server {
    return &Server{
        db:     db,
        cache:  cache,
        logger: logger,
    }
}
```

### 3. 集中式路由

不要分散 `http.Handle` 调用，返回单一 handler。

```go
func (s *Server) Routes() http.Handler {
    mux := http.NewServeMux()

    // RESTful 风格（Go 1.22+）
    mux.Handle("GET /users", s.handleListUsers())
    mux.Handle("POST /users", s.handleCreateUser())
    mux.Handle("GET /users/{id}", s.handleGetUser())
    mux.Handle("PUT /users/{id}", s.handleUpdateUser())
    mux.Handle("DELETE /users/{id}", s.handleDeleteUser())

    return mux
}
```

### 4. JSON 编解码 Helper

不要在每个 handler 中手动解码 JSON。

```go
func decode[T any](r *http.Request) (T, error) {
    var v T
    if err := json.NewDecoder(r.Body).Decode(&v); err != nil {
        return v, fmt.Errorf("decode json: %w", err)
    }
    return v, nil
}

func encode[T any](w http.ResponseWriter, status int, v T) error {
    w.Header().Set("Content-Type", "application/json")
    w.WriteHeader(status)
    return json.NewEncoder(w).Encode(v)
}

// 使用
func (s *Server) handleCreateUser() Handler {
    return func(w http.ResponseWriter, r *http.Request) error {
        req, err := decode[CreateUserRequest](r)
        if err != nil {
            return &APIError{Code: 400, Message: "invalid request"}
        }

        user, err := s.userService.Create(r.Context(), req)
        if err != nil {
            return err
        }

        return encode(w, http.StatusCreated, user)
    }
}
```

### 5. 中间件

用于横切关注点，保持业务逻辑在 handler 中。

```go
func LoggingMiddleware(logger *slog.Logger) func(http.Handler) http.Handler {
    return func(next http.Handler) http.Handler {
        return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
            start := time.Now()
            next.ServeHTTP(w, r)
            logger.Info("request",
                "method", r.Method,
                "path", r.URL.Path,
                "duration", time.Since(start),
            )
        })
    }
}

func RecoveryMiddleware(next http.Handler) http.Handler {
    return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
        defer func() {
            if err := recover(); err != nil {
                http.Error(w, "Internal Server Error", 500)
            }
        }()
        next.ServeHTTP(w, r)
    })
}

// 组合
handler := RecoveryMiddleware(LoggingMiddleware(logger)(s.Routes()))
```

---

## 第三部分：项目结构

### 标准布局

```
project/
├── cmd/
│   └── api/
│       └── main.go          # 入口点，保持精简
├── internal/                 # 私有代码
│   ├── user/                 # 按领域/功能组织
│   │   ├── handler.go
│   │   ├── service.go
│   │   ├── repository.go
│   │   └── user.go
│   └── platform/             # 基础设施
│       ├── database/
│       └── logger/
├── pkg/                      # 公开库（可选）
├── api/                      # OpenAPI/Proto 定义
├── go.mod
└── go.sum
```

**原则**：
- `cmd/<app>/main.go`：入口点，保持极简
- `internal/`：私有代码，外部不可导入
- `pkg/`：仅当**明确**需要外部导入时使用
- 按**领域/功能**组织，而非按层（如 handlers/services/）

### main.go 模式

```go
package main

import (
    "context"
    "fmt"
    "os"
    "os/signal"
    "syscall"
)

func main() {
    if err := run(context.Background(), os.Args, os.Environ()); err != nil {
        fmt.Fprintf(os.Stderr, "error: %v\n", err)
        os.Exit(1)
    }
}

func run(ctx context.Context, args []string, env []string) error {
    // 1. 解析配置（flags/env）
    cfg, err := config.Load(env)
    if err != nil {
        return fmt.Errorf("load config: %w", err)
    }

    // 2. 初始化依赖
    db, err := database.Connect(ctx, cfg.DatabaseURL)
    if err != nil {
        return fmt.Errorf("connect database: %w", err)
    }
    defer db.Close()

    logger := slog.New(slog.NewJSONHandler(os.Stdout, nil))

    // 3. 创建服务
    srv := server.New(db, logger)

    // 4. 启动 HTTP 服务器
    httpServer := &http.Server{
        Addr:    cfg.Addr,
        Handler: srv.Routes(),
    }

    // 5. 优雅关闭
    ctx, stop := signal.NotifyContext(ctx, syscall.SIGINT, syscall.SIGTERM)
    defer stop()

    go func() {
        <-ctx.Done()
        httpServer.Shutdown(context.Background())
    }()

    logger.Info("server starting", "addr", cfg.Addr)
    return httpServer.ListenAndServe()
}
```

---

## 第四部分：API 设计

### 函数选项模式

```go
type Option func(*Config)

func WithTimeout(d time.Duration) Option {
    return func(c *Config) { c.Timeout = d }
}

func WithRetries(n int) Option {
    return func(c *Config) { c.Retries = n }
}

func NewClient(addr string, opts ...Option) *Client {
    cfg := &Config{
        Timeout: 30 * time.Second,
        Retries: 3,
    }
    for _, opt := range opts {
        opt(cfg)
    }
    return &Client{addr: addr, config: cfg}
}
```

### Context 使用

```go
// ✅ 正确：Context 作为第一个参数
func (s *Service) GetUser(ctx context.Context, id string) (*User, error)

// ❌ 错误：不要存储 Context
type Service struct {
    ctx context.Context // 不要这样做
}
```

---

## 第五部分：代码检查

### 命令

```bash
# 格式化
gofmt -w .
goimports -w .

# 静态分析
go vet ./...
golangci-lint run ./...

# 构建验证
go build ./...
```

### .golangci.yml 推荐配置

```yaml
linters:
  enable:
    - errcheck      # 未处理的错误
    - govet         # 官方静态分析
    - staticcheck   # 高级静态分析
    - unused        # 未使用的代码
    - ineffassign   # 无效赋值
    - misspell      # 拼写检查
    - gofmt         # 格式化检查
    - goimports     # 导入检查

linters-settings:
  errcheck:
    check-blank: true
```

---

## 第六部分：文档规范

### 包文档（doc.go）

```go
// Package user provides user management functionality including
// authentication, authorization, and profile management.
//
// Basic usage:
//
//     svc := user.NewService(db)
//     user, err := svc.GetByID(ctx, "user-123")
package user
```

### 函数文档

```go
// GetByID retrieves a user by their unique identifier.
// It returns ErrNotFound if no user exists with the given ID.
//
// GetByID is safe for concurrent use.
func (s *Service) GetByID(ctx context.Context, id string) (*User, error)
```

---

## 审查检查清单

### 必须检查

- [ ] 接口在使用方定义？
- [ ] 函数返回具体类型？
- [ ] 所有 goroutine 有退出机制？
- [ ] 错误使用 `%w` 包装？
- [ ] 错误字符串小写无标点？
- [ ] 没有 panic（除非不可恢复）？
- [ ] 命名符合 Go 惯例？
- [ ] 没有全局状态？
- [ ] Context 正确传递？
- [ ] 通过 golangci-lint？

### HTTP 服务检查

- [ ] 依赖通过构造函数注入？
- [ ] 路由集中定义？
- [ ] 有 JSON 编解码 helper？
- [ ] 中间件只处理横切关注点？
- [ ] 支持优雅关闭？

---

## 工作流：添加 API 端点

1. 检查 `routes.go` 和 `server.go`
2. 定义请求/响应结构体
3. 实现 handler 方法
4. 在 `Routes()` 中注册路由
5. 添加测试用例
6. 验证编译和测试通过

## 工作流：代码审查

1. 理解代码功能
2. 对照检查清单审查
3. 提供可操作的反馈：
   - "这个接口在实现方定义，应移到使用方"
   - "这个 goroutine 可能泄漏，因为没有检查 ctx"
