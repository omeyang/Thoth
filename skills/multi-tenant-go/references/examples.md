# Go 多租户模式 - 完整代码实现

## 目录

- [租户上下文定义](#租户上下文定义)
- [HTTP 中间件](#http-中间件)
- [gRPC 拦截器](#grpc-拦截器)
- [数据隔离](#数据隔离)
- [租户感知缓存](#租户感知缓存)
- [消息队列租户隔离](#消息队列租户隔离)
- [租户生命周期管理](#租户生命周期管理)

---

## 租户上下文定义

### Context Key 与基础类型

```go
package tenant

import (
    "context"
    "errors"
)

// Context Key 使用 typed string 防止冲突
type contextKey string

const (
    keyPlatformID = contextKey("tenant:platform_id")
    keyTenantID   = contextKey("tenant:tenant_id")
    keyTenantName = contextKey("tenant:tenant_name")
)

// 错误定义
var (
    ErrNilContext        = errors.New("tenant: nil context")
    ErrEmptyTenantID     = errors.New("tenant: empty tenant_id")
    ErrEmptyTenantName   = errors.New("tenant: empty tenant_name")
    ErrMissingTenantID   = errors.New("tenant: missing tenant_id in context")
    ErrMissingTenantName = errors.New("tenant: missing tenant_name in context")
    ErrMissingPlatformID = errors.New("tenant: missing platform_id in context")
)

// TenantInfo 请求级租户信息
type TenantInfo struct {
    TenantID   string
    TenantName string
}

func (t TenantInfo) IsEmpty() bool { return t.TenantID == "" && t.TenantName == "" }

func (t TenantInfo) Validate() error {
    if t.TenantID == "" {
        return ErrEmptyTenantID
    }
    if t.TenantName == "" {
        return ErrEmptyTenantName
    }
    return nil
}

// Identity 完整身份信息（平台 + 租户）
type Identity struct {
    PlatformID string
    TenantID   string
    TenantName string
}

func (i Identity) Validate() error {
    if i.PlatformID == "" {
        return ErrMissingPlatformID
    }
    if i.TenantID == "" {
        return ErrMissingTenantID
    }
    if i.TenantName == "" {
        return ErrMissingTenantName
    }
    return nil
}

func (i Identity) IsComplete() bool {
    return i.PlatformID != "" && i.TenantID != "" && i.TenantName != ""
}
```

### Context 注入与提取

```go
// === 注入函数 ===

func WithTenantID(ctx context.Context, tenantID string) (context.Context, error) {
    if ctx == nil {
        return nil, ErrNilContext
    }
    return context.WithValue(ctx, keyTenantID, tenantID), nil
}

func WithTenantName(ctx context.Context, tenantName string) (context.Context, error) {
    if ctx == nil {
        return nil, ErrNilContext
    }
    return context.WithValue(ctx, keyTenantName, tenantName), nil
}

func WithPlatformID(ctx context.Context, platformID string) (context.Context, error) {
    if ctx == nil {
        return nil, ErrNilContext
    }
    return context.WithValue(ctx, keyPlatformID, platformID), nil
}

// WithTenantInfo 批量注入（仅注入非空字段）
func WithTenantInfo(ctx context.Context, info TenantInfo) (context.Context, error) {
    if ctx == nil {
        return nil, ErrNilContext
    }
    var err error
    if info.TenantID != "" {
        ctx, err = WithTenantID(ctx, info.TenantID)
        if err != nil {
            return nil, err
        }
    }
    if info.TenantName != "" {
        ctx, err = WithTenantName(ctx, info.TenantName)
        if err != nil {
            return nil, err
        }
    }
    return ctx, nil
}

// WithIdentity 批量注入完整身份（仅非空字段）
func WithIdentity(ctx context.Context, id Identity) (context.Context, error) {
    if ctx == nil {
        return nil, ErrNilContext
    }
    var err error
    if id.PlatformID != "" {
        ctx, err = WithPlatformID(ctx, id.PlatformID)
        if err != nil {
            return nil, err
        }
    }
    if id.TenantID != "" {
        ctx, err = WithTenantID(ctx, id.TenantID)
        if err != nil {
            return nil, err
        }
    }
    if id.TenantName != "" {
        ctx, err = WithTenantName(ctx, id.TenantName)
        if err != nil {
            return nil, err
        }
    }
    return ctx, nil
}

// === 提取函数（零值安全）===

func TenantID(ctx context.Context) string {
    if ctx == nil {
        return ""
    }
    if v, ok := ctx.Value(keyTenantID).(string); ok {
        return v
    }
    return ""
}

func TenantName(ctx context.Context) string {
    if ctx == nil {
        return ""
    }
    if v, ok := ctx.Value(keyTenantName).(string); ok {
        return v
    }
    return ""
}

func PlatformID(ctx context.Context) string {
    if ctx == nil {
        return ""
    }
    if v, ok := ctx.Value(keyPlatformID).(string); ok {
        return v
    }
    return ""
}

func GetTenantInfo(ctx context.Context) TenantInfo {
    return TenantInfo{
        TenantID:   TenantID(ctx),
        TenantName: TenantName(ctx),
    }
}

func GetIdentity(ctx context.Context) Identity {
    return Identity{
        PlatformID: PlatformID(ctx),
        TenantID:   TenantID(ctx),
        TenantName: TenantName(ctx),
    }
}

// === 强制提取（业务必需场景）===

func RequireTenantID(ctx context.Context) (string, error) {
    if ctx == nil {
        return "", ErrNilContext
    }
    v := TenantID(ctx)
    if v == "" {
        return "", ErrMissingTenantID
    }
    return v, nil
}

func RequireTenantName(ctx context.Context) (string, error) {
    if ctx == nil {
        return "", ErrNilContext
    }
    v := TenantName(ctx)
    if v == "" {
        return "", ErrMissingTenantName
    }
    return v, nil
}
```

---

## HTTP 中间件

### 完整 HTTP 中间件（含追踪传播）

```go
package tenant

import (
    "net/http"
    "strings"
)

// HTTP Header 常量
const (
    HeaderPlatformID = "X-Platform-ID"
    HeaderTenantID   = "X-Tenant-ID"
    HeaderTenantName = "X-Tenant-Name"
    HeaderTraceID    = "X-Trace-ID"
    HeaderSpanID     = "X-Span-ID"
    HeaderRequestID  = "X-Request-ID"
)

// ExtractFromHTTPHeader 从 HTTP Header 提取租户信息
func ExtractFromHTTPHeader(h http.Header) TenantInfo {
    if h == nil {
        return TenantInfo{}
    }
    return TenantInfo{
        TenantID:   strings.TrimSpace(h.Get(HeaderTenantID)),
        TenantName: strings.TrimSpace(h.Get(HeaderTenantName)),
    }
}

// MiddlewareOption 中间件选项
type MiddlewareOption func(*middlewareConfig)

type middlewareConfig struct {
    requireTenant   bool // 要求 TenantID + TenantName
    requireTenantID bool // 仅要求 TenantID
}

// WithRequireTenant 要求完整租户信息（TenantID + TenantName）
func WithRequireTenant() MiddlewareOption {
    return func(cfg *middlewareConfig) {
        cfg.requireTenant = true
        cfg.requireTenantID = false
    }
}

// WithRequireTenantID 仅要求 TenantID
func WithRequireTenantID() MiddlewareOption {
    return func(cfg *middlewareConfig) {
        cfg.requireTenantID = true
        cfg.requireTenant = false
    }
}

// HTTPMiddleware 返回带选项的 HTTP 中间件
func HTTPMiddleware(opts ...MiddlewareOption) func(http.Handler) http.Handler {
    cfg := &middlewareConfig{}
    for _, opt := range opts {
        opt(cfg)
    }

    return func(next http.Handler) http.Handler {
        return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
            info := ExtractFromHTTPHeader(r.Header)

            // 校验
            if cfg.requireTenant {
                if err := info.Validate(); err != nil {
                    http.Error(w, err.Error(), http.StatusBadRequest)
                    return
                }
            } else if cfg.requireTenantID && info.TenantID == "" {
                http.Error(w, ErrEmptyTenantID.Error(), http.StatusBadRequest)
                return
            }

            // 注入 context
            ctx, err := WithTenantInfo(r.Context(), info)
            if err != nil {
                http.Error(w, err.Error(), http.StatusInternalServerError)
                return
            }

            next.ServeHTTP(w, r.WithContext(ctx))
        })
    }
}

// InjectToRequest 将租户信息注入 HTTP 请求（跨服务传播）
//
// 使用 Set 语义覆盖已存在的 Header，防止 tenant leakage。
// 如果 req 为 nil 或 req.Header 为 nil，静默返回（防御性编程）。
func InjectToRequest(ctx context.Context, req *http.Request) {
    if req == nil || req.Header == nil {
        return
    }

    if tid := TenantID(ctx); tid != "" {
        req.Header.Set(HeaderTenantID, tid)
    }
    if tname := TenantName(ctx); tname != "" {
        req.Header.Set(HeaderTenantName, tname)
    }
    if pid := PlatformID(ctx); pid != "" {
        req.Header.Set(HeaderPlatformID, pid)
    }
}

// InjectTenantToHeader 将 TenantInfo 直接注入 Header
func InjectTenantToHeader(h http.Header, info TenantInfo) {
    if h == nil {
        return
    }
    if info.TenantID != "" {
        h.Set(HeaderTenantID, info.TenantID)
    }
    if info.TenantName != "" {
        h.Set(HeaderTenantName, info.TenantName)
    }
}
```

### 使用示例

```go
mux := http.NewServeMux()
mux.HandleFunc("/api/assets", handleListAssets)

// 网关层：必须有完整租户信息
handler := HTTPMiddleware(WithRequireTenant())(mux)

// 或内部服务：仅要求 TenantID
handler = HTTPMiddleware(WithRequireTenantID())(mux)

// 跨服务调用时传播
func callDownstream(ctx context.Context, url string) (*http.Response, error) {
    req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
    if err != nil {
        return nil, err
    }
    InjectToRequest(ctx, req)
    return http.DefaultClient.Do(req)
}
```

---

## gRPC 拦截器

### 完整 gRPC 拦截器（含流式）

```go
package tenant

import (
    "context"
    "strings"

    "google.golang.org/grpc"
    "google.golang.org/grpc/codes"
    "google.golang.org/grpc/metadata"
    "google.golang.org/grpc/status"
)

// gRPC Metadata Key（小写加连字符）
const (
    MetaPlatformID = "x-platform-id"
    MetaTenantID   = "x-tenant-id"
    MetaTenantName = "x-tenant-name"
    MetaTraceID    = "x-trace-id"
    MetaSpanID     = "x-span-id"
    MetaRequestID  = "x-request-id"
)

// ExtractFromMetadata 从 gRPC Metadata 提取租户信息
func ExtractFromMetadata(md metadata.MD) TenantInfo {
    if md == nil {
        return TenantInfo{}
    }
    return TenantInfo{
        TenantID:   getMetaValue(md, MetaTenantID),
        TenantName: getMetaValue(md, MetaTenantName),
    }
}

func getMetaValue(md metadata.MD, key string) string {
    values := md.Get(key)
    if len(values) == 0 {
        return ""
    }
    return strings.TrimSpace(values[0])
}

// GRPCInterceptorOption gRPC 拦截器选项
type GRPCInterceptorOption func(*grpcInterceptorConfig)

type grpcInterceptorConfig struct {
    requireTenant   bool
    requireTenantID bool
}

func WithGRPCRequireTenant() GRPCInterceptorOption {
    return func(cfg *grpcInterceptorConfig) {
        cfg.requireTenant = true
        cfg.requireTenantID = false
    }
}

func WithGRPCRequireTenantID() GRPCInterceptorOption {
    return func(cfg *grpcInterceptorConfig) {
        cfg.requireTenantID = true
        cfg.requireTenant = false
    }
}

// GRPCUnaryServerInterceptor 一元服务端拦截器
func GRPCUnaryServerInterceptor(opts ...GRPCInterceptorOption) grpc.UnaryServerInterceptor {
    cfg := &grpcInterceptorConfig{}
    for _, opt := range opts {
        opt(cfg)
    }

    return func(ctx context.Context, req any, info *grpc.UnaryServerInfo, handler grpc.UnaryHandler) (any, error) {
        // 提取
        md, _ := metadata.FromIncomingContext(ctx)
        tenant := ExtractFromMetadata(md)

        // 校验
        if cfg.requireTenant {
            if err := tenant.Validate(); err != nil {
                return nil, status.Error(codes.InvalidArgument, err.Error())
            }
        } else if cfg.requireTenantID && tenant.TenantID == "" {
            return nil, status.Error(codes.InvalidArgument, ErrEmptyTenantID.Error())
        }

        // 注入
        ctx, err := WithTenantInfo(ctx, tenant)
        if err != nil {
            return nil, status.Error(codes.Internal, err.Error())
        }

        return handler(ctx, req)
    }
}

// GRPCStreamServerInterceptor 流式服务端拦截器
func GRPCStreamServerInterceptor(opts ...GRPCInterceptorOption) grpc.StreamServerInterceptor {
    cfg := &grpcInterceptorConfig{}
    for _, opt := range opts {
        opt(cfg)
    }

    return func(srv any, ss grpc.ServerStream, info *grpc.StreamServerInfo, handler grpc.StreamHandler) error {
        md, _ := metadata.FromIncomingContext(ss.Context())
        tenant := ExtractFromMetadata(md)

        if cfg.requireTenantID && tenant.TenantID == "" {
            return status.Error(codes.InvalidArgument, ErrEmptyTenantID.Error())
        }

        ctx, err := WithTenantInfo(ss.Context(), tenant)
        if err != nil {
            return status.Error(codes.Internal, err.Error())
        }

        return handler(srv, &wrappedServerStream{ServerStream: ss, ctx: ctx})
    }
}

// wrappedServerStream 包装 ServerStream 以覆盖 Context
type wrappedServerStream struct {
    grpc.ServerStream
    ctx context.Context
}

func (w *wrappedServerStream) Context() context.Context { return w.ctx }

// InjectToOutgoingContext 将租户信息注入 outgoing context（客户端调用）
//
// 使用 Set 语义覆盖同名 key，防止 tenant leakage。
func InjectToOutgoingContext(ctx context.Context) context.Context {
    if ctx == nil {
        ctx = context.Background()
    }

    md, ok := metadata.FromOutgoingContext(ctx)
    if !ok {
        md = metadata.MD{}
    } else {
        md = md.Copy() // 复制，避免修改原始 metadata
    }

    if tid := TenantID(ctx); tid != "" {
        md.Set(MetaTenantID, tid)
    }
    if tname := TenantName(ctx); tname != "" {
        md.Set(MetaTenantName, tname)
    }
    if pid := PlatformID(ctx); pid != "" {
        md.Set(MetaPlatformID, pid)
    }

    if len(md) == 0 {
        return ctx
    }
    return metadata.NewOutgoingContext(ctx, md)
}

// GRPCUnaryClientInterceptor 一元客户端拦截器（自动传播租户信息）
func GRPCUnaryClientInterceptor() grpc.UnaryClientInterceptor {
    return func(ctx context.Context, method string, req, reply any, cc *grpc.ClientConn, invoker grpc.UnaryInvoker, opts ...grpc.CallOption) error {
        return invoker(InjectToOutgoingContext(ctx), method, req, reply, cc, opts...)
    }
}

// GRPCStreamClientInterceptor 流式客户端拦截器（自动传播租户信息）
func GRPCStreamClientInterceptor() grpc.StreamClientInterceptor {
    return func(ctx context.Context, desc *grpc.StreamDesc, cc *grpc.ClientConn, method string, streamer grpc.Streamer, opts ...grpc.CallOption) (grpc.ClientStream, error) {
        return streamer(InjectToOutgoingContext(ctx), desc, cc, method, opts...)
    }
}
```

### gRPC 服务注册示例

```go
srv := grpc.NewServer(
    // 服务端：自动提取租户信息
    grpc.ChainUnaryInterceptor(
        GRPCUnaryServerInterceptor(WithGRPCRequireTenantID()),
    ),
    grpc.ChainStreamInterceptor(
        GRPCStreamServerInterceptor(WithGRPCRequireTenantID()),
    ),
)

// 客户端：自动传播租户信息
conn, _ := grpc.Dial(addr,
    grpc.WithChainUnaryInterceptor(GRPCUnaryClientInterceptor()),
    grpc.WithChainStreamInterceptor(GRPCStreamClientInterceptor()),
)
```

---

## 数据隔离

### MongoDB 租户隔离 Repository

```go
package repository

import (
    "context"
    "fmt"

    "go.mongodb.org/mongo-driver/v2/bson"
    "go.mongodb.org/mongo-driver/v2/mongo"
    "go.mongodb.org/mongo-driver/v2/mongo/options"
)

type Asset struct {
    ID        string `bson:"_id"`
    TenantID  string `bson:"tenant_id"`
    Name      string `bson:"name"`
    Status    string `bson:"status"`
    IsDeleted bool   `bson:"is_deleted"`
}

type AssetRepo struct {
    coll *mongo.Collection
}

// FindByID 按 ID 查找（强制租户隔离）
func (r *AssetRepo) FindByID(ctx context.Context, id string) (*Asset, error) {
    tenantID, err := RequireTenantID(ctx)
    if err != nil {
        return nil, err
    }

    filter := bson.M{
        "_id":       id,
        "tenant_id": tenantID,
    }

    var asset Asset
    if err := r.coll.FindOne(ctx, filter).Decode(&asset); err != nil {
        if err == mongo.ErrNoDocuments {
            return nil, nil
        }
        return nil, fmt.Errorf("find asset: %w", err)
    }
    return &asset, nil
}

// List 分页查询（带租户隔离）
func (r *AssetRepo) List(ctx context.Context, status string, skip, limit int64) ([]*Asset, error) {
    tenantID, err := RequireTenantID(ctx)
    if err != nil {
        return nil, err
    }

    filter := bson.M{
        "tenant_id":  tenantID,
        "is_deleted": false,
    }
    if status != "" {
        filter["status"] = status
    }

    opts := options.Find().
        SetSkip(skip).
        SetLimit(limit).
        SetSort(bson.D{{"created_at", -1}})

    cursor, err := r.coll.Find(ctx, filter, opts)
    if err != nil {
        return nil, fmt.Errorf("list assets: %w", err)
    }
    defer cursor.Close(ctx)

    var assets []*Asset
    if err := cursor.All(ctx, &assets); err != nil {
        return nil, fmt.Errorf("decode assets: %w", err)
    }
    return assets, nil
}

// Insert 插入时自动注入 tenant_id
func (r *AssetRepo) Insert(ctx context.Context, asset *Asset) error {
    tenantID, err := RequireTenantID(ctx)
    if err != nil {
        return err
    }

    asset.TenantID = tenantID
    _, err = r.coll.InsertOne(ctx, asset)
    if err != nil {
        return fmt.Errorf("insert asset: %w", err)
    }
    return nil
}

// Update 更新时强制租户隔离
func (r *AssetRepo) Update(ctx context.Context, id string, update bson.M) error {
    tenantID, err := RequireTenantID(ctx)
    if err != nil {
        return err
    }

    filter := bson.M{
        "_id":       id,
        "tenant_id": tenantID,
    }

    result, err := r.coll.UpdateOne(ctx, filter, bson.M{"$set": update})
    if err != nil {
        return fmt.Errorf("update asset: %w", err)
    }
    if result.MatchedCount == 0 {
        return fmt.Errorf("asset not found or access denied")
    }
    return nil
}

// SoftDelete 软删除（租户隔离）
func (r *AssetRepo) SoftDelete(ctx context.Context, id string) error {
    return r.Update(ctx, id, bson.M{"is_deleted": true})
}

// EnsureIndexes 创建租户隔离索引
func (r *AssetRepo) EnsureIndexes(ctx context.Context) error {
    indexes := []mongo.IndexModel{
        // 租户 + 状态复合索引
        {Keys: bson.D{{"tenant_id", 1}, {"status", 1}}},
        // 租户 + 创建时间（分页排序）
        {Keys: bson.D{{"tenant_id", 1}, {"created_at", -1}}},
        // 租户 + ID 唯一索引
        {
            Keys:    bson.D{{"tenant_id", 1}, {"_id", 1}},
            Options: options.Index().SetUnique(true),
        },
    }

    _, err := r.coll.Indexes().CreateMany(ctx, indexes)
    return err
}
```

### SQL 租户隔离 (PostgreSQL)

```go
package repository

import (
    "context"
    "database/sql"
    "fmt"
)

type TenantRow struct {
    ID           int64  `db:"id"`
    TenantID     string `db:"tenant_id"`
    TenantName   string `db:"tenant_name"`
    Status       int    `db:"status"`
    IsDelete     int    `db:"is_delete"`
    ResourceID   string `db:"resource_id"`
    ResourceType string `db:"resource_type"`
}

type TenantRepo struct {
    db *sql.DB
}

// FindByTenantAndType 按租户ID和资源类型查询
func (r *TenantRepo) FindByTenantAndType(ctx context.Context, tenantID, resourceType string) (*TenantRow, error) {
    query := `
        SELECT t.id, t.tenant_id, t.tenant_name, t.status, t.is_delete,
               tr.resource_id, tr.resource_type
        FROM t_tenant t
        JOIN t_tenant_resource tr ON t.id = tr.tenant_ref_id
        WHERE t.tenant_id = $1
          AND tr.resource_type = $2
          AND t.is_delete = 0`

    var row TenantRow
    err := r.db.QueryRowContext(ctx, query, tenantID, resourceType).Scan(
        &row.ID, &row.TenantID, &row.TenantName, &row.Status, &row.IsDelete,
        &row.ResourceID, &row.ResourceType,
    )
    if err == sql.ErrNoRows {
        return nil, nil
    }
    if err != nil {
        return nil, fmt.Errorf("find tenant: %w", err)
    }
    return &row, nil
}

// ListByType 按资源类型列出所有活跃租户
func (r *TenantRepo) ListByType(ctx context.Context, resourceType string) ([]*TenantRow, error) {
    query := `
        SELECT t.id, t.tenant_id, t.tenant_name, t.status,
               tr.resource_id, tr.resource_type
        FROM t_tenant t
        JOIN t_tenant_resource tr ON t.id = tr.tenant_ref_id
        WHERE t.status = 1
          AND t.is_delete = 0
          AND tr.resource_type = $1
        ORDER BY t.id`

    rows, err := r.db.QueryContext(ctx, query, resourceType)
    if err != nil {
        return nil, fmt.Errorf("list tenants: %w", err)
    }
    defer rows.Close()

    var tenants []*TenantRow
    for rows.Next() {
        var t TenantRow
        if err := rows.Scan(&t.ID, &t.TenantID, &t.TenantName, &t.Status, &t.ResourceID, &t.ResourceType); err != nil {
            return nil, fmt.Errorf("scan tenant: %w", err)
        }
        tenants = append(tenants, &t)
    }
    return tenants, rows.Err()
}
```

---

## 租户感知缓存

### 完整租户缓存实现

```go
package cache

import (
    "context"
    "encoding/json"
    "errors"
    "fmt"
    "math/rand"
    "time"

    "github.com/redis/go-redis/v9"
)

const nullValue = "__NULL__" // 空值标记

// TenantCache 租户感知缓存
type TenantCache struct {
    client  redis.UniversalClient
    baseTTL time.Duration
    jitter  time.Duration
}

// NewTenantCache 创建租户缓存
func NewTenantCache(client redis.UniversalClient, baseTTL, jitter time.Duration) *TenantCache {
    return &TenantCache{
        client:  client,
        baseTTL: baseTTL,
        jitter:  jitter,
    }
}

// tenantKey 生成租户隔离的缓存键
func tenantKey(tenantID, resourceType, resourceID string) string {
    return fmt.Sprintf("tenant:%s:%s:%s", tenantID, resourceType, resourceID)
}

// Get 获取缓存（返回 data, hit, error）
// hit=true + data=nil 表示命中空值缓存（防穿透）
func (c *TenantCache) Get(ctx context.Context, tenantID, resourceType, resourceID string) ([]byte, bool, error) {
    key := tenantKey(tenantID, resourceType, resourceID)

    data, err := c.client.Get(ctx, key).Bytes()
    if errors.Is(err, redis.Nil) {
        return nil, false, nil // 未命中
    }
    if err != nil {
        return nil, false, fmt.Errorf("get cache %s: %w", key, err)
    }

    // 空值缓存命中
    if string(data) == nullValue {
        return nil, true, nil
    }

    return data, true, nil
}

// Set 设置缓存（data=nil 缓存空值防穿透）
func (c *TenantCache) Set(ctx context.Context, tenantID, resourceType, resourceID string, data []byte) error {
    key := tenantKey(tenantID, resourceType, resourceID)
    ttl := c.randomTTL()

    var value any
    if data == nil {
        value = nullValue
    } else {
        value = data
    }

    if err := c.client.Set(ctx, key, value, ttl).Err(); err != nil {
        return fmt.Errorf("set cache %s: %w", key, err)
    }
    return nil
}

// Delete 删除缓存
func (c *TenantCache) Delete(ctx context.Context, tenantID, resourceType, resourceID string) error {
    key := tenantKey(tenantID, resourceType, resourceID)
    return c.client.Del(ctx, key).Err()
}

// DeleteByTenant 删除租户所有缓存（租户注销时）
func (c *TenantCache) DeleteByTenant(ctx context.Context, tenantID string) error {
    pattern := fmt.Sprintf("tenant:%s:*", tenantID)
    var cursor uint64
    for {
        keys, next, err := c.client.Scan(ctx, cursor, pattern, 100).Result()
        if err != nil {
            return fmt.Errorf("scan tenant keys: %w", err)
        }
        if len(keys) > 0 {
            if err := c.client.Del(ctx, keys...).Err(); err != nil {
                return fmt.Errorf("delete tenant keys: %w", err)
            }
        }
        cursor = next
        if cursor == 0 {
            break
        }
    }
    return nil
}

// randomTTL 生成随机 TTL 防止缓存雪崩
func (c *TenantCache) randomTTL() time.Duration {
    offset := time.Duration(rand.Int63n(int64(c.jitter)))
    if rand.Intn(2) == 0 {
        return c.baseTTL - offset
    }
    return c.baseTTL + offset
}

// GetOrLoad 缓存加载模式（Cache-Aside with tenant isolation）
func GetOrLoad[T any](
    ctx context.Context,
    cache *TenantCache,
    tenantID, resourceType, resourceID string,
    loader func(ctx context.Context) (*T, error),
) (*T, error) {
    // 尝试缓存
    data, hit, err := cache.Get(ctx, tenantID, resourceType, resourceID)
    if err != nil {
        return nil, err
    }
    if hit {
        if data == nil {
            return nil, nil // 空值缓存
        }
        var result T
        if err := json.Unmarshal(data, &result); err != nil {
            return nil, fmt.Errorf("unmarshal cache: %w", err)
        }
        return &result, nil
    }

    // 加载
    result, err := loader(ctx)
    if err != nil {
        return nil, err
    }

    // 写缓存
    if result == nil {
        _ = cache.Set(ctx, tenantID, resourceType, resourceID, nil)
    } else {
        data, err := json.Marshal(result)
        if err != nil {
            return result, nil // 序列化失败不影响业务
        }
        _ = cache.Set(ctx, tenantID, resourceType, resourceID, data)
    }

    return result, nil
}
```

### 使用示例

```go
cache := NewTenantCache(redisClient, 24*time.Hour, 1*time.Hour)

func (s *TenantService) GetInfo(ctx context.Context, tenantID, resourceType string) (*TenantInfo, error) {
    return GetOrLoad(ctx, s.cache, tenantID, resourceType, "info",
        func(ctx context.Context) (*TenantInfo, error) {
            return s.repo.FindByTenantAndType(ctx, tenantID, resourceType)
        },
    )
}
```

---

## 消息队列租户隔离

### Kafka 租户分区

```go
package mq

import (
    "context"
    "encoding/json"
    "fmt"

    "github.com/confluentinc/confluent-kafka-go/v2/kafka"
)

// TenantEvent 携带租户信息的事件
type TenantEvent struct {
    EventID   string          `json:"event_id"`
    EventType string          `json:"event_type"`
    TenantID  string          `json:"tenant_id"`
    Timestamp int64           `json:"timestamp"`
    Payload   json.RawMessage `json:"payload"`
}

// TenantProducer 租户感知的 Kafka 生产者
type TenantProducer struct {
    producer *kafka.Producer
}

// Send 发送租户事件（使用 tenant_id 作为 partition key）
func (p *TenantProducer) Send(ctx context.Context, topic string, event TenantEvent) error {
    // 从 context 提取 tenant_id（如果事件未设置）
    if event.TenantID == "" {
        tenantID, err := RequireTenantID(ctx)
        if err != nil {
            return err
        }
        event.TenantID = tenantID
    }

    data, err := json.Marshal(event)
    if err != nil {
        return fmt.Errorf("marshal event: %w", err)
    }

    deliveryChan := make(chan kafka.Event, 1)
    err = p.producer.Produce(&kafka.Message{
        TopicPartition: kafka.TopicPartition{
            Topic:     &topic,
            Partition: kafka.PartitionAny,
        },
        Key:   []byte(event.TenantID), // 按 tenant_id 分区
        Value: data,
    }, deliveryChan)
    if err != nil {
        return fmt.Errorf("produce: %w", err)
    }

    e := <-deliveryChan
    m := e.(*kafka.Message)
    if m.TopicPartition.Error != nil {
        return fmt.Errorf("delivery: %w", m.TopicPartition.Error)
    }
    return nil
}

// TenantConsumer 租户感知的消费者
type TenantConsumer struct {
    consumer *kafka.Consumer
    handler  func(ctx context.Context, event TenantEvent) error
}

// Start 启动消费（自动恢复租户上下文）
func (c *TenantConsumer) Start(ctx context.Context) error {
    for {
        select {
        case <-ctx.Done():
            return ctx.Err()
        default:
            msg, err := c.consumer.ReadMessage(-1)
            if err != nil {
                continue
            }

            var event TenantEvent
            if err := json.Unmarshal(msg.Value, &event); err != nil {
                continue // 或记录日志
            }

            // 恢复租户上下文
            eventCtx := context.Background()
            eventCtx, _ = WithTenantID(eventCtx, event.TenantID)

            if err := c.handler(eventCtx, event); err != nil {
                // 处理失败逻辑（重试/DLQ）
                continue
            }

            c.consumer.CommitMessage(msg)
        }
    }
}
```

### Pulsar 租户属性

```go
package mq

import (
    "context"
    "encoding/json"

    "github.com/apache/pulsar-client-go/pulsar"
)

// PulsarTenantProducer 租户感知的 Pulsar 生产者
type PulsarTenantProducer struct {
    producer pulsar.Producer
}

// Send 发送消息（租户信息存入 Properties）
func (p *PulsarTenantProducer) Send(ctx context.Context, event TenantEvent) error {
    if event.TenantID == "" {
        tenantID, err := RequireTenantID(ctx)
        if err != nil {
            return err
        }
        event.TenantID = tenantID
    }

    data, err := json.Marshal(event)
    if err != nil {
        return err
    }

    _, err = p.producer.Send(ctx, &pulsar.ProducerMessage{
        Payload:    data,
        Key:        event.TenantID, // 分区 key
        Properties: map[string]string{
            "tenant_id":  event.TenantID,
            "event_type": event.EventType,
        },
    })
    return err
}

// PulsarTenantConsumer 租户感知的 Pulsar 消费者
type PulsarTenantConsumer struct {
    consumer pulsar.Consumer
    handler  func(ctx context.Context, event TenantEvent) error
}

// Start 启动消费
func (c *PulsarTenantConsumer) Start(ctx context.Context) error {
    for {
        msg, err := c.consumer.Receive(ctx)
        if err != nil {
            return err
        }

        var event TenantEvent
        if err := json.Unmarshal(msg.Payload(), &event); err != nil {
            c.consumer.Nack(msg)
            continue
        }

        // 恢复租户上下文
        eventCtx := context.Background()
        eventCtx, _ = WithTenantID(eventCtx, event.TenantID)

        if err := c.handler(eventCtx, event); err != nil {
            c.consumer.Nack(msg)
            continue
        }

        c.consumer.Ack(msg)
    }
}
```

---

## 租户生命周期管理

### 事件驱动的租户管理

```go
package tenant

import (
    "context"
    "encoding/json"
    "fmt"
    "time"

    "github.com/google/uuid"
)

// 租户状态
const (
    StatusPending  = 0 // 创建中
    StatusActive   = 1 // 正常
    StatusSuspend  = 2 // 暂停
    StatusDeleted  = 3 // 已删除
)

// 事件类型
const (
    EventCreate  = "tenant.create"
    EventUpdate  = "tenant.update"
    EventSuspend = "tenant.suspend"
    EventResume  = "tenant.resume"
    EventDelete  = "tenant.delete"
)

// TenantLifecycleEvent 租户生命周期事件
type TenantLifecycleEvent struct {
    EventID   string          `json:"event_id"`
    EventType string          `json:"event_type"`
    TenantID  string          `json:"tenant_id"`
    Timestamp time.Time       `json:"timestamp"`
    Payload   json.RawMessage `json:"payload"`
    Version   string          `json:"version"`
}

// TenantService 租户生命周期管理服务
type TenantService struct {
    repo       TenantRepository
    cache      *TenantCache
    publisher  EventPublisher
    eventStore EventStore
}

// Create 创建租户
func (s *TenantService) Create(ctx context.Context, req CreateTenantRequest) (*Tenant, error) {
    tenant := &Tenant{
        ID:     uuid.New().String(),
        Name:   req.Name,
        Status: StatusPending,
    }

    // 持久化
    if err := s.repo.Insert(ctx, tenant); err != nil {
        return nil, fmt.Errorf("insert tenant: %w", err)
    }

    // 发布事件
    event := TenantLifecycleEvent{
        EventID:   uuid.New().String(),
        EventType: EventCreate,
        TenantID:  tenant.ID,
        Timestamp: time.Now(),
        Version:   "1.0",
    }

    if err := s.publisher.Publish(ctx, "tenant-events", event); err != nil {
        // 事件发布失败：记录到 event store 用于重试
        _ = s.eventStore.Save(ctx, event)
    }

    return tenant, nil
}

// HandleCreateResult 处理创建结果回调
func (s *TenantService) HandleCreateResult(ctx context.Context, event TenantLifecycleEvent, success bool) error {
    var newStatus int
    if success {
        newStatus = StatusActive
    } else {
        newStatus = StatusDeleted
    }

    // 事务更新
    if err := s.repo.UpdateStatus(ctx, event.TenantID, newStatus); err != nil {
        return fmt.Errorf("update status: %w", err)
    }

    // 清理缓存
    if err := s.cache.DeleteByTenant(ctx, event.TenantID); err != nil {
        return fmt.Errorf("delete cache: %w", err) // 非致命，记录日志
    }

    return nil
}

// Suspend 暂停租户
func (s *TenantService) Suspend(ctx context.Context, tenantID string) error {
    if err := s.repo.UpdateStatus(ctx, tenantID, StatusSuspend); err != nil {
        return err
    }

    _ = s.cache.DeleteByTenant(ctx, tenantID)

    return s.publisher.Publish(ctx, "tenant-events", TenantLifecycleEvent{
        EventID:   uuid.New().String(),
        EventType: EventSuspend,
        TenantID:  tenantID,
        Timestamp: time.Now(),
    })
}

// Delete 删除租户（软删除 + 级联清理）
func (s *TenantService) Delete(ctx context.Context, tenantID string) error {
    if err := s.repo.SoftDelete(ctx, tenantID); err != nil {
        return err
    }

    // 级联清理缓存
    _ = s.cache.DeleteByTenant(ctx, tenantID)

    return s.publisher.Publish(ctx, "tenant-events", TenantLifecycleEvent{
        EventID:   uuid.New().String(),
        EventType: EventDelete,
        TenantID:  tenantID,
        Timestamp: time.Now(),
    })
}
```

### 租户发现与配置加载

```go
// TenantDiscovery 租户发现（从管理服务加载活跃租户列表）
type TenantDiscovery struct {
    client TenantManagementClient
}

type TenantConfig struct {
    TenantID     string
    TenantName   string
    ResourceID   string
    Subscription []string // 订阅的产品模块
}

// Load 加载所有活跃租户配置
func (d *TenantDiscovery) Load(ctx context.Context) ([]TenantConfig, error) {
    tenants, err := d.client.ListActiveTenants(ctx)
    if err != nil {
        return nil, fmt.Errorf("list tenants: %w", err)
    }

    var configs []TenantConfig
    for _, t := range tenants {
        if t.Status != StatusActive {
            continue
        }
        configs = append(configs, TenantConfig{
            TenantID:     t.TenantID,
            TenantName:   t.TenantName,
            ResourceID:   t.ResourceID,
            Subscription: t.Subscription,
        })
    }
    return configs, nil
}
```
