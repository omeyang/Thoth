---
name: resilience-go
description: "Go 韧性模式专家 - 熔断器(sony/gobreaker)、重试策略(avast/retry-go, 指数退避)、限流(令牌桶/滑动窗口/按Key)、超时控制(Context分层)、舱壁隔离(信号量/Worker Pool)、降级处理(缓存降级/默认值)、组合弹性调用。适用：微服务容错、外部服务调用、高可用系统、分布式系统韧性设计。不适用：单体应用内部函数调用、无外部依赖的纯计算逻辑、已有成熟框架(如 Istio)处理韧性的场景。触发词：熔断, circuit breaker, 重试, retry, 限流, rate limit, 超时, timeout, 降级, fallback, 舱壁, bulkhead, 韧性, resilience"
user-invocable: true
allowed-tools: Bash, Read, Write, Edit, Grep, Glob
---

# Go 韧性模式专家

使用 Go 实现微服务韧性模式：$ARGUMENTS

---

## 1. 熔断器（xbreaker - sony/gobreaker）

### 创建熔断器

```go
func NewBreaker(name string, opts ...BreakerOption) *Breaker

// 选项
WithTripPolicy(p TripPolicy)          // 触发策略
WithSuccessPolicy(p SuccessPolicy)    // 成功判断策略
WithTimeout(d time.Duration)          // 恢复超时（默认 60s）
WithInterval(d time.Duration)         // 统计窗口
WithMaxRequests(n uint32)             // 半开状态允许请求数（默认 1）
WithOnStateChange(f func(...))        // 状态变更回调
```

### 执行与泛型调用

```go
// 无返回值
err := breaker.Do(ctx, func() error { return callService() })

// 泛型（有返回值）
result, err := xbreaker.Execute[*User](ctx, breaker, func() (*User, error) {
    return userClient.GetUser(ctx, id)
})
```

### TripPolicy（触发策略）

```go
NewConsecutiveFailures(threshold uint32)           // N 次连续失败触发
NewFailureRatio(ratio float64, minReqs uint32)     // 失败率超阈值触发
NewFailureCount(threshold uint32)                  // 总失败次数触发
NewCompositePolicy(policies ...TripPolicy)         // OR 组合
NewSlowCallRatio(ratio float64, minReqs uint32)    // 慢调用比率触发
```

### Context 处理

```go
// 入口检查 ctx.Err()，快速失败
// Context 取消/超时 → 立即返回，不计入熔断统计
```

