---
name: etcd-go
description: "Go etcd 专家 - 使用 etcd client v3 进行 KV 存储、Watch 监听（revision 续接、Compacted 处理、自动重连）、分布式锁与选主（clientv3/concurrency Session/Mutex/Election）、租约管理与服务注册、事务与 STM、配置中心。适用：服务发现与注册、分布式配置中心、分布式锁与协调、选主（leader election）、少量关键元数据存储。不适用：大量数据存储（etcd 上限约 8GB）、高频写入场景（Raft 共识写入延迟高）、缓存场景（应使用 Redis）。触发词：etcd, distributed lock, leader election, watch, lease, service discovery, 分布式锁, 选主, 配置中心, 服务发现, KV, concurrency, STM"
---

# Go etcd 专家

使用 Go etcd client 开发分布式协调功能：$ARGUMENTS

---

## 0. 版本与依赖

基线 go1.24.6。go.mod：

```text
go.etcd.io/etcd/client/v3 v3.6.8
go.etcd.io/etcd/api/v3 v3.6.8   // rpctypes 错误值（ErrCompacted 等）
```

直接使用 `*clientv3.Client` 与 `clientv3/concurrency`，只在业务层做 key 前缀拼接的轻量封装。

---

## 1. 客户端管理

```go
package etcdx

import (
    "context"
    "fmt"
    "time"

    clientv3 "go.etcd.io/etcd/client/v3"
)

func NewClient(ctx context.Context, endpoints []string) (*clientv3.Client, error) {
    client, err := clientv3.New(clientv3.Config{
        Endpoints:            endpoints, // 多个 endpoint 实现高可用
        DialTimeout:          5 * time.Second,
        DialKeepAliveTime:    10 * time.Second,
        DialKeepAliveTimeout: 3 * time.Second,
        PermitWithoutStream:  true, // 空闲时也发 keepalive
        RejectOldCluster:     true, // 拒绝不支持 v3 API 的旧集群
        // Username / Password / TLS 按需设置
        Context: ctx,
    })
    if err != nil {
        return nil, fmt.Errorf("create etcd client: %w", err)
    }

    hctx, cancel := context.WithTimeout(ctx, 5*time.Second)
    defer cancel()
    if _, err := client.Status(hctx, endpoints[0]); err != nil {
        _ = client.Close()
        return nil, fmt.Errorf("check etcd status: %w", err)
    }
    return client, nil
}
```

轻量封装只做前缀拼接，不隐藏 clientv3 API：

```go
package etcdx

import clientv3 "go.etcd.io/etcd/client/v3"

type Etcd struct {
    client *clientv3.Client
    prefix string
}

func New(client *clientv3.Client, prefix string) *Etcd { return &Etcd{client: client, prefix: prefix} }
func (e *Etcd) Client() *clientv3.Client               { return e.client }
func (e *Etcd) key(k string) string                    { return e.prefix + k }
```

