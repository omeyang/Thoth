# Go 韧性模式 - 完整代码实现

## 目录

- [熔断器高级用法](#熔断器高级用法)
- [自定义重试策略](#自定义重试策略)
- [限流高级模式](#限流高级模式)
- [舱壁隔离高级模式](#舱壁隔离高级模式)
- [缓存降级](#缓存降级)
- [组合弹性调用](#组合弹性调用)

---

## 熔断器高级用法

### 自定义策略

```go
// 连续失败策略
type ConsecutiveFailurePolicy struct {
    threshold int
}

func (p *ConsecutiveFailurePolicy) ReadyToTrip(counts gobreaker.Counts) bool {
    return counts.ConsecutiveFailures >= uint32(p.threshold)
}

// 错误率+最小请求策略
type ErrorRatePolicy struct {
    minRequests  int
    errorRate    float64
}

func (p *ErrorRatePolicy) ReadyToTrip(counts gobreaker.Counts) bool {
    if counts.Requests < uint32(p.minRequests) {
        return false
    }
    return float64(counts.TotalFailures)/float64(counts.Requests) >= p.errorRate
}

// 超时率策略
type TimeoutPolicy struct {
    minRequests int
    timeoutRate float64
}

func (p *TimeoutPolicy) ReadyToTrip(counts gobreaker.Counts) bool {
    // 需要自定义计数器追踪超时
    return false
}
```

### HTTP 客户端集成

```go
type ResilientHTTPClient struct {
    client  *http.Client
    breaker *gobreaker.CircuitBreaker[*http.Response]
}

func NewResilientHTTPClient() *ResilientHTTPClient {
    return &ResilientHTTPClient{
        client: &http.Client{
            Timeout: 10 * time.Second,
        },
        breaker: gobreaker.NewCircuitBreaker[*http.Response](gobreaker.Settings{
            Name:        "http-client",
            MaxRequests: 3,
            Timeout:     30 * time.Second,
            ReadyToTrip: func(counts gobreaker.Counts) bool {
                return counts.ConsecutiveFailures >= 5
            },
        }),
    }
}

func (c *ResilientHTTPClient) Do(req *http.Request) (*http.Response, error) {
    return c.breaker.Execute(func() (*http.Response, error) {
        resp, err := c.client.Do(req)
        if err != nil {
            return nil, err
        }

        // 5xx 视为失败
        if resp.StatusCode >= 500 {
            resp.Body.Close()
            return nil, fmt.Errorf("server error: %d", resp.StatusCode)
        }

        return resp, nil
    })
}
```

### 熔断降级示例

```go
func (s *Service) GetUser(ctx context.Context, id string) (*User, error) {
    result, err := CallWithBreaker(ctx, s.userServiceBreaker, func() (*User, error) {
        return s.userClient.Get(ctx, id)
    })

    if errors.Is(err, gobreaker.ErrOpenState) {
        // 熔断器开启，返回降级响应
        return s.getCachedUser(ctx, id)
    }

    return result, err
}
```

---

## 自定义重试策略

### 重试策略接口

```go
type RetryPolicy interface {
    ShouldRetry(err error, attempt int) bool
    Delay(attempt int) time.Duration
}
```

### 指数退避策略

```go
type ExponentialBackoff struct {
    MaxAttempts  int
    InitialDelay time.Duration
    MaxDelay     time.Duration
    Multiplier   float64
    Jitter       float64
}

func (e *ExponentialBackoff) ShouldRetry(err error, attempt int) bool {
    if attempt >= e.MaxAttempts {
        return false
    }
    return isRetryable(err)
}

func (e *ExponentialBackoff) Delay(attempt int) time.Duration {
    delay := float64(e.InitialDelay) * math.Pow(e.Multiplier, float64(attempt))
    if delay > float64(e.MaxDelay) {
        delay = float64(e.MaxDelay)
    }

    // 添加抖动
    if e.Jitter > 0 {
        jitter := delay * e.Jitter * (rand.Float64()*2 - 1)
        delay += jitter
    }

    // 确保延迟不为负数
    if delay < 0 {
        delay = 0
    }

    return time.Duration(delay)
}
```

### 固定延迟策略

```go
type FixedDelay struct {
    MaxAttempts int
    Delay       time.Duration
}

func (f *FixedDelay) ShouldRetry(err error, attempt int) bool {
    return attempt < f.MaxAttempts && isRetryable(err)
}

func (f *FixedDelay) Delay(attempt int) time.Duration {
    return f.Delay
}
```

### 通用重试执行器

```go
func Retry[T any](ctx context.Context, policy RetryPolicy, fn func() (T, error)) (T, error) {
    var result T
    var lastErr error

    for attempt := 0; ; attempt++ {
        result, lastErr = fn()
        if lastErr == nil {
            return result, nil
        }

        if !policy.ShouldRetry(lastErr, attempt) {
            break
        }

        delay := policy.Delay(attempt)
        select {
        case <-ctx.Done():
            return result, ctx.Err()
        case <-time.After(delay):
        }
    }

    return result, lastErr
}
```

### 永久错误完整实现

```go
type PermanentError struct {
    Err error
}

func (e *PermanentError) Error() string {
    return e.Err.Error()
}

func (e *PermanentError) Unwrap() error {
    return e.Err
}

func NewPermanentError(err error) error {
    return &PermanentError{Err: err}
}

func IsPermanent(err error) bool {
    var pe *PermanentError
    return errors.As(err, &pe)
}

// 使用
func ProcessOrder(ctx context.Context, order *Order) error {
    return Retry(ctx, policy, func() error {
        if order.ID == "" {
            return NewPermanentError(ErrInvalidOrder) // 不重试
        }

        return callExternalService(ctx, order)
    })
}
```

---

## 限流高级模式

### 按 Key 限流

```go
type KeyedRateLimiter struct {
    limiters sync.Map
    rps      int
    burst    int
}

func NewKeyedRateLimiter(rps, burst int) *KeyedRateLimiter {
    return &KeyedRateLimiter{rps: rps, burst: burst}
}

func (k *KeyedRateLimiter) Allow(key string) bool {
    limiter, _ := k.limiters.LoadOrStore(key, rate.NewLimiter(rate.Limit(k.rps), k.burst))
    return limiter.(*rate.Limiter).Allow()
}

// 按用户限流中间件
func UserRateLimitMiddleware(limiter *KeyedRateLimiter) func(http.Handler) http.Handler {
    return func(next http.Handler) http.Handler {
        return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
            userID := r.Header.Get("X-User-ID")
            if userID == "" {
                userID = r.RemoteAddr
            }

            if !limiter.Allow(userID) {
                w.Header().Set("Retry-After", "1")
                http.Error(w, "rate limit exceeded", http.StatusTooManyRequests)
                return
            }

            next.ServeHTTP(w, r)
        })
    }
}
```

### 滑动窗口

```go
type SlidingWindowLimiter struct {
    mu       sync.Mutex
    requests []time.Time
    window   time.Duration
    limit    int
}

func NewSlidingWindowLimiter(window time.Duration, limit int) *SlidingWindowLimiter {
    return &SlidingWindowLimiter{
        window: window,
        limit:  limit,
    }
}

func (s *SlidingWindowLimiter) Allow() bool {
    s.mu.Lock()
    defer s.mu.Unlock()

    now := time.Now()
    cutoff := now.Add(-s.window)

    // 移除过期请求
    valid := s.requests[:0]
    for _, t := range s.requests {
        if t.After(cutoff) {
            valid = append(valid, t)
        }
    }
    s.requests = valid

    if len(s.requests) >= s.limit {
        return false
    }

    s.requests = append(s.requests, now)
    return true
}
```

### 令牌桶完整封装

```go
type RateLimiter struct {
    limiter *rate.Limiter
}

func NewRateLimiter(rps int, burst int) *RateLimiter {
    return &RateLimiter{
        limiter: rate.NewLimiter(rate.Limit(rps), burst),
    }
}

func (r *RateLimiter) Allow() bool {
    return r.limiter.Allow()
}

func (r *RateLimiter) Wait(ctx context.Context) error {
    return r.limiter.Wait(ctx)
}

func (r *RateLimiter) Reserve() *rate.Reservation {
    return r.limiter.Reserve()
}
```

---

## 舱壁隔离高级模式

### 按服务隔离

```go
type ServiceBulkheads struct {
    bulkheads map[string]*Bulkhead
    mu        sync.RWMutex
    config    BulkheadConfig
}

type BulkheadConfig struct {
    DefaultConcurrency int
    DefaultTimeout     time.Duration
    ServiceConfigs     map[string]struct {
        Concurrency int
        Timeout     time.Duration
    }
}

func (s *ServiceBulkheads) Get(service string) *Bulkhead {
    s.mu.RLock()
    if bh, ok := s.bulkheads[service]; ok {
        s.mu.RUnlock()
        return bh
    }
    s.mu.RUnlock()

    s.mu.Lock()
    defer s.mu.Unlock()

    // Double check
    if bh, ok := s.bulkheads[service]; ok {
        return bh
    }

    // 创建新的 bulkhead
    cfg := s.config.ServiceConfigs[service]
    if cfg.Concurrency == 0 {
        cfg.Concurrency = s.config.DefaultConcurrency
        cfg.Timeout = s.config.DefaultTimeout
    }

    bh := NewBulkhead(cfg.Concurrency, cfg.Timeout)
    s.bulkheads[service] = bh

    return bh
}
```

### Worker Pool 隔离

```go
type WorkerPool struct {
    jobs    chan func()
    quit    chan struct{}
    wg      sync.WaitGroup
}

func NewWorkerPool(workers, queueSize int) *WorkerPool {
    pool := &WorkerPool{
        jobs: make(chan func(), queueSize),
        quit: make(chan struct{}),
    }

    for i := 0; i < workers; i++ {
        pool.wg.Add(1)
        go pool.worker()
    }

    return pool
}

func (p *WorkerPool) worker() {
    defer p.wg.Done()
    for {
        select {
        case job := <-p.jobs:
            job()
        case <-p.quit:
            return
        }
    }
}

func (p *WorkerPool) Submit(ctx context.Context, fn func()) error {
    select {
    case p.jobs <- fn:
        return nil
    case <-ctx.Done():
        return ctx.Err()
    default:
        return ErrPoolFull
    }
}

func (p *WorkerPool) SubmitWait(ctx context.Context, fn func()) error {
    select {
    case p.jobs <- fn:
        return nil
    case <-ctx.Done():
        return ctx.Err()
    }
}

func (p *WorkerPool) Close() {
    close(p.quit)
    p.wg.Wait()
}
```

---

## 缓存降级

```go
type CacheFallback[T any] struct {
    cache   Cache[T]
    ttl     time.Duration
    staleTTL time.Duration // 允许使用过期缓存的时间
}

func (c *CacheFallback[T]) Execute(ctx context.Context, key string, loader func(context.Context) (T, error)) (T, error) {
    // 尝试从缓存获取
    if value, ok := c.cache.Get(key); ok {
        return value, nil
    }

    // 加载数据
    value, err := loader(ctx)
    if err != nil {
        // 尝试获取过期缓存
        if stale, ok := c.cache.GetStale(key); ok {
            slog.Warn("using stale cache",
                slog.String("key", key),
                slog.Any("error", err),
            )
            return stale, nil
        }
        return value, err
    }

    // 更新缓存
    c.cache.Set(key, value, c.ttl)

    return value, nil
}
```

### 降级使用示例

```go
func GetUserWithFallback(ctx context.Context, userID string) (*User, error) {
    fb := NewFallback(
        func(ctx context.Context) (*User, error) {
            return userService.GetUser(ctx, userID)
        },
        func(ctx context.Context, err error) (*User, error) {
            // 降级：从缓存获取
            if user := cache.Get(userID); user != nil {
                return user, nil
            }
            // 降级：返回默认值
            return &User{ID: userID, Name: "Unknown"}, nil
        },
    )

    return fb.Execute(ctx)
}
```

---

## 组合弹性调用

### 完整的弹性调用

```go
type ResilientCall[T any] struct {
    breaker  *gobreaker.CircuitBreaker[T]
    limiter  *RateLimiter
    bulkhead *Bulkhead
    retry    RetryPolicy
    timeout  time.Duration
    fallback func(context.Context, error) (T, error)
}

func (r *ResilientCall[T]) Execute(ctx context.Context, fn func(context.Context) (T, error)) (T, error) {
    var zero T

    // 1. 限流
    if !r.limiter.Allow() {
        if r.fallback != nil {
            return r.fallback(ctx, ErrRateLimited)
        }
        return zero, ErrRateLimited
    }

    // 2. 舱壁
    resultCh := make(chan T, 1)
    errCh := make(chan error, 1)

    err := r.bulkhead.Execute(ctx, func() error {
        // 3. 超时
        ctx, cancel := context.WithTimeout(ctx, r.timeout)
        defer cancel()

        // 4. 熔断 + 重试
        result, err := r.breaker.Execute(func() (T, error) {
            return Retry(ctx, r.retry, func() (T, error) {
                return fn(ctx)
            })
        })

        if err != nil {
            errCh <- err
            return err
        }

        resultCh <- result
        return nil
    })

    if err != nil {
        if r.fallback != nil {
            return r.fallback(ctx, err)
        }
        return zero, err
    }

    select {
    case result := <-resultCh:
        return result, nil
    case err := <-errCh:
        if r.fallback != nil {
            return r.fallback(ctx, err)
        }
        return zero, err
    }
}
```

### Builder 模式

```go
type ResilientCallBuilder[T any] struct {
    call *ResilientCall[T]
}

func NewResilientCallBuilder[T any]() *ResilientCallBuilder[T] {
    return &ResilientCallBuilder[T]{
        call: &ResilientCall[T]{
            timeout: 10 * time.Second,
        },
    }
}

func (b *ResilientCallBuilder[T]) WithCircuitBreaker(cb *gobreaker.CircuitBreaker[T]) *ResilientCallBuilder[T] {
    b.call.breaker = cb
    return b
}

func (b *ResilientCallBuilder[T]) WithRateLimiter(limiter *RateLimiter) *ResilientCallBuilder[T] {
    b.call.limiter = limiter
    return b
}

func (b *ResilientCallBuilder[T]) WithBulkhead(bh *Bulkhead) *ResilientCallBuilder[T] {
    b.call.bulkhead = bh
    return b
}

func (b *ResilientCallBuilder[T]) WithRetry(policy RetryPolicy) *ResilientCallBuilder[T] {
    b.call.retry = policy
    return b
}

func (b *ResilientCallBuilder[T]) WithTimeout(timeout time.Duration) *ResilientCallBuilder[T] {
    b.call.timeout = timeout
    return b
}

func (b *ResilientCallBuilder[T]) WithFallback(fallback func(context.Context, error) (T, error)) *ResilientCallBuilder[T] {
    b.call.fallback = fallback
    return b
}

func (b *ResilientCallBuilder[T]) Build() *ResilientCall[T] {
    return b.call
}

// 使用
call := NewResilientCallBuilder[*User]().
    WithCircuitBreaker(breaker).
    WithRateLimiter(limiter).
    WithBulkhead(bulkhead).
    WithRetry(&ExponentialBackoff{MaxAttempts: 3}).
    WithTimeout(5 * time.Second).
    WithFallback(func(ctx context.Context, err error) (*User, error) {
        return cache.GetUser(userID), nil
    }).
    Build()

user, err := call.Execute(ctx, func(ctx context.Context) (*User, error) {
    return userService.GetUser(ctx, userID)
})
```