> 自定义策略和 HTTP 客户端集成见 [references/examples.md](references/examples.md#熔断器高级用法)

---

## 2. 重试（xretry - avast/retry-go）

### 创建重试器

```go
func NewRetryer(opts ...RetryerOption) *Retryer
// 默认: FixedRetry(3) + ExponentialBackoff

// 选项
WithRetryPolicy(p RetryPolicy)       // 重试决策策略
WithBackoffPolicy(p BackoffPolicy)   // 退避计算策略
WithOnRetry(f func(attempt int, err error))  // 重试回调
```

### 执行

```go
// 无返回值
err := retryer.Do(ctx, func(ctx context.Context) error {
    return callService(ctx)
})

// 泛型（有返回值）
result, err := xretry.DoWithResult[*User](ctx, retryer, func(ctx context.Context) (*User, error) {
    return userClient.GetUser(ctx, id)
})
```

### RetryPolicy

```go
type RetryPolicy interface {
    MaxAttempts() int  // 0 = 无限
    ShouldRetry(ctx context.Context, attempt int, err error) bool
}

NewFixedRetry(maxAttempts int)   // 固定次数
NewAlwaysRetry()                 // 无限重试（慎用）
NewNeverRetry()                  // 不重试
```

### BackoffPolicy

```go
type BackoffPolicy interface {
    NextDelay(attempt int) time.Duration  // attempt 从 1 开始
}

NewFixedBackoff(delay time.Duration)
NewExponentialBackoff(opts ...ExponentialBackoffOption)
// 默认: 100ms 初始, 30s 最大, 2.0 倍增, 10% 抖动
NewLinearBackoff(initial, increment, max time.Duration)
NewNoBackoff()
```

### 错误分类

```go
type RetryableError interface {
    error
    Retryable() bool
}

NewPermanentError(err error)    // 不可重试
NewTemporaryError(err error)    // 可重试
IsRetryable(err error) bool     // 默认: 未知错误 = 可重试
```

> 自定义重试策略见 [references/examples.md](references/examples.md#自定义重试策略)

---

## 3. 限流（xlimit - Redis + 本地双后端）

### 核心接口

```go
type Limiter interface {
    Allow(ctx context.Context, key Key) (*Result, error)
    AllowN(ctx context.Context, key Key, n int) (*Result, error)
    Close() error
}

type Result struct {
    Allowed    bool          // 是否允许
    Limit      int           // 配额上限
    Remaining  int           // 剩余配额
    Rule       string        // 匹配的规则名
    RetryAfter time.Duration // 拒绝时的等待时间
}
```

### 创建限流器

```go
// 分布式限流（Redis 后端，使用 redis_rate/v10）
limiter, err := xlimit.New(redisClient, opts...)

// 本地限流（令牌桶，单 Pod）
limiter, err := xlimit.NewLocal(opts...)

// 分布式 + 本地降级（推荐生产环境）
limiter, err := xlimit.NewWithFallback(redisClient, opts...)
```

### 降级策略

```go
const (
    FallbackLocal  FallbackStrategy = "local"   // 推荐: Redis 不可用时降级到本地
    FallbackOpen   = "open"                     // 全部放行
    FallbackClose  = "close"                    // 全部拒绝
)
WithFallback(FallbackLocal)
```

### 可选查询与重置

```go
// 非消费查询
if q, ok := limiter.(xlimit.Querier); ok {
    info, _ := q.Query(ctx, key)
}

// 重置计数
if r, ok := limiter.(xlimit.Resetter); ok {
    r.Reset(ctx, key)
}
```

> 按 Key 限流、gRPC/HTTP 中间件见 [references/examples.md](references/examples.md#限流高级模式)

---

## 4. 超时控制

### 纯 Context 模式（推荐）

超时通过 caller 的 `context.WithTimeout` 控制，韧性组件不额外封装：

```go
ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
defer cancel()

// 熔断器检查 ctx.Err() 快速失败
err := breaker.Do(ctx, func() error {
    return callService(ctx)  // 操作本身也应尊重 ctx
})

// 重试器自动在 ctx 取消时停止重试
err := retryer.Do(ctx, func(ctx context.Context) error {
    return callService(ctx)
})
```

### 分层超时

```go
// 总超时 10s，每次调用最多 3s，最多重试 3 次
ctx, cancel := context.WithTimeout(ctx, 10*time.Second)
defer cancel()

err := retryer.Do(ctx, func(ctx context.Context) error {
    callCtx, callCancel := context.WithTimeout(ctx, 3*time.Second)
    defer callCancel()
    return callService(callCtx)
})
```

**关键**：超时由 context 驱动，不使用额外 channel/select 封装。操作函数必须接受并尊重 context。

---

## 5. 资源隔离（通过 xlimit）

xlimit 的 Rule 机制天然支持按维度隔离资源：

```go
type Key struct {
    Tenant   string  // 按租户隔离
    Caller   string  // 按调用方隔离
    Method   string  // 按 API 隔离
    Resource string  // 按资源隔离
}

// 本地限流器自动按 Pod 分配配额
// localLimit = max(totalLimit / podCount, 1)
```

### 熔断器半开状态隔离

```go
// MaxRequests 限制半开状态并发探测数
WithMaxRequests(3)  // 最多允许 3 个请求探测恢复
```

---

## 6. 降级（Fallback）

### 降级模式

```go
type Fallback[T any] struct {
    primary  func(context.Context) (T, error)
    fallback func(context.Context, error) (T, error)
}

func (f *Fallback[T]) Execute(ctx context.Context) (T, error) {
    result, err := f.primary(ctx)
    if err != nil { return f.fallback(ctx, err) }
    return result, nil
}
```

> 缓存降级（含过期缓存回退）见 [references/examples.md](references/examples.md#缓存降级)

---

## 7. 组合模式

### BreakerRetryer（每次重试经过熔断器）

```go
type BreakerRetryer struct {
    breaker *Breaker
    retryer *xretry.Retryer
}

// 每次重试都经过熔断器判断，连续失败可能触发熔断
func (br *BreakerRetryer) DoWithRetry(ctx context.Context, fn func(ctx context.Context) error) error
func ExecuteWithRetry[T any](ctx context.Context, br *BreakerRetryer, fn func() (T, error)) (T, error)
```

### RetryThenBreak（重试完成后才记入熔断器）

```go
type RetryThenBreak struct {
    retryer *xretry.Retryer
    breaker *Breaker
}

// 先检查熔断器，然后重试，只把最终结果记入熔断器
// 优势：重试中的中间失败不影响熔断器状态
func (rtb *RetryThenBreak) Do(ctx context.Context, fn func(ctx context.Context) error) error
```

### 错误集成

```go
// BreakerError 实现 Retryable() = false
// 熔断器错误不会触发重试，直接快速失败
type BreakerError struct { Err error; Name string; State State }
func (e *BreakerError) Retryable() bool { return false }
```

> Builder 模式和完整 Execute 实现见 [references/examples.md](references/examples.md#组合弹性调用)

---

## 最佳实践

### 熔断器
- 使用 TripPolicy 选择合适的触发策略
- 区分业务错误和系统错误（IsSuccessful）
- 熔断时提供降级响应

### 重试
- 只重试可恢复错误（NewPermanentError 标记不可恢复）
- 使用指数退避 + 抖动
- 幂等操作才能安全重试

### 限流
- 生产环境使用 `NewWithFallback`（Redis + 本地降级）
- 按 tenant/caller/method 多维度限流
- 返回 RetryAfter 供客户端使用

### 超时
- 使用 context.WithTimeout 控制超时
- 分层设置超时（总超时 > 单次超时 × 重试次数）
- 传播 deadline 到下游

### 组合
- 选择合适的组合模式：BreakerRetryer vs RetryThenBreak
- 推荐顺序：限流 → 熔断 → 超时 → 重试 → 降级

---

## 检查清单

- [ ] 外部调用有熔断（TripPolicy 配置合理）？
- [ ] 重试策略区分错误类型（PermanentError）？
- [ ] API 有限流保护（xlimit + Redis）？
- [ ] 所有外部调用有超时（context.WithTimeout）？
- [ ] 关键功能有降级方案？
- [ ] 使用 BreakerRetryer 或 RetryThenBreak 组合？
- [ ] 监控韧性指标（熔断器状态、限流拒绝率）？
- [ ] Redis 限流配置 Fallback 策略？

---

## 参考资料

- [references/examples.md](references/examples.md) - 完整代码实现（高级策略、HTTP 集成、组合模式）
