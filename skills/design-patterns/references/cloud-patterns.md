# 云架构模式 - 完整代码实现

## 目录

- [可靠性模式](#可靠性模式)
  - [断路器 Circuit Breaker](#断路器circuit-breaker)
  - [重试 Retry](#重试retry)
  - [隔离 Bulkhead](#隔离bulkhead)
  - [限流 Rate Limiting](#限流rate-limiting)
- [数据一致性模式](#数据一致性模式)
  - [Saga 模式](#saga-模式)
  - [事件溯源 Event Sourcing](#事件溯源event-sourcing)
  - [CQRS](#cqrs命令查询职责分离)
- [消息通信模式](#消息通信模式)
  - [发布/订阅 Pub/Sub](#发布订阅pubsub)
  - [竞争消费者 Competing Consumers](#竞争消费者competing-consumers)
- [API 网关模式](#api-网关模式)
  - [网关聚合 Gateway Aggregation](#网关聚合gateway-aggregation)
  - [BFF Backend for Frontend](#bffbackend-for-frontend)
  - [Strangler Fig 绞杀者模式](#strangler-fig绞杀者模式)
  - [Sidecar 边车模式](#sidecar边车模式)
  - [Ambassador 大使模式](#ambassador大使模式)
  - [API Gateway](#api-gatewayapi-网关)
- [架构决策记录 ADR](#架构决策记录adr)

---

## 可靠性模式

### 断路器（Circuit Breaker）

**意图**：防止应用程序反复执行可能失败的操作

```go
import "github.com/sony/gobreaker/v2"

cb := gobreaker.NewCircuitBreaker[*http.Response](gobreaker.Settings{
    Name:        "api-breaker",
    MaxRequests: 3,                // 半开状态最大请求数
    Interval:    10 * time.Second, // 统计周期
    Timeout:     30 * time.Second, // 开启后多久尝试半开
    ReadyToTrip: func(counts gobreaker.Counts) bool {
        return counts.ConsecutiveFailures > 5
    },
})

resp, err := cb.Execute(func() (*http.Response, error) {
    return http.Get("https://api.example.com")
})
```

### 重试（Retry）

**意图**：通过透明重试处理临时故障

```go
import "github.com/avast/retry-go/v5"

err := retry.Do(
    func() error {
        return callExternalAPI()
    },
    retry.Attempts(5),
    retry.Delay(100*time.Millisecond),
    retry.MaxDelay(5*time.Second),
    retry.DelayType(retry.BackOffDelay),
    retry.RetryIf(func(err error) bool {
        return errors.Is(err, ErrTemporary)
    }),
)
```

### 隔离（Bulkhead）

**意图**：隔离应用程序元素，使一个元素故障不影响其他元素

```go
type Bulkhead struct {
    sem chan struct{}
}

func NewBulkhead(maxConcurrent int) *Bulkhead {
    return &Bulkhead{sem: make(chan struct{}, maxConcurrent)}
}

func (b *Bulkhead) Execute(ctx context.Context, fn func() error) error {
    select {
    case b.sem <- struct{}{}:
        defer func() { <-b.sem }()
        return fn()
    case <-ctx.Done():
        return ctx.Err()
    }
}

// 为不同服务创建独立隔离舱
var (
    paymentBulkhead  = NewBulkhead(10)
    inventoryBulkhead = NewBulkhead(20)
)
```

### 限流（Rate Limiting / Throttling）

**意图**：控制资源消耗速率

```go
import "golang.org/x/time/rate"

// 令牌桶限流器
limiter := rate.NewLimiter(rate.Limit(100), 10) // 100 QPS, burst 10

func handleRequest(ctx context.Context) error {
    if err := limiter.Wait(ctx); err != nil {
        return err
    }
    return processRequest()
}

// 或使用 Allow() 非阻塞检查
if !limiter.Allow() {
    return ErrRateLimited
}
```

---

## 数据一致性模式

### Saga 模式

**意图**：在分布式事务中管理数据一致性

```go
type SagaStep struct {
    Name       string
    Execute    func(ctx context.Context) error
    Compensate func(ctx context.Context) error
}

type Saga struct {
    steps []SagaStep
}

func (s *Saga) Run(ctx context.Context) error {
    executed := []SagaStep{}

    for _, step := range s.steps {
        if err := step.Execute(ctx); err != nil {
            // 执行补偿
            for i := len(executed) - 1; i >= 0; i-- {
                if compErr := executed[i].Compensate(ctx); compErr != nil {
                    log.Printf("compensation failed for %s: %v", executed[i].Name, compErr)
                }
            }
            return fmt.Errorf("saga failed at %s: %w", step.Name, err)
        }
        executed = append(executed, step)
    }
    return nil
}

// 使用
orderSaga := &Saga{
    steps: []SagaStep{
        {Name: "reserve_inventory", Execute: reserveInventory, Compensate: releaseInventory},
        {Name: "charge_payment", Execute: chargePayment, Compensate: refundPayment},
        {Name: "create_shipment", Execute: createShipment, Compensate: cancelShipment},
    },
}
```

### 事件溯源（Event Sourcing）

**意图**：使用追加式事件存储记录完整的状态变化历史

```go
type Event struct {
    ID        string
    Type      string
    AggregateID string
    Data      json.RawMessage
    Timestamp time.Time
    Version   int
}

type EventStore interface {
    Append(ctx context.Context, events ...Event) error
    Load(ctx context.Context, aggregateID string) ([]Event, error)
}

type Account struct {
    ID      string
    Balance int
    Version int
}

func (a *Account) Apply(event Event) {
    switch event.Type {
    case "AccountCreated":
        var data struct{ InitialBalance int }
        json.Unmarshal(event.Data, &data)
        a.Balance = data.InitialBalance
    case "MoneyDeposited":
        var data struct{ Amount int }
        json.Unmarshal(event.Data, &data)
        a.Balance += data.Amount
    case "MoneyWithdrawn":
        var data struct{ Amount int }
        json.Unmarshal(event.Data, &data)
        a.Balance -= data.Amount
    }
    a.Version = event.Version
}

func LoadAccount(ctx context.Context, store EventStore, id string) (*Account, error) {
    events, err := store.Load(ctx, id)
    if err != nil {
        return nil, err
    }

    account := &Account{ID: id}
    for _, e := range events {
        account.Apply(e)
    }
    return account, nil
}
```

### CQRS（命令查询职责分离）

**意图**：分离读写操作以独立优化

```go
// 命令端（写）
type OrderCommandService struct {
    repo  OrderRepository
    bus   EventBus
}

func (s *OrderCommandService) CreateOrder(ctx context.Context, cmd CreateOrderCommand) error {
    order := NewOrder(cmd)
    if err := s.repo.Save(ctx, order); err != nil {
        return err
    }
    return s.bus.Publish(OrderCreatedEvent{Order: order})
}

// 查询端（读）
type OrderQueryService struct {
    readDB *sql.DB // 优化的读库
}

func (s *OrderQueryService) GetOrderSummary(ctx context.Context, id string) (*OrderSummaryDTO, error) {
    // 从专门优化的读模型查询
    return s.readDB.Query(ctx, "SELECT ... FROM order_summary_view WHERE id = ?", id)
}
```

---

## 消息通信模式

### 发布/订阅（Pub/Sub）

**意图**：异步广播事件给多个消费者

```go
type Publisher interface {
    Publish(ctx context.Context, topic string, msg Message) error
}

type Subscriber interface {
    Subscribe(ctx context.Context, topic string, handler func(Message)) error
}

// 使用 Kafka
func (p *KafkaPublisher) Publish(ctx context.Context, topic string, msg Message) error {
    return p.producer.Produce(&kafka.Message{
        TopicPartition: kafka.TopicPartition{Topic: &topic},
        Key:            []byte(msg.Key),
        Value:          msg.Data,
    }, nil)
}
```

### 竞争消费者（Competing Consumers）

**意图**：多个消费者并行处理消息队列

```go
func startConsumers(ctx context.Context, queue Queue, workers int, handler func(Message) error) {
    for i := 0; i < workers; i++ {
        go func(workerID int) {
            for {
                select {
                case <-ctx.Done():
                    return
                default:
                    msg, err := queue.Receive(ctx)
                    if err != nil {
                        continue
                    }
                    if err := handler(msg); err != nil {
                        queue.Nack(ctx, msg)
                    } else {
                        queue.Ack(ctx, msg)
                    }
                }
            }
        }(i)
    }
}
```

---

## API 网关模式

### 网关聚合（Gateway Aggregation）

**意图**：将多个微服务请求聚合为单个请求

```go
type ProductPageData struct {
    Product  *Product
    Reviews  []*Review
    Related  []*Product
    Inventory *InventoryStatus
}

func (g *Gateway) GetProductPage(ctx context.Context, productID string) (*ProductPageData, error) {
    var (
        result ProductPageData
        errs   []error
        mu     sync.Mutex
    )

    var wg sync.WaitGroup
    wg.Add(4)

    go func() {
        defer wg.Done()
        product, err := g.productService.Get(ctx, productID)
        mu.Lock()
        result.Product = product
        if err != nil { errs = append(errs, err) }
        mu.Unlock()
    }()

    go func() {
        defer wg.Done()
        reviews, err := g.reviewService.List(ctx, productID)
        mu.Lock()
        result.Reviews = reviews
        if err != nil { errs = append(errs, err) }
        mu.Unlock()
    }()

    // ... 其他并行请求

    wg.Wait()

    if len(errs) > 0 {
        return nil, errors.Join(errs...)
    }
    return &result, nil
}
```

### BFF（Backend for Frontend）

**意图**：为不同前端创建专用后端

```go
// Mobile BFF - 返回精简数据
type MobileBFF struct {
    services *Services
}

func (b *MobileBFF) GetUserDashboard(ctx context.Context, userID string) (*MobileDashboard, error) {
    // 返回移动端优化的数据结构
    return &MobileDashboard{
        Summary:     b.services.GetSummary(ctx, userID),
        RecentItems: b.services.GetRecent(ctx, userID, 5), // 只取5条
    }
}

// Web BFF - 返回完整数据
type WebBFF struct {
    services *Services
}

func (b *WebBFF) GetUserDashboard(ctx context.Context, userID string) (*WebDashboard, error) {
    // 返回 Web 端完整数据
    return &WebDashboard{
        Summary:      b.services.GetSummary(ctx, userID),
        RecentItems:  b.services.GetRecent(ctx, userID, 50),
        Analytics:    b.services.GetAnalytics(ctx, userID),
        Recommendations: b.services.GetRecommendations(ctx, userID),
    }
}
```

### Strangler Fig（绞杀者模式）

**意图**：渐进式迁移遗留系统，逐步用新服务替换旧功能

```go
// 路由层决定走新系统还是旧系统
type StranglerRouter struct {
    legacyService LegacyService
    newService    NewService
    featureFlags  FeatureFlags
}

func (r *StranglerRouter) GetUser(ctx context.Context, id string) (*User, error) {
    // 通过特性开关决定路由
    if r.featureFlags.IsEnabled(ctx, "new-user-service") {
        return r.newService.GetUser(ctx, id)
    }
    return r.legacyService.GetUser(ctx, id)
}

// 渐进式迁移：按用户百分比
func (r *StranglerRouter) GetOrder(ctx context.Context, userID, orderID string) (*Order, error) {
    // 10% 用户走新系统
    if r.featureFlags.IsEnabledForUser(ctx, "new-order-service", userID, 10) {
        return r.newService.GetOrder(ctx, orderID)
    }
    return r.legacyService.GetOrder(ctx, orderID)
}

// 对比模式：同时调用新旧系统，比较结果
func (r *StranglerRouter) GetUserWithShadow(ctx context.Context, id string) (*User, error) {
    // 始终返回旧系统结果
    result, err := r.legacyService.GetUser(ctx, id)

    // 异步调用新系统并比较
    go func() {
        newResult, newErr := r.newService.GetUser(ctx, id)
        r.compare("GetUser", result, newResult, err, newErr)
    }()

    return result, err
}
```

**迁移步骤**：识别边界 -> 抽象接口 -> 实现新服务 -> 影子对比 -> 逐步切流 -> 下线旧系统

### Sidecar（边车模式）

**意图**：将辅助功能作为独立进程部署在主应用旁边

```go
// Sidecar 代理：为主应用添加可观测性
type SidecarProxy struct {
    target  string
    metrics *prometheus.Registry
    tracer  trace.Tracer
}

func (p *SidecarProxy) ServeHTTP(w http.ResponseWriter, r *http.Request) {
    start := time.Now()
    ctx, span := p.tracer.Start(r.Context(), r.URL.Path)
    defer span.End()

    // 代理到主应用
    proxyReq, _ := http.NewRequestWithContext(ctx, r.Method, p.target+r.URL.Path, r.Body)
    resp, err := http.DefaultClient.Do(proxyReq)
    if err != nil {
        span.RecordError(err)
        http.Error(w, err.Error(), http.StatusBadGateway)
        return
    }
    defer resp.Body.Close()

    p.recordMetrics(r.URL.Path, resp.StatusCode, time.Since(start))
    copyResponse(w, resp)
}
```

**典型 Sidecar**：日志收集(Fluentd)、服务发现(Consul)、流量管理(Envoy)

### Ambassador（大使模式）

**意图**：代理本地与远程服务通信，处理重试、熔断、认证

```go
type Ambassador struct {
    client    *http.Client
    breaker   *gobreaker.CircuitBreaker[*http.Response]
    rateLimit *rate.Limiter
    auth      AuthProvider
}

func (a *Ambassador) Do(ctx context.Context, req *http.Request) (*http.Response, error) {
    // 限流
    if err := a.rateLimit.Wait(ctx); err != nil {
        return nil, err
    }

    // 认证
    token, _ := a.auth.GetToken(ctx)
    req.Header.Set("Authorization", "Bearer "+token)

    // 熔断 + 代理
    return a.breaker.Execute(func() (*http.Response, error) {
        return a.client.Do(req.WithContext(ctx))
    })
}
```

### API Gateway（API 网关）

**意图**：统一入口处理认证、路由、限流、协议转换

```go
type APIGateway struct {
    routes   map[string]RouteConfig
    auth     AuthMiddleware
    limiter  RateLimiter
    breakers map[string]*gobreaker.CircuitBreaker[*http.Response]
}

func (g *APIGateway) ServeHTTP(w http.ResponseWriter, r *http.Request) {
    route, found := g.matchRoute(r.URL.Path)
    if !found {
        http.NotFound(w, r)
        return
    }

    // 认证 -> 限流 -> 熔断代理
    if route.RequireAuth {
        if err := g.auth.Authenticate(r); err != nil {
            http.Error(w, "Unauthorized", http.StatusUnauthorized)
            return
        }
    }

    if !g.limiter.Allow(r.RemoteAddr, route.RateLimit) {
        http.Error(w, "Rate limited", http.StatusTooManyRequests)
        return
    }

    resp, err := g.breakers[route.Upstream].Execute(func() (*http.Response, error) {
        return g.proxyRequest(r, route)
    })
    if err != nil {
        http.Error(w, "Service unavailable", http.StatusServiceUnavailable)
        return
    }
    g.writeResponse(w, resp)
}
```

**网关职责**：认证授权 -> 路由 -> 限流 -> 熔断 -> 协议转换 -> 日志追踪

---

## 架构决策记录（ADR）

### 为什么需要 ADR

- 防止"短期记忆"和决策循环
- 记录架构决策的上下文和理由
- 便于团队成员理解历史决策

### ADR 模板

```markdown
# ADR-00X: 标题

**状态**: Draft | Proposed | Accepted | Deprecated | Superseded by ADR-XXX
**日期**: YYYY-MM-DD
**决策者**: [参与人员/团队]

## 背景

是什么问题促使我们做出这个决策？有什么约束条件？

## 考虑的选项

### 选项 1: [名称]
- 描述
- **优点**: ...
- **缺点**: ...

### 选项 2: [名称]
- 描述
- **优点**: ...
- **缺点**: ...

## 决策

我们选择**选项 X**，因为...

## 后果

### 正面
- ...

### 负面
- ...

### 风险
- ...
```

### ADR 示例

```markdown
# ADR-001: 使用 PostgreSQL 作为主数据库

**状态**: Accepted
**日期**: 2024-01-15
**决策者**: 后端团队

## 背景

我们需要为新项目选择主数据库。要求：
- 支持复杂查询和事务
- 良好的 Go 生态支持
- 可扩展性
- 团队熟悉度

## 考虑的选项

### 选项 1: PostgreSQL
- 成熟的关系型数据库
- **优点**: 强大的 SQL 支持、pgx 驱动性能优秀、团队熟悉
- **缺点**: 运维复杂度较 MySQL 略高

### 选项 2: MySQL
- 流行的关系型数据库
- **优点**: 广泛使用、文档丰富
- **缺点**: JSON 支持不如 PG、部分高级特性缺失

### 选项 3: MongoDB
- 文档型数据库
- **优点**: 灵活的 schema、水平扩展
- **缺点**: 事务支持较弱、不适合复杂关联查询

## 决策

选择 **PostgreSQL**，因为：
1. 团队有丰富经验
2. pgx 驱动性能优秀
3. 支持 JSONB 满足半结构化需求
4. 强事务保证

## 后果

### 正面
- 可利用团队现有经验
- 良好的查询性能

### 负面
- 需要配置主从复制实现高可用

### 风险
- 单点故障（通过主从复制缓解）
```

### ADR 生命周期

1. **Draft** -- 初稿，征求意见
2. **Proposed** -- 正式提议，待审核
3. **Accepted** -- 已接受，开始实施
4. **Deprecated** -- 已弃用
5. **Superseded** -- 被新 ADR 取代

### 工作流：设计新功能

1. **分析需求**：理解目标和约束
2. **起草 ADR**：在 `design/` 创建文档
3. **评审**：团队讨论选项
4. **修订**：根据反馈更新
5. **决策**：标记为 Accepted
6. **实施**：开始编码
