---
name: etcd-go
description: "Go etcd 专家 - KV 存储、Watch 监听、分布式锁、租约管理、选主、事务、配置中心。适用：服务发现与注册、分布式配置中心、分布式锁与协调、选主（leader election）、少量关键元数据存储。不适用：大量数据存储（etcd 上限约 8GB）、高频写入场景（Raft 共识写入延迟高）、缓存场景（应使用 Redis）。触发词：etcd, distributed lock, leader election, watch, lease, service discovery, 分布式锁, 选主, 配置中心, 服务发现, KV"
user-invocable: true
allowed-tools: Bash, Read, Write, Edit, Grep, Glob
---

# Go etcd 专家

使用 Go etcd client 开发分布式协调功能：$ARGUMENTS

---

## 1. 客户端管理

### 配置与创建

```go
type Config struct {
    Endpoints            []string      // 必需: ["host1:2379", "host2:2379"]
    Username             string        // 可选: 认证用户名
    Password             string        // 可选: 认证密码
    DialTimeout          time.Duration // 默认: 5s
    DialKeepAliveTime    time.Duration // 默认: 10s
    DialKeepAliveTimeout time.Duration // 默认: 3s
    AutoSyncInterval     time.Duration // 默认: 0（禁用）
    RejectOldCluster     bool          // 默认: true（安全默认）
    PermitWithoutStream  bool          // 默认: true（保活）
}

func DefaultConfig() *Config
func (c *Config) Validate() error  // 校验 host:port 格式（支持 IPv4/IPv6/域名）
```

### 客户端结构

```go
type Client struct {
    client    etcdClient       // 接口，支持 mock 测试
    rawClient *clientv3.Client // 高级操作时直接使用
    config    *Config
    closed    atomic.Bool
}

func NewClient(config *Config, opts ...Option) (*Client, error)
func (c *Client) RawClient() *clientv3.Client  // 获取底层客户端
func (c *Client) Close() error

// 选项
WithContext(ctx context.Context) Option
WithHealthCheck(enabled bool, timeout time.Duration) Option
WithTLS(config *tls.Config) Option
```

---

## 2. KV 操作

### 基本 CRUD

```go
func (c *Client) Get(ctx context.Context, key string) ([]byte, error)
func (c *Client) GetWithRevision(ctx context.Context, key string) ([]byte, int64, error)
func (c *Client) Put(ctx context.Context, key string, value []byte) error
func (c *Client) PutWithTTL(ctx context.Context, key string, value []byte, ttl time.Duration) error
func (c *Client) Delete(ctx context.Context, key string) error
func (c *Client) DeleteWithPrefix(ctx context.Context, prefix string) (int64, error)
```

### 查询操作

```go
func (c *Client) List(ctx context.Context, prefix string) (map[string][]byte, error)
func (c *Client) ListKeys(ctx context.Context, prefix string) ([]string, error)
func (c *Client) Exists(ctx context.Context, key string) (bool, error)
func (c *Client) Count(ctx context.Context, prefix string) (int64, error)
```

### PutWithTTL 实现原理

```go
// 内部: Grant lease → Put with lease → 失败时 Revoke lease 清理
func (c *Client) PutWithTTL(ctx context.Context, key string, value []byte, ttl time.Duration) error {
    lease, err := c.client.Grant(ctx, int64(ttl.Seconds()))
    // ...
    _, err = c.client.Put(ctx, key, string(value), clientv3.WithLease(lease.ID))
    // 失败时自动清理: c.tryRevokeLease(lease.ID)
}
```

---

## 3. Watch 监听

### Event 类型

```go
type EventType int
const (
    EventPut    EventType = iota
    EventDelete
)

type Event struct {
    Type            EventType
    Key             string
    Value           []byte        // DELETE 时为 nil
    Revision        int64         // ModRevision
    CompactRevision int64         // etcd 压缩版本
    Error           error         // 非 nil 表示故障
}
```

### Watch 方法

```go
// 基础 Watch（不自动重连）
func (c *Client) Watch(ctx context.Context, key string, opts ...WatchOption) (<-chan Event, error)

// 带自动重连的 Watch（推荐生产环境使用）
func (c *Client) WatchWithRetry(ctx context.Context, key string, cfg RetryConfig, opts ...WatchOption) (<-chan Event, error)
```

### Watch 选项

```go
WithPrefix() WatchOption                   // 前缀匹配
WithRevision(rev int64) WatchOption        // 从指定 revision 开始
WithBufferSize(size int) WatchOption       // channel 缓冲区大小（默认 256）
```

### 重试配置

