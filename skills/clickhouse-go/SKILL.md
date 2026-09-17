---
name: clickhouse-go
description: "Go ClickHouse OLAP 分析专家 - 表引擎选择、查询优化、批量插入、分页查询、聚合分析、数据管理。适用：大规模数据分析（OLAP）、日志分析、用户行为分析、实时报表、时序数据存储、列式存储高压缩场景。不适用：频繁单行更新/删除的 OLTP 场景（用 PostgreSQL/MySQL）、需要事务和强一致性的业务系统、数据量小于百万行的简单查询。触发词：clickhouse, OLAP, 列式存储, MergeTree, 聚合, 批量插入, 分区, TTL, 物化视图, 宽表"
---

# Go ClickHouse 专家

使用 Go clickhouse-go 开发 ClickHouse 功能：$ARGUMENTS

基线：go1.24.6，`github.com/ClickHouse/clickhouse-go/v2 v2.46.0`。示例使用原生协议接口 `driver.Conn`；完整可编译代码与 SQL 见 [references/examples.md](references/examples.md)。

---

## 1. 连接管理

```go
import (
    "github.com/ClickHouse/clickhouse-go/v2"
    "github.com/ClickHouse/clickhouse-go/v2/lib/driver"
)

func NewClickHouse(ctx context.Context, dsn string) (driver.Conn, error) {
    opts, err := clickhouse.ParseDSN(dsn) // clickhouse://user:pass@host:9000/db?dial_timeout=5s
    if err != nil {
        return nil, fmt.Errorf("parse dsn: %w", err)
    }
    opts.MaxOpenConns = 10
    opts.MaxIdleConns = 5
    opts.ConnMaxLifetime = 10 * time.Minute
    opts.DialTimeout = 5 * time.Second
    opts.ReadTimeout = 30 * time.Second
    opts.Compression = &clickhouse.Compression{Method: clickhouse.CompressionLZ4}

    conn, err := clickhouse.Open(opts)
    if err != nil {
        return nil, fmt.Errorf("open clickhouse: %w", err)
    }
    if err := conn.Ping(ctx); err != nil {
        _ = conn.Close()
        return nil, fmt.Errorf("ping clickhouse: %w", err)
    }
    return conn, nil
}
```

| 选择 | 接口 | 用途 |
|------|------|------|
| `clickhouse.Open` | `driver.Conn` | 原生协议，支持 `PrepareBatch`、`Select` 结构体映射、`AsyncInsert`，推荐 |
| `clickhouse.OpenDB` | `*sql.DB` | 需要 `database/sql` 生态（sqlx、ORM）时使用 |

多节点写 `Addr: []string{"ch1:9000", "ch2:9000"}`，客户端按顺序尝试并自动切换。

