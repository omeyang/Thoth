---
name: redis-go
description: "Go Redis 专家 - 使用 go-redis/v9 实现缓存模式(Cache-Aside/Singleflight/双层缓存)、分布式锁(SETNX/Lua/Redlock)、限流(令牌桶/滑动窗口)、Pipeline批量操作、Pub/Sub消息、数据结构(排行榜/布隆过滤器/HyperLogLog)、Lua脚本、集群/Sentinel连接。适用：缓存、会话存储、排行榜、实时计数、分布式锁、消息队列。不适用：持久化主存储(Redis非唯一数据源)、复杂关联查询(应使用关系型数据库)、强一致性事务(Redis事务不支持回滚)。触发词：redis, 缓存, cache, 分布式锁, distributed lock, 限流, 排行榜, leaderboard, pub/sub, lua脚本, pipeline, go-redis"
---

# Go Redis 专家

使用 go-redis 开发 Redis 功能：$ARGUMENTS

基线：go1.24.6，`github.com/redis/go-redis/v9 v9.22.0`，`github.com/go-redsync/redsync/v4 v4.15.0`，`github.com/go-redis/redis_rate/v10 v10.0.1`。完整可编译代码见 [references/examples.md](references/examples.md)。

---

## 1. 客户端管理

### 单机连接

```go
func NewRedisClient(addr, password string, db int) (*redis.Client, error) {
    client := redis.NewClient(&redis.Options{
        Addr:            addr,
        Password:        password,
        DB:              db,
        PoolSize:        100,
        MinIdleConns:    10,
        MaxIdleConns:    50,
        ConnMaxIdleTime: 5 * time.Minute,
        ConnMaxLifetime: 30 * time.Minute,
        DialTimeout:     5 * time.Second,
        ReadTimeout:     3 * time.Second,
        WriteTimeout:    3 * time.Second,
        PoolTimeout:     4 * time.Second,
        MaxRetries:      3,
        MinRetryBackoff: 8 * time.Millisecond,
        MaxRetryBackoff: 512 * time.Millisecond,
    })

    ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
    defer cancel()
    if err := client.Ping(ctx).Err(); err != nil {
        _ = client.Close()
        return nil, fmt.Errorf("ping redis: %w", err)
    }
    return client, nil
}
```

go-redis 9.22 的默认值：`DialTimeout` 5s、`ReadTimeout` 5s、`WriteTimeout` 跟随 `ReadTimeout`、`PoolTimeout` = `ReadTimeout` + 1s、`ConnMaxIdleTime` 30m、`MaxRetries` 3、退避 10ms 到 1s、`PoolSize` = 10 × GOMAXPROCS。上面显式写出的字段会覆盖默认值；要禁用某项超时或重试传 `-1`。

### 集群 / Sentinel

```go
cluster := redis.NewClusterClient(&redis.ClusterOptions{
    Addrs: addrs, Password: password, PoolSize: 100,
    RouteByLatency: true, // 读请求走延迟最低的节点
})

sentinel := redis.NewFailoverClient(&redis.FailoverOptions{
    MasterName: masterName, SentinelAddrs: sentinelAddrs,
    SentinelPassword: password, Password: password, PoolSize: 100,
})
```

业务代码依赖 `redis.UniversalClient` 接口，三种客户端可以互换。

```go
type Redis struct{ client redis.UniversalClient }

var (
    ErrNotFound    = errors.New("key not found")
    ErrLockNotHeld = errors.New("lock not held")
    ErrRateLimited = errors.New("rate limited")
)
```

