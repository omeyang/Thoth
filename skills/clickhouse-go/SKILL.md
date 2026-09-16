---
name: clickhouse-go
description: "Go ClickHouse OLAP 分析专家 - 表引擎选择、查询优化、批量插入、分页查询、聚合分析、数据管理。适用：大规模数据分析（OLAP）、日志分析、用户行为分析、实时报表、时序数据存储、列式存储高压缩场景。不适用：频繁单行更新/删除的 OLTP 场景（用 PostgreSQL/MySQL）、需要事务和强一致性的业务系统、数据量小于百万行的简单查询。触发词：clickhouse, OLAP, 列式存储, MergeTree, 聚合, 批量插入, 分区, TTL, 物化视图, 宽表"
user-invocable: true
allowed-tools: Bash, Read, Write, Edit, Grep, Glob
---

# Go ClickHouse 专家

使用 Go clickhouse-go 开发 ClickHouse 功能：$ARGUMENTS

---

## 1. 连接管理

### 创建连接

```go
func NewClickHouse(ctx context.Context, dsn string) (driver.Conn, error)
```

- 解析 DSN，配置连接池（MaxOpenConns=10, MaxIdleConns=5）
- 设置超时（DialTimeout=5s, ReadTimeout=30s）
- 验证 Ping

### 包装器模式

```go
type ClickHouse struct { conn driver.Conn }
func New(conn driver.Conn) *ClickHouse
func (c *ClickHouse) Conn() driver.Conn
func (c *ClickHouse) Health(ctx context.Context) error
func (c *ClickHouse) Close() error
```