```go
type RetryConfig struct {
    InitialBackoff    time.Duration // 默认: 1s
    MaxBackoff        time.Duration // 默认: 30s
    BackoffMultiplier float64       // 默认: 2.0
    MaxRetries        int           // 默认: 0（无限重试）
    OnRetry           func(attempt int, err error, nextBackoff time.Duration, lastRevision int64)
}

func DefaultRetryConfig() RetryConfig
```

---

## 4. 分布式锁

xetcd 本身**不内置分布式锁**。两种方式实现：

### 方式一：使用 xdlock 包（推荐）

```go
// xdlock 是独立的分布式锁包，支持 etcd 后端
lock := xdlock.New(etcdClient, "resource-key", xdlock.WithTTL(10*time.Second))
err := lock.Lock(ctx)
defer lock.Unlock(ctx)
```

### 方式二：通过 RawClient 使用 concurrency 包

```go
session, err := concurrency.NewSession(client.RawClient(), concurrency.WithTTL(10))
defer session.Close()
mutex := concurrency.NewMutex(session, "/locks/resource")
err = mutex.Lock(ctx)
defer mutex.Unlock(context.Background())  // 使用独立 context 释放锁
```

---

## 5. 租约管理

### 通过 PutWithTTL 使用（简单场景）

```go
// 服务注册：key 会在 TTL 后自动过期
client.PutWithTTL(ctx, "/services/myapp/instance1", []byte("addr:port"), 10*time.Second)
```

### 通过 RawClient 手动管理（高级场景）

```go
raw := client.RawClient()
lease, _ := raw.Grant(ctx, 30)           // 创建 30s 租约
ch, _ := raw.KeepAlive(ctx, lease.ID)    // 自动续租
// 必须 drain ch 防止泄漏
go func() { for range ch {} }()
```

---

## 6. 选主（Leader Election）

通过 RawClient 使用 concurrency 包：

```go
raw := client.RawClient()
session, _ := concurrency.NewSession(raw, concurrency.WithTTL(15))
election := concurrency.NewElection(session, "/election/leader")

// 参与选举（阻塞直到成为 leader）
err := election.Campaign(ctx, "my-instance-id")

// 观察 leader 变化
ch := election.Observe(ctx)

// 获取当前 leader
resp, _ := election.Leader(ctx)

// 主动放弃
election.Resign(context.Background())  // 使用独立 context
```

---

## 7. 事务

通过 RawClient 使用 Txn API：

```go
raw := client.RawClient()

// CAS (Compare-And-Swap)
resp, err := raw.Txn(ctx).
    If(clientv3.Compare(clientv3.Value("key"), "=", "old-value")).
    Then(clientv3.OpPut("key", "new-value")).
    Else(clientv3.OpGet("key")).
    Commit()

// 不存在则创建
resp, err := raw.Txn(ctx).
    If(clientv3.Compare(clientv3.CreateRevision("key"), "=", 0)).
    Then(clientv3.OpPut("key", "value")).
    Commit()
```

---

## 8. 错误处理

```go
var (
    ErrNilConfig       = errors.New("xetcd: config is nil")
    ErrNoEndpoints     = errors.New("xetcd: no endpoints configured")
    ErrInvalidEndpoint = errors.New("xetcd: invalid endpoint format")
    ErrKeyNotFound     = errors.New("xetcd: key not found")
    ErrClientClosed    = errors.New("xetcd: client is closed")
    ErrEmptyKey        = errors.New("xetcd: key is empty")
)

func IsKeyNotFound(err error) bool
func IsClientClosed(err error) bool
```

---

## 最佳实践

### 连接管理
- 使用多个 endpoints 实现高可用
- 配置合理的 DialTimeout
- 启用 HealthCheck 验证连接

### Key 设计
- 使用前缀组织 key（如 `/app/config/`）
- 避免 key 过长
- 使用目录结构表达层级关系

### Watch
- 生产环境使用 `WatchWithRetry`
- 配置 `OnRetry` 回调监控重连情况
- Error Event 包含 Revision 用于恢复

### 分布式锁
- 使用 xdlock 或 concurrency 包，不要手动实现
- unlock 使用独立 context（`context.Background()`），避免原始 ctx 取消后无法释放
- 设置合理的锁 TTL

---

## 检查清单

- [ ] 配置多个 endpoints？
- [ ] 正确处理连接超时？
- [ ] Key 使用前缀组织？
- [ ] Watch 使用 WatchWithRetry？
- [ ] 分布式锁释放使用独立 context？
- [ ] PutWithTTL 用于临时数据？
- [ ] 事务用 RawClient Txn API？
- [ ] 优雅关闭客户端？

## 参考资料

- [完整代码实现](references/examples.md) - KV 操作、Watch、分布式锁、租约、选主、事务、配置中心的完整 Go 实现
