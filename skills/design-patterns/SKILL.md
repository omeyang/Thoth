---
name: design-patterns
description: "设计模式与架构专家 - 覆盖 GoF 经典模式(创建型/结构型/行为型)、云架构模式(熔断/Saga/CQRS/事件溯源)、Go 并发模式(Pipeline/Fan-Out/Worker Pool)、SOLID/Clean Architecture、ADR 架构决策记录。适用：系统设计、代码重构、架构决策、分布式系统设计、微服务拆分。不适用：纯业务逻辑实现(无架构决策)、简单 CRUD 无需模式、性能调优(应使用 go-test 基准测试)。触发词：设计模式, design pattern, 架构, architecture, SOLID, 重构, refactor, 工厂, 单例, 策略, 观察者, 熔断, saga, CQRS, 中间件, middleware"
user-invocable: true
allowed-tools: Bash, Read, Write, Edit, Grep, Glob
---

# 设计模式与架构专家

使用设计模式解决：$ARGUMENTS

---

## 第一部分：GoF 经典设计模式

### 创建型模式（6种）

| 模式 | 意图 | Go 惯用签名 |
|------|------|-------------|
| 单例 Singleton | 确保唯一实例 | `sync.Once` + `GetInstance()` |
| 工厂方法 Factory Method | 按条件创建不同实现 | `func NewStorage(typ string) (Storage, error)` |
| 抽象工厂 Abstract Factory | 创建相关对象家族 | `type UIFactory interface { CreateButton(); CreateDialog() }` |
| 建造者 Builder | 分步构建复杂对象 | `NewBuilder().Host(h).Port(p).Build()` |
| 函数选项 Functional Options | Go 惯用灵活配置 | `func NewClient(addr string, opts ...Option)` |
| 原型 Prototype | 克隆现有对象 | `type Cloneable interface { Clone() Cloneable }` |

### 结构型模式（7种）

| 模式 | 意图 | Go 惯用签名 |
|------|------|-------------|
| 适配器 Adapter | 接口转换 | `type ZapAdapter struct{ zap *zap.Logger }` |
| 桥接 Bridge | 抽象与实现分离 | 组合接口字段 |
| 组合 Composite | 树形部分-整体 | `type Component interface { Execute(); Add(Component) }` |
| 装饰器 Decorator | 动态添加职责 | `func WithLogging(h Handler) Handler` |
| 外观 Facade | 统一高层接口 | `type OrderFacade struct { inventory; payment; shipping }` |
| 享元 Flyweight | 共享细粒度对象 | `sync.RWMutex` + `map` 缓存 |
| 代理 Proxy | 控制访问 | `CachingProxy` / `LazyProxy` |

### 行为型模式（10种）

| 模式 | 意图 | Go 惯用签名 |
|------|------|-------------|
| 责任链 Chain of Responsibility | 多处理者链 | `type Middleware func(http.Handler) http.Handler` |
| 命令 Command | 请求封装为对象 | `type Command interface { Execute() error; Undo() error }` |
| 迭代器 Iterator | 顺序访问元素 | Go 1.23+ `iter.Seq[T]` |
| 中介者 Mediator | 封装对象交互 | `EventBus` + `Subscribe/Publish` |
| 备忘录 Memento | 捕获内部状态 | `Save() *Memento` / `Restore(*Memento)` |
| 观察者 Observer | 一对多依赖通知 | `Attach(Observer)` / `Notify(Event)` 或 channel |
| 状态 State | 内部状态改变行为 | `type OrderState interface { Process(); Cancel(); Ship() }` |
| 策略 Strategy | 算法可互换 | `type Compressor interface { Compress(); Decompress() }` |
| 模板方法 Template Method | 算法骨架延迟步骤 | 接口定义步骤 + 顶层函数编排 |
| 访问者 Visitor | 不改变类定义新操作 | `type Visitor interface { VisitFile(); VisitDirectory() }` |

> 详细代码实现见 [references/creational.md](references/creational.md)、[references/structural.md](references/structural.md)、[references/behavioral.md](references/behavioral.md)

---

## 第二部分：云架构模式（分布式系统）

### 可靠性模式

| 模式 | 意图 | 关键库/签名 |
|------|------|-------------|
| 断路器 Circuit Breaker | 防止反复失败操作 | `gobreaker.NewCircuitBreaker(Settings{})` |
| 重试 Retry | 透明重试临时故障 | `retry.Do(fn, retry.Attempts(5), retry.BackOffDelay)` |
| 隔离 Bulkhead | 故障隔离 | `sem chan struct{}` 信号量 |
| 限流 Rate Limiting | 控制消耗速率 | `rate.NewLimiter(rate.Limit(100), 10)` |

### 数据一致性模式

| 模式 | 意图 | 核心结构 |
|------|------|---------|
| Saga | 分布式事务补偿 | `[]SagaStep{Execute, Compensate}` |
| 事件溯源 Event Sourcing | 追加式事件存储 | `EventStore.Append()` + `Aggregate.Apply(Event)` |
| CQRS | 读写分离优化 | `CommandService`(写) + `QueryService`(读) |

### 消息通信模式

| 模式 | 意图 |
|------|------|
| 发布/订阅 Pub/Sub | 异步广播事件 |
| 竞争消费者 Competing Consumers | 多消费者并行处理 |

### API 网关模式

