---
name: resilience-go
description: "Go 韧性模式专家 - 熔断器(sony/gobreaker/v2 泛型 CircuitBreaker[T])、重试策略(avast/retry-go/v5 New/NewWithData、指数退避、Unrecoverable)、限流(x/time/rate 令牌桶/按 Key/滑动窗口/redis_rate 分布式 + 本地降级)、超时控制(Context 分层、WithTimeoutCause)、舱壁隔离(x/sync semaphore/errgroup.SetLimit)、降级处理(Fallback/过期缓存)、组合弹性调用。适用：微服务容错、外部服务调用、高可用系统、分布式系统韧性设计。不适用：单体应用内部函数调用、无外部依赖的纯计算逻辑、已有成熟框架(如 Istio)处理韧性的场景。触发词：熔断, circuit breaker, gobreaker, 重试, retry, retry-go, 限流, rate limit, 超时, timeout, 降级, fallback, 舱壁, bulkhead, 韧性, resilience"
---

# Go 韧性模式专家

使用 Go 实现微服务韧性模式：$ARGUMENTS

---

## 0. 版本与依赖

基线 go1.24.6。go.mod：

```text
github.com/sony/gobreaker/v2 v2.4.0        // 熔断
github.com/avast/retry-go/v5 v5.0.0        // 重试（v5 API：retry.New(...).Do / retry.NewWithData[T]）
golang.org/x/time v0.14.0                  // rate 令牌桶
golang.org/x/sync v0.19.0                  // semaphore / errgroup
github.com/go-redis/redis_rate/v10 v10.0.1 // 分布式限流（可选，需 go-redis/v9 v9.22.0）
```

推荐顺序：限流 → 舱壁 → 超时 → 熔断 → 重试 → 降级。

---

## 1. 熔断器（sony/gobreaker/v2）

```go
package resilience

import (
    "context"
    "errors"
    "log/slog"
    "time"

    "github.com/sony/gobreaker/v2"
)

var ErrBusiness = errors.New("business error") // 不计入熔断的业务错误

func NewBreaker[T any](name string) *gobreaker.CircuitBreaker[T] {
    return gobreaker.NewCircuitBreaker[T](gobreaker.Settings{
        Name:         name,
        MaxRequests:  3,                // HalfOpen 探测请求数
        Interval:     60 * time.Second, // Closed 统计窗口
        BucketPeriod: 10 * time.Second, // 滚动分桶
        Timeout:      30 * time.Second, // Open 持续时间
        ReadyToTrip: func(c gobreaker.Counts) bool { // 触发策略
            return c.ConsecutiveFailures >= 5 ||
                (c.Requests >= 20 && float64(c.TotalFailures)/float64(c.Requests) >= 0.5)
        },
        IsSuccessful: func(err error) bool { return err == nil || errors.Is(err, ErrBusiness) },
        IsExcluded:   func(err error) bool { return errors.Is(err, context.Canceled) },
        OnStateChange: func(name string, from, to gobreaker.State) {
            slog.Warn("breaker state", slog.String("name", name), slog.String("to", to.String()))
        },
    })
}

// Execute 进入熔断器前检查 ctx，已取消不占用探测额度
func Execute[T any](ctx context.Context, cb *gobreaker.CircuitBreaker[T], fn func(ctx context.Context) (T, error)) (T, error) {
    var zero T
    if err := ctx.Err(); err != nil {
        return zero, err
    }
    return cb.Execute(func() (T, error) { return fn(ctx) })
}

func IsBreakerOpen(err error) bool {
    return errors.Is(err, gobreaker.ErrOpenState) || errors.Is(err, gobreaker.ErrTooManyRequests)
}
```

| Settings 字段 | 作用 |
|---------------|------|
| `ReadyToTrip(Counts) bool` | 触发策略：连续失败 / 失败率 + 最小请求数 / 组合 |
| `IsSuccessful(err) bool` | 业务错误（404 等）判为成功，不触发熔断 |
| `IsExcluded(err) bool` | 调用方取消等不计入统计 |
| `Interval` + `BucketPeriod` | Closed 状态滚动窗口统计 |
| `TwoStepCircuitBreaker[T]` | `Allow()` 返回 `done(err)`，适合流式 / 结果延后的场景 |

