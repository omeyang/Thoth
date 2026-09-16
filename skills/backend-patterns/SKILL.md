---
name: backend-patterns
description: "Go 后端架构模式专家 - 分层架构(Handler/Service/Repository)、缓存策略(Cache-Aside/Write-Through)、错误处理、认证授权(JWT/RBAC)、限流(令牌桶)、队列、中间件链、结构化日志。适用：系统设计、架构决策、服务开发、API 设计、N+1 查询优化、事务管理。不适用：前端/UI 开发；纯算法或数据结构问题；基础设施运维(K8s/Terraform)。触发词：backend, 后端, architecture, 架构, repository, 缓存, cache, middleware, 中间件, rate-limit, 限流, JWT, RBAC, REST, API设计, 分层"
user-invocable: true
allowed-tools: Bash, Read, Write, Edit, Grep, Glob
---

# 后端架构模式专家

应用后端架构模式设计或实现服务：$ARGUMENTS

---

## API 设计模式

### RESTful API 结构

```go
// 资源导向的 URL 设计
GET    /api/v1/users              // 列出资源
GET    /api/v1/users/:id          // 获取单个资源
POST   /api/v1/users              // 创建资源
PUT    /api/v1/users/:id          // 替换资源
PATCH  /api/v1/users/:id          // 更新资源
DELETE /api/v1/users/:id          // 删除资源

// 查询参数用于过滤、排序、分页
GET /api/v1/users?status=active&sort=created_at&limit=20&offset=0
```

### Repository 模式

抽象数据访问逻辑，解耦业务层和存储层。接口定义在使用方。

```go
type UserRepository interface {
    FindAll(ctx context.Context, filters UserFilters) ([]*User, error)
    FindByID(ctx context.Context, id string) (*User, error)
    Create(ctx context.Context, user *User) error
    Update(ctx context.Context, user *User) error
    Delete(ctx context.Context, id string) error
}
```

> 完整 MongoDB 实现见 [references/examples.md](references/examples.md#repository-模式实现)

### Service 层模式

业务逻辑与数据访问分离，依赖注入 Repository 和 Cache。

```go
type UserService struct {
    repo   UserRepository
    cache  CacheService
    logger *slog.Logger
}
```

> 完整 Service 实现（含缓存读取）见 [references/examples.md](references/examples.md#service-层实现)

### 中间件模式

用于请求/响应处理管道，支持链式组合。

```go
type Middleware func(http.Handler) http.Handler

func Chain(h http.Handler, middlewares ...Middleware) http.Handler {
    for i := len(middlewares) - 1; i >= 0; i-- {
        h = middlewares[i](h)
    }
    return h
}
```

> 完整 Logging/Recovery 中间件见 [references/examples.md](references/examples.md#中间件实现)

---

## 数据库模式

### 查询优化

- 只选择需要的列，避免 `SELECT *`
- 避免 N+1 查询：批量获取关联数据，用 map 组装

> 完整 N+1 修复示例见 [references/examples.md](references/examples.md#避免-n1-查询)

### 事务模式

```go
type TxManager interface {
    WithTransaction(ctx context.Context, fn func(ctx context.Context) error) error
}
```

> 完整 MongoDB 事务实现见 [references/examples.md](references/examples.md#事务模式实现)

---

## 缓存策略

### Cache-Aside 模式

读取：先查缓存 -> 未命中查 DB -> 写入缓存。更新：写 DB -> 失效缓存。

### Write-Through 模式

写入：写 DB -> 同时写缓存。

> 完整 CachedUserRepository 实现见 [references/examples.md](references/examples.md#缓存策略实现)

---

## 错误处理模式

### 集中式错误处理

统一 APIError 类型 + ErrorHandler 中间件 + handleError 辅助函数。

```go
type APIError struct {
    Code    int    `json:"-"`
    Message string `json:"message"`
    Details any    `json:"details,omitempty"`
}

var (
    ErrNotFound     = &APIError{Code: 404, Message: "resource not found"}
    ErrUnauthorized = &APIError{Code: 401, Message: "unauthorized"}
    ErrForbidden    = &APIError{Code: 403, Message: "forbidden"}
    ErrBadRequest   = &APIError{Code: 400, Message: "bad request"}
)
```

### 指数退避重试

```go
func WithRetry[T any](ctx context.Context, cfg RetryConfig, fn func() (T, error)) (T, error)
```

> 完整错误处理和重试实现见 [references/examples.md](references/examples.md#错误处理实现)

---

## 认证与授权

### JWT 验证

AuthService.ValidateToken + AuthMiddleware，从 Authorization header 提取 Bearer token。

### 基于角色的访问控制

rolePermissions map + HasPermission + RequirePermission 中间件。

> 完整 JWT + RBAC 实现见 [references/examples.md](references/examples.md#认证与授权实现)

---

## 限流

### 令牌桶限流器

- 基于 key（IP/用户 ID）的令牌桶算法
- 必须调用 `Start(ctx)` 启动后台清理协程，防止 map 无限增长
- ctx 取消时清理协程自动退出

```go
func NewRateLimiter(rate, capacity float64) *RateLimiter
func (rl *RateLimiter) Start(ctx context.Context)
func (rl *RateLimiter) Allow(key string) bool
func RateLimitMiddleware(limiter *RateLimiter) Middleware
```

> 完整限流器实现见 [references/examples.md](references/examples.md#限流实现)

---

## 后台任务队列

### 简单内存队列

基于 channel 的 worker pool，支持优雅关闭。

```go
func NewJobQueue(workers int, handler func(Job) error, logger *slog.Logger) *JobQueue
func (q *JobQueue) Start(ctx context.Context)
func (q *JobQueue) Enqueue(job Job) error
func (q *JobQueue) Shutdown()
```

> 完整 JobQueue 实现见 [references/examples.md](references/examples.md#后台任务队列实现)

---

## 结构化日志

RequestLogger 中间件：注入 request_id，创建带请求上下文的 logger。

```go
func LoggerFromContext(ctx context.Context) *slog.Logger
```

> 完整 RequestLogger 实现见 [references/examples.md](references/examples.md#结构化日志实现)

---

## 快速检查清单

### 架构设计
- [ ] 分层清晰：Handler -> Service -> Repository
- [ ] 依赖注入，避免全局状态
- [ ] 接口在使用方定义
- [ ] 错误集中处理

### API 设计
- [ ] RESTful 资源命名
- [ ] 版本控制 `/api/v1/`
- [ ] 统一响应格式
- [ ] 分页、过滤、排序参数

### 数据访问
- [ ] 避免 N+1 查询
- [ ] 只查询需要的列
- [ ] 事务处理多步操作
- [ ] 索引覆盖常用查询

### 缓存
- [ ] 合适的 TTL
- [ ] 缓存失效策略
- [ ] 防止缓存穿透/雪崩

### 安全
- [ ] 认证中间件
- [ ] 权限检查
- [ ] 限流保护
- [ ] 输入验证

---

## 参考资料

- [references/examples.md](references/examples.md) - 完整代码实现（Repository、Service、中间件、缓存、错误处理、JWT、RBAC、限流、队列、日志）

**记住**：后端架构模式使服务可扩展、可维护。选择匹配复杂度级别的模式。
