---
name: redis-go
description: "Go Redis 专家 - 使用 go-redis/v9 实现缓存模式(Cache-Aside/Singleflight/双层缓存)、分布式锁(SETNX/Lua/Redlock)、限流(令牌桶/滑动窗口)、Pipeline批量操作、Pub/Sub消息、数据结构(排行榜/布隆过滤器/HyperLogLog)、Lua脚本、集群/Sentinel连接。适用：缓存、会话存储、排行榜、实时计数、分布式锁、消息队列。不适用：持久化主存储(Redis非唯一数据源)、复杂关联查询(应使用关系型数据库)、强一致性事务(Redis事务不支持回滚)。触发词：redis, 缓存, cache, 分布式锁, distributed lock, 限流, 排行榜, leaderboard, pub/sub, lua脚本, pipeline, go-redis"
user-invocable: true
allowed-tools: Bash, Read, Write, Edit, Grep, Glob
---

# Go Redis 专家

使用 Go go-redis 开发 Redis 功能：$ARGUMENTS

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
    })

    ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
    defer cancel()

    if err := client.Ping(ctx).Err(); err != nil {
        return nil, fmt.Errorf("ping redis: %w", err)
    }
    return client, nil
}
```

### 集群 / Sentinel 连接

```go
// 集群
func NewRedisCluster(addrs []string, password string) (*redis.ClusterClient, error) {
    client := redis.NewClusterClient(&redis.ClusterOptions{
        Addrs: addrs, Password: password,
        PoolSize: 100, RouteByLatency: true,
    })
    // ... Ping 检查
}

// Sentinel
func NewRedisSentinel(masterName string, sentinelAddrs []string, password string) (*redis.Client, error) {
    client := redis.NewFailoverClient(&redis.FailoverOptions{
        MasterName: masterName, SentinelAddrs: sentinelAddrs,
        Password: password, PoolSize: 100,
    })
    // ... Ping 检查
}
```

### 包装器与错误定义

```go
type Redis struct { client redis.UniversalClient }
func New(client redis.UniversalClient) *Redis { return &Redis{client: client} }
func (r *Redis) Health(ctx context.Context) error { return r.client.Ping(ctx).Err() }

var (
    ErrNotFound    = errors.New("key not found")
    ErrLockNotHeld = errors.New("lock not held")
    ErrRateLimited = errors.New("rate limited")
)
```

> 集群/Sentinel 完整连接代码见 [references/examples.md](references/examples.md#客户端管理)

---

## 2. 缓存模式

### Cache-Aside（旁路缓存）

```go
func (r *Redis) GetOrLoad[T any](ctx context.Context, key string, loader func(context.Context) (T, error), opts CacheOptions) (T, error) {
    var zero T
    data, err := r.client.Get(ctx, key).Bytes()
    if err == nil {
        var result T
        if err := json.Unmarshal(data, &result); err != nil {
            return zero, fmt.Errorf("unmarshal cache: %w", err)
        }
        return result, nil
    }
    if !errors.Is(err, redis.Nil) {
        return zero, fmt.Errorf("get cache: %w", err)
    }
    result, err := loader(ctx)
    if err != nil {
        if errors.Is(err, ErrNotFound) && opts.NullTTL > 0 {
            r.client.Set(ctx, key, "null", opts.NullTTL)
        }
        return zero, err
    }
    data, err = json.Marshal(result)
    if err != nil { return result, nil }
    r.client.Set(ctx, key, data, opts.TTL)
    return result, nil
}
```

### Singleflight 防击穿

```go
type CacheWithSingleflight struct {
    *Redis
    group singleflight.Group
}

// Singleflight 合并并发请求，避免缓存击穿
// 签名：func (c *CacheWithSingleflight) GetOrLoad[T any](...) (T, error)
```

> Singleflight 完整实现和双层缓存(L1本地+L2 Redis)见 [references/examples.md](references/examples.md#缓存高级模式)

---

## 3. 分布式锁

### 简单锁（SETNX + Lua 原子释放）

```go
type Lock struct {
    client redis.UniversalClient
    key, value string
    ttl time.Duration
}

func (l *Lock) TryLock(ctx context.Context) (bool, error) {
    return l.client.SetNX(ctx, l.key, l.value, l.ttl).Result()
}

// Lua 脚本确保原子性释放
var unlockScript = redis.NewScript(`
if redis.call("get", KEYS[1]) == ARGV[1] then
    return redis.call("del", KEYS[1])
else return 0 end
`)

func (l *Lock) Unlock(ctx context.Context) error {
    result, err := unlockScript.Run(ctx, l.client, []string{l.key}, l.value).Int()
    if err != nil { return err }
    if result == 0 { return ErrLockNotHeld }
    return nil
}
```

### Redlock（多节点锁）

```go
import "github.com/go-redsync/redsync/v4"