熔断拒绝返回 `gobreaker.ErrOpenState` / `ErrTooManyRequests`，此类错误不重试，直接降级。

> 触发策略组合、HTTP 客户端集成、两阶段熔断见 [references/examples.md](references/examples.md#熔断器gobreakerv2)

---

## 2. 重试（avast/retry-go/v5）

v5 破坏性变更：`retry.Do(fn, opts...)` 改为 `retry.New(opts...).Do(fn)`；带返回值用 `retry.NewWithData[T](opts...).Do(fn)`。

```go
package resilience

import (
    "context"
    "log/slog"
    "time"

    "github.com/avast/retry-go/v5"
)

func DefaultRetryOptions(ctx context.Context) []retry.Option {
    return []retry.Option{
        retry.Context(ctx),                 // ctx 取消时停止
        retry.Attempts(3),                  // 含首次
        retry.Delay(100 * time.Millisecond),
        retry.MaxDelay(5 * time.Second),
        retry.MaxJitter(100 * time.Millisecond),
        retry.DelayType(retry.CombineDelay(retry.BackOffDelay, retry.RandomDelay)), // 指数退避 + 抖动
        retry.LastErrorOnly(true),          // 返回最后一次错误而非聚合 retry.Error
        retry.RetryIf(IsRetryable),         // 错误分类
        retry.OnRetry(func(n uint, err error) {
            slog.WarnContext(ctx, "retrying", slog.Uint64("attempt", uint64(n+1)), slog.Any("error", err))
        }),
    }
}

func Do(ctx context.Context, fn func(ctx context.Context) error, opts ...retry.Option) error {
    return retry.New(append(DefaultRetryOptions(ctx), opts...)...).Do(func() error { return fn(ctx) })
}

func DoWithData[T any](ctx context.Context, fn func(ctx context.Context) (T, error), opts ...retry.Option) (T, error) {
    return retry.NewWithData[T](append(DefaultRetryOptions(ctx), opts...)...).Do(func() (T, error) { return fn(ctx) })
}
```

### 错误分类

```go
package resilience

import (
    "context"
    "errors"
    "net"

    "github.com/avast/retry-go/v5"
)

// 永久错误：retry.Unrecoverable(err) 包装后立即停止；retry.IsRecoverable 判断
func IsRetryable(err error) bool {
    switch {
    case err == nil, !retry.IsRecoverable(err):
        return false
    case errors.Is(err, context.Canceled), errors.Is(err, context.DeadlineExceeded):
        return false
    case IsBreakerOpen(err):
        return false // 熔断拒绝不重试
    }
    var netErr net.Error
    if errors.As(err, &netErr) {
        return netErr.Timeout()
    }
    return true // 未知错误默认重试
}
```

其他选项：`retry.AttemptsForError(n, err)` 对特定错误单独计次；`retry.UntilSucceeded()` 无限重试（慎用）；
`retry.WrapContextErrorWithLastError(true)` 让 ctx 超时错误携带最后一次业务错误；
未设 `LastErrorOnly` 时返回 `retry.Error`（`Unwrap() []error`），用 `errors.Is/As` 或 `LastError()` 检查。

> 完整示例见 [references/examples.md](references/examples.md#重试retry-gov5)

---

## 3. 限流

### 本地令牌桶（x/time/rate）

```go
package resilience

import (
    "context"
    "time"

    "golang.org/x/time/rate"
)

type TokenBucket struct{ lim *rate.Limiter }

func NewTokenBucket(perSecond float64, burst int) *TokenBucket {
    return &TokenBucket{lim: rate.NewLimiter(rate.Limit(perSecond), burst)}
}

func (b *TokenBucket) Allow() bool                    { return b.lim.Allow() } // 非阻塞
func (b *TokenBucket) Wait(ctx context.Context) error { return b.lim.Wait(ctx) } // 阻塞等令牌

// RetryAfter 拒绝时返回建议等待时间（预约后取消，不消耗令牌）
func (b *TokenBucket) RetryAfter() (time.Duration, bool) {
    r := b.lim.Reserve()
    if d := r.Delay(); d > 0 {
        r.Cancel()
        return d, false
    }
    return 0, true
}
```

| 模式 | 实现 | 适用 |
|------|------|------|
| 按 Key | `map[string]*rate.Limiter` + 互斥锁 + 定期清理空闲 key | 按租户 / 用户 / 方法限流 |
| 滑动窗口 | 记录时间戳切片，剔除窗口外 | 低 QPS 精确控制 |
| 分布式 | `redis_rate.NewLimiter(rdb).Allow(ctx, key, redis_rate.PerSecond(n))` | 多副本共享配额 |
| 分布式 + 降级 | Redis 出错时按策略：`local`（本地令牌桶，配额 / 副本数）、`open`、`close` | 生产推荐 |

HTTP 拒绝返回 `429` + `Retry-After`；gRPC 返回 `codes.ResourceExhausted` + `errdetails.RetryInfo`。

> 按 Key、滑动窗口、`DistributedLimiter` 见 [references/examples.md](references/examples.md#限流)

---

## 4. 超时控制

```go
package resilience

import (
    "context"
    "errors"
    "time"
)

var ErrCallTimeout = errors.New("call timeout")

// 分层超时：总预算 10s，每次调用 3s；retry.Context(ctx) 让总预算到期时停止重试
func layered(ctx context.Context, call func(ctx context.Context) error) error {
    ctx, cancel := context.WithTimeout(ctx, 10*time.Second)
    defer cancel()

    return Do(ctx, func(ctx context.Context) error {
        cctx, ccancel := context.WithTimeoutCause(ctx, 3*time.Second, ErrCallTimeout)
        defer ccancel()
        err := call(cctx)
        if errors.Is(context.Cause(cctx), ErrCallTimeout) {
            return ErrCallTimeout // 单次超时：可重试
        }
        return err // 总预算超时：context.DeadlineExceeded，IsRetryable 返回 false
    })
}
```

- 超时由 context 驱动，不用额外 goroutine + select 包装；操作函数必须尊重 ctx
- `WithTimeoutCause` + `context.Cause` 区分单次超时与总预算超时
- 总超时 > 单次超时 × 重试次数 + 退避总和

---

## 5. 舱壁隔离

```go
package resilience

import (
    "context"
    "errors"
    "time"

    "golang.org/x/sync/semaphore"
)

var ErrBulkheadFull = errors.New("bulkhead full")

// Bulkhead 限制并发；等待许可超过 maxWait 直接拒绝，避免排队放大延迟
type Bulkhead struct {
    sem     *semaphore.Weighted
    maxWait time.Duration
}

func NewBulkhead(maxConcurrent int64, maxWait time.Duration) *Bulkhead {
    return &Bulkhead{sem: semaphore.NewWeighted(maxConcurrent), maxWait: maxWait}
}

func (b *Bulkhead) Execute(ctx context.Context, fn func(ctx context.Context) error) error {
    actx, cancel := context.WithTimeout(ctx, b.maxWait)
    defer cancel()
    if err := b.sem.Acquire(actx, 1); err != nil {
        if ctx.Err() != nil {
            return ctx.Err()
        }
        return ErrBulkheadFull
    }
    defer b.sem.Release(1)
    return fn(ctx)
}
```

- 每个下游服务独立舱壁（`map[service]*Bulkhead`），一个服务变慢不拖垮全部并发
- 批处理用 `errgroup.Group.SetLimit(n)` + `Go` / `TryGo`（队列满时非阻塞）
- 熔断器 `MaxRequests` 限制 HalfOpen 探测并发，是另一种隔离

> 按服务隔离、errgroup worker pool 见 [references/examples.md](references/examples.md#舱壁隔离)

---

## 6. 降级（Fallback）

```go
package resilience

import "context"

type Fallback[T any] struct {
    primary  func(ctx context.Context) (T, error)
    fallback func(ctx context.Context, err error) (T, error)
    shouldFB func(err error) bool // nil = 任何错误都降级
}

func (f *Fallback[T]) Execute(ctx context.Context) (T, error) {
    result, err := f.primary(ctx)
    if err == nil || (f.shouldFB != nil && !f.shouldFB(err)) {
        return result, err
    }
    return f.fallback(ctx, err)
}
```

- 只对熔断打开 / 超时 / 瞬时错误降级，业务错误（参数非法）直接返回
- 降级来源优先级：过期缓存（stale-while-error）→ 默认值 → 空结果 + 标记

> 过期缓存降级 `StaleCache[T]` 见 [references/examples.md](references/examples.md#降级)

---

## 7. 组合模式

### 熔断与重试的两种顺序

```go
package resilience

import (
    "context"

    "github.com/avast/retry-go/v5"
    "github.com/sony/gobreaker/v2"
)

// RetryAroundBreaker：每次重试经过熔断器，连续失败快速触发熔断；熔断拒绝不重试
func RetryAroundBreaker[T any](ctx context.Context, cb *gobreaker.CircuitBreaker[T], fn func(ctx context.Context) (T, error)) (T, error) {
    return DoWithData(ctx, func(ctx context.Context) (T, error) { return Execute(ctx, cb, fn) })
}

// BreakerAroundRetry：只把重试后的最终结果记入熔断器，中间抖动不影响熔断状态
func BreakerAroundRetry[T any](ctx context.Context, cb *gobreaker.CircuitBreaker[T], fn func(ctx context.Context) (T, error)) (T, error) {
    return Execute(ctx, cb, func(ctx context.Context) (T, error) {
        return DoWithData(ctx, fn, retry.Attempts(2))
    })
}
```

| 组合 | 熔断统计 | 适用 |
|------|----------|------|
| RetryAroundBreaker | 每次尝试都计入 | 下游持续故障需快速熔断 |
| BreakerAroundRetry | 只计最终结果 | 下游偶发抖动多、整体可用 |

### 完整弹性调用

`ResilientCall[T]`：限流（`TokenBucket`）→ 舱壁（`Bulkhead`）→ 超时 → 熔断（`CircuitBreaker[T]`）→ 重试（retry-go）→ 降级。
Builder 链式配置：`NewResilientCall[*User]("user-service").WithRateLimiter(...).WithBulkhead(...).WithTimeout(5s).WithRetry(retry.Attempts(3)).WithFallback(...).Build()`。

> 完整实现与 Builder 见 [references/examples.md](references/examples.md#组合弹性调用)

---

## 最佳实践

### 熔断器
- `ReadyToTrip` 用失败率 + 最小请求数，避免低流量误触发
- `IsSuccessful` 排除业务错误，`IsExcluded` 排除调用方取消
- 熔断时提供降级响应，`OnStateChange` 上报指标

### 重试
- 只重试幂等操作与瞬时错误；`retry.Unrecoverable` 标记永久错误
- 指数退避 + 抖动；`retry.Context(ctx)` 绑定总预算
- 熔断拒绝、ctx 取消不重试

### 限流
- 生产用分布式限流 + 本地降级
- 按 tenant / caller / method 多维度限流
- 拒绝时返回 `Retry-After` / `RetryInfo`

### 超时
- context 分层：总超时 > 单次超时 × 次数
- `WithTimeoutCause` 区分超时来源
- deadline 随 ctx 传播到下游

### 组合
- 顺序：限流 → 舱壁 → 超时 → 熔断 → 重试 → 降级
- 按下游特性选择 RetryAroundBreaker 或 BreakerAroundRetry

---

## 检查清单

- [ ] 外部调用有熔断（触发策略含最小请求数）？
- [ ] 重试策略区分错误类型（`Unrecoverable` / `RetryIf`）？
- [ ] API 有限流保护（本地或 Redis + 降级）？
- [ ] 所有外部调用有超时（`context.WithTimeout`）？
- [ ] 关键功能有降级方案？
- [ ] 熔断与重试组合顺序明确？
- [ ] 监控韧性指标（熔断器状态、限流拒绝率、重试次数）？
- [ ] 舱壁按下游服务隔离？

---

## 参考资料

- [references/examples.md](references/examples.md) - 完整代码实现（熔断策略、retry-go v5、限流、舱壁、降级、组合）
- [gobreaker/v2 文档](https://pkg.go.dev/github.com/sony/gobreaker/v2)
- [retry-go/v5 文档](https://pkg.go.dev/github.com/avast/retry-go/v5)
- [x/time/rate 文档](https://pkg.go.dev/golang.org/x/time/rate)
- [x/sync 文档](https://pkg.go.dev/golang.org/x/sync)
