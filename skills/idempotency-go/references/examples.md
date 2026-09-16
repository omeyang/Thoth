# Go 幂等性处理 - 完整代码实现

## 目录

- [幂等键设计](#幂等键设计)
  - [客户端生成](#客户端生成)
  - [服务端生成](#服务端生成)
- [Redis 存储](#redis-存储)
- [PostgreSQL 存储](#postgresql-存储)
- [HTTP 中间件](#http-中间件)
- [业务层幂等 - 订单创建](#业务层幂等---订单创建)
- [消息幂等](#消息幂等)
  - [Kafka 消费者幂等](#kafka-消费者幂等)
  - [业务 ID 去重](#业务-id-去重)
- [清理策略](#清理策略)
- [请求验证](#请求验证)

---

## 幂等键设计

### 客户端生成

```go
// HTTP Header 传递
const IdempotencyKeyHeader = "Idempotency-Key"

func GetIdempotencyKey(r *http.Request) string {
    return r.Header.Get(IdempotencyKeyHeader)
}

// 客户端生成规则
// 推荐：UUID v4 或 ULID
// 格式：{client_id}:{operation}:{unique_id}
// 示例：app-123:create-order:550e8400-e29b-41d4-a716-446655440000
```

### 服务端生成

```go
import (
    "crypto/sha256"
    "encoding/hex"
    "strconv"
)

// 基于请求内容生成
func GenerateIdempotencyKey(userID, operation string, payload []byte) string {
    h := sha256.New()
    h.Write([]byte(userID))
    h.Write([]byte(operation))
    h.Write(payload)
    return hex.EncodeToString(h.Sum(nil))
}

// 基于业务字段生成
type CreateOrderRequest struct {
    UserID    string `json:"user_id"`
    ProductID string `json:"product_id"`
    Quantity  int    `json:"quantity"`
}

func (r *CreateOrderRequest) IdempotencyKey() string {
    h := sha256.New()
    h.Write([]byte(r.UserID))
    h.Write([]byte(r.ProductID))
    h.Write([]byte(strconv.Itoa(r.Quantity)))
    h.Write([]byte(time.Now().Format("2006-01-02"))) // 每天可以重复
    return hex.EncodeToString(h.Sum(nil))
}
```

---

## Redis 存储

```go
import "errors"

type RedisIdempotencyStore struct {
    client *redis.Client
    ttl    time.Duration
}

type IdempotencyRecord struct {
    Status     string          `json:"status"` // processing, completed, failed
    Response   json.RawMessage `json:"response,omitempty"`
    StatusCode int             `json:"status_code,omitempty"`
    Error      string          `json:"error,omitempty"`
    CreatedAt  time.Time       `json:"created_at"`
    ExpiresAt  time.Time       `json:"expires_at"`
}

func NewRedisIdempotencyStore(client *redis.Client, ttl time.Duration) *RedisIdempotencyStore {
    return &RedisIdempotencyStore{client: client, ttl: ttl}
}

func (s *RedisIdempotencyStore) key(idempotencyKey string) string {
    return "idempotency:" + idempotencyKey
}

// TryAcquire 尝试获取处理权
func (s *RedisIdempotencyStore) TryAcquire(ctx context.Context, key string) (*IdempotencyRecord, bool, error) {
    redisKey := s.key(key)

    // 检查是否已存在
    data, err := s.client.Get(ctx, redisKey).Bytes()
    if err == nil {
        var record IdempotencyRecord
        if err := json.Unmarshal(data, &record); err != nil {
            return nil, false, err
        }
        return &record, false, nil // 已存在，未获取
    }

    if !errors.Is(err, redis.Nil) {
        return nil, false, err
    }

    // 尝试设置 processing 状态
    record := IdempotencyRecord{
        Status:    "processing",
        CreatedAt: time.Now(),
        ExpiresAt: time.Now().Add(s.ttl),
    }

    data, _ = json.Marshal(record) // json.Marshal of known struct types won't fail

    // SET NX - 只有不存在时才设置
    ok, err := s.client.SetNX(ctx, redisKey, data, s.ttl).Result()
    if err != nil {
        return nil, false, err
    }

    if !ok {
        // 并发竞争，重新获取
        return s.TryAcquire(ctx, key)
    }

    return &record, true, nil // 成功获取处理权
}

// Complete 标记完成
func (s *RedisIdempotencyStore) Complete(ctx context.Context, key string, statusCode int, response any) error {
    respData, err := json.Marshal(response)
    if err != nil {
        return err
    }

    record := IdempotencyRecord{
        Status:     "completed",
        Response:   respData,
        StatusCode: statusCode,
        CreatedAt:  time.Now(),
        ExpiresAt:  time.Now().Add(s.ttl),
    }

    data, _ := json.Marshal(record) // json.Marshal of known struct types won't fail
    return s.client.Set(ctx, s.key(key), data, s.ttl).Err()
}

// Fail 标记失败
func (s *RedisIdempotencyStore) Fail(ctx context.Context, key string, err error) error {
    record := IdempotencyRecord{
        Status:    "failed",
        Error:     err.Error(),
        CreatedAt: time.Now(),
        ExpiresAt: time.Now().Add(s.ttl),
    }

    data, _ := json.Marshal(record) // json.Marshal of known struct types won't fail
    return s.client.Set(ctx, s.key(key), data, s.ttl).Err()
}

// Release 释放处理权（用于异常情况）
func (s *RedisIdempotencyStore) Release(ctx context.Context, key string) error {
    return s.client.Del(ctx, s.key(key)).Err()
}
```

---

## PostgreSQL 存储

### DDL

```sql
CREATE TABLE idempotency_keys (
    key VARCHAR(255) PRIMARY KEY,
    request_hash VARCHAR(64) NOT NULL,
    status VARCHAR(20) NOT NULL DEFAULT 'processing',
    status_code INTEGER,
    response JSONB,
    error TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    expires_at TIMESTAMPTZ NOT NULL,

    CONSTRAINT valid_status CHECK (status IN ('processing', 'completed', 'failed'))
);

CREATE INDEX idx_idempotency_expires ON idempotency_keys (expires_at);
```

### Go 实现

```go
type PostgresIdempotencyStore struct {
    db  *sql.DB
    ttl time.Duration
}

func (s *PostgresIdempotencyStore) TryAcquire(ctx context.Context, key string, requestHash string) (*IdempotencyRecord, bool, error) {
    // 使用 INSERT ... ON CONFLICT DO NOTHING 实现原子操作
    query := `
        INSERT INTO idempotency_keys (key, request_hash, status, expires_at)
        VALUES ($1, $2, 'processing', $3)
        ON CONFLICT (key) DO NOTHING
        RETURNING status, created_at
    `

    var record IdempotencyRecord
    err := s.db.QueryRowContext(ctx, query, key, requestHash, time.Now().Add(s.ttl)).
        Scan(&record.Status, &record.CreatedAt)

    if err == sql.ErrNoRows {
        // 已存在，查询现有记录
        return s.Get(ctx, key)
    }

    if err != nil {
        return nil, false, err
    }

    return &record, true, nil
}

func (s *PostgresIdempotencyStore) Get(ctx context.Context, key string) (*IdempotencyRecord, bool, error) {
    query := `
        SELECT status, status_code, response, error, created_at, expires_at
        FROM idempotency_keys
        WHERE key = $1
    `

    var record IdempotencyRecord
    var statusCode sql.NullInt32
    var response []byte
    var errMsg sql.NullString

    err := s.db.QueryRowContext(ctx, query, key).
        Scan(&record.Status, &statusCode, &response, &errMsg, &record.CreatedAt, &record.ExpiresAt)

    if err == sql.ErrNoRows {
        return nil, false, nil
    }

    if err != nil {
        return nil, false, err
    }

    if statusCode.Valid {
        record.StatusCode = int(statusCode.Int32)
    }
    record.Response = response
    if errMsg.Valid {
        record.Error = errMsg.String
    }

    return &record, true, nil
}

// CompleteInTx 在事务中完成（推荐）
func (s *PostgresIdempotencyStore) CompleteInTx(ctx context.Context, tx *sql.Tx, key string, statusCode int, response any) error {
    respData, err := json.Marshal(response)
    if err != nil {
        return err
    }

    query := `
        UPDATE idempotency_keys
        SET status = 'completed', status_code = $2, response = $3
        WHERE key = $1
    `

    _, err = tx.ExecContext(ctx, query, key, statusCode, respData)
    return err
}
```

---

## HTTP 中间件

```go
type IdempotencyMiddleware struct {
    store IdempotencyStore
}

func NewIdempotencyMiddleware(store IdempotencyStore) *IdempotencyMiddleware {
    return &IdempotencyMiddleware{store: store}
}

func (m *IdempotencyMiddleware) Wrap(next http.Handler) http.Handler {
    return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
        // 只对非幂等方法启用
        if r.Method == http.MethodGet || r.Method == http.MethodHead || r.Method == http.MethodOptions {
            next.ServeHTTP(w, r)
            return
        }

        key := r.Header.Get(IdempotencyKeyHeader)
        if key == "" {
            // 没有幂等键，正常处理
            next.ServeHTTP(w, r)
            return
        }

        ctx := r.Context()

        // 尝试获取处理权
        record, acquired, err := m.store.TryAcquire(ctx, key)
        if err != nil {
            http.Error(w, "idempotency check failed", http.StatusInternalServerError)
            return
        }

        if !acquired {
            // 已有处理记录
            m.handleExisting(w, r, record)
            return
        }

        // 获得处理权，执行请求
        rw := &responseWriter{ResponseWriter: w, statusCode: http.StatusOK}
        next.ServeHTTP(rw, r)

        // 保存结果
        if rw.statusCode >= 200 && rw.statusCode < 300 {
            m.store.Complete(ctx, key, rw.statusCode, json.RawMessage(rw.body.Bytes()))
        } else if rw.statusCode >= 400 {
            m.store.Fail(ctx, key, fmt.Errorf("request failed with status %d", rw.statusCode))
        }
    })
}

func (m *IdempotencyMiddleware) handleExisting(w http.ResponseWriter, r *http.Request, record *IdempotencyRecord) {
    switch record.Status {
    case "processing":
        // 还在处理中
        w.Header().Set("Retry-After", "1")
        http.Error(w, "request is being processed", http.StatusConflict)

    case "completed":
        // 返回缓存的响应
        w.Header().Set("X-Idempotency-Replayed", "true")
        w.WriteHeader(record.StatusCode)
        w.Write(record.Response)

    case "failed":
        // 返回错误，允许重试
        http.Error(w, record.Error, http.StatusInternalServerError)
    }
}

// 响应捕获器
type responseWriter struct {
    http.ResponseWriter
    statusCode int
    body       bytes.Buffer
}

func (rw *responseWriter) WriteHeader(code int) {
    rw.statusCode = code
    rw.ResponseWriter.WriteHeader(code)
}

func (rw *responseWriter) Write(b []byte) (int, error) {
    rw.body.Write(b)
    return rw.ResponseWriter.Write(b)
}
```

---

## 业务层幂等 - 订单创建

```go
type OrderService struct {
    db    *sql.DB
    store IdempotencyStore
}

func (s *OrderService) CreateOrder(ctx context.Context, req *CreateOrderRequest) (*Order, error) {
    // 生成或获取幂等键
    idempotencyKey := req.IdempotencyKey
    if idempotencyKey == "" {
        idempotencyKey = req.GenerateIdempotencyKey()
    }

    // 尝试获取处理权
    record, acquired, err := s.store.TryAcquire(ctx, idempotencyKey)
    if err != nil {
        return nil, fmt.Errorf("idempotency check: %w", err)
    }

    if !acquired {
        return s.handleExistingOrder(ctx, record)
    }

    // 在事务中执行
    tx, err := s.db.BeginTx(ctx, nil)
    if err != nil {
        s.store.Release(ctx, idempotencyKey)
        return nil, err
    }

    defer func() {
        if err != nil {
            tx.Rollback()
            s.store.Fail(ctx, idempotencyKey, err)
        }
    }()

    // 创建订单
    order, err := s.createOrderInTx(ctx, tx, req)
    if err != nil {
        return nil, err
    }

    // 保存幂等结果（在同一事务中）
    if pgStore, ok := s.store.(*PostgresIdempotencyStore); ok {
        if err := pgStore.CompleteInTx(ctx, tx, idempotencyKey, 201, order); err != nil {
            return nil, err
        }
    }

    if err := tx.Commit(); err != nil {
        return nil, err
    }

    // 如果不是 PostgreSQL 存储，事务后保存
    if _, ok := s.store.(*PostgresIdempotencyStore); !ok {
        s.store.Complete(ctx, idempotencyKey, 201, order)
    }

    return order, nil
}

func (s *OrderService) handleExistingOrder(ctx context.Context, record *IdempotencyRecord) (*Order, error) {
    switch record.Status {
    case "processing":
        return nil, ErrRequestInProgress

    case "completed":
        var order Order
        if err := json.Unmarshal(record.Response, &order); err != nil {
            return nil, err
        }
        return &order, nil

    case "failed":
        return nil, fmt.Errorf("previous attempt failed: %s", record.Error)

    default:
        return nil, fmt.Errorf("unknown status: %s", record.Status)
    }
}
```

---

## 消息幂等

### Kafka 消费者幂等

```go
type IdempotentConsumer struct {
    store   IdempotencyStore
    handler func(context.Context, *kafka.Message) error
}

func (c *IdempotentConsumer) Handle(ctx context.Context, msg *kafka.Message) error {
    // 使用消息 ID 作为幂等键
    idempotencyKey := fmt.Sprintf("kafka:%s:%d:%d",
        *msg.TopicPartition.Topic,
        msg.TopicPartition.Partition,
        msg.TopicPartition.Offset,
    )

    record, acquired, err := c.store.TryAcquire(ctx, idempotencyKey)
    if err != nil {
        return err
    }

    if !acquired {
        if record.Status == "completed" {
            // 已处理，跳过
            return nil
        }
        if record.Status == "processing" {
            // 正在处理，等待
            return ErrRequestInProgress
        }
        // 失败了，重新处理
    }

    if err := c.handler(ctx, msg); err != nil {
        c.store.Fail(ctx, idempotencyKey, err)
        return err
    }

    c.store.Complete(ctx, idempotencyKey, 200, nil)
    return nil
}
```

### 业务 ID 去重

```go
type MessageDeduplicator struct {
    store IdempotencyStore
}

func (d *MessageDeduplicator) IsDuplicate(ctx context.Context, messageID string) (bool, error) {
    record, acquired, err := d.store.TryAcquire(ctx, "msg:"+messageID)
    if err != nil {
        return false, err
    }

    if !acquired && record.Status == "completed" {
        return true, nil
    }

    return false, nil
}

func (d *MessageDeduplicator) MarkProcessed(ctx context.Context, messageID string) error {
    return d.store.Complete(ctx, "msg:"+messageID, 200, nil)
}
```

---

## 清理策略

### 定时清理（PostgreSQL）

```go
func (s *PostgresIdempotencyStore) Cleanup(ctx context.Context) error {
    query := `
        DELETE FROM idempotency_keys
        WHERE expires_at < NOW()
        AND ctid IN (
            SELECT ctid FROM idempotency_keys
            WHERE expires_at < NOW()
            LIMIT 1000
        )
    `

    result, err := s.db.ExecContext(ctx, query)
    if err != nil {
        return err
    }

    deleted, _ := result.RowsAffected()
    slog.Info("cleaned up idempotency keys", slog.Int64("deleted", deleted))

    return nil
}

// 启动清理任务
func StartCleanupJob(ctx context.Context, store *PostgresIdempotencyStore, interval time.Duration) {
    ticker := time.NewTicker(interval)
    defer ticker.Stop()

    for {
        select {
        case <-ctx.Done():
            return
        case <-ticker.C:
            if err := store.Cleanup(ctx); err != nil {
                slog.Error("cleanup failed", slog.Any("error", err))
            }
        }
    }
}
```

### Redis 自动过期

Redis 使用 TTL 自动清理，无需额外清理任务。

```go
// 设置合理的 TTL
store := NewRedisIdempotencyStore(client, 24*time.Hour)
```

---

## 请求验证

### 防止请求篡改

```go
func (s *PostgresIdempotencyStore) TryAcquireWithValidation(ctx context.Context, key string, requestBody []byte) (*IdempotencyRecord, bool, error) {
    requestHash := sha256Hash(requestBody)

    record, acquired, err := s.TryAcquire(ctx, key, requestHash)
    if err != nil {
        return nil, false, err
    }

    if !acquired && record.Status == "completed" {
        // 验证请求内容是否一致
        storedHash, _ := s.getRequestHash(ctx, key)
        if storedHash != requestHash {
            return nil, false, ErrIdempotencyKeyReused
        }
    }

    return record, acquired, nil
}

func sha256Hash(data []byte) string {
    h := sha256.Sum256(data)
    return hex.EncodeToString(h[:])
}

func (s *PostgresIdempotencyStore) getRequestHash(ctx context.Context, key string) (string, error) {
    var hash string
    err := s.db.QueryRowContext(ctx, "SELECT request_hash FROM idempotency_keys WHERE key = $1", key).Scan(&hash)
    return hash, err
}

var ErrIdempotencyKeyReused = errors.New("idempotency key was used with different request body")
var ErrRequestInProgress = errors.New("request is being processed")
```
