# Go ClickHouse 完整代码示例

## 目录

- [1. 连接管理](#1-连接管理)
  - [创建连接](#创建连接)
  - [包装器模式](#包装器模式)
- [2. 表引擎选择](#2-表引擎选择)
  - [MergeTree](#mergetree最常用)
  - [ReplacingMergeTree](#replacingmergetree去重)
  - [AggregatingMergeTree](#aggregatingmergetree预聚合)
  - [SummingMergeTree](#summingmergetree自动求和)
- [3. 查询操作](#3-查询操作)
  - [基本查询](#基本查询)
  - [结构体查询](#结构体查询)
  - [分页查询](#分页查询)
- [4. 批量插入](#4-批量插入)
  - [使用 Batch](#使用-batch)
  - [分批插入](#分批插入大数据量)
- [5. 聚合查询](#5-聚合查询)
  - [常用聚合函数](#常用聚合函数)
  - [窗口函数](#窗口函数)
- [6. 查询优化](#6-查询优化)
  - [使用索引](#使用索引)
  - [查询计划分析](#查询计划分析)
  - [优化技巧](#优化技巧)
- [7. 数据管理](#7-数据管理)
  - [TTL 自动过期](#ttl-自动过期)
  - [分区管理](#分区管理)
  - [数据去重](#数据去重)
- [8. 最佳实践](#8-最佳实践)
  - [Schema 设计](#schema-设计)
  - [连接池配置](#连接池配置)

---

## 1. 连接管理

### 创建连接

```go
import (
    "context"
    "time"

    "github.com/ClickHouse/clickhouse-go/v2"
    "github.com/ClickHouse/clickhouse-go/v2/lib/driver"
)

func NewClickHouse(ctx context.Context, dsn string) (driver.Conn, error) {
    opts, err := clickhouse.ParseDSN(dsn)
    if err != nil {
        return nil, fmt.Errorf("parse dsn: %w", err)
    }

    // 配置连接池
    opts.MaxOpenConns = 10
    opts.MaxIdleConns = 5
    opts.ConnMaxLifetime = 10 * time.Minute
    opts.DialTimeout = 5 * time.Second
    opts.ReadTimeout = 30 * time.Second

    conn, err := clickhouse.Open(opts)
    if err != nil {
        return nil, fmt.Errorf("open clickhouse: %w", err)
    }

    // 验证连接
    if err := conn.Ping(ctx); err != nil {
        return nil, fmt.Errorf("ping clickhouse: %w", err)
    }

    return conn, nil
}
```

### 包装器模式

```go
type ClickHouse struct {
    conn driver.Conn
}

func New(conn driver.Conn) *ClickHouse {
    return &ClickHouse{conn: conn}
}

// Conn 暴露底层连接
func (c *ClickHouse) Conn() driver.Conn {
    return c.conn
}

// Health 健康检查
func (c *ClickHouse) Health(ctx context.Context) error {
    return c.conn.Ping(ctx)
}

// Close 关闭连接
func (c *ClickHouse) Close() error {
    return c.conn.Close()
}
```

---

## 2. 表引擎选择

### MergeTree（最常用）

适用于：通用 OLAP、时序数据、日志分析

```sql
CREATE TABLE events (
    event_date Date,
    event_time DateTime,
    user_id UInt64,
    event_type String,
    properties String,

    INDEX idx_user_id user_id TYPE minmax GRANULARITY 4
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(event_date)
ORDER BY (event_date, user_id, event_time)
TTL event_date + INTERVAL 90 DAY
SETTINGS index_granularity = 8192;
```

### ReplacingMergeTree（去重）

适用于：可能有重复数据的场景

```sql
CREATE TABLE user_profiles (
    user_id UInt64,
    name String,
    email String,
    updated_at DateTime
) ENGINE = ReplacingMergeTree(updated_at)
ORDER BY user_id;

-- 查询时强制合并去重
SELECT * FROM user_profiles FINAL WHERE user_id = 123;
```

### AggregatingMergeTree（预聚合）

适用于：实时统计、仪表盘

```sql
-- 原始表
CREATE TABLE events_raw (
    event_date Date,
    user_id UInt64,
    event_type String,
    value UInt64
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(event_date)
ORDER BY (event_date, user_id);

-- 聚合表
CREATE TABLE events_daily (
    event_date Date,
    event_type String,
    total_value AggregateFunction(sum, UInt64),
    event_count AggregateFunction(count, UInt64),
    unique_users AggregateFunction(uniq, UInt64)
) ENGINE = AggregatingMergeTree()
PARTITION BY toYYYYMM(event_date)
ORDER BY (event_date, event_type);

-- 物化视图自动聚合
CREATE MATERIALIZED VIEW events_daily_mv TO events_daily AS
SELECT
    event_date,
    event_type,
    sumState(value) AS total_value,
    countState() AS event_count,
    uniqState(user_id) AS unique_users
FROM events_raw
GROUP BY event_date, event_type;

-- 查询聚合结果
SELECT
    event_date,
    event_type,
    sumMerge(total_value) AS total,
    countMerge(event_count) AS count,
    uniqMerge(unique_users) AS users
FROM events_daily
GROUP BY event_date, event_type;
```

### SummingMergeTree（自动求和）

适用于：计数器、累加统计

```sql
CREATE TABLE page_views (
    date Date,
    page String,
    views UInt64,
    unique_visitors UInt64
) ENGINE = SummingMergeTree((views, unique_visitors))
ORDER BY (date, page);
```

---

## 3. 查询操作

### 基本查询

```go
func (c *ClickHouse) Query(ctx context.Context, query string, args ...any) ([]map[string]any, error) {
    rows, err := c.conn.Query(ctx, query, args...)
    if err != nil {
        return nil, fmt.Errorf("query: %w", err)
    }
    defer rows.Close()

    columns := rows.Columns()
    columnTypes := rows.ColumnTypes()

    var results []map[string]any

    for rows.Next() {
        values := make([]any, len(columns))
        valuePtrs := make([]any, len(columns))
        for i := range values {
            valuePtrs[i] = &values[i]
        }

        if err := rows.Scan(valuePtrs...); err != nil {
            return nil, fmt.Errorf("scan: %w", err)
        }

        row := make(map[string]any)
        for i, col := range columns {
            row[col] = values[i]
        }
        results = append(results, row)
    }

    return results, rows.Err()
}
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
        FROM events
        WHERE user_id = ?
        ORDER BY event_time DESC
        LIMIT ?
    `, userID, limit)

    return events, err
}
```

### 分页查询

```go
import (
    "fmt"
    "strings"
)

type PageOptions struct {
    Page     int64
    PageSize int64
    OrderBy  string
}

type PageResult[T any] struct {
    Data       []T
    Total      int64
    Page       int64
    PageSize   int64
    TotalPages int64
}

// allowedColumns 定义允许排序的列名白名单，防止 SQL 注入
var allowedColumns = map[string]bool{
    "event_date": true, "event_time": true, "user_id": true,
    "created_at": true, "updated_at": true, "id": true,
}

func validateOrderBy(orderBy string) error {
    // 允许格式: "column" 或 "column ASC" 或 "column DESC"
    parts := strings.Fields(orderBy)
    if len(parts) == 0 || len(parts) > 2 {
        return fmt.Errorf("invalid order by: %s", orderBy)
    }
    if !allowedColumns[parts[0]] {
        return fmt.Errorf("column not allowed for sorting: %s", parts[0])
    }
    if len(parts) == 2 {
        dir := strings.ToUpper(parts[1])
        if dir != "ASC" && dir != "DESC" {
            return fmt.Errorf("invalid sort direction: %s", parts[1])
        }
    }
    return nil
}

func (c *ClickHouse) QueryPage[T any](ctx context.Context, baseQuery string, opts PageOptions, args ...any) (*PageResult[T], error) {
    // 校验 OrderBy 防止 SQL 注入
    if err := validateOrderBy(opts.OrderBy); err != nil {
        return nil, fmt.Errorf("validate order by: %w", err)
    }

    // 计算 total
    countQuery := fmt.Sprintf("SELECT count() FROM (%s)", baseQuery)
    var total uint64
    if err := c.conn.QueryRow(ctx, countQuery, args...).Scan(&total); err != nil {
        return nil, fmt.Errorf("count: %w", err)
    }

    // 分页查询
    offset := (opts.Page - 1) * opts.PageSize
    pageQuery := fmt.Sprintf("%s ORDER BY %s LIMIT %d OFFSET %d",
        baseQuery, opts.OrderBy, opts.PageSize, offset)

    var data []T
    if err := c.conn.Select(ctx, &data, pageQuery, args...); err != nil {
        return nil, fmt.Errorf("select: %w", err)
    }

    totalPages := (int64(total) + opts.PageSize - 1) / opts.PageSize

    return &PageResult[T]{
        Data:       data,
        Total:      int64(total),
        Page:       opts.Page,
        PageSize:   opts.PageSize,
        TotalPages: totalPages,
    }, nil
}
```

---

## 4. 批量插入

### 使用 Batch

```go
func (c *ClickHouse) BatchInsert(ctx context.Context, table string, data []Event) error {
    batch, err := c.conn.PrepareBatch(ctx, fmt.Sprintf("INSERT INTO %s", table))
    if err != nil {
        return fmt.Errorf("prepare batch: %w", err)
    }

    for _, event := range data {
        if err := batch.Append(
            event.Date,
            event.Time,
            event.UserID,
            event.EventType,
        ); err != nil {
            return fmt.Errorf("append: %w", err)
        }
    }

    return batch.Send()
}
```

### 分批插入（大数据量）

```go
func (c *ClickHouse) BatchInsertChunked(ctx context.Context, table string, data []Event, chunkSize int) error {
    for i := 0; i < len(data); i += chunkSize {
        end := i + chunkSize
        if end > len(data) {
            end = len(data)
        }

        chunk := data[i:end]
        if err := c.BatchInsert(ctx, table, chunk); err != nil {
            return fmt.Errorf("batch chunk %d: %w", i/chunkSize, err)
        }

        // 检查 context 取消
        select {
        case <-ctx.Done():
            return ctx.Err()
        default:
        }
    }

    return nil
}
```

---

## 5. 聚合查询

### 常用聚合函数

```sql
-- 基础聚合
SELECT
    toStartOfDay(event_time) AS day,
    event_type,
    count() AS total,
    uniq(user_id) AS unique_users,
    sum(value) AS total_value,
    avg(value) AS avg_value,
    min(value) AS min_value,
    max(value) AS max_value
FROM events
WHERE event_date >= today() - 7
GROUP BY day, event_type
ORDER BY day DESC;

-- 分位数
SELECT
    quantile(0.50)(response_time) AS median,
    quantile(0.95)(response_time) AS p95,
    quantile(0.99)(response_time) AS p99,
    quantilesExact(0.50, 0.95, 0.99)(response_time) AS percentiles
FROM requests
WHERE timestamp >= now() - INTERVAL 1 HOUR;

-- TopK
SELECT
    topK(10)(user_id) AS top_users,
    topKWeighted(10)(page, views) AS top_pages
FROM page_views;
```

### 窗口函数

```sql
-- 累计求和
SELECT
    event_date,
    value,
    sum(value) OVER (ORDER BY event_date) AS cumulative
FROM daily_stats;

-- 排名
SELECT
    user_id,
    score,
    rank() OVER (ORDER BY score DESC) AS rank,
    dense_rank() OVER (ORDER BY score DESC) AS dense_rank
FROM leaderboard;

-- 移动平均
SELECT
    date,
    value,
    avg(value) OVER (ORDER BY date ROWS BETWEEN 6 PRECEDING AND CURRENT ROW) AS ma7
FROM daily_stats;
```

---

## 6. 查询优化

### 使用索引

```sql
-- 创建跳数索引
ALTER TABLE events ADD INDEX idx_event_type event_type TYPE set(100) GRANULARITY 4;

-- 布隆过滤器索引（适合高基数列）
ALTER TABLE events ADD INDEX idx_user_id user_id TYPE bloom_filter() GRANULARITY 4;

-- 使用 PREWHERE（在主键过滤后进一步过滤）
SELECT * FROM events
PREWHERE event_type = 'click'
WHERE event_date >= '2024-01-01'
  AND user_id = 123;
```

### 查询计划分析

```sql
-- 查看执行计划
EXPLAIN SELECT * FROM events WHERE user_id = 123;

-- 查看详细执行统计
EXPLAIN PIPELINE SELECT * FROM events WHERE user_id = 123;

-- 开启 profile
SET send_logs_level = 'trace';
SELECT * FROM events WHERE user_id = 123;
```

### 优化技巧

```sql
-- 使用 IN 替代多个 OR
SELECT * FROM events WHERE user_id IN (1, 2, 3, 4, 5);

-- 使用 LIMIT BY 进行分组限制
SELECT * FROM events
ORDER BY event_time DESC
LIMIT 10 BY user_id;

-- 避免 SELECT *
SELECT event_date, event_type, count() FROM events GROUP BY 1, 2;

-- 使用物化列
ALTER TABLE events ADD COLUMN event_hour UInt8 MATERIALIZED toHour(event_time);
```

---

## 7. 数据管理

### TTL 自动过期

```sql
-- 行级 TTL
ALTER TABLE events MODIFY TTL event_date + INTERVAL 90 DAY;

-- 列级 TTL（归档旧数据的详细字段）
ALTER TABLE events MODIFY COLUMN properties String TTL event_date + INTERVAL 30 DAY;

-- 移动到冷存储
ALTER TABLE events MODIFY TTL event_date + INTERVAL 7 DAY TO VOLUME 'hot',
                              event_date + INTERVAL 30 DAY TO VOLUME 'cold';
```

### 分区管理

```sql
-- 查看分区
SELECT partition, name, rows, bytes_on_disk
FROM system.parts
WHERE table = 'events' AND active;

-- 删除分区
ALTER TABLE events DROP PARTITION '202401';

-- 分离分区（备份）
ALTER TABLE events DETACH PARTITION '202401';

-- 附加分区
ALTER TABLE events ATTACH PARTITION '202401';
```

### 数据去重

```sql
-- 手动去重
OPTIMIZE TABLE events FINAL;

-- 强制合并
OPTIMIZE TABLE events FINAL DEDUPLICATE;

-- 按条件去重
OPTIMIZE TABLE events FINAL DEDUPLICATE BY user_id, event_type;
```

---

## 8. 最佳实践

### Schema 设计

```go
// Go 结构体与 ClickHouse 类型映射
type Event struct {
    // Date 类型
    EventDate time.Time `ch:"event_date"` // Date

    // DateTime 类型
    EventTime time.Time `ch:"event_time"` // DateTime

    // 整数类型
    UserID   uint64 `ch:"user_id"`   // UInt64
    Count    int32  `ch:"count"`     // Int32
    SmallNum uint8  `ch:"small_num"` // UInt8

    // 字符串类型
    Name    string `ch:"name"`    // String
    FixedID string `ch:"fixed_id"` // FixedString(32)

    // 数组类型
    Tags []string `ch:"tags"` // Array(String)

    // Nullable
    Optional *string `ch:"optional"` // Nullable(String)

    // 低基数（枚举优化）
    Status string `ch:"status"` // LowCardinality(String)
}
```

### 连接池配置

```go
opts := &clickhouse.Options{
    Addr: []string{"clickhouse1:9000", "clickhouse2:9000"},
    Auth: clickhouse.Auth{
        Database: "default",
        Username: "default",
        Password: "",
    },
    MaxOpenConns:    10,
    MaxIdleConns:    5,
    ConnMaxLifetime: 10 * time.Minute,
    Compression: &clickhouse.Compression{
        Method: clickhouse.CompressionLZ4,
    },
}
```