> 配置校验、健康检查见 [references/examples.md](references/examples.md#客户端管理)

---

## 2. KV 操作

```go
package etcdx

import (
    "context"
    "errors"
    "fmt"
    "time"

    clientv3 "go.etcd.io/etcd/client/v3"
)

var ErrKeyNotFound = errors.New("etcdx: key not found")

func (e *Etcd) Get(ctx context.Context, key string) (string, error) {
    resp, err := e.client.Get(ctx, e.key(key))
    if err != nil {
        return "", fmt.Errorf("get %s: %w", key, err)
    }
    if len(resp.Kvs) == 0 { // etcd 不返回 not-found 错误，靠 Kvs 为空判断
        return "", ErrKeyNotFound
    }
    return string(resp.Kvs[0].Value), nil
}

// PutWithTTL：Grant 租约 → Put 绑定租约 → Put 失败时 Revoke 清理
func (e *Etcd) PutWithTTL(ctx context.Context, key, value string, ttl time.Duration) error {
    lease, err := e.client.Grant(ctx, int64(ttl.Seconds()))
    if err != nil {
        return fmt.Errorf("grant lease: %w", err)
    }
    if _, err := e.client.Put(ctx, e.key(key), value, clientv3.WithLease(lease.ID)); err != nil {
        rctx, cancel := context.WithTimeout(context.WithoutCancel(ctx), 3*time.Second)
        defer cancel()
        _, _ = e.client.Revoke(rctx, lease.ID)
        return fmt.Errorf("put %s: %w", key, err)
    }
    return nil
}
```

常用选项：

| 选项 | 用途 |
|------|------|
| `clientv3.WithPrefix()` | 前缀查询 / 删除 / 监听 |
| `clientv3.WithKeysOnly()` | 只返回 key |
| `clientv3.WithCountOnly()` | 只返回数量（Exists / Count） |
| `clientv3.WithLease(id)` | Put 绑定租约 |
| `clientv3.WithRev(rev)` | 从指定 revision 读取 / 监听 |
| `clientv3.WithSerializable()` | 本地读，牺牲线性一致换延迟 |

> CRUD、List、CAS、PutIfAbsent、乐观锁见 [references/examples.md](references/examples.md#kv-操作)

---

## 3. Watch 监听

### 基础 Watch

```go
package etcdx

import (
    "context"
    "log/slog"

    clientv3 "go.etcd.io/etcd/client/v3"
)

func (e *Etcd) watchOnce(ctx context.Context, prefix string, fromRev int64) {
    wch := e.client.Watch(clientv3.WithRequireLeader(ctx), e.key(prefix),
        clientv3.WithPrefix(), clientv3.WithRev(fromRev), clientv3.WithPrevKV())
    for resp := range wch {
        if err := resp.Err(); err != nil { // Canceled / Compacted / 失去 leader
            slog.Warn("watch interrupted", slog.Any("error", err), slog.Int64("compact_rev", resp.CompactRevision))
            return
        }
        for _, ev := range resp.Events {
            switch ev.Type {
            case clientv3.EventTypePut:
                slog.Info("put", slog.String("key", string(ev.Kv.Key)), slog.Int64("rev", ev.Kv.ModRevision))
            case clientv3.EventTypeDelete:
                slog.Info("delete", slog.String("key", string(ev.Kv.Key)))
            }
        }
    }
}
```

### 可靠 Watch 三要素

1. **先 List 后 Watch**：`Get` 拿到 `resp.Header.Revision`，从 `Revision+1` 开始 `WithRev`，不漏不重。
2. **续接**：每处理一个事件记录 `ev.Kv.ModRevision + 1`，中断后从该 revision 重建 watch。
3. **Compacted**：`errors.Is(resp.Err(), rpctypes.ErrCompacted)` 时历史已被压缩，从 `resp.CompactRevision`
   重新 watch，并全量 List 一次修正本地状态。

`WithRequireLeader(ctx)` 让失去 leader 时立即报错而不是静默挂起。重连用指数退避 + 抖动。

> `WatchWithRetry`、`WatchPrefixWithHandler` 见 [references/examples.md](references/examples.md#watch-监听)

---

## 4. 分布式锁

使用 `clientv3/concurrency`，不要手写锁：Session 绑定租约自动续约，Mutex 按 revision 排队保证公平。

```go
package etcdx

import (
    "context"
    "errors"
    "fmt"
    "time"

    "go.etcd.io/etcd/client/v3/concurrency"
)

func (e *Etcd) Lock(ctx context.Context, name string, ttlSec int) (unlock func() error, err error) {
    session, err := concurrency.NewSession(e.client, concurrency.WithTTL(ttlSec), concurrency.WithContext(ctx))
    if err != nil {
        return nil, fmt.Errorf("create session: %w", err)
    }
    mutex := concurrency.NewMutex(session, e.key("/locks/"+name))
    if err := mutex.Lock(ctx); err != nil { // TryLock 非阻塞，占用时返回 concurrency.ErrLocked
        _ = session.Close()
        return nil, fmt.Errorf("acquire lock: %w", err)
    }
    return func() error {
        defer session.Close()
        // 独立 context 释放，避免调用方 ctx 已取消导致锁残留到 TTL 过期
        uctx, cancel := context.WithTimeout(context.WithoutCancel(ctx), 5*time.Second)
        defer cancel()
        return mutex.Unlock(uctx)
    }, nil
}

func isLocked(err error) bool { return errors.Is(err, concurrency.ErrLocked) }
```

要点：

- 持有者崩溃后锁在 Session TTL 内自动释放；TTL 过短会因网络抖动误释放
- `session.Done()` 关闭表示租约失效，锁内工作应随之取消
- 写操作放进 `Txn(...).If(mutex.IsOwner())`，防止锁过期后的双写

> TryLock、LockWithTimeout、WithLock 见 [references/examples.md](references/examples.md#分布式锁)

---

## 5. 租约管理

```go
package etcdx

import (
    "context"
    "log/slog"

    clientv3 "go.etcd.io/etcd/client/v3"
)

// 服务注册：Put 绑定租约 + KeepAlive 续租；进程退出 Revoke 立即摘除
func (e *Etcd) Register(ctx context.Context, key, addr string, ttlSec int64) (clientv3.LeaseID, error) {
    lease, err := e.client.Grant(ctx, ttlSec)
    if err != nil {
        return 0, err
    }
    if _, err := e.client.Put(ctx, e.key(key), addr, clientv3.WithLease(lease.ID)); err != nil {
        return 0, err
    }
    ch, err := e.client.KeepAlive(ctx, lease.ID)
    if err != nil {
        return 0, err
    }
    go func() {
        for resp := range ch { // 必须消费，否则客户端丢弃响应并告警
            if resp == nil {
                slog.Warn("lease expired", slog.Int64("lease", int64(lease.ID)))
                return
            }
        }
    }()
    return lease.ID, nil
}
```

- 简单临时数据用 `PutWithTTL`（一次性租约，不续租）
- 需要"存活即注册"用 `KeepAlive`；channel 关闭说明租约失效，需要重新注册
- 一个租约可绑定多个 key，`Revoke` 时一并删除

> 完整注册/发现见 [references/examples.md](references/examples.md#租约管理)

---

## 6. 选主（Leader Election）

```go
package etcdx

import (
    "context"

    "go.etcd.io/etcd/client/v3/concurrency"
)

func (e *Etcd) campaign(ctx context.Context, name, instanceID string, work func(ctx context.Context) error) error {
    session, err := concurrency.NewSession(e.client, concurrency.WithTTL(15), concurrency.WithContext(ctx))
    if err != nil {
        return err
    }
    defer session.Close()

    election := concurrency.NewElection(session, e.key("/election/"+name))
    if err := election.Campaign(ctx, instanceID); err != nil { // 阻塞直到成为 leader
        return err
    }
    defer func() { _ = election.Resign(context.WithoutCancel(ctx)) }()

    wctx, cancel := context.WithCancel(ctx)
    defer cancel()
    go func() { // session 失效（失联超过 TTL）时停止 leader 工作
        select {
        case <-session.Done():
            cancel()
        case <-wctx.Done():
        }
    }()
    return work(wctx)
}
```

| 方法 | 用途 |
|------|------|
| `election.Campaign(ctx, val)` | 参选，阻塞直到当选 |
| `election.Observe(ctx)` | 观察 leader 变化（`<-chan GetResponse`） |
| `election.Leader(ctx)` | 查询当前 leader |
| `election.Resign(ctx)` | 主动让出，用独立 context |
| `election.Proclaim(ctx, val)` | 更新 leader 携带的值 |

> 完整 Election 封装与 RunAsLeader 见 [references/examples.md](references/examples.md#选主leader-election)

---

## 7. 事务

```go
package etcdx

import (
    "context"

    clientv3 "go.etcd.io/etcd/client/v3"
)

// CAS：值相等时替换
func (e *Etcd) CompareAndSwap(ctx context.Context, key, oldVal, newVal string) (bool, error) {
    resp, err := e.client.Txn(ctx).
        If(clientv3.Compare(clientv3.Value(e.key(key)), "=", oldVal)).
        Then(clientv3.OpPut(e.key(key), newVal)).
        Else(clientv3.OpGet(e.key(key))).
        Commit()
    if err != nil {
        return false, err
    }
    return resp.Succeeded, nil
}

// 不存在则创建：CreateRevision == 0
func (e *Etcd) PutIfAbsent(ctx context.Context, key, val string) (bool, error) {
    resp, err := e.client.Txn(ctx).
        If(clientv3.Compare(clientv3.CreateRevision(e.key(key)), "=", 0)).
        Then(clientv3.OpPut(e.key(key), val)).
        Commit()
    if err != nil {
        return false, err
    }
    return resp.Succeeded, nil
}
```

- 比较目标：`Value`、`CreateRevision`、`ModRevision`、`Version`、`LeaseValue`
- 多 key 读写依赖用 `concurrency.NewSTM`（冲突自动重试，`WithIsolation(concurrency.SerializableSnapshot)`）
- 单事务操作数受 `--max-txn-ops`（默认 128）限制

> 通用 Txn、MoveKey、STM 见 [references/examples.md](references/examples.md#事务)

---

## 8. 错误处理

```go
package etcdx

import (
    "context"
    "errors"

    "go.etcd.io/etcd/api/v3/v3rpc/rpctypes"
)

func classify(err error) string {
    switch {
    case err == nil:
        return "ok"
    case errors.Is(err, context.DeadlineExceeded), errors.Is(err, context.Canceled):
        return "client-timeout" // 调用方 ctx 到期
    case errors.Is(err, rpctypes.ErrCompacted):
        return "compacted" // watch/read 的 revision 已被压缩，需要重新 List
    case errors.Is(err, rpctypes.ErrLeaseNotFound):
        return "lease-expired" // 租约已失效，重新 Grant + Put
    case errors.Is(err, rpctypes.ErrNoLeader):
        return "no-leader" // 集群选举中，退避重试
    case errors.Is(err, rpctypes.ErrTooManyRequests):
        return "overloaded"
    default:
        return "unknown"
    }
}
```

`rpctypes` 错误已实现 `Is`，客户端返回的 gRPC 错误可直接用 `errors.Is` 匹配。

---

## 最佳实践

### 连接管理
- 多个 endpoints；`AutoSyncInterval` 让客户端自动跟随成员变更
- 全局共享一个 `*clientv3.Client`，退出时 `Close`

### Key 设计
- 前缀组织（`/app/config/`、`/services/<name>/<instance>`），前缀以 `/` 结尾避免误匹配
- 单值不超过 1.5MB（默认请求上限）；大对象拆分或改用对象存储

### Watch
- 先 List 后 Watch，记录 revision 续接
- 处理 `ErrCompacted`：全量重载后从 `CompactRevision` 继续
- 生产环境使用带退避的重连循环

### 分布式锁与选主
- 只用 `concurrency` 包；TTL 覆盖最长网络抖动
- 释放锁 / Resign 用独立 context
- 关键写操作附带 `IsOwner()` 条件

---

## 检查清单

- [ ] 配置多个 endpoints 与 DialTimeout？
- [ ] Key 使用前缀组织？
- [ ] Watch 先 List 再从 revision+1 续接？
- [ ] 处理 Compacted 与自动重连？
- [ ] 锁 / Resign 释放使用独立 context？
- [ ] KeepAlive channel 被消费？
- [ ] 事务条件覆盖并发写入场景？
- [ ] 优雅关闭客户端？

## 参考资料

- [references/examples.md](references/examples.md) - KV、Watch、分布式锁、租约、选主、事务、STM、配置中心完整实现
- [clientv3 文档](https://pkg.go.dev/go.etcd.io/etcd/client/v3)
- [concurrency 包文档](https://pkg.go.dev/go.etcd.io/etcd/client/v3/concurrency)
- [etcd 官方文档](https://etcd.io/docs/)
