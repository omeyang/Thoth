---
name: idempotency-go
description: "Go 幂等性处理专家 - 幂等键设计、状态追踪、去重策略、分布式幂等、清理策略。适用：支付扣款操作、订单创建、消息消费去重（Kafka/Pulsar at-least-once）、Webhook 回调去重、Saga 补偿操作。不适用：天然幂等操作（GET/PUT/DELETE）、高频读取接口（查询类无需幂等检查）、无状态纯函数计算。触发词：idempotent, idempotency, dedup, deduplication, retry, Idempotency-Key, 幂等, 去重, 重试, 防重复"
user-invocable: true
allowed-tools: Bash, Read, Write, Edit, Grep, Glob
---

# Go 幂等性处理专家

使用 Go 实现幂等性处理：$ARGUMENTS

---

## 1. 幂等性基础

### 天然幂等 vs 需要保护

| 操作 | 天然幂等 | 说明 |
|------|---------|------|
| GET /users/123 | Y | 读取操作 |
| PUT /users/123 | Y | 全量替换 |
| DELETE /users/123 | Y | 删除操作 |
| POST /orders | N | 需要幂等保护 |
| POST /payments | N | 需要幂等保护 |
| PATCH /users/123 | N | 增量更新可能不幂等 |

---

## 2. 幂等键设计

- **客户端生成**：HTTP Header `Idempotency-Key`，推荐 UUID v4 或 ULID
- **服务端生成**：`GenerateIdempotencyKey(userID, operation, payload)` - 基于业务字段 SHA256 哈希
- **业务字段生成**：`IdempotencyKey()` 方法，含时间窗口（如每天可重复）

---

## 3. 存储策略

### Redis 存储（推荐用于简单场景）

- `IdempotencyRecord{Status, Response, StatusCode, Error, CreatedAt, ExpiresAt}`
- `TryAcquire(ctx, key)` - SET NX 原子获取处理权，返回 (record, acquired, error)
- `Complete(ctx, key, statusCode, response)` - 标记完成
- `Fail(ctx, key, err)` - 标记失败
- `Release(ctx, key)` - 释放处理权（异常情况）

### PostgreSQL 存储（推荐用于事务场景）

- DDL：`idempotency_keys` 表，`INSERT ON CONFLICT DO NOTHING` 实现原子获取
- `CompleteInTx(ctx, tx, key, statusCode, response)` - 在同一事务中完成

---

## 4. 中间件实现

- `IdempotencyMiddleware.Wrap(next)` - HTTP 中间件
- 仅对非幂等方法（POST/PATCH）启用
- 无 Idempotency-Key 则正常处理
- processing 状态返回 409 Conflict + Retry-After
- completed 状态返回缓存响应 + `X-Idempotency-Replayed: true`
- failed 状态返回错误，允许重试
- `responseWriter` 捕获状态码和响应体

---

## 5. 业务层幂等

### 订单创建流程

1. 获取/生成幂等键
2. `TryAcquire` 获取处理权
3. 未获取 -> `handleExistingOrder`（按 status 返回）
4. 获取 -> 开启事务 -> 创建订单 -> `CompleteInTx`（同事务）-> Commit
5. 失败 -> Rollback + `Fail`

---

## 6. 消息幂等

- **Kafka 消费者**：幂等键 = `kafka:{topic}:{partition}:{offset}`
- **业务 ID 去重**：`MessageDeduplicator.IsDuplicate(ctx, messageID)` + `MarkProcessed`

---

## 7. 清理策略

- **PostgreSQL**：定时删除过期记录（`WHERE expires_at < NOW() LIMIT 1000`），`StartCleanupJob` 启动定时任务
- **Redis**：TTL 自动过期，无需额外清理

---

## 8. 请求验证

- `TryAcquireWithValidation(ctx, key, requestBody)` - SHA256 哈希验证请求内容一致性
- 相同幂等键不同请求体 -> `ErrIdempotencyKeyReused`

---

## 最佳实践

### 幂等键
- 客户端生成推荐 UUID v4
- 服务端生成基于业务字段哈希
- 包含时间窗口（如每天）

### 存储选择
- 简单场景用 Redis + TTL
- 事务场景用 PostgreSQL
- 高并发用分布式锁 + 缓存

### 状态管理
- 三态：processing/completed/failed
- processing 返回 409 Conflict
- failed 允许重试

### TTL 设置
- 支付类：24-48 小时
- 订单类：1-24 小时
- 消息类：根据重试窗口

---

## 检查清单

- [ ] 非幂等操作有保护？
- [ ] 幂等键唯一且稳定？
- [ ] 请求哈希验证？
- [ ] 并发竞争处理？
- [ ] 合理的 TTL？
- [ ] 定期清理？
- [ ] processing 状态处理？
- [ ] 事务与幂等结合？

## 参考资料

- [完整代码实现](references/examples.md) - Redis/PostgreSQL 存储、HTTP 中间件、业务层幂等、消息去重的完整 Go 实现
