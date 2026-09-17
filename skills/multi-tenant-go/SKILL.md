---
name: multi-tenant-go
description: "Go 多租户模式专家 - 租户上下文传播(HTTP Header/gRPC Metadata)、Context 注入与提取、HTTP中间件/gRPC拦截器自动传播、数据隔离(共享数据库+租户分区键)、租户感知缓存(键隔离/空值防穿透/随机TTL防雪崩)、消息队列租户隔离(Kafka分区/Pulsar属性)、跨服务传播(HTTP InjectToRequest/gRPC InjectToOutgoingContext)、租户生命周期管理。适用：SaaS多租户系统、B2B平台、微服务租户隔离、多租户数据安全。不适用：单租户系统、租户无数据隔离需求的内部工具、纯前端多租户(应在BFF层处理)。触发词：multi-tenant, 多租户, tenant, 租户隔离, tenant isolation, tenant context, 租户上下文, SaaS, B2B, 数据隔离"
---

# Go 多租户模式专家

使用 Go 实现多租户模式：$ARGUMENTS

基线：go1.24.6。示例只依赖标准库与上游库（grpc v1.80.0、mongo-driver/v2 v2.8.2、go-redis/v9 v9.22.0、confluent-kafka-go/v2 v2.14.1、pulsar-client-go v0.20.0），租户上下文 helper 定义在本 skill 的 `package tenant` 中。完整可编译代码见 [references/examples.md](references/examples.md)。

---

## 0. 隔离模型选择

| 模型 | 隔离 | 成本 | 适用 |
|------|------|------|------|
| 共享库 + 分区键（`tenant_id` 列） | 逻辑隔离 | 最低 | 大多数 SaaS，租户数多、单租户数据量小 |
| 独立 schema / database | 中等 | 中 | 合规要求按租户备份恢复 |
| 独立实例 | 物理隔离 | 最高 | 大客户、数据主权要求 |

本 skill 以共享库 + 分区键为主线；其他模型只是把 `tenant_id` 从过滤条件变成连接选择。

---

## 1. 租户上下文

```go
package tenant

type contextKey struct{ name string } // 私有类型，避免跨包冲突

var (
    keyTenantID   = contextKey{"tenant_id"}
    keyTenantName = contextKey{"tenant_name"}
)

type Info struct {
    TenantID   string
    TenantName string
}

func WithTenantID(ctx context.Context, tenantID string) context.Context {
    return context.WithValue(ctx, keyTenantID, tenantID)
}

func WithInfo(ctx context.Context, info Info) context.Context // 只注入非空字段

func TenantID(ctx context.Context) string { // 零值安全
    v, _ := ctx.Value(keyTenantID).(string)
    return v
}

func RequireTenantID(ctx context.Context) (string, error) { // 关键路径：缺失即报错
    v := TenantID(ctx)
    if v == "" {
        return "", ErrMissingTenantID
    }
    return v, nil
}
```

- `With*` 只返回 `context.Context`；ctx 为 nil 是编程错误，不做运行时兜底
- 读路径用 `TenantID`（允许空），写路径和数据访问用 `RequireTenantID`

