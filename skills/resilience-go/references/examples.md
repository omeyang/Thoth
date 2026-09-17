# Go 韧性模式 - 完整代码实现

基线：go1.24.6。模块版本：

```text
github.com/sony/gobreaker/v2 v2.4.0      // 泛型 CircuitBreaker[T]
github.com/avast/retry-go/v5 v5.0.0      // retry.New(...).Do / retry.NewWithData[T]
golang.org/x/time v0.14.0                // rate 令牌桶
golang.org/x/sync v0.19.0                // errgroup / semaphore
github.com/go-redis/redis_rate/v10 v10.0.1 + github.com/redis/go-redis/v9 v9.22.0  // 分布式限流
```

所有片段同属一个包 `resilience`。

## 目录

- [熔断器（gobreaker/v2）](#熔断器gobreakerv2)
- [重试（retry-go/v5）](#重试retry-gov5)
- [限流](#限流)
- [舱壁隔离](#舱壁隔离)
- [超时控制](#超时控制)
- [降级](#降级)
- [组合弹性调用](#组合弹性调用)

---

## 熔断器（gobreaker/v2）

### 创建与触发策略

```go
package resilience

import (
    "context"
    "errors"
    "log/slog"
    "time"

    "github.com/sony/gobreaker/v2"
)

// TripPolicy 决定何时从 Closed 进入 Open，签名与 gobreaker.Settings.ReadyToTrip 一致。
type TripPolicy func(counts gobreaker.Counts) bool

// ConsecutiveFailures N 次连续失败触发。
func ConsecutiveFailures(n uint32) TripPolicy {
    return func(c gobreaker.Counts) bool { return c.ConsecutiveFailures >= n }
}

// FailureRatio 请求数达到 minRequests 且失败率超过 ratio 触发。
func FailureRatio(ratio float64, minRequests uint32) TripPolicy {
    return func(c gobreaker.Counts) bool {
        if c.Requests < minRequests {
            return false
        }
        return float64(c.TotalFailures)/float64(c.Requests) >= ratio
    }
}

// AnyOf 任一策略满足即触发。
func AnyOf(policies ...TripPolicy) TripPolicy {
    return func(c gobreaker.Counts) bool {
        for _, p := range policies {
            if p(c) {
                return true
            }
        }
        return false
    }
}

// NewBreaker 创建带日志与合理默认值的熔断器。
//   - Interval + BucketPeriod：Closed 状态下按滚动窗口统计（v2.4 支持分桶）
//   - Timeout：Open 状态持续时间，之后进入 HalfOpen
//   - MaxRequests：HalfOpen 允许的探测请求数
//   - IsSuccessful：业务错误（如 404）不计入失败
//   - IsExcluded：调用方取消 / 超时不计入统计
func NewBreaker[T any](name string, trip TripPolicy) *gobreaker.CircuitBreaker[T] {
    return gobreaker.NewCircuitBreaker[T](gobreaker.Settings{
        Name:         name,
        MaxRequests:  3,
        Interval:     60 * time.Second,
        BucketPeriod: 10 * time.Second,
        Timeout:      30 * time.Second,
        ReadyToTrip:  trip,
        IsSuccessful: func(err error) bool {
            return err == nil || errors.Is(err, ErrBusiness)
        },
        IsExcluded: func(err error) bool {
            return errors.Is(err, context.Canceled)
        },
        OnStateChange: func(name string, from, to gobreaker.State) {
            slog.Warn("circuit breaker state changed",
                slog.String("name", name), slog.String("from", from.String()), slog.String("to", to.String()))
        },
    })
}

// ErrBusiness 标记不应触发熔断的业务错误（例如资源不存在）。
var ErrBusiness = errors.New("business error")
```

### Context 感知的执行

```go
package resilience

import (
    "context"
    "errors"

    "github.com/sony/gobreaker/v2"
)

// IsBreakerOpen 判断错误是否由熔断器拒绝产生（Open 或 HalfOpen 探测额度用尽）。
func IsBreakerOpen(err error) bool {
    return errors.Is(err, gobreaker.ErrOpenState) || errors.Is(err, gobreaker.ErrTooManyRequests)
}

// Execute 在进入熔断器前检查 ctx，已取消则直接返回，不占用 HalfOpen 探测额度。
func Execute[T any](ctx context.Context, cb *gobreaker.CircuitBreaker[T], fn func(ctx context.Context) (T, error)) (T, error) {
    var zero T
    if err := ctx.Err(); err != nil {
        return zero, err
    }
    return cb.Execute(func() (T, error) { return fn(ctx) })
}
```

### HTTP 客户端集成

```go
package resilience

import (
    "context"
    "fmt"
    "io"
    "net/http"
    "time"

    "github.com/sony/gobreaker/v2"
)

type BreakerHTTPClient struct {
    client  *http.Client
    breaker *gobreaker.CircuitBreaker[*http.Response]
}

func NewBreakerHTTPClient(name string) *BreakerHTTPClient {
    return &BreakerHTTPClient{
        client:  &http.Client{Timeout: 10 * time.Second},
        breaker: NewBreaker[*http.Response](name, AnyOf(ConsecutiveFailures(5), FailureRatio(0.5, 20))),
    }
}

// Do 把 5xx 视为失败；4xx 视为业务错误不计入熔断。
func (c *BreakerHTTPClient) Do(req *http.Request) (*http.Response, error) {
    return Execute(req.Context(), c.breaker, func(ctx context.Context) (*http.Response, error) {
        resp, err := c.client.Do(req.WithContext(ctx))
        if err != nil {
            return nil, err
        }
        switch {
        case resp.StatusCode >= 500:
            _, _ = io.Copy(io.Discard, resp.Body)
            _ = resp.Body.Close()
            return nil, fmt.Errorf("upstream %s: %w", resp.Status, ErrUpstream)
        case resp.StatusCode >= 400:
            return resp, fmt.Errorf("upstream %s: %w", resp.Status, ErrBusiness) // 不触发熔断
        }
        return resp, nil
    })
}
```

```go
package resilience

import "errors"

var ErrUpstream = errors.New("upstream failure")
```

### 两阶段熔断（流式 / 长连接）

```go
package resilience

import (
    "context"

    "github.com/sony/gobreaker/v2"
)

// TwoStep 适合结果在稍后才知道的场景：先 Allow 拿到 done，再在结果确定时调用 done(err)。
func streamWithBreaker(ctx context.Context, cb *gobreaker.TwoStepCircuitBreaker[struct{}], open func(ctx context.Context) (func() error, error)) error {
    done, err := cb.Allow()
    if err != nil {
        return err // ErrOpenState / ErrTooManyRequests
    }
    wait, err := open(ctx)
    if err != nil {
        done(err)
        return err
    }
    err = wait() // 流结束后再计入统计
    done(err)
    return err
}
```

### 熔断降级

```go
package resilience

import "context"

type User struct {
    ID   string
    Name string
}

type UserClient interface {
    Get(ctx context.Context, id string) (*User, error)
}

type UserCache interface {
    Get(ctx context.Context, id string) (*User, bool)
}

// GetUserWithBreaker 熔断打开时返回缓存值。
func GetUserWithBreaker(ctx context.Context, cb interface {
    Execute(func() (*User, error)) (*User, error)
}, client UserClient, cache UserCache, id string) (*User, error) {
    user, err := cb.Execute(func() (*User, error) { return client.Get(ctx, id) })
    if IsBreakerOpen(err) {
        if cached, ok := cache.Get(ctx, id); ok {
            return cached, nil
        }
    }
    return user, err
}
```

---

## 重试（retry-go/v5）

v5 破坏性变更：包级 `retry.Do` 改为 `retry.New(opts...).Do(fn)`，带返回值用 `retry.NewWithData[T](opts...).Do(fn)`；
返回的聚合错误 `retry.Error` 实现 `Unwrap() []error`，用 `errors.Is/As` 检查，`LastError()` 取最后一次错误。

### 基本用法

```go
package resilience

import (
    "context"
    "log/slog"
    "time"

    "github.com/avast/retry-go/v5"
)

// DefaultRetryOptions 指数退避 + 抖动，最多 3 次，尊重 ctx。
func DefaultRetryOptions(ctx context.Context) []retry.Option {
    return []retry.Option{
        retry.Context(ctx),
        retry.Attempts(3),
        retry.Delay(100 * time.Millisecond),
        retry.MaxDelay(5 * time.Second),
        retry.MaxJitter(100 * time.Millisecond),
        retry.DelayType(retry.CombineDelay(retry.BackOffDelay, retry.RandomDelay)),
        retry.LastErrorOnly(true), // 只返回最后一次错误，而不是聚合的 retry.Error
        retry.OnRetry(func(n uint, err error) {
            slog.WarnContext(ctx, "retrying", slog.Uint64("attempt", uint64(n+1)), slog.Any("error", err))
        }),
    }
}

// Do 无返回值重试。
func Do(ctx context.Context, fn func(ctx context.Context) error, opts ...retry.Option) error {
    opts = append(DefaultRetryOptions(ctx), opts...)
    return retry.New(opts...).Do(func() error { return fn(ctx) })
}

// DoWithData 带返回值重试。
func DoWithData[T any](ctx context.Context, fn func(ctx context.Context) (T, error), opts ...retry.Option) (T, error) {
    opts = append(DefaultRetryOptions(ctx), opts...)
    return retry.NewWithData[T](opts...).Do(func() (T, error) { return fn(ctx) })
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

// PermanentError 标记不可重试的错误；retry.Unrecoverable 是等价的库内实现。
type PermanentError struct{ Err error }

func (e *PermanentError) Error() string { return "permanent: " + e.Err.Error() }
func (e *PermanentError) Unwrap() error { return e.Err }

func Permanent(err error) error {
    if err == nil {
        return nil
    }
    return &PermanentError{Err: err}
}

// IsRetryable 默认策略：永久错误、ctx 错误、熔断拒绝不重试；网络超时与未知错误重试。
func IsRetryable(err error) bool {
    var pe *PermanentError
    switch {
    case err == nil:
        return false
    case errors.As(err, &pe):
        return false
    case !retry.IsRecoverable(err): // retry.Unrecoverable 包装的错误
        return false
    case errors.Is(err, context.Canceled), errors.Is(err, context.DeadlineExceeded):
        return false
    case IsBreakerOpen(err):
        return false
    }
    var netErr net.Error
    if errors.As(err, &netErr) {
        return netErr.Timeout()
    }
    return true
}

// RetryIfRetryable 作为 retry.RetryIf 选项使用。
func RetryIfRetryable() retry.Option { return retry.RetryIf(IsRetryable) }
```

### 完整示例

```go
package resilience

import (
    "context"
    "errors"
    "fmt"

    "github.com/avast/retry-go/v5"
)

var ErrInvalidOrder = errors.New("invalid order")

type Order struct{ ID string }

func ProcessOrderWithRetry(ctx context.Context, order *Order, call func(ctx context.Context, o *Order) error) error {
    return Do(ctx, func(ctx context.Context) error {
        if order.ID == "" {
            return retry.Unrecoverable(ErrInvalidOrder) // 立即停止
        }
        return call(ctx, order)
    }, RetryIfRetryable())
}

// 针对特定错误设置独立次数：限流错误多等几次，其余按默认
func FetchWithRetry(ctx context.Context, fetch func(ctx context.Context) ([]byte, error)) ([]byte, error) {
    return DoWithData(ctx, fetch,
        retry.AttemptsForError(5, ErrRateLimited),
        retry.WrapContextErrorWithLastError(true), // ctx 超时时把最后一次错误一并带出
    )
}

// 聚合错误检查（未设置 LastErrorOnly 时）
func inspectRetryError(err error) {
    var agg retry.Error
    if errors.As(err, &agg) {
        fmt.Printf("failed after %d attempts, last: %v\n", len(agg), agg.LastError())
    }
    if errors.Is(err, ErrRateLimited) { // 会检查所有被包裹的错误
        fmt.Println("hit rate limit at least once")
    }
}
```

```go
package resilience

import "errors"

var ErrRateLimited = errors.New("rate limited")
```

---

## 限流

### 本地令牌桶（x/time/rate）

```go
package resilience

import (
    "context"
    "time"

    "golang.org/x/time/rate"
)

// TokenBucket 封装 rate.Limiter 的三种用法。
type TokenBucket struct{ lim *rate.Limiter }

func NewTokenBucket(perSecond float64, burst int) *TokenBucket {
    return &TokenBucket{lim: rate.NewLimiter(rate.Limit(perSecond), burst)}
}

// Allow 非阻塞：没有令牌立即拒绝。
func (b *TokenBucket) Allow() bool { return b.lim.Allow() }

// Wait 阻塞直到拿到令牌或 ctx 取消；等待时间超过 ctx deadline 时立即返回错误。
func (b *TokenBucket) Wait(ctx context.Context) error { return b.lim.Wait(ctx) }

// RetryAfter 预约一个令牌并返回需要等待的时间；不想等待时取消预约。
func (b *TokenBucket) RetryAfter() (time.Duration, bool) {
    r := b.lim.Reserve()
    if !r.OK() {
        return 0, false
    }
    if d := r.Delay(); d > 0 {
        r.Cancel()
        return d, false
    }
    return 0, true
}

// SetRate 运行时调整速率（例如根据下游反馈自适应）。
func (b *TokenBucket) SetRate(perSecond float64, burst int) {
    b.lim.SetLimit(rate.Limit(perSecond))
    b.lim.SetBurst(burst)
}
```

### 按 Key 限流（带清理）

```go
package resilience

import (
    "context"
    "sync"
    "time"

    "golang.org/x/time/rate"
)

type KeyedLimiter struct {
    mu      sync.Mutex
    entries map[string]*keyedEntry
    limit   rate.Limit
    burst   int
    idle    time.Duration
}

type keyedEntry struct {
    lim      *rate.Limiter
    lastSeen time.Time
}

func NewKeyedLimiter(perSecond float64, burst int, idle time.Duration) *KeyedLimiter {
    return &KeyedLimiter{entries: make(map[string]*keyedEntry), limit: rate.Limit(perSecond), burst: burst, idle: idle}
}

func (k *KeyedLimiter) get(key string) *rate.Limiter {
    k.mu.Lock()
    defer k.mu.Unlock()
    e, ok := k.entries[key]
    if !ok {
        e = &keyedEntry{lim: rate.NewLimiter(k.limit, k.burst)}
        k.entries[key] = e
    }
    e.lastSeen = time.Now()
    return e.lim
}

func (k *KeyedLimiter) Allow(key string) bool { return k.get(key).Allow() }

// Run 周期清理空闲 key，直到 ctx 取消。
func (k *KeyedLimiter) Run(ctx context.Context, every time.Duration) {
    ticker := time.NewTicker(every)
    defer ticker.Stop()
    for {
        select {
        case <-ctx.Done():
            return
        case <-ticker.C:
            cutoff := time.Now().Add(-k.idle)
            k.mu.Lock()
            for key, e := range k.entries {
                if e.lastSeen.Before(cutoff) {
                    delete(k.entries, key)
                }
            }
            k.mu.Unlock()
        }
    }
}
```

### HTTP 中间件

```go
package resilience

import (
    "net/http"
    "strconv"
)

// RateLimitMiddleware 按 X-User-ID（缺省用 RemoteAddr）限流，拒绝时带 Retry-After。
func RateLimitMiddleware(limiter *KeyedLimiter, retryAfterSec int) func(http.Handler) http.Handler {
    return func(next http.Handler) http.Handler {
        return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
            key := r.Header.Get("X-User-ID")
            if key == "" {
                key = r.RemoteAddr
            }
            if !limiter.Allow(key) {
                w.Header().Set("Retry-After", strconv.Itoa(retryAfterSec))
                http.Error(w, "rate limit exceeded", http.StatusTooManyRequests)
                return
            }
            next.ServeHTTP(w, r)
        })
    }
}
```

### 滑动窗口（本地）

```go
package resilience

import (
    "sync"
    "time"
)

// SlidingWindow 精确滑动窗口：记录每次请求时间戳，适合低 QPS 精确控制。
type SlidingWindow struct {
    mu     sync.Mutex
    times  []time.Time
    window time.Duration
    limit  int
}

func NewSlidingWindow(window time.Duration, limit int) *SlidingWindow {
    return &SlidingWindow{window: window, limit: limit, times: make([]time.Time, 0, limit)}
}

func (s *SlidingWindow) Allow() bool {
    s.mu.Lock()
    defer s.mu.Unlock()

    now := time.Now()
    cutoff := now.Add(-s.window)
    kept := s.times[:0]
    for _, t := range s.times {
        if t.After(cutoff) {
            kept = append(kept, t)
        }
    }
    s.times = kept

    if len(s.times) >= s.limit {
        return false
    }
    s.times = append(s.times, now)
    return true
}
```

### 分布式限流（redis_rate）+ 本地降级

```go
package resilience

import (
    "context"
    "log/slog"
    "time"

    "github.com/go-redis/redis_rate/v10"
    "github.com/redis/go-redis/v9"
)

type FallbackStrategy string

const (
    FallbackLocal FallbackStrategy = "local" // Redis 不可用时降级到本地令牌桶（推荐）
    FallbackOpen  FallbackStrategy = "open"  // 全部放行
    FallbackClose FallbackStrategy = "close" // 全部拒绝
)

type Result struct {
    Allowed    bool
    Remaining  int
    RetryAfter time.Duration
}

// DistributedLimiter 用 Redis GCRA 做全局限流，Redis 故障时按策略降级。
type DistributedLimiter struct {
    redis    *redis_rate.Limiter
    limit    redis_rate.Limit
    fallback FallbackStrategy
    local    *KeyedLimiter // FallbackLocal 时使用，配额按副本数分摊
}

func NewDistributedLimiter(rdb *redis.Client, limit redis_rate.Limit, fallback FallbackStrategy, replicas int) *DistributedLimiter {
    perReplica := max(float64(limit.Rate)/float64(max(replicas, 1))/limit.Period.Seconds(), 1)
    return &DistributedLimiter{
        redis:    redis_rate.NewLimiter(rdb),
        limit:    limit,
        fallback: fallback,
        local:    NewKeyedLimiter(perReplica, max(limit.Burst/max(replicas, 1), 1), 10*time.Minute),
    }
}

func (d *DistributedLimiter) Allow(ctx context.Context, key string) Result {
    res, err := d.redis.Allow(ctx, key, d.limit)
    if err == nil {
        return Result{Allowed: res.Allowed > 0, Remaining: res.Remaining, RetryAfter: res.RetryAfter}
    }

    slog.WarnContext(ctx, "redis rate limiter unavailable, falling back",
        slog.String("strategy", string(d.fallback)), slog.Any("error", err))
    switch d.fallback {
    case FallbackOpen:
        return Result{Allowed: true}
    case FallbackClose:
        return Result{Allowed: false, RetryAfter: time.Second}
    default:
        return Result{Allowed: d.local.Allow(key)}
    }
}

// 用法：NewDistributedLimiter(rdb, redis_rate.PerSecond(100), FallbackLocal, 4)
```

---

## 舱壁隔离

### 信号量舱壁

```go
package resilience

import (
    "context"
    "errors"
    "time"

    "golang.org/x/sync/semaphore"
)

var ErrBulkheadFull = errors.New("bulkhead full")

// Bulkhead 限制并发数；获取许可等待超过 maxWait 则拒绝，避免请求堆积。
type Bulkhead struct {
    sem     *semaphore.Weighted
    maxWait time.Duration
}

func NewBulkhead(maxConcurrent int64, maxWait time.Duration) *Bulkhead {
    return &Bulkhead{sem: semaphore.NewWeighted(maxConcurrent), maxWait: maxWait}
}

func (b *Bulkhead) Execute(ctx context.Context, fn func(ctx context.Context) error) error {
    if b.maxWait == 0 {
        if !b.sem.TryAcquire(1) {
            return ErrBulkheadFull
        }
    } else {
        actx, cancel := context.WithTimeoutCause(ctx, b.maxWait, ErrBulkheadFull)
        defer cancel()
        if err := b.sem.Acquire(actx, 1); err != nil {
            if ctx.Err() != nil {
                return ctx.Err() // 调用方取消
            }
            return ErrBulkheadFull
        }
    }
    defer b.sem.Release(1)
    return fn(ctx)
}
```

### 按服务隔离

```go
package resilience

import (
    "sync"
    "time"
)

type BulkheadConfig struct {
    Concurrency int64
    MaxWait     time.Duration
}

// ServiceBulkheads 为每个下游服务维护独立舱壁，一个服务变慢不会耗尽全部并发。
type ServiceBulkheads struct {
    mu        sync.Mutex
    byName    map[string]*Bulkhead
    defaults  BulkheadConfig
    overrides map[string]BulkheadConfig
}

func NewServiceBulkheads(defaults BulkheadConfig, overrides map[string]BulkheadConfig) *ServiceBulkheads {
    return &ServiceBulkheads{byName: make(map[string]*Bulkhead), defaults: defaults, overrides: overrides}
}

func (s *ServiceBulkheads) Get(service string) *Bulkhead {
    s.mu.Lock()
    defer s.mu.Unlock()
    if b, ok := s.byName[service]; ok {
        return b
    }
    cfg := s.defaults
    if o, ok := s.overrides[service]; ok {
        cfg = o
    }
    b := NewBulkhead(cfg.Concurrency, cfg.MaxWait)
    s.byName[service] = b
    return b
}
```

### Worker Pool（errgroup.SetLimit）

```go
package resilience

import (
    "context"

    "golang.org/x/sync/errgroup"
)

// ProcessAll 以固定并发处理 items；任一失败取消其余并返回首个错误。
func ProcessAll[T any](ctx context.Context, items []T, workers int, fn func(ctx context.Context, item T) error) error {
    g, gctx := errgroup.WithContext(ctx)
    g.SetLimit(workers)
    for _, item := range items {
        if gctx.Err() != nil {
            break
        }
        g.Go(func() error { return fn(gctx, item) })
    }
    return g.Wait()
}

// TrySubmit 队列已满时不阻塞：TryGo 返回 false 表示当前并发已达上限。
func TrySubmit(g *errgroup.Group, fn func() error) bool {
    return g.TryGo(fn)
}
```

---

## 超时控制

```go
package resilience

import (
    "context"
    "errors"
    "time"
)

var ErrCallTimeout = errors.New("call timeout")

// 分层超时：总预算 10s，单次调用 3s，重试由 retry-go 在 ctx 到期时自动停止。
func layeredTimeout(ctx context.Context, call func(ctx context.Context) error) error {
    ctx, cancel := context.WithTimeout(ctx, 10*time.Second)
    defer cancel()

    return Do(ctx, func(ctx context.Context) error {
        cctx, ccancel := context.WithTimeoutCause(ctx, 3*time.Second, ErrCallTimeout)
        defer ccancel()
        err := call(cctx)
        if errors.Is(context.Cause(cctx), ErrCallTimeout) {
            return ErrCallTimeout // 单次超时可重试；总预算超时由 retry.Context 终止
        }
        return err
    })
}
```

原则：超时由 context 驱动，不用额外 goroutine + select 包装；操作函数必须接受并尊重 ctx。
`context.WithTimeoutCause` 让调用方区分"单次超时"与"总预算超时"。

---

## 降级

### 通用 Fallback

```go
package resilience

import "context"

type Fallback[T any] struct {
    primary  func(ctx context.Context) (T, error)
    fallback func(ctx context.Context, err error) (T, error)
    shouldFB func(err error) bool // nil 表示任何错误都降级
}

func NewFallback[T any](primary func(context.Context) (T, error), fallback func(context.Context, error) (T, error)) *Fallback[T] {
    return &Fallback[T]{primary: primary, fallback: fallback}
}

// OnlyWhen 限定触发降级的错误（例如只在熔断打开或超时时降级，业务错误直接返回）。
func (f *Fallback[T]) OnlyWhen(pred func(error) bool) *Fallback[T] {
    f.shouldFB = pred
    return f
}

func (f *Fallback[T]) Execute(ctx context.Context) (T, error) {
    result, err := f.primary(ctx)
    if err == nil {
        return result, nil
    }
    if f.shouldFB != nil && !f.shouldFB(err) {
        return result, err
    }
    return f.fallback(ctx, err)
}
```

### 过期缓存降级

```go
package resilience

import (
    "context"
    "log/slog"
    "sync"
    "time"
)

type staleEntry[T any] struct {
    value     T
    expiresAt time.Time
}

// StaleCache 加载失败时允许返回已过期但仍在 staleTTL 内的值。
type StaleCache[T any] struct {
    mu       sync.RWMutex
    items    map[string]staleEntry[T]
    ttl      time.Duration
    staleTTL time.Duration
}

func NewStaleCache[T any](ttl, staleTTL time.Duration) *StaleCache[T] {
    return &StaleCache[T]{items: make(map[string]staleEntry[T]), ttl: ttl, staleTTL: staleTTL}
}

func (c *StaleCache[T]) Get(ctx context.Context, key string, load func(ctx context.Context) (T, error)) (T, error) {
    c.mu.RLock()
    e, ok := c.items[key]
    c.mu.RUnlock()
    now := time.Now()

    if ok && now.Before(e.expiresAt) {
        return e.value, nil
    }

    value, err := load(ctx)
    if err != nil {
        if ok && now.Before(e.expiresAt.Add(c.staleTTL)) {
            slog.WarnContext(ctx, "serving stale cache", slog.String("key", key), slog.Any("error", err))
            return e.value, nil
        }
        return value, err
    }

    c.mu.Lock()
    c.items[key] = staleEntry[T]{value: value, expiresAt: now.Add(c.ttl)}
    c.mu.Unlock()
    return value, nil
}
```

### 降级使用示例

```go
package resilience

import "context"

func GetUserWithFallback(ctx context.Context, client UserClient, cache UserCache, id string) (*User, error) {
    return NewFallback(
        func(ctx context.Context) (*User, error) { return client.Get(ctx, id) },
        func(ctx context.Context, _ error) (*User, error) {
            if u, ok := cache.Get(ctx, id); ok {
                return u, nil
            }
            return &User{ID: id, Name: "unknown"}, nil // 默认值
        },
    ).OnlyWhen(func(err error) bool {
        return IsBreakerOpen(err) || IsRetryable(err) // 熔断或瞬时错误才降级，业务错误直接返回
    }).Execute(ctx)
}
```

---

## 组合弹性调用

### 两种组合顺序

```go
package resilience

import (
    "context"

    "github.com/avast/retry-go/v5"
    "github.com/sony/gobreaker/v2"
)

// RetryAroundBreaker：每次重试都经过熔断器，连续失败可快速触发熔断；
// 熔断拒绝错误不重试（IsRetryable 已排除）。
func RetryAroundBreaker[T any](ctx context.Context, cb *gobreaker.CircuitBreaker[T], fn func(ctx context.Context) (T, error)) (T, error) {
    return DoWithData(ctx, func(ctx context.Context) (T, error) {
        return Execute(ctx, cb, fn)
    }, RetryIfRetryable())
}

// BreakerAroundRetry：重试完成后只把最终结果记入熔断器，中间失败不影响熔断状态；
// 适合下游偶发抖动多、但整体可用的场景。
func BreakerAroundRetry[T any](ctx context.Context, cb *gobreaker.CircuitBreaker[T], fn func(ctx context.Context) (T, error)) (T, error) {
    return Execute(ctx, cb, func(ctx context.Context) (T, error) {
        return DoWithData(ctx, fn, RetryIfRetryable(), retry.Attempts(2))
    })
}
```

### 完整的弹性调用

顺序：限流 → 舱壁 → 超时 → 熔断 → 重试 → 降级。

```go
package resilience

import (
    "context"
    "time"

    "github.com/avast/retry-go/v5"
    "github.com/sony/gobreaker/v2"
)

type ResilientCall[T any] struct {
    limiter  *TokenBucket
    bulkhead *Bulkhead
    timeout  time.Duration
    breaker  *gobreaker.CircuitBreaker[T]
    retry    []retry.Option
    fallback func(ctx context.Context, err error) (T, error)
}

func (r *ResilientCall[T]) Execute(ctx context.Context, fn func(ctx context.Context) (T, error)) (T, error) {
    var zero T

    if r.limiter != nil && !r.limiter.Allow() {
        return r.finish(ctx, zero, ErrRateLimited)
    }

    var result T
    run := func(ctx context.Context) error {
        if r.timeout > 0 {
            var cancel context.CancelFunc
            ctx, cancel = context.WithTimeout(ctx, r.timeout)
            defer cancel()
        }
        var err error
        result, err = Execute(ctx, r.breaker, func(ctx context.Context) (T, error) {
            return DoWithData(ctx, fn, append([]retry.Option{RetryIfRetryable()}, r.retry...)...)
        })
        return err
    }

    var err error
    if r.bulkhead != nil {
        err = r.bulkhead.Execute(ctx, run)
    } else {
        err = run(ctx)
    }
    return r.finish(ctx, result, err)
}

func (r *ResilientCall[T]) finish(ctx context.Context, result T, err error) (T, error) {
    if err != nil && r.fallback != nil {
        return r.fallback(ctx, err)
    }
    return result, err
}
```

### Builder

```go
package resilience

import (
    "context"
    "time"

    "github.com/avast/retry-go/v5"
    "github.com/sony/gobreaker/v2"
)

type ResilientCallBuilder[T any] struct{ call *ResilientCall[T] }

func NewResilientCall[T any](name string) *ResilientCallBuilder[T] {
    return &ResilientCallBuilder[T]{call: &ResilientCall[T]{
        breaker: NewBreaker[T](name, ConsecutiveFailures(5)),
        timeout: 10 * time.Second,
    }}
}

func (b *ResilientCallBuilder[T]) WithBreaker(cb *gobreaker.CircuitBreaker[T]) *ResilientCallBuilder[T] {
    b.call.breaker = cb
    return b
}

func (b *ResilientCallBuilder[T]) WithRateLimiter(l *TokenBucket) *ResilientCallBuilder[T] {
    b.call.limiter = l
    return b
}

func (b *ResilientCallBuilder[T]) WithBulkhead(bh *Bulkhead) *ResilientCallBuilder[T] {
    b.call.bulkhead = bh
    return b
}

func (b *ResilientCallBuilder[T]) WithTimeout(d time.Duration) *ResilientCallBuilder[T] {
    b.call.timeout = d
    return b
}

func (b *ResilientCallBuilder[T]) WithRetry(opts ...retry.Option) *ResilientCallBuilder[T] {
    b.call.retry = opts
    return b
}

func (b *ResilientCallBuilder[T]) WithFallback(fb func(context.Context, error) (T, error)) *ResilientCallBuilder[T] {
    b.call.fallback = fb
    return b
}

func (b *ResilientCallBuilder[T]) Build() *ResilientCall[T] { return b.call }

// 使用
func exampleResilientCall(ctx context.Context, client UserClient, cache UserCache, id string) (*User, error) {
    call := NewResilientCall[*User]("user-service").
        WithRateLimiter(NewTokenBucket(100, 200)).
        WithBulkhead(NewBulkhead(20, 50*time.Millisecond)).
        WithTimeout(5 * time.Second).
        WithRetry(retry.Attempts(3), retry.Delay(50*time.Millisecond)).
        WithFallback(func(ctx context.Context, err error) (*User, error) {
            if u, ok := cache.Get(ctx, id); ok {
                return u, nil
            }
            return nil, err
        }).
        Build()

    return call.Execute(ctx, func(ctx context.Context) (*User, error) {
        return client.Get(ctx, id)
    })
}
```
