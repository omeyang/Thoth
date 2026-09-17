# Go Redis - 完整代码实现

## 目录

- [导入与依赖](#导入与依赖)
- [客户端](#客户端)
- [包装器与错误](#包装器与错误)
- [缓存模式](#缓存模式)
- [分布式锁](#分布式锁)
- [限流](#限流)
- [Pipeline](#pipeline)
- [Pub/Sub](#pubsub)
- [数据结构](#数据结构)
- [Lua 脚本](#lua-脚本)

---

所有代码在 go1.24.6 + `github.com/redis/go-redis/v9 v9.22.0` 下通过 `go vet`。示例合并在一个包里，导入块只列一次。

```text
go get github.com/redis/go-redis/v9@v9.22.0
go get github.com/go-redsync/redsync/v4@v4.15.0
go get github.com/go-redis/redis_rate/v10@v10.0.1
go get github.com/hashicorp/golang-lru/v2@v2.0.7
go get golang.org/x/sync@v0.19.0
go get github.com/google/uuid@v1.6.0
```

---

## 导入与依赖

```go
package redisx

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"time"

	"github.com/go-redis/redis_rate/v10"
	"github.com/go-redsync/redsync/v4"
	redsyncredis "github.com/go-redsync/redsync/v4/redis"
	"github.com/go-redsync/redsync/v4/redis/goredis/v9"
	"github.com/google/uuid"
	"github.com/hashicorp/golang-lru/v2/expirable"
	"github.com/redis/go-redis/v9"
	"golang.org/x/sync/singleflight"
)
```

---

## 客户端

9.22 调整了默认值（见 `NewRedisClient` 注释）。未显式设置的字段按新默认值生效，压测过的旧配置要逐项核对。

```go
// NewRedisClient 单机连接。
// go-redis 9.22 的默认值：DialTimeout 5s、ReadTimeout 5s、WriteTimeout 跟随 ReadTimeout、
// PoolTimeout = ReadTimeout + 1s、ConnMaxIdleTime 30m、MaxRetries 3、退避 10ms..1s、PoolSize = 10 * GOMAXPROCS。
// 下面显式设置的值会覆盖默认值；要关闭某项超时或重试，传 -1。
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

func NewRedisCluster(addrs []string, password string) (*redis.ClusterClient, error) {
	client := redis.NewClusterClient(&redis.ClusterOptions{
		Addrs:          addrs,
		Password:       password,
		PoolSize:       100,
		MinIdleConns:   10,
		MaxIdleConns:   50,
		DialTimeout:    5 * time.Second,
		ReadTimeout:    3 * time.Second,
		WriteTimeout:   3 * time.Second,
		RouteByLatency: true, // 读请求路由到延迟最低的节点
		RouteRandomly:  false,
	})

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	if err := client.Ping(ctx).Err(); err != nil {
		_ = client.Close()
		return nil, fmt.Errorf("ping cluster: %w", err)
	}
	return client, nil
}

func NewRedisSentinel(masterName string, sentinelAddrs []string, password string) (*redis.Client, error) {
	client := redis.NewFailoverClient(&redis.FailoverOptions{
		MasterName:       masterName,
		SentinelAddrs:    sentinelAddrs,
		SentinelPassword: password,
		Password:         password,
		DB:               0,
		PoolSize:         100,
	})

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	if err := client.Ping(ctx).Err(); err != nil {
		_ = client.Close()
		return nil, fmt.Errorf("ping sentinel: %w", err)
	}
	return client, nil
}
```

---

## 包装器与错误

```go
type Redis struct {
	client redis.UniversalClient
}

func New(client redis.UniversalClient) *Redis { return &Redis{client: client} }

func (r *Redis) Client() redis.UniversalClient    { return r.client }
func (r *Redis) Health(ctx context.Context) error { return r.client.Ping(ctx).Err() }
func (r *Redis) Close() error                     { return r.client.Close() }

var (
	ErrNotFound            = errors.New("key not found")
	ErrLockNotHeld         = errors.New("lock not held")
	ErrRateLimited         = errors.New("rate limited")
	ErrInsufficientBalance = errors.New("insufficient balance")
)
```

---

## 缓存模式

Go 方法不能带类型参数，`GetOrLoad` / `GetOrLoadSingleflight` 写成普通泛型函数。

```go
type CacheOptions struct {
	TTL     time.Duration // 正常值 TTL
	NullTTL time.Duration // 空值 TTL，0 表示不缓存空值
}

const nullMarker = "null"

// GetOrLoad Cache-Aside。Go 方法不能带类型参数，因此写成普通泛型函数
func GetOrLoad[T any](ctx context.Context, r *Redis, key string, loader func(context.Context) (T, error), opts CacheOptions) (T, error) {
	var zero T

	data, err := r.client.Get(ctx, key).Bytes()
	switch {
	case err == nil:
		if string(data) == nullMarker {
			return zero, ErrNotFound
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
			_ = r.client.Set(ctx, key, nullMarker, opts.NullTTL).Err() // 空值缓存防穿透
		}
		return zero, err
	}

	data, err = json.Marshal(result)
	if err != nil {
		return result, nil // 序列化失败不影响业务返回
	}
	_ = r.client.Set(ctx, key, data, opts.TTL).Err()
	return result, nil
}

// CacheWithSingleflight 合并并发的相同 key 回源，防止缓存击穿
type CacheWithSingleflight struct {
	*Redis
	group singleflight.Group
}

func GetOrLoadSingleflight[T any](ctx context.Context, c *CacheWithSingleflight, key string, loader func(context.Context) (T, error), opts CacheOptions) (T, error) {
	var zero T

	data, err := c.client.Get(ctx, key).Bytes()
	if err == nil {
		var result T
		if err := json.Unmarshal(data, &result); err != nil {
			return zero, err
		}
		return result, nil
	}
	if !errors.Is(err, redis.Nil) {
		return zero, err
	}

	v, err, _ := c.group.Do(key, func() (any, error) {
		// 二次检查：其他请求可能已回填
		data, err := c.client.Get(ctx, key).Bytes()
		if err == nil {
			var result T
			if err := json.Unmarshal(data, &result); err != nil {
				return zero, err
			}
			return result, nil
		}
		result, err := loader(ctx)
		if err != nil {
			return zero, err
		}
		if data, err := json.Marshal(result); err == nil {
			_ = c.client.Set(ctx, key, data, opts.TTL).Err()
		}
		return result, nil
	})
	if err != nil {
		return zero, err
	}
	return v.(T), nil
}

// DualCache L1 本地 LRU + L2 Redis
type DualCache[T any] struct {
	l1    *expirable.LRU[string, T]
	l2    *Redis
	l2TTL time.Duration
}

func NewDualCache[T any](l2 *Redis, l1Size int, l1TTL, l2TTL time.Duration) *DualCache[T] {
	return &DualCache[T]{
		l1:    expirable.NewLRU[string, T](l1Size, nil, l1TTL),
		l2:    l2,
		l2TTL: l2TTL,
	}
}

func (c *DualCache[T]) Get(ctx context.Context, key string) (T, bool) {
	var zero T
	if v, ok := c.l1.Get(key); ok {
		return v, true
	}
	data, err := c.l2.client.Get(ctx, key).Bytes()
	if err != nil {
		return zero, false
	}
	var result T
	if err := json.Unmarshal(data, &result); err != nil {
		return zero, false
	}
	c.l1.Add(key, result) // 回填 L1
	return result, true
}

func (c *DualCache[T]) Set(ctx context.Context, key string, value T) error {
	c.l1.Add(key, value)
	data, err := json.Marshal(value)
	if err != nil {
		return err
	}
	return c.l2.client.Set(ctx, key, data, c.l2TTL).Err()
}

func (c *DualCache[T]) Delete(ctx context.Context, key string) error {
	c.l1.Remove(key)
	return c.l2.client.Del(ctx, key).Err()
}
```

---

## 分布式锁

单节点锁适合非关键路径；跨节点强互斥用 redsync（Redlock），`Unlock` 返回 `(ok, err)`，`ok=false` 表示锁已过期。

```go
type Lock struct {
	client redis.UniversalClient
	key    string
	value  string
	ttl    time.Duration
}

func NewLock(client redis.UniversalClient, key string, ttl time.Duration) *Lock {
	return &Lock{
		client: client,
		key:    "lock:" + key,
		value:  uuid.NewString(), // 持有者标识，释放时校验
		ttl:    ttl,
	}
}

func (l *Lock) TryLock(ctx context.Context) (bool, error) {
	return l.client.SetNX(ctx, l.key, l.value, l.ttl).Result()
}

// Lock 阻塞等待直到获得锁或 ctx 结束
func (l *Lock) Lock(ctx context.Context) error {
	ticker := time.NewTicker(50 * time.Millisecond)
	defer ticker.Stop()
	for {
		ok, err := l.TryLock(ctx)
		if err != nil {
			return err
		}
		if ok {
			return nil
		}
		select {
		case <-ctx.Done():
			return ctx.Err()
		case <-ticker.C:
		}
	}
}

// Lua 脚本保证"校验持有者 + 删除"原子执行
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

var extendScript = redis.NewScript(`
if redis.call("get", KEYS[1]) == ARGV[1] then
    return redis.call("pexpire", KEYS[1], ARGV[2])
end
return 0
`)

// Extend 续期（看门狗调用）
func (l *Lock) Extend(ctx context.Context, ttl time.Duration) error {
	n, err := extendScript.Run(ctx, l.client, []string{l.key}, l.value, ttl.Milliseconds()).Int()
	if err != nil {
		return err
	}
	if n == 0 {
		return ErrLockNotHeld
	}
	l.ttl = ttl
	return nil
}

// NewRedlock 多节点 Redlock（redsync/v4）
func NewRedlock(clients ...redis.UniversalClient) *redsync.Redsync {
	pools := make([]redsyncredis.Pool, 0, len(clients))
	for _, c := range clients {
		pools = append(pools, goredis.NewPool(c))
	}
	return redsync.New(pools...)
}

func WithRedlock(ctx context.Context, rs *redsync.Redsync, name string, fn func(ctx context.Context) error) error {
	mutex := rs.NewMutex(name,
		redsync.WithExpiry(10*time.Second),
		redsync.WithTries(32),
		redsync.WithRetryDelay(100*time.Millisecond),
	)
	if err := mutex.LockContext(ctx); err != nil {
		return fmt.Errorf("acquire %s: %w", name, err)
	}
	defer func() {
		// Unlock 返回 (ok, err)；ok=false 表示锁已过期或被他人持有
		if ok, err := mutex.UnlockContext(ctx); !ok || err != nil {
			_ = err
		}
	}()
	return fn(ctx)
}
```

---

## 限流

`redis_rate` 使用 GCRA 算法，`PerSecond(10)` 等价于每秒 10 个令牌、突发 10。

```go
// RateLimiter 令牌桶（GCRA），基于 redis_rate/v10
type RateLimiter struct {
	limiter *redis_rate.Limiter
}

func NewRateLimiter(client redis.UniversalClient) *RateLimiter {
	return &RateLimiter{limiter: redis_rate.NewLimiter(client)}
}

func (r *RateLimiter) Allow(ctx context.Context, key string, limit redis_rate.Limit) (bool, error) {
	res, err := r.limiter.Allow(ctx, key, limit)
	if err != nil {
		return false, err
	}
	return res.Allowed > 0, nil
}

func CheckUserRate(ctx context.Context, limiter *RateLimiter, userID string) error {
	allowed, err := limiter.Allow(ctx, "rate:user:"+userID, redis_rate.PerSecond(10)) // 每秒 10 次，突发 10
	if err != nil {
		return err
	}
	if !allowed {
		return ErrRateLimited
	}
	return nil
}

var slidingWindowScript = redis.NewScript(`
local key = KEYS[1]
local now = tonumber(ARGV[1])
local window = tonumber(ARGV[2])
local limit = tonumber(ARGV[3])
local member = ARGV[4]
redis.call("ZREMRANGEBYSCORE", key, 0, now - window)
local count = redis.call("ZCARD", key)
if count < limit then
    redis.call("ZADD", key, now, member)
    redis.call("PEXPIRE", key, window)
    return 1
end
return 0
`)

// SlidingWindowLimit 滑动窗口限流（member 用唯一 ID，避免同一毫秒碰撞）
func (r *Redis) SlidingWindowLimit(ctx context.Context, key string, window time.Duration, limit int64) (bool, error) {
	now := time.Now().UnixMilli()
	n, err := slidingWindowScript.Run(ctx, r.client, []string{key},
		now, window.Milliseconds(), limit, uuid.NewString()).Int()
	if err != nil {
		return false, err
	}
	return n == 1, nil
}
```

---

## Pipeline

```go
func (r *Redis) BatchGet(ctx context.Context, keys []string) (map[string]string, error) {
	pipe := r.client.Pipeline()
	cmds := make(map[string]*redis.StringCmd, len(keys))
	for _, key := range keys {
		cmds[key] = pipe.Get(ctx, key)
	}
	// Exec 返回第一个失败命令的错误；缺失 key 的 redis.Nil 不算失败
	if _, err := pipe.Exec(ctx); err != nil && !errors.Is(err, redis.Nil) {
		return nil, err
	}
	results := make(map[string]string, len(keys))
	for key, cmd := range cmds {
		if val, err := cmd.Result(); err == nil {
			results[key] = val
		}
	}
	return results, nil
}

func (r *Redis) BatchSet(ctx context.Context, items map[string]any, ttl time.Duration) error {
	pipe := r.client.Pipeline()
	for key, value := range items {
		data, err := json.Marshal(value)
		if err != nil {
			return err
		}
		pipe.Set(ctx, key, data, ttl)
	}
	_, err := pipe.Exec(ctx)
	return err
}

// Transfer WATCH + MULTI/EXEC 乐观锁；键冲突时 Watch 返回 redis.TxFailedErr
func (r *Redis) Transfer(ctx context.Context, from, to string, amount int64) error {
	return r.client.Watch(ctx, func(tx *redis.Tx) error {
		balance, err := tx.Get(ctx, from).Int64()
		if err != nil {
			return err
		}
		if balance < amount {
			return ErrInsufficientBalance
		}
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

## Pub/Sub

```go
func (r *Redis) Publish(ctx context.Context, channel string, message any) error {
	data, err := json.Marshal(message)
	if err != nil {
		return err
	}
	return r.client.Publish(ctx, channel, data).Err()
}

func (r *Redis) Subscribe(ctx context.Context, channels []string, handler func(channel string, payload []byte)) error {
	pubsub := r.client.Subscribe(ctx, channels...)
	defer pubsub.Close()

	// 等待订阅确认，避免丢失订阅前的消息
	if _, err := pubsub.Receive(ctx); err != nil {
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

func (r *Redis) PSubscribe(ctx context.Context, patterns []string, handler func(pattern, channel string, payload []byte)) error {
	pubsub := r.client.PSubscribe(ctx, patterns...)
	defer pubsub.Close()

	if _, err := pubsub.Receive(ctx); err != nil {
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
			handler(msg.Pattern, msg.Channel, []byte(msg.Payload))
		}
	}
}
```

---

## 数据结构

```go
type Leaderboard struct {
	*Redis
	key string
}

func NewLeaderboard(r *Redis, name string) *Leaderboard {
	return &Leaderboard{Redis: r, key: "leaderboard:" + name}
}

func (l *Leaderboard) Add(ctx context.Context, member string, score float64) error {
	return l.client.ZAdd(ctx, l.key, redis.Z{Score: score, Member: member}).Err()
}

func (l *Leaderboard) IncrScore(ctx context.Context, member string, delta float64) (float64, error) {
	return l.client.ZIncrBy(ctx, l.key, delta, member).Result()
}

func (l *Leaderboard) Top(ctx context.Context, n int64) ([]redis.Z, error) {
	return l.client.ZRevRangeWithScores(ctx, l.key, 0, n-1).Result()
}

// Rank 返回 1-based 排名
func (l *Leaderboard) Rank(ctx context.Context, member string) (int64, error) {
	rank, err := l.client.ZRevRank(ctx, l.key, member).Result()
	if err != nil {
		return -1, err
	}
	return rank + 1, nil
}

func (l *Leaderboard) Score(ctx context.Context, member string) (float64, error) {
	return l.client.ZScore(ctx, l.key, member).Result()
}

func (l *Leaderboard) Around(ctx context.Context, member string, count int64) ([]redis.Z, error) {
	rank, err := l.client.ZRevRank(ctx, l.key, member).Result()
	if err != nil {
		return nil, err
	}
	start := max(rank-count, 0)
	return l.client.ZRevRangeWithScores(ctx, l.key, start, rank+count).Result()
}

// 布隆过滤器：go-redis v9 内置 RedisBloom 命令（需服务端加载 bf 模块）
func (r *Redis) BFReserve(ctx context.Context, key string, errorRate float64, capacity int64) error {
	return r.client.BFReserve(ctx, key, errorRate, capacity).Err()
}

func (r *Redis) BFAdd(ctx context.Context, key, item string) (bool, error) {
	return r.client.BFAdd(ctx, key, item).Result()
}

func (r *Redis) BFExists(ctx context.Context, key, item string) (bool, error) {
	return r.client.BFExists(ctx, key, item).Result()
}

func (r *Redis) BFMAdd(ctx context.Context, key string, items ...string) ([]bool, error) {
	args := make([]any, len(items))
	for i, item := range items {
		args[i] = item
	}
	return r.client.BFMAdd(ctx, key, args...).Result()
}

// HyperLogLog 基数统计
func (r *Redis) HLLAdd(ctx context.Context, key string, elements ...string) error {
	args := make([]any, len(elements))
	for i, e := range elements {
		args[i] = e
	}
	return r.client.PFAdd(ctx, key, args...).Err()
}

func (r *Redis) HLLCount(ctx context.Context, keys ...string) (int64, error) {
	return r.client.PFCount(ctx, keys...).Result()
}

func (r *Redis) RecordUV(ctx context.Context, date, userID string) error {
	return r.HLLAdd(ctx, "uv:"+date, userID)
}

func (r *Redis) GetUV(ctx context.Context, dates ...string) (int64, error) {
	keys := make([]string, len(dates))
	for i, d := range dates {
		keys[i] = "uv:" + d
	}
	return r.HLLCount(ctx, keys...)
}
```

---

## Lua 脚本

```go
var (
	scriptCompareAndSet = redis.NewScript(`
if redis.call("get", KEYS[1]) == ARGV[1] then
    return redis.call("set", KEYS[1], ARGV[2])
end
return nil
`)

	scriptIncrWithCap = redis.NewScript(`
local current = tonumber(redis.call("get", KEYS[1]) or 0)
local cap = tonumber(ARGV[1])
local incr = tonumber(ARGV[2])
if current + incr > cap then
    return -1
end
return redis.call("incrby", KEYS[1], incr)
`)
)

// CompareAndSet 仅当当前值等于 expected 时写入
func (r *Redis) CompareAndSet(ctx context.Context, key, expected, newValue string) (bool, error) {
	_, err := scriptCompareAndSet.Run(ctx, r.client, []string{key}, expected, newValue).Result()
	if errors.Is(err, redis.Nil) {
		return false, nil
	}
	if err != nil {
		return false, err
	}
	return true, nil
}

func (r *Redis) IncrWithCap(ctx context.Context, key string, capacity, incr int64) (int64, error) {
	return scriptIncrWithCap.Run(ctx, r.client, []string{key}, capacity, incr).Int64()
}

// clusterSafeKey 用 Hash Tag 让相关键落在同一个槽，脚本多键操作才能在集群下执行
func clusterSafeKey(resource string) string {
	return fmt.Sprintf("{%s}:lock", resource)
}

var _ = clusterSafeKey
```
