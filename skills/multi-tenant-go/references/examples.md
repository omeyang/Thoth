# Go 多租户模式 - 完整代码实现

## 目录

- [租户上下文（context.go）](#租户上下文contextgo)
- [HTTP 中间件与跨服务传播（http.go）](#http-中间件与跨服务传播httpgo)
- [gRPC 拦截器（grpc.go）](#grpc-拦截器grpcgo)
- [数据隔离：MongoDB 与 PostgreSQL（repo.go）](#数据隔离mongodb-与-postgresqlrepogo)
- [租户感知缓存（cache.go）](#租户感知缓存cachego)
- [消息队列：Kafka 与 Pulsar（mq.go）](#消息队列kafka-与-pulsarmqgo)
- [租户生命周期（lifecycle.go）](#租户生命周期lifecyclego)

---

所有代码在 go1.24.6 下通过 `go vet`，统一放在 `package tenant`（按文件拆分展示）。依赖版本：

```text
go get google.golang.org/grpc@v1.80.0
go get go.mongodb.org/mongo-driver/v2@v2.8.2
go get github.com/redis/go-redis/v9@v9.22.0
go get github.com/confluentinc/confluent-kafka-go/v2@v2.14.1
go get github.com/apache/pulsar-client-go@v0.20.0
go get github.com/google/uuid@v1.6.0
```

---

## 租户上下文（context.go）

Context key 用私有结构体类型，`With*` 只返回 `context.Context`，提取函数零值安全。

```go
package tenant

import (
	"context"
	"errors"
)

// contextKey 使用私有类型防止与其他包的 key 冲突
type contextKey struct{ name string }

var (
	keyTenantID   = contextKey{"tenant_id"}
	keyTenantName = contextKey{"tenant_name"}
)

var (
	ErrEmptyTenantID   = errors.New("tenant: empty tenant_id")
	ErrEmptyTenantName = errors.New("tenant: empty tenant_name")
	ErrMissingTenantID = errors.New("tenant: missing tenant_id in context")
)

// Info 请求级租户信息
type Info struct {
	TenantID   string
	TenantName string
}

func (t Info) IsEmpty() bool { return t.TenantID == "" && t.TenantName == "" }

func (t Info) Validate() error {
	if t.TenantID == "" {
		return ErrEmptyTenantID
	}
	if t.TenantName == "" {
		return ErrEmptyTenantName
	}
	return nil
}

// ---------- 注入 ----------

func WithTenantID(ctx context.Context, tenantID string) context.Context {
	return context.WithValue(ctx, keyTenantID, tenantID)
}

func WithTenantName(ctx context.Context, tenantName string) context.Context {
	return context.WithValue(ctx, keyTenantName, tenantName)
}

// WithInfo 批量注入，只注入非空字段
func WithInfo(ctx context.Context, info Info) context.Context {
	if info.TenantID != "" {
		ctx = WithTenantID(ctx, info.TenantID)
	}
	if info.TenantName != "" {
		ctx = WithTenantName(ctx, info.TenantName)
	}
	return ctx
}

// ---------- 提取（零值安全） ----------

func TenantID(ctx context.Context) string {
	v, _ := ctx.Value(keyTenantID).(string)
	return v
}

func TenantName(ctx context.Context) string {
	v, _ := ctx.Value(keyTenantName).(string)
	return v
}

func FromContext(ctx context.Context) Info {
	return Info{TenantID: TenantID(ctx), TenantName: TenantName(ctx)}
}

// RequireTenantID 业务必需场景：缺失即报错
func RequireTenantID(ctx context.Context) (string, error) {
	v := TenantID(ctx)
	if v == "" {
		return "", ErrMissingTenantID
	}
	return v, nil
}
```

---

## HTTP 中间件与跨服务传播（http.go）

`Requirement` 决定校验强度：网关用 `NeedTenant`，内部服务用 `NeedTenantID`。

```go
package tenant

import (
	"context"
	"net/http"
	"strings"
)

const (
	HeaderTenantID   = "X-Tenant-ID"
	HeaderTenantName = "X-Tenant-Name"
)

// ExtractFromHeader 从 HTTP Header 提取租户信息
func ExtractFromHeader(h http.Header) Info {
	return Info{
		TenantID:   strings.TrimSpace(h.Get(HeaderTenantID)),
		TenantName: strings.TrimSpace(h.Get(HeaderTenantName)),
	}
}

// Requirement 中间件校验级别
type Requirement int

const (
	Optional     Requirement = iota // 不校验
	NeedTenantID                    // 只要求 tenant_id
	NeedTenant                      // 要求 tenant_id + tenant_name
)

func (r Requirement) check(info Info) error {
	switch r {
	case NeedTenant:
		return info.Validate()
	case NeedTenantID:
		if info.TenantID == "" {
			return ErrEmptyTenantID
		}
	}
	return nil
}

// HTTPMiddleware 提取 Header 并注入 Context
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

// InjectToRequest 调用下游服务时注入 Header。
// 用 Set 覆盖同名 Header，避免上游残留值造成 tenant leakage
func InjectToRequest(ctx context.Context, req *http.Request) {
	if req == nil {
		return
	}
	if req.Header == nil {
		req.Header = http.Header{}
	}
	if tid := TenantID(ctx); tid != "" {
		req.Header.Set(HeaderTenantID, tid)
	}
	if tname := TenantName(ctx); tname != "" {
		req.Header.Set(HeaderTenantName, tname)
	}
}

// TenantTransport 作为 http.Client 的 Transport，自动传播租户信息
type TenantTransport struct {
	Base http.RoundTripper
}

func (t *TenantTransport) RoundTrip(req *http.Request) (*http.Response, error) {
	base := t.Base
	if base == nil {
		base = http.DefaultTransport
	}
	clone := req.Clone(req.Context())
	InjectToRequest(req.Context(), clone)
	return base.RoundTrip(clone)
}

// 使用示例
func NewRouter() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET /api/assets", func(w http.ResponseWriter, r *http.Request) {
		tenantID, err := RequireTenantID(r.Context())
		if err != nil {
			http.Error(w, err.Error(), http.StatusBadRequest)
			return
		}
		_, _ = w.Write([]byte("tenant " + tenantID))
	})
	// 网关入口：要求完整租户信息；内部服务可改为 NeedTenantID
	return HTTPMiddleware(NeedTenant)(mux)
}

func CallDownstream(ctx context.Context, url string) (*http.Response, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return nil, err
	}
	InjectToRequest(ctx, req)
	return http.DefaultClient.Do(req)
}
```

---

## gRPC 拦截器（grpc.go）

metadata key 必须小写；注入用 `md.Set` 覆盖，避免 `Append` 累积多值。客户端用 `grpc.NewClient`。

```go
package tenant

import (
	"context"
	"strings"

	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/credentials/insecure"
	"google.golang.org/grpc/metadata"
	"google.golang.org/grpc/status"
)

// gRPC metadata key 必须小写
const (
	MetaTenantID   = "x-tenant-id"
	MetaTenantName = "x-tenant-name"
)

func ExtractFromMetadata(md metadata.MD) Info {
	return Info{
		TenantID:   metaValue(md, MetaTenantID),
		TenantName: metaValue(md, MetaTenantName),
	}
}

func metaValue(md metadata.MD, key string) string {
	values := md.Get(key)
	if len(values) == 0 {
		return ""
	}
	return strings.TrimSpace(values[0])
}

func requirementToStatus(err error) error {
	return status.Error(codes.InvalidArgument, err.Error())
}

// UnaryServerInterceptor 一元服务端拦截器
func UnaryServerInterceptor(req Requirement) grpc.UnaryServerInterceptor {
	return func(ctx context.Context, request any, _ *grpc.UnaryServerInfo, handler grpc.UnaryHandler) (any, error) {
		md, _ := metadata.FromIncomingContext(ctx)
		info := ExtractFromMetadata(md)
		if err := req.check(info); err != nil {
			return nil, requirementToStatus(err)
		}
		return handler(WithInfo(ctx, info), request)
	}
}

// StreamServerInterceptor 流式服务端拦截器
func StreamServerInterceptor(req Requirement) grpc.StreamServerInterceptor {
	return func(srv any, ss grpc.ServerStream, _ *grpc.StreamServerInfo, handler grpc.StreamHandler) error {
		md, _ := metadata.FromIncomingContext(ss.Context())
		info := ExtractFromMetadata(md)
		if err := req.check(info); err != nil {
			return requirementToStatus(err)
		}
		return handler(srv, &wrappedServerStream{ServerStream: ss, ctx: WithInfo(ss.Context(), info)})
	}
}

// wrappedServerStream 覆盖 Context()，让 handler 拿到注入后的 ctx
type wrappedServerStream struct {
	grpc.ServerStream
	ctx context.Context
}

func (w *wrappedServerStream) Context() context.Context { return w.ctx }

// InjectToOutgoingContext 客户端调用前注入 metadata。
// md.Set 覆盖同名 key，避免 Append 造成多值与 tenant leakage
func InjectToOutgoingContext(ctx context.Context) context.Context {
	md, ok := metadata.FromOutgoingContext(ctx)
	if !ok {
		md = metadata.MD{}
	} else {
		md = md.Copy()
	}
	if tid := TenantID(ctx); tid != "" {
		md.Set(MetaTenantID, tid)
	}
	if tname := TenantName(ctx); tname != "" {
		md.Set(MetaTenantName, tname)
	}
	if len(md) == 0 {
		return ctx
	}
	return metadata.NewOutgoingContext(ctx, md)
}

func UnaryClientInterceptor() grpc.UnaryClientInterceptor {
	return func(ctx context.Context, method string, req, reply any, cc *grpc.ClientConn, invoker grpc.UnaryInvoker, opts ...grpc.CallOption) error {
		return invoker(InjectToOutgoingContext(ctx), method, req, reply, cc, opts...)
	}
}

func StreamClientInterceptor() grpc.StreamClientInterceptor {
	return func(ctx context.Context, desc *grpc.StreamDesc, cc *grpc.ClientConn, method string, streamer grpc.Streamer, opts ...grpc.CallOption) (grpc.ClientStream, error) {
		return streamer(InjectToOutgoingContext(ctx), desc, cc, method, opts...)
	}
}

// 注册示例
func NewGRPCServer() *grpc.Server {
	return grpc.NewServer(
		grpc.ChainUnaryInterceptor(UnaryServerInterceptor(NeedTenantID)),
		grpc.ChainStreamInterceptor(StreamServerInterceptor(NeedTenantID)),
	)
}

func NewGRPCClient(target string) (*grpc.ClientConn, error) {
	// grpc.Dial 已弃用，使用 NewClient
	return grpc.NewClient(target,
		grpc.WithTransportCredentials(insecure.NewCredentials()),
		grpc.WithChainUnaryInterceptor(UnaryClientInterceptor()),
		grpc.WithChainStreamInterceptor(StreamClientInterceptor()),
	)
}
```

---

## 数据隔离：MongoDB 与 PostgreSQL（repo.go）

每个查询都从 ctx 取 tenant_id 并加入过滤条件；写入时用 ctx 值覆盖请求体里的 tenant_id。

```go
package tenant

import (
	"context"
	"database/sql"
	"errors"
	"fmt"

	"go.mongodb.org/mongo-driver/v2/bson"
	"go.mongodb.org/mongo-driver/v2/mongo"
	"go.mongodb.org/mongo-driver/v2/mongo/options"
)

var ErrNotFound = errors.New("not found")

// ---------- MongoDB：共享集合 + tenant_id 分区键 ----------

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

func NewAssetRepo(coll *mongo.Collection) *AssetRepo { return &AssetRepo{coll: coll} }

// FindByID 过滤条件同时带 _id 与 tenant_id，跨租户访问返回 ErrNotFound
func (r *AssetRepo) FindByID(ctx context.Context, id string) (*Asset, error) {
	tenantID, err := RequireTenantID(ctx)
	if err != nil {
		return nil, err
	}
	var asset Asset
	err = r.coll.FindOne(ctx, bson.M{"_id": id, "tenant_id": tenantID}).Decode(&asset)
	if errors.Is(err, mongo.ErrNoDocuments) {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, fmt.Errorf("find asset: %w", err)
	}
	return &asset, nil
}

func (r *AssetRepo) List(ctx context.Context, status string, skip, limit int64) ([]Asset, error) {
	tenantID, err := RequireTenantID(ctx)
	if err != nil {
		return nil, err
	}
	filter := bson.M{"tenant_id": tenantID, "is_deleted": false}
	if status != "" {
		filter["status"] = status
	}
	opts := options.Find().
		SetSkip(skip).
		SetLimit(limit).
		SetSort(bson.D{{Key: "created_at", Value: -1}})

	cursor, err := r.coll.Find(ctx, filter, opts)
	if err != nil {
		return nil, fmt.Errorf("list assets: %w", err)
	}
	defer cursor.Close(ctx)

	var assets []Asset
	if err := cursor.All(ctx, &assets); err != nil {
		return nil, fmt.Errorf("decode assets: %w", err)
	}
	return assets, nil
}

// Insert 写入时用 ctx 中的 tenant_id 覆盖，防止调用方伪造
func (r *AssetRepo) Insert(ctx context.Context, asset *Asset) error {
	tenantID, err := RequireTenantID(ctx)
	if err != nil {
		return err
	}
	asset.TenantID = tenantID
	if _, err := r.coll.InsertOne(ctx, asset); err != nil {
		return fmt.Errorf("insert asset: %w", err)
	}
	return nil
}

func (r *AssetRepo) Update(ctx context.Context, id string, update bson.M) error {
	tenantID, err := RequireTenantID(ctx)
	if err != nil {
		return err
	}
	delete(update, "tenant_id") // 禁止改写分区键
	result, err := r.coll.UpdateOne(ctx,
		bson.M{"_id": id, "tenant_id": tenantID},
		bson.M{"$set": update},
	)
	if err != nil {
		return fmt.Errorf("update asset: %w", err)
	}
	if result.MatchedCount == 0 {
		return ErrNotFound
	}
	return nil
}

func (r *AssetRepo) SoftDelete(ctx context.Context, id string) error {
	return r.Update(ctx, id, bson.M{"is_deleted": true})
}

// EnsureIndexes 复合索引以 tenant_id 为前缀，每个租户的查询都能走索引
func (r *AssetRepo) EnsureIndexes(ctx context.Context) error {
	indexes := []mongo.IndexModel{
		{Keys: bson.D{{Key: "tenant_id", Value: 1}, {Key: "status", Value: 1}}},
		{Keys: bson.D{{Key: "tenant_id", Value: 1}, {Key: "created_at", Value: -1}}},
		{
			Keys:    bson.D{{Key: "tenant_id", Value: 1}, {Key: "name", Value: 1}},
			Options: options.Index().SetUnique(true), // 租户内名称唯一
		},
	}
	_, err := r.coll.Indexes().CreateMany(ctx, indexes)
	return err
}

// ---------- PostgreSQL：共享表 + tenant_id 列 ----------

type Order struct {
	ID       int64
	TenantID string
	Status   string
	Amount   int64
}

type OrderRepo struct {
	db *sql.DB
}

func NewOrderRepo(db *sql.DB) *OrderRepo { return &OrderRepo{db: db} }

func (r *OrderRepo) FindByID(ctx context.Context, id int64) (*Order, error) {
	tenantID, err := RequireTenantID(ctx)
	if err != nil {
		return nil, err
	}
	const q = `SELECT id, tenant_id, status, amount FROM orders WHERE id = $1 AND tenant_id = $2`
	var o Order
	err = r.db.QueryRowContext(ctx, q, id, tenantID).Scan(&o.ID, &o.TenantID, &o.Status, &o.Amount)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, ErrNotFound
	}
	if err != nil {
		return nil, fmt.Errorf("find order: %w", err)
	}
	return &o, nil
}

func (r *OrderRepo) ListByStatus(ctx context.Context, status string) ([]Order, error) {
	tenantID, err := RequireTenantID(ctx)
	if err != nil {
		return nil, err
	}
	const q = `SELECT id, tenant_id, status, amount FROM orders
	           WHERE tenant_id = $1 AND status = $2 ORDER BY id`
	rows, err := r.db.QueryContext(ctx, q, tenantID, status)
	if err != nil {
		return nil, fmt.Errorf("list orders: %w", err)
	}
	defer rows.Close()

	var orders []Order
	for rows.Next() {
		var o Order
		if err := rows.Scan(&o.ID, &o.TenantID, &o.Status, &o.Amount); err != nil {
			return nil, fmt.Errorf("scan order: %w", err)
		}
		orders = append(orders, o)
	}
	return orders, rows.Err()
}

// DDL 参考：
// CREATE TABLE orders (
//     id        BIGSERIAL PRIMARY KEY,
//     tenant_id TEXT NOT NULL,
//     status    TEXT NOT NULL,
//     amount    BIGINT NOT NULL
// );
// CREATE INDEX idx_orders_tenant_status ON orders (tenant_id, status);
// 可选：ALTER TABLE orders ENABLE ROW LEVEL SECURITY 配合 current_setting('app.tenant_id') 做兜底
```

---

## 租户感知缓存（cache.go）

键含 tenant_id；空值标记防穿透；`math/rand/v2` 生成 TTL 抖动防雪崩；租户变更时 SCAN 级联清理。

```go
package tenant

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"math/rand/v2"
	"time"

	"github.com/redis/go-redis/v9"
)

const nullValue = "__NULL__" // 空值标记

// Cache 租户感知缓存：键含 tenant_id，空值缓存防穿透，随机 TTL 防雪崩
type Cache struct {
	client  redis.UniversalClient
	baseTTL time.Duration
	jitter  time.Duration
}

func NewCache(client redis.UniversalClient, baseTTL, jitter time.Duration) *Cache {
	return &Cache{client: client, baseTTL: baseTTL, jitter: jitter}
}

// CacheKey 缓存键必须以 tenant_id 分段，防止跨租户读到别人的数据
func CacheKey(tenantID, resourceType, resourceID string) string {
	return fmt.Sprintf("tenant:%s:%s:%s", tenantID, resourceType, resourceID)
}

// Get 返回 (data, hit, err)。hit=true 且 data=nil 表示命中空值缓存
func (c *Cache) Get(ctx context.Context, tenantID, resourceType, resourceID string) ([]byte, bool, error) {
	key := CacheKey(tenantID, resourceType, resourceID)
	data, err := c.client.Get(ctx, key).Bytes()
	if errors.Is(err, redis.Nil) {
		return nil, false, nil
	}
	if err != nil {
		return nil, false, fmt.Errorf("get cache %s: %w", key, err)
	}
	if string(data) == nullValue {
		return nil, true, nil
	}
	return data, true, nil
}

// Set data=nil 时写入空值标记
func (c *Cache) Set(ctx context.Context, tenantID, resourceType, resourceID string, data []byte) error {
	key := CacheKey(tenantID, resourceType, resourceID)
	var value any = data
	if data == nil {
		value = nullValue
	}
	if err := c.client.Set(ctx, key, value, c.randomTTL()).Err(); err != nil {
		return fmt.Errorf("set cache %s: %w", key, err)
	}
	return nil
}

func (c *Cache) Delete(ctx context.Context, tenantID, resourceType, resourceID string) error {
	return c.client.Del(ctx, CacheKey(tenantID, resourceType, resourceID)).Err()
}

// DeleteByTenant 租户注销或变更时用 SCAN 级联清理（不要用 KEYS）
func (c *Cache) DeleteByTenant(ctx context.Context, tenantID string) error {
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
			return nil
		}
	}
}

// randomTTL 在 [baseTTL - jitter, baseTTL + jitter) 内随机，避免同一批键同时过期
func (c *Cache) randomTTL() time.Duration {
	if c.jitter <= 0 {
		return c.baseTTL
	}
	offset := rand.N(2*c.jitter) - c.jitter
	return c.baseTTL + offset
}

// GetOrLoad Cache-Aside；loader 返回 (nil, nil) 表示资源不存在，写入空值缓存
func GetOrLoad[T any](ctx context.Context, cache *Cache, resourceType, resourceID string, loader func(ctx context.Context) (*T, error)) (*T, error) {
	tenantID, err := RequireTenantID(ctx)
	if err != nil {
		return nil, err
	}

	data, hit, err := cache.Get(ctx, tenantID, resourceType, resourceID)
	if err != nil {
		return nil, err
	}
	if hit {
		if data == nil {
			return nil, nil
		}
		var result T
		if err := json.Unmarshal(data, &result); err != nil {
			return nil, fmt.Errorf("unmarshal cache: %w", err)
		}
		return &result, nil
	}

	result, err := loader(ctx)
	if err != nil {
		return nil, err
	}
	if result == nil {
		_ = cache.Set(ctx, tenantID, resourceType, resourceID, nil)
		return nil, nil
	}
	if data, err := json.Marshal(result); err == nil {
		_ = cache.Set(ctx, tenantID, resourceType, resourceID, data)
	}
	return result, nil
}

// 使用示例
type Service struct {
	cache *Cache
	repo  *AssetRepo
}

func (s *Service) GetAsset(ctx context.Context, id string) (*Asset, error) {
	return GetOrLoad(ctx, s.cache, "asset", id, func(ctx context.Context) (*Asset, error) {
		asset, err := s.repo.FindByID(ctx, id)
		if errors.Is(err, ErrNotFound) {
			return nil, nil // 触发空值缓存
		}
		return asset, err
	})
}
```

---

## 消息队列：Kafka 与 Pulsar（mq.go）

Kafka 用 tenant_id 作 Key 保证租户内有序；Pulsar 用 Key + Properties。消费端从消息体恢复 ctx。

```go
package tenant

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"time"

	"github.com/apache/pulsar-client-go/pulsar"
	"github.com/confluentinc/confluent-kafka-go/v2/kafka"
)

// Event 消息体自带 tenant_id，消费端据此恢复上下文
type Event struct {
	EventID   string          `json:"event_id"`
	EventType string          `json:"event_type"`
	TenantID  string          `json:"tenant_id"`
	Timestamp time.Time       `json:"timestamp"`
	Payload   json.RawMessage `json:"payload,omitempty"`
}

// ---------- Kafka ----------

type KafkaProducer struct {
	producer *kafka.Producer
}

// Send 以 tenant_id 作为 Key：同一租户落同一分区，租户内有序
func (p *KafkaProducer) Send(ctx context.Context, topic string, event Event) error {
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

	delivery := make(chan kafka.Event, 1)
	err = p.producer.Produce(&kafka.Message{
		TopicPartition: kafka.TopicPartition{Topic: &topic, Partition: kafka.PartitionAny},
		Key:            []byte(event.TenantID),
		Value:          data,
		Headers:        []kafka.Header{{Key: "tenant_id", Value: []byte(event.TenantID)}},
	}, delivery)
	if err != nil {
		return fmt.Errorf("produce: %w", err)
	}

	select {
	case <-ctx.Done():
		return ctx.Err()
	case e := <-delivery:
		m, ok := e.(*kafka.Message)
		if !ok {
			return fmt.Errorf("unexpected event %T", e)
		}
		if m.TopicPartition.Error != nil {
			return fmt.Errorf("delivery: %w", m.TopicPartition.Error)
		}
		return nil
	}
}

type KafkaConsumer struct {
	consumer *kafka.Consumer
	handler  func(ctx context.Context, event Event) error
}

// Run 轮询消费，为每条消息恢复租户上下文
func (c *KafkaConsumer) Run(ctx context.Context) error {
	for {
		if err := ctx.Err(); err != nil {
			return err
		}
		msg, err := c.consumer.ReadMessage(500 * time.Millisecond)
		if err != nil {
			var kerr kafka.Error
			if errors.As(err, &kerr) && kerr.IsTimeout() {
				continue
			}
			slog.Error("read message", slog.Any("error", err))
			continue
		}

		var event Event
		if err := json.Unmarshal(msg.Value, &event); err != nil {
			slog.Warn("bad payload", slog.Any("error", err))
			continue
		}
		if event.TenantID == "" {
			event.TenantID = string(msg.Key)
		}

		msgCtx := WithTenantID(ctx, event.TenantID)
		if err := c.handler(msgCtx, event); err != nil {
			slog.Error("handle event", slog.String("tenant", event.TenantID), slog.Any("error", err))
			continue // 重试或转 DLQ
		}
		if _, err := c.consumer.CommitMessage(msg); err != nil {
			slog.Error("commit", slog.Any("error", err))
		}
	}
}

// ---------- Pulsar ----------

type PulsarProducer struct {
	producer pulsar.Producer
}

// Send Key 用于 KeyShared 订阅按租户分派；Properties 供消费端过滤
func (p *PulsarProducer) Send(ctx context.Context, event Event) error {
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
		Payload: data,
		Key:     event.TenantID,
		Properties: map[string]string{
			"tenant_id":  event.TenantID,
			"event_type": event.EventType,
		},
	})
	return err
}

type PulsarConsumer struct {
	consumer pulsar.Consumer
	handler  func(ctx context.Context, event Event) error
}

func (c *PulsarConsumer) Run(ctx context.Context) error {
	for {
		msg, err := c.consumer.Receive(ctx)
		if err != nil {
			return err // ctx 取消或连接关闭
		}

		var event Event
		if err := json.Unmarshal(msg.Payload(), &event); err != nil {
			c.consumer.Nack(msg)
			continue
		}
		if event.TenantID == "" {
			event.TenantID = msg.Properties()["tenant_id"]
		}

		msgCtx := WithTenantID(ctx, event.TenantID)
		if err := c.handler(msgCtx, event); err != nil {
			c.consumer.Nack(msg) // 触发重投或 DLQ
			continue
		}
		if err := c.consumer.Ack(msg); err != nil {
			slog.Error("ack", slog.Any("error", err))
		}
	}
}
```

---

## 租户生命周期（lifecycle.go）

状态变更后缓存必须失效；事件发布失败落 outbox 重试；定时任务按租户扇出时为每个租户构造独立 ctx。

```go
package tenant

import (
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"time"

	"github.com/google/uuid"
)

// 租户状态
const (
	StatusPending = 0
	StatusActive  = 1
	StatusSuspend = 2
	StatusDeleted = 3
)

// 事件类型
const (
	EventCreate  = "tenant.create"
	EventSuspend = "tenant.suspend"
	EventResume  = "tenant.resume"
	EventDelete  = "tenant.delete"
)

type Tenant struct {
	ID     string
	Name   string
	Status int
}

type CreateTenantRequest struct {
	Name string
}

// 依赖以接口声明，便于替换与测试
type Repository interface {
	Insert(ctx context.Context, t *Tenant) error
	UpdateStatus(ctx context.Context, tenantID string, status int) error
	ListActive(ctx context.Context) ([]Tenant, error)
}

type Publisher interface {
	Publish(ctx context.Context, topic string, event Event) error
}

type Outbox interface {
	Save(ctx context.Context, topic string, event Event) error
}

type LifecycleService struct {
	repo   Repository
	cache  *Cache
	pub    Publisher
	outbox Outbox
}

func NewLifecycleService(repo Repository, cache *Cache, pub Publisher, outbox Outbox) *LifecycleService {
	return &LifecycleService{repo: repo, cache: cache, pub: pub, outbox: outbox}
}

func (s *LifecycleService) emit(ctx context.Context, eventType, tenantID string, payload any) {
	event := Event{
		EventID:   uuid.NewString(),
		EventType: eventType,
		TenantID:  tenantID,
		Timestamp: time.Now(),
	}
	if payload != nil {
		if data, err := json.Marshal(payload); err == nil {
			event.Payload = data
		}
	}
	if err := s.pub.Publish(ctx, "tenant-events", event); err != nil {
		// 发布失败不阻塞主流程：落 outbox 由后台任务重试
		slog.Warn("publish failed, saved to outbox", slog.String("event", eventType), slog.Any("error", err))
		_ = s.outbox.Save(ctx, "tenant-events", event)
	}
}

// Create 先持久化再发事件；下游（初始化配额、建索引）消费事件后回调 HandleProvisioned
func (s *LifecycleService) Create(ctx context.Context, req CreateTenantRequest) (*Tenant, error) {
	t := &Tenant{ID: uuid.NewString(), Name: req.Name, Status: StatusPending}
	if err := s.repo.Insert(ctx, t); err != nil {
		return nil, fmt.Errorf("insert tenant: %w", err)
	}
	s.emit(ctx, EventCreate, t.ID, req)
	return t, nil
}

func (s *LifecycleService) HandleProvisioned(ctx context.Context, tenantID string, ok bool) error {
	status := StatusActive
	if !ok {
		status = StatusDeleted
	}
	if err := s.repo.UpdateStatus(ctx, tenantID, status); err != nil {
		return fmt.Errorf("update status: %w", err)
	}
	return s.cache.DeleteByTenant(ctx, tenantID)
}

func (s *LifecycleService) Suspend(ctx context.Context, tenantID string) error {
	if err := s.repo.UpdateStatus(ctx, tenantID, StatusSuspend); err != nil {
		return err
	}
	_ = s.cache.DeleteByTenant(ctx, tenantID) // 状态变更后缓存必须失效
	s.emit(ctx, EventSuspend, tenantID, nil)
	return nil
}

// Delete 软删除 + 级联清理缓存；数据物理删除由离线任务按 tenant_id 分批执行
func (s *LifecycleService) Delete(ctx context.Context, tenantID string) error {
	if err := s.repo.UpdateStatus(ctx, tenantID, StatusDeleted); err != nil {
		return err
	}
	_ = s.cache.DeleteByTenant(ctx, tenantID)
	s.emit(ctx, EventDelete, tenantID, nil)
	return nil
}

// ---------- 租户发现 ----------

// Registry 进程内缓存活跃租户，供定时任务按租户扇出
type Registry struct {
	repo Repository
}

func (r *Registry) Load(ctx context.Context) ([]Tenant, error) {
	tenants, err := r.repo.ListActive(ctx)
	if err != nil {
		return nil, fmt.Errorf("list tenants: %w", err)
	}
	active := tenants[:0]
	for _, t := range tenants {
		if t.Status == StatusActive {
			active = append(active, t)
		}
	}
	return active, nil
}

// ForEachTenant 为每个租户构造独立 ctx 执行任务
func (r *Registry) ForEachTenant(ctx context.Context, fn func(ctx context.Context, t Tenant) error) error {
	tenants, err := r.Load(ctx)
	if err != nil {
		return err
	}
	for _, t := range tenants {
		tctx := WithInfo(ctx, Info{TenantID: t.ID, TenantName: t.Name})
		if err := fn(tctx, t); err != nil {
			slog.Error("tenant job", slog.String("tenant", t.ID), slog.Any("error", err))
		}
	}
	return nil
}
```
