# Go etcd - 完整代码实现

基线：go1.24.6，`go.etcd.io/etcd/client/v3 v3.6.8`（`go.etcd.io/etcd/api/v3 v3.6.8` 提供 `rpctypes` 错误）。
所有片段同属一个包 `etcdx`，可按需拆分文件。

## 目录

- [客户端管理](#客户端管理)
- [KV 操作](#kv-操作)
- [Watch 监听](#watch-监听)
- [分布式锁](#分布式锁)
- [租约管理](#租约管理)
- [选主（Leader Election）](#选主leader-election)
- [事务](#事务)
- [配置中心](#配置中心)

---

## 客户端管理

### 创建客户端

```go
package etcdx

import (
    "context"
    "crypto/tls"
    "errors"
    "fmt"
    "net"
    "time"

    clientv3 "go.etcd.io/etcd/client/v3"
)

// Config 是 clientv3.Config 的业务子集，字段含义与之一致。
type Config struct {
    Endpoints            []string      // 必需: ["host1:2379", "host2:2379"]
    Username             string        // 可选
    Password             string        // 可选
    TLS                  *tls.Config   // 可选
    DialTimeout          time.Duration // 默认 5s
    DialKeepAliveTime    time.Duration // 默认 10s
    DialKeepAliveTimeout time.Duration // 默认 3s
    AutoSyncInterval     time.Duration // 默认 0（不自动同步成员列表）
}

var (
    ErrNoEndpoints     = errors.New("etcdx: no endpoints configured")
    ErrInvalidEndpoint = errors.New("etcdx: invalid endpoint")
    ErrKeyNotFound     = errors.New("etcdx: key not found")
    ErrNoLeader        = errors.New("etcdx: no leader elected")
)

func (c *Config) validate() error {
    if len(c.Endpoints) == 0 {
        return ErrNoEndpoints
    }
    for _, ep := range c.Endpoints {
        if _, _, err := net.SplitHostPort(ep); err != nil {
            return fmt.Errorf("%w: %s", ErrInvalidEndpoint, ep)
        }
    }
    return nil
}

func (c *Config) withDefaults() Config {
    out := *c
    if out.DialTimeout == 0 {
        out.DialTimeout = 5 * time.Second
    }
    if out.DialKeepAliveTime == 0 {
        out.DialKeepAliveTime = 10 * time.Second
    }
    if out.DialKeepAliveTimeout == 0 {
        out.DialKeepAliveTimeout = 3 * time.Second
    }
    return out
}

// NewClient 创建 clientv3.Client 并验证至少一个 endpoint 可用。
func NewClient(ctx context.Context, cfg Config) (*clientv3.Client, error) {
    if err := cfg.validate(); err != nil {
        return nil, err
    }
    cfg = cfg.withDefaults()

    client, err := clientv3.New(clientv3.Config{
        Endpoints:            cfg.Endpoints,
        Username:             cfg.Username,
        Password:             cfg.Password,
        TLS:                  cfg.TLS,
        DialTimeout:          cfg.DialTimeout,
        DialKeepAliveTime:    cfg.DialKeepAliveTime,
        DialKeepAliveTimeout: cfg.DialKeepAliveTimeout,
        AutoSyncInterval:     cfg.AutoSyncInterval,
        PermitWithoutStream:  true, // 空闲时也发送 keepalive
        RejectOldCluster:     true, // 拒绝连接不支持 v3 API 的旧集群
        Context:              ctx,
    })
    if err != nil {
        return nil, fmt.Errorf("create etcd client: %w", err)
    }

    hctx, cancel := context.WithTimeout(ctx, cfg.DialTimeout)
    defer cancel()
    if _, err := client.Status(hctx, cfg.Endpoints[0]); err != nil {
        _ = client.Close()
        return nil, fmt.Errorf("check etcd status: %w", err)
    }
    return client, nil
}
```

### 带前缀的轻量封装

```go
package etcdx

import (
    clientv3 "go.etcd.io/etcd/client/v3"
)

// Etcd 只做 key 前缀拼接，不隐藏 clientv3 API；高级操作直接用 Client()。
type Etcd struct {
    client *clientv3.Client
    prefix string
}

func New(client *clientv3.Client, prefix string) *Etcd {
    return &Etcd{client: client, prefix: prefix}
}

func (e *Etcd) Client() *clientv3.Client { return e.client }
func (e *Etcd) Close() error             { return e.client.Close() }
func (e *Etcd) key(k string) string      { return e.prefix + k }
```

### 健康检查

```go
package etcdx

import (
    "context"
    "fmt"
)

// Health 对每个 endpoint 调用 Status，任一失败即报错。
func (e *Etcd) Health(ctx context.Context) error {
    for _, ep := range e.client.Endpoints() {
        if _, err := e.client.Status(ctx, ep); err != nil {
            return fmt.Errorf("endpoint %s: %w", ep, err)
        }
    }
    return nil
}
```

---

## KV 操作

### 基本 CRUD

```go
package etcdx

import (
    "context"
    "fmt"
    "time"

    clientv3 "go.etcd.io/etcd/client/v3"
)

func (e *Etcd) Put(ctx context.Context, key, value string) error {
    if _, err := e.client.Put(ctx, e.key(key), value); err != nil {
        return fmt.Errorf("put %s: %w", key, err)
    }
    return nil
}

// PutWithTTL 先 Grant 租约再 Put；Put 失败时回收租约，避免泄漏。
func (e *Etcd) PutWithTTL(ctx context.Context, key, value string, ttl time.Duration) error {
    lease, err := e.client.Grant(ctx, int64(ttl.Seconds()))
    if err != nil {
        return fmt.Errorf("grant lease: %w", err)
    }
    if _, err := e.client.Put(ctx, e.key(key), value, clientv3.WithLease(lease.ID)); err != nil {
        rctx, cancel := context.WithTimeout(context.WithoutCancel(ctx), 3*time.Second)
        defer cancel()
        _, _ = e.client.Revoke(rctx, lease.ID)
        return fmt.Errorf("put %s with lease: %w", key, err)
    }
    return nil
}

func (e *Etcd) Get(ctx context.Context, key string) (string, error) {
    resp, err := e.client.Get(ctx, e.key(key))
    if err != nil {
        return "", fmt.Errorf("get %s: %w", key, err)
    }
    if len(resp.Kvs) == 0 {
        return "", ErrKeyNotFound
    }
    return string(resp.Kvs[0].Value), nil
}

// GetWithRevision 返回值与 ModRevision，供后续 Watch 从该 revision 之后续接。
func (e *Etcd) GetWithRevision(ctx context.Context, key string) (string, int64, error) {
    resp, err := e.client.Get(ctx, e.key(key))
    if err != nil {
        return "", 0, fmt.Errorf("get %s: %w", key, err)
    }
    if len(resp.Kvs) == 0 {
        return "", resp.Header.Revision, ErrKeyNotFound
    }
    return string(resp.Kvs[0].Value), resp.Kvs[0].ModRevision, nil
}

func (e *Etcd) List(ctx context.Context, prefix string) (map[string]string, error) {
    resp, err := e.client.Get(ctx, e.key(prefix), clientv3.WithPrefix())
    if err != nil {
        return nil, fmt.Errorf("list %s: %w", prefix, err)
    }
    out := make(map[string]string, len(resp.Kvs))
    for _, kv := range resp.Kvs {
        out[string(kv.Key)] = string(kv.Value)
    }
    return out, nil
}

// ListKeys 只取 key，减少传输量。
func (e *Etcd) ListKeys(ctx context.Context, prefix string) ([]string, error) {
    resp, err := e.client.Get(ctx, e.key(prefix), clientv3.WithPrefix(), clientv3.WithKeysOnly())
    if err != nil {
        return nil, fmt.Errorf("list keys %s: %w", prefix, err)
    }
    keys := make([]string, 0, len(resp.Kvs))
    for _, kv := range resp.Kvs {
        keys = append(keys, string(kv.Key))
    }
    return keys, nil
}

func (e *Etcd) Exists(ctx context.Context, key string) (bool, error) {
    resp, err := e.client.Get(ctx, e.key(key), clientv3.WithCountOnly())
    if err != nil {
        return false, fmt.Errorf("exists %s: %w", key, err)
    }
    return resp.Count > 0, nil
}

func (e *Etcd) Count(ctx context.Context, prefix string) (int64, error) {
    resp, err := e.client.Get(ctx, e.key(prefix), clientv3.WithPrefix(), clientv3.WithCountOnly())
    if err != nil {
        return 0, fmt.Errorf("count %s: %w", prefix, err)
    }
    return resp.Count, nil
}

func (e *Etcd) Delete(ctx context.Context, key string) error {
    if _, err := e.client.Delete(ctx, e.key(key)); err != nil {
        return fmt.Errorf("delete %s: %w", key, err)
    }
    return nil
}

func (e *Etcd) DeleteWithPrefix(ctx context.Context, prefix string) (int64, error) {
    resp, err := e.client.Delete(ctx, e.key(prefix), clientv3.WithPrefix())
    if err != nil {
        return 0, fmt.Errorf("delete prefix %s: %w", prefix, err)
    }
    return resp.Deleted, nil
}
```

### 原子操作

```go
package etcdx

import (
    "context"
    "fmt"

    clientv3 "go.etcd.io/etcd/client/v3"
)

// CompareAndSwap 值相等时替换。
func (e *Etcd) CompareAndSwap(ctx context.Context, key, oldValue, newValue string) (bool, error) {
    resp, err := e.client.Txn(ctx).
        If(clientv3.Compare(clientv3.Value(e.key(key)), "=", oldValue)).
        Then(clientv3.OpPut(e.key(key), newValue)).
        Commit()
    if err != nil {
        return false, fmt.Errorf("cas %s: %w", key, err)
    }
    return resp.Succeeded, nil
}

// PutIfAbsent 不存在时创建（CreateRevision == 0 表示不存在）。
func (e *Etcd) PutIfAbsent(ctx context.Context, key, value string) (bool, error) {
    resp, err := e.client.Txn(ctx).
        If(clientv3.Compare(clientv3.CreateRevision(e.key(key)), "=", 0)).
        Then(clientv3.OpPut(e.key(key), value)).
        Commit()
    if err != nil {
        return false, fmt.Errorf("put if absent %s: %w", key, err)
    }
    return resp.Succeeded, nil
}

// PutIfRevision 乐观锁：只有 ModRevision 未变时才写入。
func (e *Etcd) PutIfRevision(ctx context.Context, key, value string, modRev int64) (bool, error) {
    resp, err := e.client.Txn(ctx).
        If(clientv3.Compare(clientv3.ModRevision(e.key(key)), "=", modRev)).
        Then(clientv3.OpPut(e.key(key), value)).
        Commit()
    if err != nil {
        return false, fmt.Errorf("put if revision %s: %w", key, err)
    }
    return resp.Succeeded, nil
}
```

---

## Watch 监听

### 事件模型

```go
package etcdx

import (
    clientv3 "go.etcd.io/etcd/client/v3"
)

type EventType int

const (
    EventPut EventType = iota
    EventDelete
)

// Event 是 clientv3.Event 的业务投影，Error 非 nil 表示 watch 中断。
type Event struct {
    Type     EventType
    Key      string
    Value    []byte // Delete 时为 nil
    Revision int64  // ModRevision
    Error    error
}

func fromClientEvent(ev *clientv3.Event) Event {
    out := Event{Key: string(ev.Kv.Key), Revision: ev.Kv.ModRevision}
    switch ev.Type {
    case clientv3.EventTypePut:
        out.Type = EventPut
        out.Value = ev.Kv.Value
    case clientv3.EventTypeDelete:
        out.Type = EventDelete
    }
    return out
}
```

### 基础 Watch（不自动重连）

```go
package etcdx

import (
    "context"

    clientv3 "go.etcd.io/etcd/client/v3"
)

// Watch 监听 key（或前缀），ctx 取消或 watch 被服务端取消时关闭返回的 channel。
// 生产环境优先使用 WatchWithRetry。
func (e *Etcd) Watch(ctx context.Context, key string, prefix bool, fromRev int64) <-chan Event {
    out := make(chan Event, 256)

    opts := []clientv3.OpOption{clientv3.WithPrevKV()}
    if prefix {
        opts = append(opts, clientv3.WithPrefix())
    }
    if fromRev > 0 {
        opts = append(opts, clientv3.WithRev(fromRev))
    }

    // WithRequireLeader：失去 leader 时立即报错，而不是静默挂起
    wch := e.client.Watch(clientv3.WithRequireLeader(ctx), e.key(key), opts...)

    go func() {
        defer close(out)
        for resp := range wch {
            if err := resp.Err(); err != nil {
                out <- Event{Error: err}
                return
            }
            for _, ev := range resp.Events {
                select {
                case out <- fromClientEvent(ev):
                case <-ctx.Done():
                    return
                }
            }
        }
    }()
    return out
}
```

### 带自动重连的 Watch

```go
package etcdx

import (
    "context"
    "errors"
    "log/slog"
    "math"
    "math/rand/v2"
    "time"

    "go.etcd.io/etcd/api/v3/v3rpc/rpctypes"
    clientv3 "go.etcd.io/etcd/client/v3"
)

type RetryConfig struct {
    InitialBackoff time.Duration // 默认 1s
    MaxBackoff     time.Duration // 默认 30s
    Multiplier     float64       // 默认 2.0
    MaxRetries     int           // 默认 0（无限）
    OnRetry        func(attempt int, err error, next time.Duration, lastRev int64)
}

func (c RetryConfig) withDefaults() RetryConfig {
    if c.InitialBackoff == 0 {
        c.InitialBackoff = time.Second
    }
    if c.MaxBackoff == 0 {
        c.MaxBackoff = 30 * time.Second
    }
    if c.Multiplier == 0 {
        c.Multiplier = 2.0
    }
    return c
}

func (c RetryConfig) backoff(attempt int) time.Duration {
    d := float64(c.InitialBackoff) * math.Pow(c.Multiplier, float64(attempt))
    d = min(d, float64(c.MaxBackoff))
    jitter := 1 + (rand.Float64()*0.2 - 0.1) // ±10%
    return time.Duration(d * jitter)
}

// WatchWithRetry 在 watch 中断后从最后一个已消费 revision + 1 续接。
// 遇到 ErrCompacted（历史已压缩）时从 CompactRevision 重新开始，并投递一条 Error 事件让调用方决定是否全量重载。
func (e *Etcd) WatchWithRetry(ctx context.Context, key string, prefix bool, fromRev int64, cfg RetryConfig) <-chan Event {
    cfg = cfg.withDefaults()
    out := make(chan Event, 256)

    go func() {
        defer close(out)
        nextRev := fromRev
        attempt := 0

        for {
            opts := []clientv3.OpOption{clientv3.WithPrevKV()}
            if prefix {
                opts = append(opts, clientv3.WithPrefix())
            }
            if nextRev > 0 {
                opts = append(opts, clientv3.WithRev(nextRev))
            }

            wctx, cancel := context.WithCancel(ctx)
            wch := e.client.Watch(clientv3.WithRequireLeader(wctx), e.key(key), opts...)

            var werr error
            for resp := range wch {
                if err := resp.Err(); err != nil {
                    werr = err
                    if errors.Is(err, rpctypes.ErrCompacted) && resp.CompactRevision > 0 {
                        nextRev = resp.CompactRevision
                    }
                    break
                }
                attempt = 0 // 收到正常响应，重置退避
                for _, ev := range resp.Events {
                    nextRev = ev.Kv.ModRevision + 1
                    select {
                    case out <- fromClientEvent(ev):
                    case <-ctx.Done():
                        cancel()
                        return
                    }
                }
            }
            cancel()

            if ctx.Err() != nil {
                return
            }
            if werr == nil {
                werr = errors.New("etcdx: watch channel closed")
            }
            if cfg.MaxRetries > 0 && attempt >= cfg.MaxRetries {
                out <- Event{Error: werr, Revision: nextRev}
                return
            }

            // 通知调用方（Compacted 时调用方通常需要全量 List 一次）
            select {
            case out <- Event{Error: werr, Revision: nextRev}:
            case <-ctx.Done():
                return
            }

            wait := cfg.backoff(attempt)
            if cfg.OnRetry != nil {
                cfg.OnRetry(attempt+1, werr, wait, nextRev)
            } else {
                slog.Warn("etcd watch interrupted, retrying",
                    slog.Int("attempt", attempt+1), slog.Duration("backoff", wait), slog.Any("error", werr))
            }
            attempt++

            select {
            case <-time.After(wait):
            case <-ctx.Done():
                return
            }
        }
    }()
    return out
}
```

### Watch 处理器

```go
package etcdx

import (
    "context"
    "log/slog"
)

type WatchHandler struct {
    OnPut    func(key string, value []byte, rev int64)
    OnDelete func(key string, rev int64)
    OnError  func(err error, lastRev int64) // 返回后继续等待重连
}

// WatchPrefixWithHandler 先 List 一次拿到基线 revision，再从该 revision 之后持续监听，
// 保证不漏事件也不重复。
func (e *Etcd) WatchPrefixWithHandler(ctx context.Context, prefix string, h WatchHandler) error {
    resp, err := e.client.Get(ctx, e.key(prefix), clientv3PrefixOpt())
    if err != nil {
        return err
    }
    for _, kv := range resp.Kvs {
        if h.OnPut != nil {
            h.OnPut(string(kv.Key), kv.Value, kv.ModRevision)
        }
    }

    for ev := range e.WatchWithRetry(ctx, prefix, true, resp.Header.Revision+1, RetryConfig{}) {
        switch {
        case ev.Error != nil:
            if h.OnError != nil {
                h.OnError(ev.Error, ev.Revision)
            } else {
                slog.Warn("watch error", slog.Any("error", ev.Error))
            }
        case ev.Type == EventPut && h.OnPut != nil:
            h.OnPut(ev.Key, ev.Value, ev.Revision)
        case ev.Type == EventDelete && h.OnDelete != nil:
            h.OnDelete(ev.Key, ev.Revision)
        }
    }
    return ctx.Err()
}
```

```go
package etcdx

import clientv3 "go.etcd.io/etcd/client/v3"

func clientv3PrefixOpt() clientv3.OpOption { return clientv3.WithPrefix() }
```

---

## 分布式锁

使用 `clientv3/concurrency`：Session 绑定租约并自动续约，Mutex 基于 revision 排队，无需自行实现。

### 基本锁

```go
package etcdx

import (
    "context"
    "errors"
    "fmt"
    "time"

    "go.etcd.io/etcd/client/v3/concurrency"
)

// Unlocker 释放锁并关闭 session。
type Unlocker func() error

// Lock 阻塞直到获得锁。ttl 为 session 租约秒数，持有者崩溃后锁在 ttl 内自动释放。
func (e *Etcd) Lock(ctx context.Context, name string, ttlSec int) (Unlocker, error) {
    session, err := concurrency.NewSession(e.client, concurrency.WithTTL(ttlSec), concurrency.WithContext(ctx))
    if err != nil {
        return nil, fmt.Errorf("create session: %w", err)
    }

    mutex := concurrency.NewMutex(session, e.key("/locks/"+name))
    if err := mutex.Lock(ctx); err != nil {
        _ = session.Close()
        return nil, fmt.Errorf("acquire lock %s: %w", name, err)
    }

    return func() error {
        defer session.Close()
        // 用独立 context 释放，避免调用方 ctx 已取消导致锁残留到 TTL 过期
        uctx, cancel := context.WithTimeout(context.WithoutCancel(ctx), 5*time.Second)
        defer cancel()
        return mutex.Unlock(uctx)
    }, nil
}

// TryLock 非阻塞；锁被占用时返回 (nil, false, nil)。
func (e *Etcd) TryLock(ctx context.Context, name string, ttlSec int) (Unlocker, bool, error) {
    session, err := concurrency.NewSession(e.client, concurrency.WithTTL(ttlSec), concurrency.WithContext(ctx))
    if err != nil {
        return nil, false, fmt.Errorf("create session: %w", err)
    }

    mutex := concurrency.NewMutex(session, e.key("/locks/"+name))
    if err := mutex.TryLock(ctx); err != nil {
        _ = session.Close()
        if errors.Is(err, concurrency.ErrLocked) {
            return nil, false, nil
        }
        return nil, false, fmt.Errorf("try lock %s: %w", name, err)
    }

    return func() error {
        defer session.Close()
        uctx, cancel := context.WithTimeout(context.WithoutCancel(ctx), 5*time.Second)
        defer cancel()
        return mutex.Unlock(uctx)
    }, true, nil
}

// LockWithTimeout 在 timeout 内未获得锁则放弃。
func (e *Etcd) LockWithTimeout(ctx context.Context, name string, ttlSec int, timeout time.Duration) (Unlocker, error) {
    lctx, cancel := context.WithTimeout(ctx, timeout)
    defer cancel()
    return e.Lock(lctx, name, ttlSec)
}
```

### 使用示例与守护

```go
package etcdx

import (
    "context"
    "fmt"
)

// WithLock 在锁保护下执行 fn；session 失效（Done）时取消 fn 的 ctx。
func (e *Etcd) WithLock(ctx context.Context, name string, ttlSec int, fn func(ctx context.Context) error) error {
    unlock, err := e.Lock(ctx, name, ttlSec)
    if err != nil {
        return err
    }
    defer func() { _ = unlock() }()

    return fn(ctx)
}

func exampleWithLock(ctx context.Context, e *Etcd) error {
    return e.WithLock(ctx, "order-settlement", 30, func(ctx context.Context) error {
        fmt.Println("settling orders under lock")
        return nil
    })
}
```

> `Mutex.IsOwner()` 返回 `clientv3.Cmp`，可放进 `Txn(...).If(...)`，让写操作只在仍持有锁时生效，
> 避免锁过期后的"双写"问题。

---

## 租约管理

### 创建与续租

```go
package etcdx

import (
    "context"
    "fmt"
    "log/slog"

    clientv3 "go.etcd.io/etcd/client/v3"
)

func (e *Etcd) GrantLease(ctx context.Context, ttlSec int64) (clientv3.LeaseID, error) {
    resp, err := e.client.Grant(ctx, ttlSec)
    if err != nil {
        return 0, fmt.Errorf("grant lease: %w", err)
    }
    return resp.ID, nil
}

// KeepAlive 持续续租，直到 ctx 取消或租约失效。返回的 channel 在续租终止时关闭。
// KeepAlive 响应 channel 必须被消费，否则客户端会打印告警并丢弃响应。
func (e *Etcd) KeepAlive(ctx context.Context, leaseID clientv3.LeaseID) (<-chan struct{}, error) {
    ch, err := e.client.KeepAlive(ctx, leaseID)
    if err != nil {
        return nil, fmt.Errorf("keepalive: %w", err)
    }

    done := make(chan struct{})
    go func() {
        defer close(done)
        for resp := range ch { // ctx 取消或租约过期时 ch 关闭
            if resp == nil {
                slog.Warn("lease expired", slog.Int64("lease", int64(leaseID)))
                return
            }
        }
        slog.Info("keepalive stopped", slog.Int64("lease", int64(leaseID)))
    }()
    return done, nil
}
```

### 服务注册

```go
package etcdx

import (
    "context"
    "fmt"
    "time"

    clientv3 "go.etcd.io/etcd/client/v3"
)

type Registration struct {
    etcd    *Etcd
    leaseID clientv3.LeaseID
    key     string
    Done    <-chan struct{} // 续租终止（租约失效）时关闭，调用方应重新注册
}

// Register 用租约注册实例；进程存活期间自动续租，退出时 Deregister 立即摘除。
func (e *Etcd) Register(ctx context.Context, service, instanceID, addr string, ttlSec int64) (*Registration, error) {
    leaseID, err := e.GrantLease(ctx, ttlSec)
    if err != nil {
        return nil, err
    }

    key := e.key(fmt.Sprintf("/services/%s/%s", service, instanceID))
    if _, err := e.client.Put(ctx, key, addr, clientv3.WithLease(leaseID)); err != nil {
        return nil, fmt.Errorf("register %s: %w", key, err)
    }

    done, err := e.KeepAlive(ctx, leaseID)
    if err != nil {
        return nil, err
    }

    return &Registration{etcd: e, leaseID: leaseID, key: key, Done: done}, nil
}

func (r *Registration) Deregister(ctx context.Context) error {
    dctx, cancel := context.WithTimeout(context.WithoutCancel(ctx), 5*time.Second)
    defer cancel()
    if _, err := r.etcd.client.Revoke(dctx, r.leaseID); err != nil {
        return fmt.Errorf("revoke lease: %w", err)
    }
    return nil
}

// Discover 列出服务的全部实例。
func (e *Etcd) Discover(ctx context.Context, service string) (map[string]string, error) {
    return e.List(ctx, fmt.Sprintf("/services/%s/", service))
}
```

---

## 选主（Leader Election）

```go
package etcdx

import (
    "context"
    "fmt"
    "time"

    "go.etcd.io/etcd/client/v3/concurrency"
)

type Election struct {
    session  *concurrency.Session
    election *concurrency.Election
}

// NewElection 创建选举参与者；Session TTL 决定 leader 失联后多久触发重新选举。
func (e *Etcd) NewElection(ctx context.Context, name string, ttlSec int) (*Election, error) {
    session, err := concurrency.NewSession(e.client, concurrency.WithTTL(ttlSec), concurrency.WithContext(ctx))
    if err != nil {
        return nil, fmt.Errorf("create session: %w", err)
    }
    return &Election{
        session:  session,
        election: concurrency.NewElection(session, e.key("/election/"+name)),
    }, nil
}

// Campaign 阻塞直到成为 leader（或 ctx 取消）。
func (el *Election) Campaign(ctx context.Context, value string) error {
    if err := el.election.Campaign(ctx, value); err != nil {
        return fmt.Errorf("campaign: %w", err)
    }
    return nil
}

// Done 在 session 失效（与 etcd 失联超过 TTL）时关闭，leader 必须据此停止工作。
func (el *Election) Done() <-chan struct{} { return el.session.Done() }

// Observe 观察 leader 变化，每次变更投递当前 leader 值。
func (el *Election) Observe(ctx context.Context) <-chan string {
    out := make(chan string, 1)
    go func() {
        defer close(out)
        for resp := range el.election.Observe(ctx) {
            if len(resp.Kvs) > 0 {
                select {
                case out <- string(resp.Kvs[0].Value):
                case <-ctx.Done():
                    return
                }
            }
        }
    }()
    return out
}

// Leader 查询当前 leader。
func (el *Election) Leader(ctx context.Context) (string, error) {
    resp, err := el.election.Leader(ctx)
    if err != nil {
        return "", err
    }
    if len(resp.Kvs) == 0 {
        return "", ErrNoLeader
    }
    return string(resp.Kvs[0].Value), nil
}

// Resign 主动让出 leader 并关闭 session。使用独立 context，保证原 ctx 已取消时仍能让出。
func (el *Election) Resign(ctx context.Context) error {
    rctx, cancel := context.WithTimeout(context.WithoutCancel(ctx), 5*time.Second)
    defer cancel()
    err := el.election.Resign(rctx)
    _ = el.session.Close()
    return err
}
```

### 选主使用示例

```go
package etcdx

import (
    "context"
    "log/slog"
    "time"
)

// RunAsLeader 竞选成功后执行 work；session 失效或 ctx 取消时退出并让出。
func (e *Etcd) RunAsLeader(ctx context.Context, name, instanceID string, work func(ctx context.Context) error) error {
    el, err := e.NewElection(ctx, name, 15)
    if err != nil {
        return err
    }
    defer func() { _ = el.Resign(ctx) }()

    if err := el.Campaign(ctx, instanceID); err != nil {
        return err
    }
    slog.Info("became leader", slog.String("election", name), slog.String("instance", instanceID))

    // leader 工作的 ctx 与 session 生命周期绑定
    wctx, cancel := context.WithCancel(ctx)
    defer cancel()
    go func() {
        select {
        case <-el.Done():
            slog.Warn("session lost, stepping down")
            cancel()
        case <-wctx.Done():
        }
    }()

    return work(wctx)
}

func exampleLeaderWork(ctx context.Context) error {
    ticker := time.NewTicker(time.Second)
    defer ticker.Stop()
    for {
        select {
        case <-ctx.Done():
            return ctx.Err()
        case <-ticker.C:
            slog.Info("leader tick")
        }
    }
}
```

---

## 事务

```go
package etcdx

import (
    "context"
    "fmt"

    clientv3 "go.etcd.io/etcd/client/v3"
)

// Txn 通用事务：全部条件成立时执行 thenOps，否则执行 elseOps。
func (e *Etcd) Txn(ctx context.Context, cmps []clientv3.Cmp, thenOps, elseOps []clientv3.Op) (*clientv3.TxnResponse, error) {
    resp, err := e.client.Txn(ctx).If(cmps...).Then(thenOps...).Else(elseOps...).Commit()
    if err != nil {
        return nil, fmt.Errorf("txn: %w", err)
    }
    return resp, nil
}

// PutMultiple 原子写入多个 key。
func (e *Etcd) PutMultiple(ctx context.Context, kvs map[string]string) error {
    ops := make([]clientv3.Op, 0, len(kvs))
    for k, v := range kvs {
        ops = append(ops, clientv3.OpPut(e.key(k), v))
    }
    _, err := e.Txn(ctx, nil, ops, nil)
    return err
}

// MoveKey 原子地把 src 的值改名到 dst：src 存在且 dst 不存在时才执行。
func (e *Etcd) MoveKey(ctx context.Context, src, dst string) (bool, error) {
    val, err := e.Get(ctx, src)
    if err != nil {
        return false, err
    }
    resp, err := e.Txn(ctx,
        []clientv3.Cmp{
            clientv3.Compare(clientv3.Value(e.key(src)), "=", val),
            clientv3.Compare(clientv3.CreateRevision(e.key(dst)), "=", 0),
        },
        []clientv3.Op{clientv3.OpPut(e.key(dst), val), clientv3.OpDelete(e.key(src))},
        nil,
    )
    if err != nil {
        return false, err
    }
    return resp.Succeeded, nil
}
```

### STM（软件事务内存）

多 key 读写依赖时用 `concurrency.NewSTM`，冲突自动重试：

```go
package etcdx

import (
    "context"
    "fmt"
    "strconv"

    "go.etcd.io/etcd/client/v3/concurrency"
)

// TransferQuota 从 from 转移 n 到 to，读写在同一快照内，冲突时自动重试。
func (e *Etcd) TransferQuota(ctx context.Context, from, to string, n int64) error {
    _, err := concurrency.NewSTM(e.client, func(stm concurrency.STM) error {
        fromVal, _ := strconv.ParseInt(stm.Get(e.key(from)), 10, 64)
        if fromVal < n {
            return fmt.Errorf("insufficient quota in %s", from)
        }
        toVal, _ := strconv.ParseInt(stm.Get(e.key(to)), 10, 64)
        stm.Put(e.key(from), strconv.FormatInt(fromVal-n, 10))
        stm.Put(e.key(to), strconv.FormatInt(toVal+n, 10))
        return nil
    }, concurrency.WithAbortContext(ctx), concurrency.WithIsolation(concurrency.SerializableSnapshot))
    return err
}
```

---

## 配置中心

```go
package etcdx

import (
    "context"
    "log/slog"
    "sync"
)

// ConfigCenter 本地缓存 + Watch 实时更新。
type ConfigCenter struct {
    etcd   *Etcd
    prefix string
    mu     sync.RWMutex
    values map[string]string
}

func NewConfigCenter(etcd *Etcd, prefix string) *ConfigCenter {
    return &ConfigCenter{etcd: etcd, prefix: prefix, values: make(map[string]string)}
}

// Run 加载基线并持续监听，阻塞直到 ctx 取消。Compacted 等错误后自动全量重载。
func (c *ConfigCenter) Run(ctx context.Context) error {
    return c.etcd.WatchPrefixWithHandler(ctx, c.prefix, WatchHandler{
        OnPut: func(key string, value []byte, _ int64) {
            c.mu.Lock()
            c.values[key] = string(value)
            c.mu.Unlock()
            slog.Info("config updated", slog.String("key", key))
        },
        OnDelete: func(key string, _ int64) {
            c.mu.Lock()
            delete(c.values, key)
            c.mu.Unlock()
            slog.Info("config deleted", slog.String("key", key))
        },
        OnError: func(err error, _ int64) {
            slog.Warn("config watch interrupted, reloading", slog.Any("error", err))
            if err := c.reload(ctx); err != nil {
                slog.Error("config reload failed", slog.Any("error", err))
            }
        },
    })
}

func (c *ConfigCenter) reload(ctx context.Context) error {
    all, err := c.etcd.List(ctx, c.prefix)
    if err != nil {
        return err
    }
    c.mu.Lock()
    c.values = all
    c.mu.Unlock()
    return nil
}

func (c *ConfigCenter) Get(key string) (string, bool) {
    c.mu.RLock()
    defer c.mu.RUnlock()
    v, ok := c.values[c.etcd.key(key)]
    return v, ok
}
```
