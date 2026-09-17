---
name: idempotency-go
description: "Go 幂等性处理专家 - 幂等键设计、状态追踪(processing/completed/failed)、请求哈希校验、Redis/PostgreSQL/MongoDB 三种存储、HTTP 中间件、事务内幂等、消息消费去重、清理策略。适用：支付扣款操作、订单创建、消息消费去重（Kafka/Pulsar at-least-once）、Webhook 回调去重、Saga 补偿操作。不适用：天然幂等操作（GET/PUT/DELETE）、高频读取接口（查询类无需幂等检查）、无状态纯函数计算。触发词：idempotent, idempotency, dedup, deduplication, retry, Idempotency-Key, 幂等, 去重, 重试, 防重复"
---

# Go 幂等性处理专家

使用 Go 实现幂等性处理：$ARGUMENTS

基线：go1.24.6。存储实现依赖 go-redis/v9 v9.22.0、mongo-driver/v2 v2.8.2、`database/sql`；消息示例依赖 confluent-kafka-go/v2 v2.14.1。完整可编译代码见 [references/examples.md](references/examples.md)。

---

## 1. 哪些操作需要保护

| 操作 | 天然幂等 | 说明 |
|------|---------|------|
| GET / HEAD | 是 | 读取 |
| PUT /users/123 | 是 | 全量替换 |
| DELETE /users/123 | 是 | 重复删除结果相同（响应码可能不同） |
| POST /orders | 否 | 重复创建 |
| POST /payments | 否 | 重复扣款 |
| PATCH（增量、`$inc`） | 否 | 重复累加 |
| 消息消费（at-least-once） | 否 | 重投导致重复处理 |

判断标准：重复执行是否改变最终状态或产生副作用（扣款、发消息、调第三方）。

---

## 2. 幂等键设计

| 来源 | 形式 | 适用 |
|------|------|------|
| 客户端生成 | Header `Idempotency-Key: <uuid v4>` | 公开 API，客户端重试 |
| 服务端派生 | `sha256(userID \| operation \| payload)` | 客户端不可控，按业务语义去重 |
| 业务字段 + 时间窗口 | `sha256(user \| product \| qty \| day)` | 同一天同一订单只允许一次 |
| 消息位置 | `kafka:{topic}:{partition}:{offset}` | 消费去重 |
| 业务消息 ID | `msg:{message_id}` | 跨 topic 重投也能识别 |

```go
func DeriveKey(userID, operation string, payload []byte) string {
    h := sha256.New()
    h.Write([]byte(userID))
    h.Write([]byte{0}) // 分隔符，避免字段拼接歧义
    h.Write([]byte(operation))
    h.Write([]byte{0})
    h.Write(payload)
    return hex.EncodeToString(h.Sum(nil))
}
```

幂等键要带作用域前缀（用户、租户），防止不同主体的键碰撞。

---

## 3. 记录与状态机

```go
const (
    StatusProcessing = "processing"
    StatusCompleted  = "completed"
    StatusFailed     = "failed"
)

type Record struct {
    Status      string
    RequestHash string          // 校验同键不同体
    StatusCode  int
    Response    json.RawMessage // 回放用
    Error       string
    CreatedAt   time.Time
    ExpiresAt   time.Time
}

type Store interface {
    TryAcquire(ctx context.Context, key, requestHash string) (rec *Record, acquired bool, err error)
    Complete(ctx context.Context, key string, statusCode int, response any) error
    Fail(ctx context.Context, key string, cause error) error
    Release(ctx context.Context, key string) error // 处理中异常退出时删除，允许重试
}
```

| 当前状态 | 再次到达同键 | 处理 |
|----------|------------|------|
| 无记录 | 首次 | 原子写入 processing，执行业务 |
| processing | 并发或重试过早 | 409 Conflict + `Retry-After`，不执行 |
| completed | 重放 | 直接返回保存的响应，加 `X-Idempotency-Replayed: true` |
| failed | 上次失败 | 返回错误，或 `Release` 后允许重新执行 |
| 任意 | 请求体哈希不同 | `ErrIdempotencyKeyReused`，422 |

---

## 4. 存储选择

| 存储 | 原子获取 | 清理 | 适用 |
|------|---------|------|------|
| Redis | `SET NX` + TTL | TTL 自动 | 高并发、无事务需求 |
| PostgreSQL | `INSERT ... ON CONFLICT DO NOTHING RETURNING` | 定时分批 DELETE | 幂等记录要与业务写入同事务 |
| MongoDB | `_id` 唯一 + `IsDuplicateKeyError` | `expires_at` TTL 索引 | 主存储是 Mongo |

### Redis

```go
ok, err := s.client.SetNX(ctx, s.key(key), data, s.ttl).Result()
if ok {
    return &rec, true, nil
}
existing, err := s.get(ctx, key) // 已存在：读回并校验 RequestHash
```

### PostgreSQL

```go
const q = `
    INSERT INTO idempotency_keys (key, request_hash, status, expires_at)
    VALUES ($1, $2, 'processing', $3)
    ON CONFLICT (key) DO NOTHING
    RETURNING status, request_hash, created_at, expires_at`
// 冲突时不返回行 -> sql.ErrNoRows -> 读现有记录
```