| 模式 | 意图 |
|------|------|
| 网关聚合 Gateway Aggregation | 多服务请求聚合 |
| BFF Backend for Frontend | 不同前端专用后端 |
| Strangler Fig 绞杀者 | 渐进式遗留迁移 |
| Sidecar 边车 | 辅助功能独立部署 |
| Ambassador 大使 | 代理远程通信(重试/熔断/认证) |
| API Gateway | 统一入口(认证/路由/限流) |

> 详细代码实现见 [references/cloud-patterns.md](references/cloud-patterns.md)

---

## 第三部分：Go 并发模式

### Pipeline 模式

```go
func generator[T any](items ...T) <-chan T
func transform[T, R any](in <-chan T, fn func(T) R) <-chan R
func filter[T any](in <-chan T, predicate func(T) bool) <-chan T
```

### Fan-Out/Fan-In 模式

```go
func fanOut[T any](in <-chan T, workers int, process func(T) T) []<-chan T
func fanIn[T any](channels ...<-chan T) <-chan T
```

### Worker Pool 模式

```go
type WorkerPool[T, R any] struct { workers int; jobs chan T; results chan R; process func(T) R }
func (p *WorkerPool[T, R]) Start(ctx context.Context)
func (p *WorkerPool[T, R]) Submit(job T)
```

### errgroup 并发控制

```go
g, ctx := errgroup.WithContext(ctx)
g.SetLimit(10) // 最多 10 个并发
g.Go(func() error { ... })
g.Wait()
```

> 详细代码实现见 [references/concurrency.md](references/concurrency.md)

---

## 第四部分：架构原则

### SOLID 原则

| 原则 | 说明 | Go 实践 |
|------|------|---------|
| **S**ingle Responsibility | 一个类只做一件事 | 小接口、小包 |
| **O**pen/Closed | 对扩展开放，对修改关闭 | 接口 + 组合 |
| **L**iskov Substitution | 子类可替换父类 | 接口契约 |
| **I**nterface Segregation | 接口最小化 | 小接口（1-3 方法）|
| **D**ependency Inversion | 依赖抽象而非具体 | 依赖注入 |

### Clean Architecture 分层

```
┌────────────────────────────────────────┐
│           Frameworks & Drivers         │  <- HTTP, gRPC, DB, External
├────────────────────────────────────────┤
│          Interface Adapters            │  <- Controllers, Presenters, Gateways
├────────────────────────────────────────┤
│           Application/Use Cases        │  <- Business Logic Orchestration
├────────────────────────────────────────┤
│              Domain/Entities           │  <- Core Business Rules
└────────────────────────────────────────┘

依赖方向：外层依赖内层，内层不知道外层
```

```go
// Domain 层
type UserRepository interface {
    FindByID(ctx context.Context, id string) (*User, error)
    Save(ctx context.Context, user *User) error
}

// Use Case 层
type CreateUserUseCase struct { repo UserRepository }

// Interface Adapter 层
type UserHandler struct { useCase *CreateUserUseCase }

// Infrastructure 层
type PostgresUserRepository struct { db *sql.DB }
```

---

## 第五部分：架构决策记录（ADR）

### 何时创建 ADR

- 新功能的架构设计
- 依赖变更（添加/移除重要依赖）
- 重大重构 / 技术栈选择

### ADR 存放与模板

```
project/
└── design/
    ├── ADR-001-database-selection.md
    └── ADR-002-authentication-strategy.md
```

模板结构：**状态** -> **背景** -> **考虑的选项** -> **决策** -> **后果（正面/负面/风险）**

生命周期：Draft -> Proposed -> Accepted -> Deprecated / Superseded

> 完整 ADR 模板和示例见 [references/cloud-patterns.md](references/cloud-patterns.md) 末尾

---

## 模式选择指南

| 问题场景 | 推荐模式 |
|----------|----------|
| 对象创建复杂 | Builder / Functional Options |
| 根据条件创建不同对象 | Factory Method / Abstract Factory |
| 全局唯一实例 | Singleton (sync.Once) |
| 为已有类型添加功能 | Decorator / Adapter |
| 算法可互换 | Strategy |
| 对象状态决定行为 | State |
| 请求处理链 | Chain of Responsibility / Middleware |
| 事件通知 | Observer / Pub-Sub |
| 分布式事务 | Saga / 补偿事务 |
| 防止级联故障 | Circuit Breaker / Bulkhead |
| 处理临时故障 | Retry with Backoff |
| 读写分离优化 | CQRS |
| 审计追溯 | Event Sourcing |
| 并发任务处理 | Worker Pool / errgroup |
| 数据流处理 | Pipeline / Fan-Out/Fan-In |
| 限制并发数 | Semaphore / Bulkhead |
| 微服务网关 | Gateway Aggregation / BFF |

---

## 参考资料

- [references/creational.md](references/creational.md) - 创建型模式完整代码
- [references/structural.md](references/structural.md) - 结构型模式完整代码
- [references/behavioral.md](references/behavioral.md) - 行为型模式完整代码
- [references/cloud-patterns.md](references/cloud-patterns.md) - 云架构模式 + 并发模式 + ADR
- [references/concurrency.md](references/concurrency.md) - Go 并发模式完整代码
- [Refactoring Guru 设计模式](https://refactoringguru.cn/design-patterns)
- [Microsoft 云架构模式](https://learn.microsoft.com/zh-cn/azure/architecture/patterns/)
- [Go Patterns](https://github.com/tmrts/go-patterns)
- [ADR GitHub Organization](https://adr.github.io/)
