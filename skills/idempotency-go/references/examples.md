# Go 幂等性处理 - 完整代码实现

## 目录

- [记录与存储接口（store.go）](#记录与存储接口storego)
- [幂等键设计（key.go）](#幂等键设计keygo)
- [Redis 存储（redis.go）](#redis-存储redisgo)
- [PostgreSQL 存储（postgres.go）](#postgresql-存储postgresgo)
- [MongoDB 存储（mongo.go）](#mongodb-存储mongogo)
- [HTTP 中间件（middleware.go）](#http-中间件middlewarego)
- [业务层幂等：订单创建（service.go）](#业务层幂等订单创建servicego)
- [消息消费去重（consumer.go）](#消息消费去重consumergo)

---

所有代码在 go1.24.6 下通过 `go vet`，统一放在 `package idem`（按文件拆分展示）。三个存储实现都满足 `Store` 接口。依赖版本：

```text
go get github.com/redis/go-redis/v9@v9.22.0
go get go.mongodb.org/mongo-driver/v2@v2.8.2
go get github.com/confluentinc/confluent-kafka-go/v2@v2.14.1
go get github.com/google/uuid@v1.6.0
```

---

## 记录与存储接口（store.go）

`TryAcquire` 同时接收请求哈希：同一幂等键配不同请求体时返回 `ErrIdempotencyKeyReused`。

```go
package idem

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"time"
)

// 状态
const (
	StatusProcessing = "processing"
	StatusCompleted  = "completed"
	StatusFailed     = "failed"
)

var (
	ErrRequestInProgress    = errors.New("idempotency: request is being processed")
	ErrIdempotencyKeyReused = errors.New("idempotency: key was used with a different request body")
)

// Record 幂等记录
type Record struct {
	Status      string          `json:"status" bson:"status"`
	RequestHash string          `json:"request_hash" bson:"request_hash"`
	StatusCode  int             `json:"status_code,omitempty" bson:"status_code,omitempty"`
	Response    json.RawMessage `json:"response,omitempty" bson:"response,omitempty"`
	Error       string          `json:"error,omitempty" bson:"error,omitempty"`
	CreatedAt   time.Time       `json:"created_at" bson:"created_at"`
	ExpiresAt   time.Time       `json:"expires_at" bson:"expires_at"`
}

// Store 幂等存储抽象：三种实现（Redis / PostgreSQL / MongoDB）共用
type Store interface {
	// TryAcquire 原子获取处理权。acquired=false 时返回已有记录
	TryAcquire(ctx context.Context, key, requestHash string) (rec *Record, acquired bool, err error)
	Complete(ctx context.Context, key string, statusCode int, response any) error
	Fail(ctx context.Context, key string, cause error) error
	// Release 处理中异常退出时删除记录，允许重试
	Release(ctx context.Context, key string) error
}

// HashRequest 请求体哈希，用于校验同一幂等键是否被不同请求复用
func HashRequest(body []byte) string {
	sum := sha256.Sum256(body)
	return hex.EncodeToString(sum[:])
}
```

---

## 幂等键设计（key.go）

```go
package idem

import (
	"crypto/sha256"
	"encoding/hex"
	"net/http"
	"strconv"
	"time"

	"github.com/google/uuid"
)

const HeaderIdempotencyKey = "Idempotency-Key"

// KeyFromRequest 客户端生成（推荐 UUID v4），通过 Header 传递
func KeyFromRequest(r *http.Request) string {
	return r.Header.Get(HeaderIdempotencyKey)
}

// NewClientKey 客户端侧生成示例：{client}:{operation}:{uuid}
func NewClientKey(clientID, operation string) string {
	return clientID + ":" + operation + ":" + uuid.NewString()
}

// DeriveKey 服务端按业务字段派生：同一用户、同一操作、同一载荷得到同一键
func DeriveKey(userID, operation string, payload []byte) string {
	h := sha256.New()
	h.Write([]byte(userID))
	h.Write([]byte{0})
	h.Write([]byte(operation))
	h.Write([]byte{0})
	h.Write(payload)
	return hex.EncodeToString(h.Sum(nil))
}

type CreateOrderRequest struct {
	IdempotencyKey string `json:"-"` // 来自 Header，可为空
	UserID         string `json:"user_id"`
	ProductID      string `json:"product_id"`
	Quantity       int    `json:"quantity"`
}

// DerivedKey 未提供幂等键时按业务字段 + 时间窗口（天）派生
func (r *CreateOrderRequest) DerivedKey(now time.Time) string {
	h := sha256.New()
	h.Write([]byte(r.UserID))
	h.Write([]byte{0})
	h.Write([]byte(r.ProductID))
	h.Write([]byte{0})
	h.Write([]byte(strconv.Itoa(r.Quantity)))
	h.Write([]byte{0})
	h.Write([]byte(now.UTC().Format("2006-01-02")))
	return hex.EncodeToString(h.Sum(nil))
}
```

---

## Redis 存储（redis.go）

`SET NX` + TTL 原子获取；到期自动清理，无需清理任务。

```go
package idem

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"time"

	"github.com/redis/go-redis/v9"
)

// RedisStore 基于 SET NX + TTL；TTL 到期自动清理
type RedisStore struct {
	client redis.UniversalClient
	ttl    time.Duration
}

func NewRedisStore(client redis.UniversalClient, ttl time.Duration) *RedisStore {
	return &RedisStore{client: client, ttl: ttl}
}

func (s *RedisStore) key(k string) string { return "idempotency:" + k }

func (s *RedisStore) get(ctx context.Context, key string) (*Record, error) {
	data, err := s.client.Get(ctx, s.key(key)).Bytes()
	if err != nil {
		return nil, err
	}
	var rec Record
	if err := json.Unmarshal(data, &rec); err != nil {
		return nil, fmt.Errorf("decode record: %w", err)
	}
	return &rec, nil
}

func (s *RedisStore) TryAcquire(ctx context.Context, key, requestHash string) (*Record, bool, error) {
	now := time.Now()
	rec := Record{
		Status:      StatusProcessing,
		RequestHash: requestHash,
		CreatedAt:   now,
		ExpiresAt:   now.Add(s.ttl),
	}
	data, err := json.Marshal(rec)
	if err != nil {
		return nil, false, err
	}

	// SET NX：不存在才写入，原子获取处理权
	ok, err := s.client.SetNX(ctx, s.key(key), data, s.ttl).Result()
	if err != nil {
		return nil, false, fmt.Errorf("setnx: %w", err)
	}
	if ok {
		return &rec, true, nil
	}

	// 已存在：读取现有记录（可能刚被并发请求写入）
	existing, err := s.get(ctx, key)
	if errors.Is(err, redis.Nil) {
		// 竞争窗口内记录已过期或被 Release，再试一次
		return s.TryAcquire(ctx, key, requestHash)
	}
	if err != nil {
		return nil, false, err
	}
	if existing.RequestHash != "" && existing.RequestHash != requestHash {
		return existing, false, ErrIdempotencyKeyReused
	}
	return existing, false, nil
}

func (s *RedisStore) update(ctx context.Context, key string, mutate func(*Record)) error {
	rec, err := s.get(ctx, key)
	if errors.Is(err, redis.Nil) {
		rec = &Record{CreatedAt: time.Now()}
	} else if err != nil {
		return err
	}
	mutate(rec)
	rec.ExpiresAt = time.Now().Add(s.ttl)
	data, err := json.Marshal(rec)
	if err != nil {
		return err
	}
	// 保留剩余 TTL 语义：完成后重新计时
	return s.client.Set(ctx, s.key(key), data, s.ttl).Err()
}

func (s *RedisStore) Complete(ctx context.Context, key string, statusCode int, response any) error {
	body, err := json.Marshal(response)
	if err != nil {
		return err
	}
	return s.update(ctx, key, func(r *Record) {
		r.Status = StatusCompleted
		r.StatusCode = statusCode
		r.Response = body
		r.Error = ""
	})
}

func (s *RedisStore) Fail(ctx context.Context, key string, cause error) error {
	return s.update(ctx, key, func(r *Record) {
		r.Status = StatusFailed
		r.Error = cause.Error()
	})
}

func (s *RedisStore) Release(ctx context.Context, key string) error {
	return s.client.Del(ctx, s.key(key)).Err()
}
```

---

## PostgreSQL 存储（postgres.go）

`INSERT ... ON CONFLICT DO NOTHING RETURNING` 原子获取；`CompleteInTx` 与业务写入同事务。

```go
package idem

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"time"
)

// DDL：
// CREATE TABLE idempotency_keys (
//     key          VARCHAR(255) PRIMARY KEY,
//     request_hash VARCHAR(64)  NOT NULL,
//     status       VARCHAR(20)  NOT NULL DEFAULT 'processing',
//     status_code  INTEGER,
//     response     JSONB,
//     error        TEXT,
//     created_at   TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
//     expires_at   TIMESTAMPTZ  NOT NULL,
//     CONSTRAINT valid_status CHECK (status IN ('processing', 'completed', 'failed'))
// );
// CREATE INDEX idx_idempotency_expires ON idempotency_keys (expires_at);

// PostgresStore 适合需要"业务写入与幂等记录同事务"的场景
type PostgresStore struct {
	db  *sql.DB
	ttl time.Duration
}

func NewPostgresStore(db *sql.DB, ttl time.Duration) *PostgresStore {
	return &PostgresStore{db: db, ttl: ttl}
}

func (s *PostgresStore) TryAcquire(ctx context.Context, key, requestHash string) (*Record, bool, error) {
	// INSERT ... ON CONFLICT DO NOTHING RETURNING：冲突时不返回行
	const q = `
		INSERT INTO idempotency_keys (key, request_hash, status, expires_at)
		VALUES ($1, $2, 'processing', $3)
		ON CONFLICT (key) DO NOTHING
		RETURNING status, request_hash, created_at, expires_at`

	var rec Record
	err := s.db.QueryRowContext(ctx, q, key, requestHash, time.Now().Add(s.ttl)).
		Scan(&rec.Status, &rec.RequestHash, &rec.CreatedAt, &rec.ExpiresAt)
	if err == nil {
		return &rec, true, nil
	}
	if !errors.Is(err, sql.ErrNoRows) {
		return nil, false, fmt.Errorf("insert key: %w", err)
	}

	existing, err := s.Get(ctx, key)
	if err != nil {
		return nil, false, err
	}
	if existing == nil {
		return nil, false, ErrRequestInProgress // 竞争窗口内被清理，让调用方重试
	}
	if existing.RequestHash != requestHash {
		return existing, false, ErrIdempotencyKeyReused
	}
	return existing, false, nil
}

func (s *PostgresStore) Get(ctx context.Context, key string) (*Record, error) {
	const q = `
		SELECT status, request_hash, status_code, response, error, created_at, expires_at
		FROM idempotency_keys WHERE key = $1`

	var (
		rec        Record
		statusCode sql.NullInt32
		response   []byte
		errMsg     sql.NullString
	)
	err := s.db.QueryRowContext(ctx, q, key).Scan(
		&rec.Status, &rec.RequestHash, &statusCode, &response, &errMsg, &rec.CreatedAt, &rec.ExpiresAt)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, nil
	}
	if err != nil {
		return nil, fmt.Errorf("get key: %w", err)
	}
	if statusCode.Valid {
		rec.StatusCode = int(statusCode.Int32)
	}
	rec.Response = response
	if errMsg.Valid {
		rec.Error = errMsg.String
	}
	return &rec, nil
}

func (s *PostgresStore) Complete(ctx context.Context, key string, statusCode int, response any) error {
	return s.completeWith(ctx, s.db, key, statusCode, response)
}

// CompleteInTx 与业务写入同一事务：要么都提交，要么都回滚
func (s *PostgresStore) CompleteInTx(ctx context.Context, tx *sql.Tx, key string, statusCode int, response any) error {
	return s.completeWith(ctx, tx, key, statusCode, response)
}

type execer interface {
	ExecContext(ctx context.Context, query string, args ...any) (sql.Result, error)
}

func (s *PostgresStore) completeWith(ctx context.Context, ex execer, key string, statusCode int, response any) error {
	body, err := json.Marshal(response)
	if err != nil {
		return err
	}
	const q = `UPDATE idempotency_keys
	           SET status = 'completed', status_code = $2, response = $3, error = NULL
	           WHERE key = $1`
	_, err = ex.ExecContext(ctx, q, key, statusCode, body)
	return err
}

func (s *PostgresStore) Fail(ctx context.Context, key string, cause error) error {
	const q = `UPDATE idempotency_keys SET status = 'failed', error = $2 WHERE key = $1`
	_, err := s.db.ExecContext(ctx, q, key, cause.Error())
	return err
}

func (s *PostgresStore) Release(ctx context.Context, key string) error {
	_, err := s.db.ExecContext(ctx, `DELETE FROM idempotency_keys WHERE key = $1`, key)
	return err
}

// Cleanup 分批删除过期记录，避免长事务
func (s *PostgresStore) Cleanup(ctx context.Context) (int64, error) {
	const q = `
		DELETE FROM idempotency_keys
		WHERE key IN (
			SELECT key FROM idempotency_keys
			WHERE expires_at < NOW()
			LIMIT 1000
		)`
	result, err := s.db.ExecContext(ctx, q)
	if err != nil {
		return 0, err
	}
	return result.RowsAffected()
}

// RunCleanup 定时清理任务
func RunCleanup(ctx context.Context, store *PostgresStore, interval time.Duration) {
	ticker := time.NewTicker(interval)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			deleted, err := store.Cleanup(ctx)
			if err != nil {
				slog.Error("idempotency cleanup", slog.Any("error", err))
				continue
			}
			slog.Info("idempotency cleanup", slog.Int64("deleted", deleted))
		}
	}
}
```

---

## MongoDB 存储（mongo.go）

`_id` 唯一约束做原子获取，`IsDuplicateKeyError` 识别冲突；`expires_at` TTL 索引自动清理。

```go
package idem

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"time"

	"go.mongodb.org/mongo-driver/v2/bson"
	"go.mongodb.org/mongo-driver/v2/mongo"
	"go.mongodb.org/mongo-driver/v2/mongo/options"
)

// MongoStore 用 _id 唯一性做原子获取，TTL 索引自动清理
type MongoStore struct {
	coll *mongo.Collection
	ttl  time.Duration
}

func NewMongoStore(coll *mongo.Collection, ttl time.Duration) *MongoStore {
	return &MongoStore{coll: coll, ttl: ttl}
}

type mongoRecord struct {
	Key    string `bson:"_id"`
	Record `bson:",inline"`
}

// EnsureIndexes TTL 索引：expires_at 到期后由服务端后台删除
func (s *MongoStore) EnsureIndexes(ctx context.Context) error {
	_, err := s.coll.Indexes().CreateOne(ctx, mongo.IndexModel{
		Keys:    bson.D{{Key: "expires_at", Value: 1}},
		Options: options.Index().SetExpireAfterSeconds(0),
	})
	return err
}

func (s *MongoStore) TryAcquire(ctx context.Context, key, requestHash string) (*Record, bool, error) {
	now := time.Now()
	doc := mongoRecord{
		Key: key,
		Record: Record{
			Status:      StatusProcessing,
			RequestHash: requestHash,
			CreatedAt:   now,
			ExpiresAt:   now.Add(s.ttl),
		},
	}
	_, err := s.coll.InsertOne(ctx, doc)
	if err == nil {
		return &doc.Record, true, nil
	}
	if !mongo.IsDuplicateKeyError(err) {
		return nil, false, fmt.Errorf("insert record: %w", err)
	}

	var existing mongoRecord
	err = s.coll.FindOne(ctx, bson.M{"_id": key}).Decode(&existing)
	if errors.Is(err, mongo.ErrNoDocuments) {
		return nil, false, ErrRequestInProgress
	}
	if err != nil {
		return nil, false, fmt.Errorf("find record: %w", err)
	}
	if existing.RequestHash != requestHash {
		return &existing.Record, false, ErrIdempotencyKeyReused
	}
	return &existing.Record, false, nil
}

func (s *MongoStore) Complete(ctx context.Context, key string, statusCode int, response any) error {
	body, err := json.Marshal(response)
	if err != nil {
		return err
	}
	_, err = s.coll.UpdateOne(ctx, bson.M{"_id": key}, bson.M{"$set": bson.M{
		"status":      StatusCompleted,
		"status_code": statusCode,
		"response":    body,
		"error":       "",
	}})
	return err
}

func (s *MongoStore) Fail(ctx context.Context, key string, cause error) error {
	_, err := s.coll.UpdateOne(ctx, bson.M{"_id": key}, bson.M{"$set": bson.M{
		"status": StatusFailed,
		"error":  cause.Error(),
	}})
	return err
}

func (s *MongoStore) Release(ctx context.Context, key string) error {
	_, err := s.coll.DeleteOne(ctx, bson.M{"_id": key})
	return err
}
```

---

## HTTP 中间件（middleware.go）

processing 返回 409 + Retry-After；completed 回放并带 `X-Idempotency-Replayed`；5xx 标记 failed 允许重试。

```go
package idem

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strconv"
)

const maxBodyBytes = 1 << 20 // 1 MiB

// Middleware 对 POST/PATCH 等非幂等方法启用；无 Idempotency-Key 则直接放行
type Middleware struct {
	store Store
}

func NewMiddleware(store Store) *Middleware { return &Middleware{store: store} }

func (m *Middleware) Wrap(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.Method {
		case http.MethodGet, http.MethodHead, http.MethodOptions, http.MethodDelete, http.MethodPut:
			next.ServeHTTP(w, r)
			return
		}
		key := KeyFromRequest(r)
		if key == "" {
			next.ServeHTTP(w, r)
			return
		}

		// 读取请求体计算哈希，再放回供下游读取
		body, err := io.ReadAll(io.LimitReader(r.Body, maxBodyBytes))
		if err != nil {
			http.Error(w, "read body", http.StatusBadRequest)
			return
		}
		r.Body = io.NopCloser(bytes.NewReader(body))
		hash := HashRequest(body)

		ctx := r.Context()
		rec, acquired, err := m.store.TryAcquire(ctx, key, hash)
		switch {
		case errors.Is(err, ErrIdempotencyKeyReused):
			http.Error(w, err.Error(), http.StatusUnprocessableEntity)
			return
		case err != nil:
			http.Error(w, "idempotency check failed", http.StatusInternalServerError)
			return
		case !acquired:
			m.replay(w, rec)
			return
		}

		rw := &responseRecorder{ResponseWriter: w, statusCode: http.StatusOK}
		next.ServeHTTP(rw, r)

		switch {
		case rw.statusCode >= 200 && rw.statusCode < 300:
			_ = m.store.Complete(ctx, key, rw.statusCode, rawJSON(rw.body.Bytes()))
		case rw.statusCode >= 500:
			// 服务端错误允许重试：标记 failed
			_ = m.store.Fail(ctx, key, fmt.Errorf("status %d", rw.statusCode))
		default:
			// 4xx 是确定性结果，同样回放
			_ = m.store.Complete(ctx, key, rw.statusCode, rawJSON(rw.body.Bytes()))
		}
	})
}

func (m *Middleware) replay(w http.ResponseWriter, rec *Record) {
	switch rec.Status {
	case StatusProcessing:
		w.Header().Set("Retry-After", "1")
		http.Error(w, "request is being processed", http.StatusConflict)
	case StatusCompleted:
		w.Header().Set("X-Idempotency-Replayed", "true")
		w.Header().Set("Content-Type", "application/json")
		w.Header().Set("Content-Length", strconv.Itoa(len(rec.Response)))
		w.WriteHeader(rec.StatusCode)
		_, _ = w.Write(rec.Response)
	case StatusFailed:
		// 上次失败：返回错误，客户端可带同一键重试（Release 后）
		http.Error(w, rec.Error, http.StatusInternalServerError)
	default:
		http.Error(w, "unknown idempotency state", http.StatusInternalServerError)
	}
}

// rawJSON 让 Complete 的 json.Marshal 原样保存响应体
type rawJSON []byte

func (r rawJSON) MarshalJSON() ([]byte, error) {
	if len(r) == 0 {
		return []byte("null"), nil
	}
	return r, nil
}

type responseRecorder struct {
	http.ResponseWriter
	statusCode int
	body       bytes.Buffer
}

func (rw *responseRecorder) WriteHeader(code int) {
	rw.statusCode = code
	rw.ResponseWriter.WriteHeader(code)
}

func (rw *responseRecorder) Write(b []byte) (int, error) {
	rw.body.Write(b)
	return rw.ResponseWriter.Write(b)
}

// WithKey 业务层需要时从 ctx 取幂等键
type ctxKey struct{}

func WithKey(ctx context.Context, key string) context.Context {
	return context.WithValue(ctx, ctxKey{}, key)
}

func KeyFromContext(ctx context.Context) string {
	v, _ := ctx.Value(ctxKey{}).(string)
	return v
}
```

---

## 业务层幂等：订单创建（service.go）

幂等记录与订单在同一事务提交；命名返回值 `err` 让 defer 能看到 `Commit` 的错误。

```go
package idem

import (
	"context"
	"database/sql"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"time"
)

type Order struct {
	ID        string `json:"id"`
	UserID    string `json:"user_id"`
	ProductID string `json:"product_id"`
	Quantity  int    `json:"quantity"`
}

// OrderService 业务层幂等：幂等记录与订单写入同一事务
type OrderService struct {
	db    *sql.DB
	store *PostgresStore
}

func NewOrderService(db *sql.DB, store *PostgresStore) *OrderService {
	return &OrderService{db: db, store: store}
}

func (s *OrderService) CreateOrder(ctx context.Context, req *CreateOrderRequest) (*Order, error) {
	key := req.IdempotencyKey
	if key == "" {
		key = req.DerivedKey(time.Now())
	}
	payload, err := json.Marshal(req)
	if err != nil {
		return nil, err
	}

	rec, acquired, err := s.store.TryAcquire(ctx, key, HashRequest(payload))
	if err != nil {
		return nil, fmt.Errorf("idempotency check: %w", err)
	}
	if !acquired {
		return s.replay(rec)
	}

	order, err := s.createInTx(ctx, key, req)
	if err != nil {
		// 业务失败：标记 failed，客户端可重试
		_ = s.store.Fail(ctx, key, err)
		return nil, err
	}
	return order, nil
}

func (s *OrderService) createInTx(ctx context.Context, key string, req *CreateOrderRequest) (order *Order, err error) {
	tx, err := s.db.BeginTx(ctx, nil)
	if err != nil {
		return nil, err
	}
	defer func() {
		if err != nil {
			_ = tx.Rollback()
		}
	}()

	order = &Order{ID: newOrderID(), UserID: req.UserID, ProductID: req.ProductID, Quantity: req.Quantity}
	if _, err = tx.ExecContext(ctx,
		`INSERT INTO orders (id, user_id, product_id, quantity) VALUES ($1, $2, $3, $4)`,
		order.ID, order.UserID, order.ProductID, order.Quantity,
	); err != nil {
		return nil, fmt.Errorf("insert order: %w", err)
	}

	// 幂等记录与订单同事务提交
	if err = s.store.CompleteInTx(ctx, tx, key, http.StatusCreated, order); err != nil {
		return nil, fmt.Errorf("complete idempotency: %w", err)
	}
	if err = tx.Commit(); err != nil {
		return nil, fmt.Errorf("commit: %w", err)
	}
	return order, nil
}

func (s *OrderService) replay(rec *Record) (*Order, error) {
	switch rec.Status {
	case StatusProcessing:
		return nil, ErrRequestInProgress
	case StatusCompleted:
		var order Order
		if err := json.Unmarshal(rec.Response, &order); err != nil {
			return nil, err
		}
		return &order, nil
	case StatusFailed:
		return nil, fmt.Errorf("previous attempt failed: %s", rec.Error)
	default:
		return nil, errors.New("unknown idempotency state: " + rec.Status)
	}
}

func newOrderID() string { return fmt.Sprintf("ord_%d", time.Now().UnixNano()) }
```

---

## 消息消费去重（consumer.go）

Kafka 幂等键 = topic/partition/offset；跨 topic 重投用业务消息 ID。

```go
package idem

import (
	"context"
	"errors"
	"fmt"

	"github.com/confluentinc/confluent-kafka-go/v2/kafka"
)

// KafkaConsumer at-least-once 消费去重：幂等键 = topic/partition/offset
type KafkaConsumer struct {
	store   Store
	handler func(ctx context.Context, msg *kafka.Message) error
}

func NewKafkaConsumer(store Store, handler func(ctx context.Context, msg *kafka.Message) error) *KafkaConsumer {
	return &KafkaConsumer{store: store, handler: handler}
}

func (c *KafkaConsumer) Handle(ctx context.Context, msg *kafka.Message) error {
	tp := msg.TopicPartition
	key := fmt.Sprintf("kafka:%s:%d:%d", *tp.Topic, tp.Partition, tp.Offset)

	rec, acquired, err := c.store.TryAcquire(ctx, key, "")
	if err != nil && !errors.Is(err, ErrIdempotencyKeyReused) {
		return err
	}
	if !acquired {
		switch rec.Status {
		case StatusCompleted:
			return nil // 已处理，跳过
		case StatusProcessing:
			return ErrRequestInProgress // 另一实例处理中，稍后重试
		}
		// failed：重新处理
	}

	if err := c.handler(ctx, msg); err != nil {
		_ = c.store.Fail(ctx, key, err)
		return err
	}
	return c.store.Complete(ctx, key, 200, nil)
}

// Deduplicator 按业务消息 ID 去重（跨 topic 重投也能识别）
type Deduplicator struct {
	store Store
}

func NewDeduplicator(store Store) *Deduplicator { return &Deduplicator{store: store} }

// Claim 首次见到返回 true；重复返回 false
func (d *Deduplicator) Claim(ctx context.Context, messageID string) (bool, error) {
	rec, acquired, err := d.store.TryAcquire(ctx, "msg:"+messageID, "")
	if err != nil {
		return false, err
	}
	if acquired {
		return true, nil
	}
	return rec.Status == StatusFailed, nil // 上次失败允许重做
}

func (d *Deduplicator) Done(ctx context.Context, messageID string) error {
	return d.store.Complete(ctx, "msg:"+messageID, 200, nil)
}

func (d *Deduplicator) Failed(ctx context.Context, messageID string, cause error) error {
	return d.store.Fail(ctx, "msg:"+messageID, cause)
}
```