### MongoDB

```go
_, err := s.coll.InsertOne(ctx, doc)
if err == nil {
    return &doc.Record, true, nil
}
if !mongo.IsDuplicateKeyError(err) {
    return nil, false, err
}
// 冲突：FindOne 读现有记录
```

> 三种实现见 [references/examples.md](references/examples.md)

---

## 5. HTTP 中间件

```go
func (m *Middleware) Wrap(next http.Handler) http.Handler {
    return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
        switch r.Method {
        case http.MethodGet, http.MethodHead, http.MethodOptions, http.MethodDelete, http.MethodPut:
            next.ServeHTTP(w, r) // 天然幂等
            return
        }
        key := r.Header.Get("Idempotency-Key")
        if key == "" {
            next.ServeHTTP(w, r)
            return
        }

        body, _ := io.ReadAll(io.LimitReader(r.Body, maxBodyBytes))
        r.Body = io.NopCloser(bytes.NewReader(body)) // 放回给下游
        hash := HashRequest(body)

        rec, acquired, err := m.store.TryAcquire(r.Context(), key, hash)
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
        // 2xx/4xx 保存回放；5xx 标记 failed 允许重试
    })
}
```

- 响应捕获器记录状态码与 body；回放时带原状态码、`Content-Type` 和 `X-Idempotency-Replayed`
- 4xx 是确定性结果，同样回放；5xx 视为可重试

> 完整实现见 [references/examples.md#http-中间件middlewarego](references/examples.md#http-中间件middlewarego)

---

## 6. 业务层：幂等记录与业务写入同事务

```go
func (s *OrderService) CreateOrder(ctx context.Context, req *CreateOrderRequest) (*Order, error) {
    key := req.IdempotencyKey
    if key == "" {
        key = req.DerivedKey(time.Now())
    }
    payload, _ := json.Marshal(req)

    rec, acquired, err := s.store.TryAcquire(ctx, key, HashRequest(payload))
    if err != nil {
        return nil, fmt.Errorf("idempotency check: %w", err)
    }
    if !acquired {
        return s.replay(rec) // 按状态返回：processing 报错、completed 回放、failed 报错
    }

    order, err := s.createInTx(ctx, key, req) // 订单 INSERT + CompleteInTx 同一事务
    if err != nil {
        _ = s.store.Fail(ctx, key, err)
        return nil, err
    }
    return order, nil
}
```

- 用命名返回值 `err`，`defer` 里的 `Rollback` 才能看到 `Commit` 的错误
- Redis 存储没有事务：先提交业务，再 `Complete`；两步之间崩溃会留下 processing，靠 TTL 或 `Release` 恢复

> 完整实现见 [references/examples.md#业务层幂等订单创建servicego](references/examples.md#业务层幂等订单创建servicego)

---

## 7. 消息消费去重

```go
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
            return ErrRequestInProgress // 另一实例处理中
        }
        // failed：重新处理
    }
    if err := c.handler(ctx, msg); err != nil {
        _ = c.store.Fail(ctx, key, err)
        return err
    }
    return c.store.Complete(ctx, key, 200, nil)
}
```

- offset 键只在同一 topic 内有效；跨 topic 重投（DLQ 回灌）用业务消息 ID `msg:{id}`
- 业务处理本身能写成幂等 upsert 时（`ON CONFLICT DO UPDATE`、`$set`），可以不引入幂等表

> 完整实现见 [references/examples.md#消息消费去重consumergo](references/examples.md#消息消费去重consumergo)

---

## 8. TTL 与清理

| 场景 | TTL | 依据 |
|------|-----|------|
| 支付 | 24 到 48 小时 | 覆盖客户端最长重试与对账窗口 |
| 订单创建 | 1 到 24 小时 | 用户重复提交的时间范围 |
| 消息消费 | 大于消费者最大重试窗口 | 重投在 TTL 内才能被识别 |
| Webhook | 7 天 | 第三方重推周期 |

- Redis：`SET ... EX`，无需清理任务
- PostgreSQL：`DELETE ... WHERE key IN (SELECT key ... WHERE expires_at < NOW() LIMIT 1000)` 定时分批
- MongoDB：`expires_at` 上建 `expireAfterSeconds: 0` 的 TTL 索引

---

## 检查清单

- [ ] 非幂等操作（POST、PATCH、消费）都有保护？
- [ ] 幂等键带作用域前缀，唯一且稳定？
- [ ] `TryAcquire` 原子（SET NX / ON CONFLICT / 唯一索引）？
- [ ] 请求哈希校验，同键不同体返回 422？
- [ ] processing 返回 409 + Retry-After，completed 回放原响应？
- [ ] 事务场景幂等记录与业务写入同事务？
- [ ] 5xx 标记 failed 允许重试，4xx 回放？
- [ ] TTL 覆盖重试窗口，有清理策略？

---

## 参考资料

- [references/examples.md](references/examples.md) - 完整可编译代码（记录与接口、幂等键、Redis/PostgreSQL/MongoDB 存储、中间件、事务内幂等、消息去重）
- [IETF draft: The Idempotency-Key HTTP Header Field](https://datatracker.ietf.org/doc/draft-ietf-httpapi-idempotency-key-header/)
