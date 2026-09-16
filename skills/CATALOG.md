# 技能包目录

技能包总数：23

| 技能包 | 描述 | 路径 |
|---|---|---|
| `algorithms` | 算法与数据结构专家 - 实现高效算法、选择合适数据结构、分析时间空间复杂度。使用场景：性能优化、算法设计、面试准备。 | `skills/algorithms/SKILL.md` |
| `api-design-go` | Go API 设计专家 - RESTful 规范、版本控制、分页策略、错误处理、HATEOAS、契约优先。使用场景：HTTP API、微服务接口、公开 API。 | `skills/api-design-go/SKILL.md` |
| `backend-patterns` | 后端架构模式专家 - 分层架构、Repository 模式、缓存策略、错误处理、认证授权、限流、队列、日志。使用场景：系统设计、架构决策、服务开发。 | `skills/backend-patterns/SKILL.md` |
| `clickhouse-go` | Go ClickHouse 专家 - OLAP 分析、表引擎选择、查询优化、批量插入、分页查询。使用场景：数据分析、实时报表、日志存储。 | `skills/clickhouse-go/SKILL.md` |
| `cr` | 代码审查专家 - 三种模式：local（本地快速审查）、pr（PR 差异审查）、teams（多 Agent 对抗审查）。覆盖 Go/Python/Shell，A/B/C 优先级检查清单，风险矩阵驱动修复决策。使用场景：代码审查、PR Review、安全扫描、质量把关。 | `skills/cr/SKILL.md` |
| `design-patterns` | 设计模式与架构专家 - 覆盖 GoF 经典模式、云架构模式、Go 并发模式、SOLID/DDD 等。使用场景：系统设计、代码重构、架构决策、分布式系统。 | `skills/design-patterns/SKILL.md` |
| `diagram-png-export` | 跨项目生成白底、4 倍分辨率、完整无裁切的图表 PNG 附件并提供预览。使用场景：图表交付、超宽图导出、批量导出文档中的图、迁移 WIKI。 | `skills/diagram-png-export/SKILL.md` |
| `etcd-go` | Go etcd 专家 - KV 存储、Watch 监听、分布式锁、租约管理、选主。使用场景：配置中心、服务发现、分布式协调。 | `skills/etcd-go/SKILL.md` |
| `go-performance` | Go 性能优化工作台（1.25.9+ 基线）- 决策优先 runbook：`for b.Loop()`、pprof/trace/flight recorder、逃逸/内联、sync.Pool、零分配模式、weak.Pointer、GOMEMLIMIT、容器感知 GOMAXPROCS、PGO、Green Tea GC、二进制瘦身。使用场景：代码路径调优、内存/CPU 瓶颈定位、基准回归分析、降 GC 压力。 | `skills/go-performance/SKILL.md` |
| `go-runtime` | Go 运行时原理专家（1.25.9+ 基线）- GMP 调度器、三色标记+混合写屏障 GC、mspan/mcache/mcentral/mheap、Swiss Tables、hchan、defer 三代、itab、reflect 成本、sync 原语底层。使用场景：性能问题根因分析、异常行为排查（GC 抖动、调度延迟、死锁）、调优决策依据、GODEBUG 输出解读。 | `skills/go-runtime/SKILL.md` |
| `go-style` | Go 代码规范与后端开发专家 - 惯用法、代码审查、HTTP 服务、API 设计。使用场景：代码审查、重构、后端开发、API 实现。 | `skills/go-style/SKILL.md` |
| `go-test` | Go 测试专家 - 表驱动测试、httptest、基准测试、模糊测试、mock、testcontainers。使用场景：编写测试、修复失败测试、提高覆盖率、性能调优。 | `skills/go-test/SKILL.md` |
| `golang-patterns` | Go 惯用模式专家 - 简洁设计、零值可用、接口设计、错误处理、并发模式、内存优化。使用场景：编写新代码、代码审查、重构优化。 | `skills/golang-patterns/SKILL.md` |
| `grpc-go` | Go gRPC 专家 - 服务定义、拦截器、错误处理、元数据传播、流式RPC、负载均衡。使用场景：微服务通信、API 网关、内部服务。 | `skills/grpc-go/SKILL.md` |
| `idempotency-go` | Go 幂等性处理专家 - 幂等键设计、状态追踪、去重策略、分布式幂等、清理策略。使用场景：支付、订单创建、消息处理。 | `skills/idempotency-go/SKILL.md` |
| `k8s-go` | Kubernetes Go 开发专家 - 使用 client-go 编写 K8s 控制器、Operator、客户端代码。使用场景：K8s API 交互、controller 开发、CRD 操作。 | `skills/k8s-go/SKILL.md` |
| `kafka-go` | Go Kafka 专家 - 生产消费、分区策略、消费者组、Exactly-Once、死信队列、链路追踪。使用场景：事件驱动、日志收集、流处理。 | `skills/kafka-go/SKILL.md` |
| `mongodb-go` | Go MongoDB 专家 - 使用 mongo-driver 进行 CRUD、聚合管道、索引优化、事务处理。使用场景：数据库设计、查询优化、性能调优。 | `skills/mongodb-go/SKILL.md` |
| `multi-tenant-go` | Go 多租户模式专家 - 租户上下文传播（HTTP/gRPC）、Context 注入与提取、数据隔离、租户感知缓存、消息队列租户隔离、跨服务传播。使用场景：SaaS 多租户、B2B 平台、微服务租户隔离、数据安全。 | `skills/multi-tenant-go/SKILL.md` |
| `otel-go` | Go OpenTelemetry 专家 - 分布式追踪、指标收集、日志关联、上下文传播、采样策略。使用场景：可观测性、APM、服务监控。 | `skills/otel-go/SKILL.md` |
| `pulsar-go` | Go Pulsar 专家 - 消息生产消费、订阅模式、死信队列、链路追踪、Schema 管理。使用场景：异步消息、事件驱动、流处理。 | `skills/pulsar-go/SKILL.md` |
| `redis-go` | Go Redis 专家 - 缓存模式、分布式锁、限流、Lua脚本、Pipeline、Pub/Sub、集群模式。使用场景：缓存、会话、排行榜、实时计数。 | `skills/redis-go/SKILL.md` |
| `resilience-go` | Go 韧性模式专家 - 熔断器、重试策略、限流、超时、舱壁隔离、降级处理。使用场景：微服务容错、外部服务调用、高可用系统。 | `skills/resilience-go/SKILL.md` |