> 完整连接代码见 [references/examples.md#客户端](references/examples.md#客户端)

---

## 2. 缓存模式

### Cache-Aside

Go 方法不能带类型参数，缓存加载写成普通泛型函数：

```go
type CacheOptions struct {
    TTL     time.Duration
    NullTTL time.Duration // 空值 TTL，0 表示不缓存空值
}

func GetOrLoad[T any](ctx context.Context, r *Redis, key string, loader func(context.Context) (T, error), opts CacheOptions) (T, error) {
    var zero T
    data, err := r.client.Get(ctx, key).Bytes()
    switch {
    case err == nil:
        if string(data) == "null" {
            return zero, ErrNotFound // 空值缓存命中
        }
        var result T
        if err := json.Unmarshal(data, &result); err != nil {
            return zero, fmt.Errorf("unmarshal cache: %w", err)
        }
        return result, nil
    case !errors.Is(err, redis.Nil):
        return zero, fmt.Errorf("get cache: %w", err)
    }

    result, err := loader(ctx)
    if err != nil {
        if errors.Is(err, ErrNotFound) && opts.NullTTL > 0 {
            _ = r.client.Set(ctx, key, "null", opts.NullTTL).Err() // 防穿透
        }
        return zero, err
    }
    if data, err := json.Marshal(result); err == nil {
        _ = r.client.Set(ctx, key, data, opts.TTL).Err()
    }
    return result, nil
}
```

### 三种缓存故障与对策

| 问题 | 原因 | 对策 |
|------|------|------|
| 穿透 | 查询不存在的 key 直达 DB | 空值缓存（短 TTL）或布隆过滤器 |
| 击穿 | 热 key 过期瞬间大量回源 | `singleflight.Group` 合并同 key 回源 |
| 雪崩 | 大量 key 同时过期 | TTL 加随机抖动；L1 本地缓存兜底 |

- Singleflight：`group.Do(key, fn)` 内再查一次缓存，避免排队的请求重复回源
- 双层缓存：`expirable.NewLRU[string, T](size, nil, ttl)` 做 L1，Redis 做 L2，写入时同时更新

> Singleflight、双层缓存完整实现见 [references/examples.md#缓存模式](references/examples.md#缓存模式)

---

## 3. 分布式锁

### 单节点锁（SET NX + Lua 释放）

```go
type Lock struct {
    client redis.UniversalClient
    key    string
    value  string // uuid，释放时校验持有者
    ttl    time.Duration
}

func (l *Lock) TryLock(ctx context.Context) (bool, error) {
    return l.client.SetNX(ctx, l.key, l.value, l.ttl).Result()
}

var unlockScript = redis.NewScript(`
if redis.call("get", KEYS[1]) == ARGV[1] then
    return redis.call("del", KEYS[1])
end
return 0
`)

func (l *Lock) Unlock(ctx context.Context) error {
    n, err := unlockScript.Run(ctx, l.client, []string{l.key}, l.value).Int()
    if err != nil {
        return err
    }
    if n == 0 {
        return ErrLockNotHeld
    }
    return nil
}
```

- 值必须是随机持有者标识，防止释放别人的锁
- 释放必须用 Lua 让 GET + DEL 原子执行
- 长任务用 `Extend`（`pexpire` 脚本）续期，或把 TTL 设为任务上限

### Redlock（redsync/v4）

```go
rs := redsync.New(goredis.NewPool(client1), goredis.NewPool(client2), goredis.NewPool(client3))
mutex := rs.NewMutex("resource-key",
    redsync.WithExpiry(10*time.Second),
    redsync.WithTries(32),
    redsync.WithRetryDelay(100*time.Millisecond),
)
if err := mutex.LockContext(ctx); err != nil { return err }
defer mutex.UnlockContext(ctx) // 返回 (ok bool, err error)
```

单节点锁在主从切换时可能失效；需要跨节点强互斥时用 Redlock，否则用单节点锁 + 业务幂等。

> 完整锁实现（阻塞等待、续期、Redlock 封装）见 [references/examples.md#分布式锁](references/examples.md#分布式锁)

---

## 4. 限流

### 令牌桶（redis_rate/v10，GCRA）

```go
limiter := redis_rate.NewLimiter(client)
res, err := limiter.Allow(ctx, "rate:user:"+userID, redis_rate.PerSecond(10))
if err != nil { return err }
if res.Allowed == 0 {
    return ErrRateLimited // res.RetryAfter 可写入 Retry-After 头
}
```

### 滑动窗口（Lua + ZSET）

```go
var slidingWindowScript = redis.NewScript(`
local key, now, window, limit, member = KEYS[1], tonumber(ARGV[1]), tonumber(ARGV[2]), tonumber(ARGV[3]), ARGV[4]
redis.call("ZREMRANGEBYSCORE", key, 0, now - window)
if redis.call("ZCARD", key) < limit then
    redis.call("ZADD", key, now, member)
    redis.call("PEXPIRE", key, window)
    return 1
end
return 0
`)
```

`member` 传唯一 ID（uuid），避免同一毫秒多个请求互相覆盖。

> 完整限流实现见 [references/examples.md#限流](references/examples.md#限流)

---

## 5. Pipeline 与事务

```go
// Pipeline：一次往返发送多条命令
pipe := r.client.Pipeline()
cmds := make(map[string]*redis.StringCmd, len(keys))
for _, key := range keys {
    cmds[key] = pipe.Get(ctx, key)
}
if _, err := pipe.Exec(ctx); err != nil && !errors.Is(err, redis.Nil) {
    return nil, err // Exec 返回第一个失败命令的错误
}
```

```go
// WATCH + MULTI/EXEC 乐观锁；冲突时返回 redis.TxFailedErr，由调用方重试
err := r.client.Watch(ctx, func(tx *redis.Tx) error {
    balance, err := tx.Get(ctx, from).Int64()
    if err != nil { return err }
    if balance < amount { return ErrInsufficientBalance }
    _, err = tx.TxPipelined(ctx, func(pipe redis.Pipeliner) error {
        pipe.DecrBy(ctx, from, amount)
        pipe.IncrBy(ctx, to, amount)
        return nil
    })
    return err
}, from)
```

Redis 事务没有回滚：`EXEC` 中某条命令失败，其余命令仍然执行。需要原子读改写时优先用 Lua 脚本。

---

## 6. Pub/Sub

```go
func (r *Redis) Subscribe(ctx context.Context, channels []string, handler func(channel string, payload []byte)) error {
    pubsub := r.client.Subscribe(ctx, channels...)
    defer pubsub.Close()

    if _, err := pubsub.Receive(ctx); err != nil { // 等待订阅确认
        return err
    }
    ch := pubsub.Channel()
    for {
        select {
        case <-ctx.Done():
            return ctx.Err()
        case msg, ok := <-ch:
            if !ok {
                return nil
            }
            handler(msg.Channel, []byte(msg.Payload))
        }
    }
}
```

Pub/Sub 是 fire-and-forget：订阅者离线期间的消息丢失。需要持久化或消费确认时用 Redis Streams（`XADD`/`XREADGROUP`）或消息队列。

> `PSubscribe` 模式订阅见 [references/examples.md#pubsub](references/examples.md#pubsub)

---

## 7. 数据结构

| 场景 | 结构 | 核心命令 |
|------|------|----------|
| 排行榜 | Sorted Set | `ZAdd` / `ZIncrBy` / `ZRevRangeWithScores` / `ZRevRank` |
| 去重判断（允许误判） | 布隆过滤器（RedisBloom） | `BFReserve` / `BFAdd` / `BFExists` / `BFMAdd` |
| UV 统计 | HyperLogLog | `PFAdd` / `PFCount`（误差约 0.81%） |
| 计数器 | String | `Incr` / `IncrBy` + `Expire` |
| 对象缓存 | Hash | `HSet` / `HGetAll`，字段数控制在 1000 以内 |

go-redis v9 内置 RedisBloom 命令（`client.BFAdd` 等），不需要 `Do` 手写命令名；服务端需要加载 bf 模块。

> 排行榜、布隆过滤器、HyperLogLog 完整实现见 [references/examples.md#数据结构](references/examples.md#数据结构)

---

## 8. Lua 脚本

```go
var scriptIncrWithCap = redis.NewScript(`
local current = tonumber(redis.call("get", KEYS[1]) or 0)
if current + tonumber(ARGV[2]) > tonumber(ARGV[1]) then
    return -1
end
return redis.call("incrby", KEYS[1], ARGV[2])
`)

n, err := scriptIncrWithCap.Run(ctx, r.client, []string{key}, capacity, incr).Int64()
```

- `redis.NewScript` 先 `EVALSHA`，`NOSCRIPT` 时自动回退 `EVAL`
- 脚本返回 `nil` 时 `Result()` 得到 `redis.Nil`，用 `errors.Is` 判断
- 所有键必须通过 `KEYS` 传入；集群下多键要用 Hash Tag `{resource}:a`、`{resource}:b` 落到同一槽

---

## 最佳实践

- 键命名：`业务:对象:ID`（`user:123:profile`），集群多键操作加 Hash Tag
- 每个键设置 TTL；无 TTL 的键要有明确的清理路径
- 大 key 拆分：List/Set/Hash 元素不超过 1 万，String 不超过 1MB
- 遍历用 `SCAN`，禁止线上 `KEYS`
- 批量读写用 Pipeline；单命令 RTT 是最大开销
- 监控 `slowlog get`、`info memory`、连接池 `PoolStats()`

---

## 检查清单

- [ ] 连接池大小与超时按 9.22 默认值核对过？
- [ ] 业务代码依赖 `redis.UniversalClient` 而非具体类型？
- [ ] 每个键有 TTL，热点键有抖动？
- [ ] 空值缓存 + singleflight 处理穿透和击穿？
- [ ] 锁值随机、Lua 释放、长任务续期？
- [ ] 集群多键操作用 Hash Tag？
- [ ] 批量操作用 Pipeline？
- [ ] `errors.Is(err, redis.Nil)` 区分未命中与故障？

---

## 参考资料

- [references/examples.md](references/examples.md) - 完整可编译代码（连接、缓存、锁、限流、Pipeline、Pub/Sub、数据结构、Lua）
- [go-redis v9 pkg.go.dev](https://pkg.go.dev/github.com/redis/go-redis/v9)
- [redsync/v4 pkg.go.dev](https://pkg.go.dev/github.com/go-redsync/redsync/v4)
- [redis_rate/v10 pkg.go.dev](https://pkg.go.dev/github.com/go-redis/redis_rate/v10)