> 完整实现见 [references/examples.md#连接](references/examples.md#连接)

---

## 2. 表引擎选择

| 引擎 | 适用场景 | 特点 |
|------|---------|------|
| MergeTree | 通用 OLAP、时序、日志 | 最常用，支持分区、TTL、跳数索引 |
| ReplacingMergeTree | 有重复写入、按版本保留最新 | 合并异步，查询需 `FINAL` |
| AggregatingMergeTree | 实时统计、仪表盘 | 配合物化视图存 `-State`，查询 `-Merge` |
| SummingMergeTree | 计数器、累加统计 | 合并时自动求和指定列 |
| ReplicatedMergeTree | 生产集群 | 上述引擎都有 Replicated 版本，通过 Keeper 复制 |

建表三要素：

- `PARTITION BY`：按时间粒度（`toYYYYMM`），单表分区数控制在几百以内
- `ORDER BY`：最常用的过滤前缀在前，低基数列在前，决定主键稀疏索引
- `TTL`：行级过期或冷热分层

> DDL 示例见 [references/examples.md#表引擎-ddl](references/examples.md#表引擎-ddl)

---

## 3. 查询操作

### 结构体映射（推荐）

```go
type Event struct {
    Date      time.Time `ch:"event_date"`
    Time      time.Time `ch:"event_time"`
    UserID    uint64    `ch:"user_id"`
    EventType string    `ch:"event_type"`
}

var events []Event
err := conn.Select(ctx, &events, `
    SELECT event_date, event_time, user_id, event_type
    FROM events WHERE user_id = ? ORDER BY event_time DESC LIMIT ?
`, userID, limit)
```

### 通用查询

`rows.Scan` 需要与列类型匹配的目标指针。列未知时按 `ColumnTypes()[i].ScanType()` 用 `reflect.New` 分配，再转成 `map[string]any`。

### 分页

Go 方法不能带类型参数，分页写成普通泛型函数：

```go
type PageOptions struct {
    Page, PageSize int64
    OrderBy        string // "column" 或 "column DESC"，白名单校验
}

func QueryPage[T any](ctx context.Context, conn driver.Conn, baseQuery string, opts PageOptions, args ...any) (*PageResult[T], error)
```

- `ORDER BY` 只能拼接白名单里的列名和方向，`LIMIT/OFFSET` 用整数格式化
- 先 `SELECT count() FROM (baseQuery)` 再取页；深翻页改用 `WHERE sortKey > lastValue`

> 完整实现见 [references/examples.md#查询](references/examples.md#查询)、[#分页](references/examples.md#分页)

---

## 4. 批量插入

ClickHouse 每次 INSERT 生成一个 part，单条插入会触发 `Too many parts`。

```go
func (c *ClickHouse) BatchInsert(ctx context.Context, table string, data []Event) error {
    batch, err := c.conn.PrepareBatch(ctx, "INSERT INTO "+table)
    if err != nil {
        return fmt.Errorf("prepare batch: %w", err)
    }
    for _, e := range data {
        if err := batch.Append(e.Date, e.Time, e.UserID, e.EventType); err != nil {
            return fmt.Errorf("append: %w", err)
        }
    }
    return batch.Send()
}
```

| 方式 | 适用 |
|------|------|
| `batch.Append(cols...)` | 列顺序与表一致 |
| `batch.AppendStruct(&row)` | 按 `ch` tag 映射，字段顺序无关 |
| `BatchInsertChunked` | 超大切片按 1 万到 10 万行分批，每批前检查 `ctx.Err()` |
| `conn.AsyncInsert(ctx, sql, wait, args...)` | 小批量高频写入，交给服务端 `async_insert` 缓冲合并 |

> 完整实现见 [references/examples.md#批量插入](references/examples.md#批量插入)

---

## 5. 聚合查询

- 基础：`count()`、`uniq()`（近似）、`uniqExact()`、`sum()`、`avg()`
- 分位数：`quantile(0.95)(col)` 近似，`quantilesExact(0.5, 0.95, 0.99)(col)` 精确
- TopK：`topK(10)(col)`、`topKWeighted(10)(col, weight)`
- 时间桶：`toStartOfDay`、`toStartOfHour`、`toStartOfInterval(t, INTERVAL 5 MINUTE)`
- 窗口：`sum(v) OVER (ORDER BY d)`、`rank() OVER (...)`、`avg(v) OVER (ORDER BY d ROWS BETWEEN 6 PRECEDING AND CURRENT ROW)`

预聚合：物化视图写 `sumState()`/`uniqState()` 到 AggregatingMergeTree，查询用 `sumMerge()`/`uniqMerge()`。

> SQL 示例见 [references/examples.md#聚合与窗口函数-sql](references/examples.md#聚合与窗口函数-sql)

---

## 6. 查询优化

```sql
ALTER TABLE events ADD INDEX idx_event_type event_type TYPE set(100) GRANULARITY 4;
ALTER TABLE events ADD INDEX idx_user_id user_id TYPE bloom_filter() GRANULARITY 4;
ALTER TABLE events MATERIALIZE INDEX idx_user_id; -- 历史分区需要物化
```

- 过滤条件命中 `ORDER BY` 前缀才能裁剪 granule；`EXPLAIN indexes = 1` 查看
- `PREWHERE` 先按小列过滤再读其余列；`WHERE` 里的条件服务端会自动挪一部分到 PREWHERE
- `IN (...)` 代替多个 `OR`；`LIMIT n BY key` 做分组取前 N
- 避免 `SELECT *`；高频计算字段用 `MATERIALIZED` 列
- 低基数字符串用 `LowCardinality(String)`；可空列有额外开销，能用默认值就不用 `Nullable`

> 完整 SQL 见 [references/examples.md#查询优化-sql](references/examples.md#查询优化-sql)

---

## 7. 数据管理

```sql
ALTER TABLE events MODIFY TTL event_date + INTERVAL 90 DAY;                      -- 行级
ALTER TABLE events MODIFY COLUMN properties String TTL event_date + INTERVAL 30 DAY; -- 列级
ALTER TABLE events MODIFY TTL event_date + INTERVAL 7 DAY TO VOLUME 'hot',
                              event_date + INTERVAL 30 DAY TO VOLUME 'cold';     -- 分层
ALTER TABLE events DROP PARTITION '202401';                                      -- 按分区删除，代价最低
OPTIMIZE TABLE events FINAL DEDUPLICATE BY user_id, event_type;                  -- 低峰期执行
```

`ALTER TABLE ... DELETE/UPDATE` 是异步 mutation，重写整个 part，不要当作 OLTP 更新用。需要频繁修正的数据用 ReplacingMergeTree 写新版本。

> 完整 SQL 见 [references/examples.md#数据管理-sql](references/examples.md#数据管理-sql)

---

## 8. Schema 设计

| Go 类型 | ClickHouse 类型 | 说明 |
|---------|----------------|------|
| `time.Time` | Date / DateTime / DateTime64 | 时区按列定义 |
| `uint8` / `int32` / `uint64` | UInt8 / Int32 / UInt64 | 选最小够用的宽度 |
| `string` | String / FixedString(N) / LowCardinality(String) | 低基数用 LC |
| `[]string` | Array(String) | |
| `*string` | Nullable(String) | 能用默认值就不用 Nullable |
| `map[string]string` | Map(String, String) | |
| `decimal.Decimal` | Decimal(P, S) | `github.com/shopspring/decimal` |

---

## 常用命令

```bash
clickhouse-client -h localhost -u default --query "SELECT version()"
```

```sql
-- 表大小
SELECT table, formatReadableSize(sum(bytes)) AS size, sum(rows) AS rows
FROM system.parts WHERE active GROUP BY table ORDER BY sum(bytes) DESC;

-- 慢查询
SELECT query, query_duration_ms, read_rows, read_bytes
FROM system.query_log WHERE type = 'QueryFinish' AND query_duration_ms > 1000
ORDER BY query_duration_ms DESC LIMIT 10;
```

---

## 检查清单

- [ ] 引擎匹配写入模式（去重用 Replacing，预聚合用 Aggregating）？
- [ ] `PARTITION BY` 粒度合理，`ORDER BY` 覆盖高频过滤前缀？
- [ ] 写入走 `PrepareBatch` 或 `AsyncInsert`，没有单条 INSERT？
- [ ] 动态 `ORDER BY` 经过白名单校验？
- [ ] 配置了 TTL 或分区淘汰策略？
- [ ] 没有 `SELECT *`，高基数过滤列有跳数索引？
- [ ] 连接启用了压缩，`ReadTimeout` 覆盖最长查询？

---

## 参考资料

- [references/examples.md](references/examples.md) - 完整可编译代码与 SQL（连接、查询、分页、批量插入、DDL、聚合、优化、数据管理）
- [clickhouse-go/v2 pkg.go.dev](https://pkg.go.dev/github.com/ClickHouse/clickhouse-go/v2)
- [ClickHouse 官方文档](https://clickhouse.com/docs)
