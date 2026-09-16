---
name: multi-tenant-go
description: "Go 多租户模式专家 - 租户上下文传播(HTTP Header/gRPC Metadata)、Context 注入与提取、HTTP中间件/gRPC拦截器自动传播、数据隔离(共享数据库+租户分区键)、租户感知缓存(键隔离/空值防穿透/随机TTL防雪崩)、消息队列租户隔离(Kafka分区/Pulsar属性)、跨服务传播(HTTP InjectToRequest/gRPC InjectToOutgoingContext)、租户生命周期管理。适用：SaaS多租户系统、B2B平台、微服务租户隔离、多租户数据安全。不适用：单租户系统、租户无数据隔离需求的内部工具、纯前端多租户(应在BFF层处理)。触发词：multi-tenant, 多租户, tenant, 租户隔离, tenant isolation, tenant context, 租户上下文, SaaS, B2B, 数据隔离"
user-invocable: true
allowed-tools: Bash, Read, Write, Edit, Grep, Glob
---

# Go 多租户模式专家

使用 Go 实现多租户模式：$ARGUMENTS

---

## 1. 租户上下文定义

### Context Key 与基础操作

```go
// 使用 typed key 防止冲突
type contextKey string

const (
    keyTenantID   = contextKey("tenant_id")
    keyTenantName = contextKey("tenant_name")
)

// TenantInfo 租户信息（请求级）
type TenantInfo struct {
    TenantID   string
    TenantName string
}

func (t TenantInfo) IsEmpty() bool    { return t.TenantID == "" && t.TenantName == "" }
func (t TenantInfo) Validate() error {
    if t.TenantID == "" { return ErrEmptyTenantID }
    if t.TenantName == "" { return ErrEmptyTenantName }
    return nil
}

var (
    ErrEmptyTenantID   = errors.New("empty tenant_id")
    ErrEmptyTenantName = errors.New("empty tenant_name")
)
```

### Context 注入与提取

```go
// 注入
func WithTenantID(ctx context.Context, id string) context.Context {
    return context.WithValue(ctx, keyTenantID, id)
}
func WithTenantInfo(ctx context.Context, info TenantInfo) context.Context {
    if info.TenantID != "" { ctx = context.WithValue(ctx, keyTenantID, info.TenantID) }
    if info.TenantName != "" { ctx = context.WithValue(ctx, keyTenantName, info.TenantName) }
    return ctx
}

// 提取（零值安全）
func TenantID(ctx context.Context) string {
    if v, ok := ctx.Value(keyTenantID).(string); ok { return v }
    return ""
}

// 强制提取（业务必需场景）
func RequireTenantID(ctx context.Context) (string, error) {
    v := TenantID(ctx)
    if v == "" { return "", ErrEmptyTenantID }
    return v, nil
}
```