mutex := rs.NewMutex("resource-key",
    redsync.WithExpiry(10*time.Second),
    redsync.WithTries(32),
)
```

> 完整锁实现（含阻塞等待、续期）和 Redlock 示例见 [references/examples.md](references/examples.md#分布式锁)

---

## 4. 限流

### 令牌桶（go-redis/redis_rate）

```go
limiter := redis_rate.NewLimiter(client)
res, err := limiter.Allow(ctx, "user:123", redis_rate.PerSecond(10))
allowed := res.Allowed > 0
```

### 滑动窗口（Lua 脚本）

```go
var slidingWindowScript = redis.NewScript(`
local key = KEYS[1]
local now = tonumber(ARGV[1])
local window = tonumber(ARGV[2])
local limit = tonumber(ARGV[3])
redis.call("ZREMRANGEBYSCORE", key, 0, now - window)
local count = redis.call("ZCARD", key)
if count < limit then
    redis.call("ZADD", key, now, now .. "-" .. math.random())
    redis.call("PEXPIRE", key, window)
    return 1
else return 0 end
`)
```

> 完整限流实现见 [references/examples.md](references/examples.md#限流)

---

## 5. Pipeline 批量操作

### 基础 Pipeline

```go
func (r *Redis) BatchGet(ctx context.Context, keys []string) (map[string]string, error) {
    pipe := r.client.Pipeline()
    cmds := make(map[string]*redis.StringCmd)
    for _, key := range keys { cmds[key] = pipe.Get(ctx, key) }
    _, err := pipe.Exec(ctx)
    if err != nil && !errors.Is(err, redis.Nil) { return nil, err }
    results := make(map[string]string)
    for key, cmd := range cmds {
        if val, err := cmd.Result(); err == nil { results[key] = val }
    }
    return results, nil
}
```

### 事务 Pipeline（乐观锁）

```go
func (r *Redis) Transfer(ctx context.Context, from, to string, amount int64) error {
    return r.client.Watch(ctx, func(tx *redis.Tx) error {
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
}
```

---

## 6. Pub/Sub

```go
func (r *Redis) Publish(ctx context.Context, channel string, message any) error {
    data, err := json.Marshal(message)
    if err != nil { return err }
    return r.client.Publish(ctx, channel, data).Err()
}

func (r *Redis) Subscribe(ctx context.Context, channels []string, handler func(channel string, payload []byte)) error {
    pubsub := r.client.Subscribe(ctx, channels...)
    defer pubsub.Close()
    ch := pubsub.Channel()
    for {
        select {
        case <-ctx.Done(): return ctx.Err()
        case msg, ok := <-ch:
            if !ok { return nil }
            handler(msg.Channel, []byte(msg.Payload))
        }
    }
}
```

> 模式订阅 PSubscribe 见 [references/examples.md](references/examples.md#pubsub)

---

## 7. 数据结构

### 排行榜（Sorted Set）— 核心 API

```go
type Leaderboard struct { *Redis; key string }

func (l *Leaderboard) Add(ctx context.Context, member string, score float64) error
func (l *Leaderboard) IncrScore(ctx context.Context, member string, delta float64) (float64, error)
func (l *Leaderboard) Top(ctx context.Context, n int64) ([]redis.Z, error)
func (l *Leaderboard) Rank(ctx context.Context, member string) (int64, error)
func (l *Leaderboard) Around(ctx context.Context, member string, count int64) ([]redis.Z, error)
```

### 布隆过滤器 / HyperLogLog

```go
// 布隆过滤器（RedisBloom 模块）
func (r *Redis) BFAdd(ctx context.Context, key, item string) error
func (r *Redis) BFExists(ctx context.Context, key, item string) (bool, error)

// HyperLogLog 基数统计
func (r *Redis) RecordUV(ctx context.Context, date, userID string) error
func (r *Redis) GetUV(ctx context.Context, dates ...string) (int64, error)
```

> 排行榜、布隆过滤器、HyperLogLog 完整实现见 [references/examples.md](references/examples.md#数据结构)

---

## 8. Lua 脚本

### 脚本管理

```go
var scriptCompareAndSet = redis.NewScript(`
    if redis.call("get", KEYS[1]) == ARGV[1] then
        return redis.call("set", KEYS[1], ARGV[2])
    else return nil end
`)

var scriptIncrWithCap = redis.NewScript(`
    local current = tonumber(redis.call("get", KEYS[1]) or 0)
    local cap = tonumber(ARGV[1])
    local incr = tonumber(ARGV[2])
    if current + incr > cap then return -1 end
    return redis.call("incrby", KEYS[1], incr)
`)
```

### 集群兼容

```go
// 使用 Hash Tag 确保键在同一个槽
func clusterSafeKey(resource string) string {
    return fmt.Sprintf("{%s}:lock", resource)
}
```

---

## 最佳实践

### 连接管理
- 复用连接池，合理配置 PoolSize（CPU 核数 * 10）
- 设置 ConnMaxIdleTime 清理空闲连接

### 键设计
- 冒号分隔命名空间 `user:123:profile`
- 集群模式使用 Hash Tag `{user:123}:profile`
- 设置合理 TTL，避免内存溢出

### 性能
- 批量操作使用 Pipeline
- 大键拆分（Hash 字段 < 1000）
- 避免 KEYS 命令（用 SCAN）

### 可靠性
- 分布式锁使用 Redlock
- 设置合理重试策略
- 监控慢查询

---

## 检查清单

- [ ] 连接池配置合理？
- [ ] 键命名规范？
- [ ] 设置 TTL？
- [ ] 批量操作用 Pipeline？
- [ ] 分布式锁用 Lua 原子操作？
- [ ] 集群模式用 Hash Tag？
- [ ] 空值缓存防穿透？
- [ ] Singleflight 防击穿？

---

## 参考资料

- [references/examples.md](references/examples.md) - 完整代码实现（连接、缓存、锁、数据结构）