> 完整实现见 [references/examples.md#租户上下文contextgo](references/examples.md#租户上下文contextgo)

---

## 2. HTTP 传播

```go
const (
    HeaderTenantID   = "X-Tenant-ID"
    HeaderTenantName = "X-Tenant-Name"
)

type Requirement int

const (
    Optional     Requirement = iota
    NeedTenantID             // 只要求 tenant_id
    NeedTenant               // 要求 tenant_id + tenant_name
)

func HTTPMiddleware(req Requirement) func(http.Handler) http.Handler {
    return func(next http.Handler) http.Handler {
        return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
            info := ExtractFromHeader(r.Header)
            if err := req.check(info); err != nil {
                http.Error(w, err.Error(), http.StatusBadRequest)
                return
            }
            next.ServeHTTP(w, r.WithContext(WithInfo(r.Context(), info)))
        })
    }
}

// 调用下游：Set 覆盖同名 Header，避免上游残留值泄漏
func InjectToRequest(ctx context.Context, req *http.Request) {
    if tid := TenantID(ctx); tid != "" {
        req.Header.Set(HeaderTenantID, tid)
    }
    if tname := TenantName(ctx); tname != "" {
        req.Header.Set(HeaderTenantName, tname)
    }
}
```

- 网关入口用 `NeedTenant`，内部服务用 `NeedTenantID`
- 租户身份来自认证结果（JWT claim、API key 映射），不能只信任客户端 Header；网关校验后再向内部传播
- `TenantTransport` 实现 `http.RoundTripper`，让 `http.Client` 自动注入

> 完整实现见 [references/examples.md#http-中间件与跨服务传播httpgo](references/examples.md#http-中间件与跨服务传播httpgo)

---

## 3. gRPC 传播

```go
const MetaTenantID = "x-tenant-id" // metadata key 必须小写

func UnaryServerInterceptor(req Requirement) grpc.UnaryServerInterceptor {
    return func(ctx context.Context, request any, _ *grpc.UnaryServerInfo, handler grpc.UnaryHandler) (any, error) {
        md, _ := metadata.FromIncomingContext(ctx)
        info := ExtractFromMetadata(md)
        if err := req.check(info); err != nil {
            return nil, status.Error(codes.InvalidArgument, err.Error())
        }
        return handler(WithInfo(ctx, info), request)
    }
}

func InjectToOutgoingContext(ctx context.Context) context.Context {
    md, ok := metadata.FromOutgoingContext(ctx)
    if !ok {
        md = metadata.MD{}
    } else {
        md = md.Copy()
    }
    if tid := TenantID(ctx); tid != "" {
        md.Set(MetaTenantID, tid) // Set 覆盖，不用 Append
    }
    return metadata.NewOutgoingContext(ctx, md)
}
```

- 流式 RPC 用 `wrappedServerStream` 覆盖 `Context()`
- 客户端用 `grpc.NewClient(target, grpc.WithChainUnaryInterceptor(UnaryClientInterceptor()))`；`grpc.Dial` 已弃用

> 完整实现（含流式）见 [references/examples.md#grpc-拦截器grpcgo](references/examples.md#grpc-拦截器grpcgo)

---

## 4. 数据隔离

```go
// Repository：每个查询都从 ctx 取 tenant_id 并加入过滤条件
func (r *AssetRepo) FindByID(ctx context.Context, id string) (*Asset, error) {
    tenantID, err := RequireTenantID(ctx)
    if err != nil {
        return nil, err
    }
    var asset Asset
    err = r.coll.FindOne(ctx, bson.M{"_id": id, "tenant_id": tenantID}).Decode(&asset)
    if errors.Is(err, mongo.ErrNoDocuments) {
        return nil, ErrNotFound // 跨租户访问与不存在同样返回 NotFound
    }
    return &asset, err
}

// 写入：用 ctx 值覆盖请求体里的 tenant_id，禁止改写分区键
asset.TenantID = tenantID
delete(update, "tenant_id")
```

索引以 `tenant_id` 为前缀，每个租户的查询都能命中：

```go
{Keys: bson.D{{Key: "tenant_id", Value: 1}, {Key: "status", Value: 1}}},
{Keys: bson.D{{Key: "tenant_id", Value: 1}, {Key: "created_at", Value: -1}}},
{Keys: bson.D{{Key: "tenant_id", Value: 1}, {Key: "name", Value: 1}}, Options: options.Index().SetUnique(true)},
```

SQL 同理：`WHERE tenant_id = $1 AND ...`，索引 `(tenant_id, ...)`。PostgreSQL 可用 Row Level Security 配合 `SET app.tenant_id` 做兜底。

> MongoDB 与 PostgreSQL 完整实现见 [references/examples.md#数据隔离mongodb-与-postgresqlrepogo](references/examples.md#数据隔离mongodb-与-postgresqlrepogo)

---

## 5. 租户感知缓存

```go
func CacheKey(tenantID, resourceType, resourceID string) string {
    return fmt.Sprintf("tenant:%s:%s:%s", tenantID, resourceType, resourceID)
}

type Cache struct {
    client  redis.UniversalClient
    baseTTL time.Duration // 24h
    jitter  time.Duration // 1h
}

// data=nil 写入空值标记 "__NULL__"，防穿透
func (c *Cache) Set(ctx context.Context, tenantID, resourceType, resourceID string, data []byte) error

// TTL 在 [baseTTL - jitter, baseTTL + jitter) 内随机，防雪崩
func (c *Cache) randomTTL() time.Duration {
    offset := rand.N(2*c.jitter) - c.jitter // math/rand/v2
    return c.baseTTL + offset
}

// 租户变更时按前缀 SCAN 清理（不用 KEYS）
func (c *Cache) DeleteByTenant(ctx context.Context, tenantID string) error

// Cache-Aside：tenant_id 从 ctx 取，loader 返回 (nil, nil) 写空值
func GetOrLoad[T any](ctx context.Context, cache *Cache, resourceType, resourceID string,
    loader func(ctx context.Context) (*T, error)) (*T, error)
```

> 完整实现见 [references/examples.md#租户感知缓存cachego](references/examples.md#租户感知缓存cachego)

---

## 6. 消息队列

```go
// Kafka：tenant_id 作 Key，同一租户落同一分区，租户内有序
err = p.producer.Produce(&kafka.Message{
    TopicPartition: kafka.TopicPartition{Topic: &topic, Partition: kafka.PartitionAny},
    Key:            []byte(event.TenantID),
    Value:          data,
    Headers:        []kafka.Header{{Key: "tenant_id", Value: []byte(event.TenantID)}},
}, delivery)

// 消费端：从消息体恢复上下文，每条消息独立 ctx
msgCtx := WithTenantID(ctx, event.TenantID)
if err := c.handler(msgCtx, event); err != nil { /* 重试或 DLQ */ }
```

Pulsar：`ProducerMessage.Key` 供 KeyShared 订阅按租户分派，`Properties["tenant_id"]` 供消费端过滤。

- 消息体必须自带 `tenant_id`，不能依赖消费端的进程级状态
- 大租户打爆单分区时改用 `hash(tenant_id + entity_id)` 作 Key，牺牲租户级全序

> Kafka 与 Pulsar 完整实现见 [references/examples.md#消息队列kafka-与-pulsarmqgo](references/examples.md#消息队列kafka-与-pulsarmqgo)

---

## 7. 租户生命周期

```go
const (
    StatusPending = 0
    StatusActive  = 1
    StatusSuspend = 2
    StatusDeleted = 3
)

func (s *LifecycleService) Create(ctx context.Context, req CreateTenantRequest) (*Tenant, error) {
    t := &Tenant{ID: uuid.NewString(), Name: req.Name, Status: StatusPending}
    if err := s.repo.Insert(ctx, t); err != nil {
        return nil, fmt.Errorf("insert tenant: %w", err)
    }
    s.emit(ctx, EventCreate, t.ID, req) // 发布失败落 outbox 重试
    return t, nil
}
```

- 状态变更（暂停、删除）后立即 `DeleteByTenant` 清缓存
- 删除只做软删除 + 事件；物理清理由离线任务按 `tenant_id` 分批执行
- 定时任务按租户扇出时，`ForEachTenant` 为每个租户构造独立 ctx

> 完整实现见 [references/examples.md#租户生命周期lifecyclego](references/examples.md#租户生命周期lifecyclego)

---

## 最佳实践

### 传播

- 所有入口（HTTP、gRPC、MQ 消费、定时任务）都必须注入租户上下文，用中间件、拦截器自动化
- 跨服务调用用 `InjectToRequest` / `InjectToOutgoingContext`，禁止手写 Header
- 注入用 Set 覆盖语义，避免 Append 累积多值造成 tenant leakage

### 数据

- Repository 是唯一的数据访问层，所有方法以 `RequireTenantID` 开头
- 写入用 ctx 值覆盖请求体，更新禁止改写 `tenant_id`
- 复合索引以 `tenant_id` 为前缀，唯一约束也要带 `tenant_id`

### 缓存与消息

- 缓存键第一段是 `tenant_id`；空值缓存 + TTL 抖动
- 消息体自带 `tenant_id`，Key 按租户分区

### 安全

- 租户身份来自认证，不信任未经网关校验的 Header
- 日志、指标、trace 都带 `tenant_id` 标签，便于按租户排障与计量
- 单租户配额（限流、连接数）按 `tenant_id` 维度设置，防止噪声邻居

---

## 检查清单

- [ ] 所有入口点都有租户提取中间件或拦截器？
- [ ] Repository 每个方法都以 `RequireTenantID` 开头，过滤条件含 `tenant_id`？
- [ ] 写入用 ctx 覆盖 `tenant_id`，更新禁止改写？
- [ ] 复合索引与唯一约束以 `tenant_id` 为前缀？
- [ ] 缓存键含 `tenant_id`，有空值缓存和 TTL 抖动？
- [ ] 跨服务调用自动传播，注入用 Set 语义？
- [ ] 消息体含 `tenant_id`，消费端恢复 ctx？
- [ ] 租户状态变更后清缓存、发事件？

---

## 参考资料

- [references/examples.md](references/examples.md) - 完整可编译代码（上下文、HTTP、gRPC、数据隔离、缓存、消息队列、生命周期）
- [grpc-go metadata](https://pkg.go.dev/google.golang.org/grpc/metadata)
- [PostgreSQL Row Security Policies](https://www.postgresql.org/docs/current/ddl-rowsecurity.html)