> 完整 Context 操作和 Identity 结构体见 [references/examples.md](references/examples.md#租户上下文定义)

---

## 2. HTTP 中间件自动传播

### 中间件（提取 Header -> 注入 Context）

```go
const (
    HeaderTenantID   = "X-Tenant-ID"
    HeaderTenantName = "X-Tenant-Name"
)

func ExtractFromHTTPHeader(h http.Header) TenantInfo {
    return TenantInfo{
        TenantID:   strings.TrimSpace(h.Get(HeaderTenantID)),
        TenantName: strings.TrimSpace(h.Get(HeaderTenantName)),
    }
}

// 中间件选项
type MiddlewareOption func(*middlewareConfig)
type middlewareConfig struct {
    requireTenant   bool  // 要求 TenantID + TenantName
    requireTenantID bool  // 仅要求 TenantID
}
func WithRequireTenant() MiddlewareOption { /* ... */ }
func WithRequireTenantID() MiddlewareOption { /* ... */ }

func TenantMiddleware(opts ...MiddlewareOption) func(http.Handler) http.Handler {
    cfg := &middlewareConfig{}
    for _, opt := range opts { opt(cfg) }
    return func(next http.Handler) http.Handler {
        return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
            info := ExtractFromHTTPHeader(r.Header)
            if cfg.requireTenant {
                if err := info.Validate(); err != nil {
                    http.Error(w, err.Error(), http.StatusBadRequest)
                    return
                }
            }
            ctx := WithTenantInfo(r.Context(), info)
            next.ServeHTTP(w, r.WithContext(ctx))
        })
    }
}
```

### 跨服务 HTTP 传播

```go
// 调用下游服务时，将租户信息注入请求
func InjectToRequest(ctx context.Context, req *http.Request) {
    if req == nil || req.Header == nil { return }
    if tid := TenantID(ctx); tid != "" { req.Header.Set(HeaderTenantID, tid) }
    if tname := TenantName(ctx); tname != "" { req.Header.Set(HeaderTenantName, tname) }
}
```

> 完整 HTTP 中间件（含 trace 传播）见 [references/examples.md](references/examples.md#http-中间件)

---

## 3. gRPC 拦截器自动传播

### 服务端拦截器

```go
const (
    MetaTenantID   = "x-tenant-id"   // gRPC metadata 使用小写
    MetaTenantName = "x-tenant-name"
)

func ExtractFromMetadata(md metadata.MD) TenantInfo {
    return TenantInfo{
        TenantID:   getMetaValue(md, MetaTenantID),
        TenantName: getMetaValue(md, MetaTenantName),
    }
}

func GRPCUnaryServerInterceptor(opts ...GRPCInterceptorOption) grpc.UnaryServerInterceptor {
    cfg := &grpcInterceptorConfig{}
    for _, opt := range opts { opt(cfg) }
    return func(ctx context.Context, req any, info *grpc.UnaryServerInfo, handler grpc.UnaryHandler) (any, error) {
        md, _ := metadata.FromIncomingContext(ctx)
        tenant := ExtractFromMetadata(md)
        if cfg.requireTenantID && tenant.TenantID == "" {
            return nil, status.Error(codes.InvalidArgument, "missing tenant_id")
        }
        ctx = WithTenantInfo(ctx, tenant)
        return handler(ctx, req)
    }
}
```

### 客户端拦截器（跨服务传播）

```go
func InjectToOutgoingContext(ctx context.Context) context.Context {
    md, ok := metadata.FromOutgoingContext(ctx)
    if !ok { md = metadata.MD{} } else { md = md.Copy() }
    if tid := TenantID(ctx); tid != "" { md.Set(MetaTenantID, tid) }
    if tname := TenantName(ctx); tname != "" { md.Set(MetaTenantName, tname) }
    return metadata.NewOutgoingContext(ctx, md)
}

func GRPCUnaryClientInterceptor() grpc.UnaryClientInterceptor {
    return func(ctx context.Context, method string, req, reply any, cc *grpc.ClientConn, invoker grpc.UnaryInvoker, opts ...grpc.CallOption) error {
        return invoker(InjectToOutgoingContext(ctx), method, req, reply, cc, opts...)
    }
}
```

> 完整 gRPC 拦截器（含流式）见 [references/examples.md](references/examples.md#grpc-拦截器)

---

## 4. 数据隔离模式

### 共享数据库 + 租户分区键

```go
// Repository 层：所有查询必须带 tenant_id
type AssetRepo struct { db *mongo.Collection }

func (r *AssetRepo) FindByID(ctx context.Context, id string) (*Asset, error) {
    tenantID, err := RequireTenantID(ctx)
    if err != nil { return nil, err }
    filter := bson.M{"_id": id, "tenant_id": tenantID}
    var asset Asset
    if err := r.db.FindOne(ctx, filter).Decode(&asset); err != nil {
        return nil, fmt.Errorf("find asset: %w", err)
    }
    return &asset, nil
}

func (r *AssetRepo) List(ctx context.Context, opts ListOptions) ([]*Asset, error) {
    tenantID, err := RequireTenantID(ctx)
    if err != nil { return nil, err }
    filter := bson.M{"tenant_id": tenantID, "is_deleted": false}
    // ... 分页查询
}
```

### 索引策略

```go
// 复合索引：tenant_id 作为前缀（确保每个租户的查询都命中索引）
indexes := []mongo.IndexModel{
    {Keys: bson.D{{"tenant_id", 1}, {"status", 1}}},
    {Keys: bson.D{{"tenant_id", 1}, {"created_at", -1}}},
    {Keys: bson.D{{"tenant_id", 1}, {"_id", 1}}, Options: options.Index().SetUnique(true)},
}
```

> 完整数据隔离模式（含 SQL 示例）见 [references/examples.md](references/examples.md#数据隔离)

---

## 5. 租户感知缓存

### 缓存键隔离

```go
// 缓存键包含 tenant_id，防止跨租户数据泄露
func tenantCacheKey(tenantID, resourceType, resourceID string) string {
    return fmt.Sprintf("tenant:%s:%s:%s", tenantID, resourceType, resourceID)
}
```

### 缓存穿透防护 + 随机 TTL

```go
type TenantCache struct {
    client redis.UniversalClient
    baseTTL time.Duration  // 24h
    jitter  time.Duration  // 1h
}

func (c *TenantCache) Get(ctx context.Context, tenantID, key string) ([]byte, bool, error) {
    cacheKey := tenantCacheKey(tenantID, "info", key)
    data, err := c.client.Get(ctx, cacheKey).Bytes()
    if errors.Is(err, redis.Nil) { return nil, false, nil }
    if err != nil { return nil, false, err }
    if string(data) == "__NULL__" { return nil, true, nil }  // 空值缓存命中
    return data, true, nil
}

func (c *TenantCache) Set(ctx context.Context, tenantID, key string, data []byte) error {
    cacheKey := tenantCacheKey(tenantID, "info", key)
    ttl := c.randomTTL()
    if data == nil {
        return c.client.Set(ctx, cacheKey, "__NULL__", ttl).Err()  // 缓存空值
    }
    return c.client.Set(ctx, cacheKey, data, ttl).Err()
}

// 随机 TTL 防止缓存雪崩
func (c *TenantCache) randomTTL() time.Duration {
    offset := time.Duration(rand.Int63n(int64(c.jitter)))
    if rand.Intn(2) == 0 { return c.baseTTL - offset }
    return c.baseTTL + offset
}
```

> 完整缓存实现见 [references/examples.md](references/examples.md#租户感知缓存)

---

## 6. 消息队列租户隔离

### Kafka 分区策略

```go
// 使用 tenant_id 作为 partition key，保证同一租户的消息有序
func (p *Producer) SendTenantEvent(ctx context.Context, topic string, event TenantEvent) error {
    tenantID, err := RequireTenantID(ctx)
    if err != nil { return err }
    event.TenantID = tenantID
    data, _ := json.Marshal(event)
    return p.Produce(&kafka.Message{
        TopicPartition: kafka.TopicPartition{Topic: &topic, Partition: kafka.PartitionAny},
        Key:   []byte(tenantID),  // 按 tenant_id 分区
        Value: data,
    }, nil)
}
```

### 消费端租户上下文恢复

```go
func (c *Consumer) handleMessage(msg *kafka.Message) error {
    var event TenantEvent
    if err := json.Unmarshal(msg.Value, &event); err != nil { return err }
    ctx := WithTenantID(context.Background(), event.TenantID)
    return c.handler(ctx, event)
}
```

> 完整消息队列模式（含 Pulsar）见 [references/examples.md](references/examples.md#消息队列租户隔离)

---

## 7. 租户生命周期管理

### 事件驱动模式

```go
type TenantEvent struct {
    EventID   string    `json:"event_id"`
    EventType string    `json:"event_type"`  // create, update, delete, suspend
    TenantID  string    `json:"tenant_id"`
    Timestamp time.Time `json:"timestamp"`
    Payload   json.RawMessage `json:"payload"`
}

// 创建租户的完整事务流程
func (s *TenantService) Create(ctx context.Context, req CreateTenantRequest) error {
    tenant := &Tenant{ID: uuid.New().String(), Name: req.Name, Status: StatusPending}
    if err := s.repo.Insert(ctx, tenant); err != nil { return err }
    event := TenantEvent{
        EventID: uuid.New().String(), EventType: "create",
        TenantID: tenant.ID, Timestamp: time.Now(),
    }
    if err := s.publisher.Publish(ctx, "tenant-events", event); err != nil {
        // 事件发布失败不影响主流程，记录到 DB 用于重试
        s.eventStore.Save(ctx, event)
    }
    return nil
}
```

> 完整生命周期管理见 [references/examples.md](references/examples.md#租户生命周期管理)

---

## 最佳实践

### 上下文传播
- 所有入口点（HTTP/gRPC/MQ Consumer）必须提取并注入租户信息
- 使用中间件/拦截器自动化，避免业务代码遗漏
- 跨服务调用时自动传播，使用 `InjectToRequest` / `InjectToOutgoingContext`

### 数据隔离
- Repository 层所有查询强制包含 `tenant_id` 过滤
- 复合索引以 `tenant_id` 为前缀
- 使用 `RequireTenantID()` 确保租户上下文存在

### 缓存安全
- 缓存键必须包含 `tenant_id`，防止跨租户数据泄露
- 空值缓存防穿透 + 随机 TTL 防雪崩
- 租户删除/变更时级联清理缓存

### 消息队列
- 消息体携带 `tenant_id`，消费端恢复上下文
- Kafka 使用 `tenant_id` 作为 partition key 保证租户内有序

### 安全
- 防止 tenant leakage：使用 `md.Set()` 覆盖而非 `md.Append()`
- gRPC metadata 使用小写 key（`x-tenant-id`），HTTP Header 使用标准格式（`X-Tenant-ID`）
- nil 检查采用防御性编程

---

## 检查清单

- [ ] 所有入口点都有租户提取中间件/拦截器？
- [ ] Repository 查询全部包含 tenant_id 过滤？
- [ ] 缓存键包含 tenant_id？
- [ ] 跨服务调用传播了租户信息？
- [ ] 消息队列消息体包含 tenant_id？
- [ ] 使用 RequireTenantID 确保关键路径有租户上下文？
- [ ] 复合索引以 tenant_id 为前缀？
- [ ] gRPC metadata 使用 Set 覆盖语义？

---

## 参考资料

- [references/examples.md](references/examples.md) - 完整代码实现（上下文、中间件、拦截器、数据隔离、缓存、消息队列）