> 完整实现见 [references/examples.md](references/examples.md#1-连接管理)

---

## 2. 表引擎选择

| 引擎 | 适用场景 | 特点 |
|------|---------|------|
| MergeTree | 通用 OLAP、时序、日志 | 最常用，支持分区/TTL/索引 |
| ReplacingMergeTree | 有重复数据 | 按版本号去重，查询用 FINAL |
| AggregatingMergeTree | 实时统计、仪表盘 | 配合物化视图预聚合 |
| SummingMergeTree | 计数器、累加统计 | 自动求和指定列 |

> 完整 DDL 示例见 [references/examples.md](references/examples.md#2-表引擎选择)

---

## 3. 查询操作

### 基本查询

```go
func (c *ClickHouse) Query(ctx context.Context, query string, args ...any) ([]map[string]any, error)
```

### 结构体查询

```go
type Event struct {
    Date      time.Time `ch:"event_date"`
    Time      time.Time `ch:"event_time"`
    UserID    uint64    `ch:"user_id"`
    EventType string    `ch:"event_type"`
}

func (c *ClickHouse) QueryEvents(ctx context.Context, userID uint64, limit int) ([]Event, error) {
    var events []Event
    err := c.conn.Select(ctx, &events, `
        SELECT event_date, event_time, user_id, event_type
        FROM events WHERE user_id = ? ORDER BY event_time DESC LIMIT ?
    `, userID, limit)
    return events, err
}
```

### 分页查询

```go
type PageOptions struct { Page, PageSize int64; OrderBy string }
type PageResult[T any] struct { Data []T; Total, Page, PageSize, TotalPages int64 }

func (c *ClickHouse) QueryPage[T any](ctx context.Context, baseQuery string, opts PageOptions, args ...any) (*PageResult[T], error)
```

- 使用 `validateOrderBy()` 白名单防止 SQL 注入
- 先 count 后分页

> 完整实现见 [references/examples.md](references/examples.md#3-查询操作)

---

## 4. 批量插入

### 使用 Batch

```go
func (c *ClickHouse) BatchInsert(ctx context.Context, table string, data []Event) error {
    batch, err := c.conn.PrepareBatch(ctx, fmt.Sprintf("INSERT INTO %s", table))
    // ... batch.Append() + batch.Send()
}
```

### 分批插入（大数据量）

```go
func (c *ClickHouse) BatchInsertChunked(ctx context.Context, table string, data []Event, chunkSize int) error
```

- 按 chunkSize 分批调用 BatchInsert
- 每批检查 ctx 取消

> 完整实现见 [references/examples.md](references/examples.md#4-批量插入)

---

## 5. 聚合查询

### 常用聚合函数

- 基础：`count()`, `uniq()`, `sum()`, `avg()`, `min()`, `max()`
- 分位数：`quantile(0.95)(col)`, `quantilesExact(0.50, 0.95, 0.99)(col)`
- TopK：`topK(10)(col)`, `topKWeighted(10)(col, weight)`

### 窗口函数

- 累计求和：`sum(value) OVER (ORDER BY date)`
- 排名：`rank() OVER (ORDER BY score DESC)`
- 移动平均：`avg(value) OVER (ORDER BY date ROWS BETWEEN 6 PRECEDING AND CURRENT ROW)`

> 完整 SQL 示例见 [references/examples.md](references/examples.md#5-聚合查询)

---

## 6. 查询优化

### 索引策略

```sql
-- 跳数索引
ALTER TABLE events ADD INDEX idx_event_type event_type TYPE set(100) GRANULARITY 4;
-- 布隆过滤器（高基数列）
ALTER TABLE events ADD INDEX idx_user_id user_id TYPE bloom_filter() GRANULARITY 4;
```

### 优化技巧

- 使用 `PREWHERE` 在主键过滤后进一步过滤
- 使用 `IN` 替代多个 `OR`
- 使用 `LIMIT BY` 分组限制
- 避免 `SELECT *`
- 使用物化列减少计算

> 完整示例见 [references/examples.md](references/examples.md#6-查询优化)

---

## 7. 数据管理

### TTL 自动过期

```sql
-- 行级 TTL
ALTER TABLE events MODIFY TTL event_date + INTERVAL 90 DAY;
-- 列级 TTL
ALTER TABLE events MODIFY COLUMN properties String TTL event_date + INTERVAL 30 DAY;
-- 冷热分层
ALTER TABLE events MODIFY TTL event_date + INTERVAL 7 DAY TO VOLUME 'hot',
                              event_date + INTERVAL 30 DAY TO VOLUME 'cold';
```

### 分区管理

```sql
-- 查看/删除/分离/附加分区
SELECT partition, name, rows, bytes_on_disk FROM system.parts WHERE table = 'events' AND active;
ALTER TABLE events DROP PARTITION '202401';
```

### 数据去重

```sql
OPTIMIZE TABLE events FINAL DEDUPLICATE;
OPTIMIZE TABLE events FINAL DEDUPLICATE BY user_id, event_type;
```

---

## 8. 最佳实践

### Schema 设计

Go 结构体与 ClickHouse 类型映射：

| Go 类型 | ClickHouse 类型 | 说明 |
|---------|----------------|------|
| `time.Time` | Date / DateTime | 日期时间 |
| `uint64` | UInt64 | 无符号整数 |
| `string` | String / LowCardinality(String) | 低基数用 LC |
| `[]string` | Array(String) | 数组 |
| `*string` | Nullable(String) | 可空 |

### 连接池配置

- 多节点地址：`Addr: []string{"ch1:9000", "ch2:9000"}`
- 启用压缩：`Compression: &clickhouse.Compression{Method: clickhouse.CompressionLZ4}`

> 完整代码见 [references/examples.md](references/examples.md#8-最佳实践)

---

## 常用命令

```bash
# 连接 ClickHouse
clickhouse-client -h localhost -u default

# 查看表大小
SELECT table, formatReadableSize(sum(bytes)) AS size, sum(rows) AS rows
FROM system.parts WHERE active GROUP BY table ORDER BY sum(bytes) DESC;

# 查看慢查询
SELECT query, query_duration_ms, read_rows, read_bytes
FROM system.query_log WHERE type = 'QueryFinish' AND query_duration_ms > 1000
ORDER BY query_duration_ms DESC LIMIT 10;
```

---

## 检查清单

- [ ] 选择合适的表引擎？
- [ ] 分区键选择合理？
- [ ] ORDER BY 包含常用查询字段？
- [ ] 批量插入而非单条？
- [ ] 使用 PREWHERE 优化查询？
- [ ] 配置 TTL 自动清理？
- [ ] 避免 SELECT *？

---

## 参考资料

- [完整代码示例](references/examples.md) — 连接、表引擎 DDL、查询、批量插入、聚合、优化完整实现
