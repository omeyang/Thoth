# Go ClickHouse - 完整代码示例

## 目录

- [导入与依赖](#导入与依赖)
- [连接](#连接)
- [包装器](#包装器)
- [查询](#查询)
- [分页](#分页)
- [批量插入](#批量插入)
- [异步插入](#异步插入)
- [Schema](#schema)
- [表引擎 DDL](#表引擎-ddl)
- [聚合与窗口函数 SQL](#聚合与窗口函数-sql)
- [查询优化 SQL](#查询优化-sql)
- [数据管理 SQL](#数据管理-sql)

---

所有 Go 代码在 go1.24.6 + `github.com/ClickHouse/clickhouse-go/v2 v2.46.0` 下通过 `go vet`。示例合并在一个包里，导入块只列一次。

```text
go get github.com/ClickHouse/clickhouse-go/v2@v2.46.0
```

`clickhouse.Open` 返回原生协议的 `driver.Conn`（推荐）；需要 `database/sql` 接口时改用 `clickhouse.OpenDB`。

---

## 导入与依赖

```go
package ch

import (
	"context"
	"fmt"
	"reflect"
	"strings"
	"time"

	"github.com/ClickHouse/clickhouse-go/v2"
	"github.com/ClickHouse/clickhouse-go/v2/lib/driver"
)
```

---

## 连接

```go
func NewClickHouse(ctx context.Context, dsn string) (driver.Conn, error) {
	opts, err := clickhouse.ParseDSN(dsn)
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

// NewClickHouseOptions 不用 DSN 时直接构造 Options
func NewClickHouseOptions(addrs []string, database, username, password string) *clickhouse.Options {
	return &clickhouse.Options{
		Addr: addrs, // 多节点：客户端按顺序尝试，失败自动切换
		Auth: clickhouse.Auth{
			Database: database,
			Username: username,
			Password: password,
		},
		MaxOpenConns:    10,
		MaxIdleConns:    5,
		ConnMaxLifetime: 10 * time.Minute,
		DialTimeout:     5 * time.Second,
		Compression:     &clickhouse.Compression{Method: clickhouse.CompressionLZ4},
		Settings: clickhouse.Settings{
			"max_execution_time": 60,
		},
	}
}
```

---

## 包装器

```go
type ClickHouse struct {
	conn driver.Conn
}

func New(conn driver.Conn) *ClickHouse { return &ClickHouse{conn: conn} }

func (c *ClickHouse) Conn() driver.Conn                { return c.conn }
func (c *ClickHouse) Health(ctx context.Context) error { return c.conn.Ping(ctx) }
func (c *ClickHouse) Close() error                     { return c.conn.Close() }
```

---

## 查询

`rows.Scan` 需要与列类型匹配的目标指针，通用查询按 `ColumnType.ScanType()` 分配。已知结构时优先用 `Select` + `ch` tag。

```go
// Query 通用查询：按列类型的 ScanType 分配目标，再转成 map
func (c *ClickHouse) Query(ctx context.Context, query string, args ...any) ([]map[string]any, error) {
	rows, err := c.conn.Query(ctx, query, args...)
	if err != nil {
		return nil, fmt.Errorf("query: %w", err)
	}
	defer rows.Close()

	columns := rows.Columns()
	types := rows.ColumnTypes()

	var results []map[string]any
	for rows.Next() {
		dest := make([]any, len(columns))
		for i, ct := range types {
			dest[i] = reflect.New(ct.ScanType()).Interface()
		}
		if err := rows.Scan(dest...); err != nil {
			return nil, fmt.Errorf("scan: %w", err)
		}
		row := make(map[string]any, len(columns))
		for i, col := range columns {
			row[col] = reflect.ValueOf(dest[i]).Elem().Interface()
		}
		results = append(results, row)
	}
	return results, rows.Err()
}

type Event struct {
	Date      time.Time `ch:"event_date"`
	Time      time.Time `ch:"event_time"`
	UserID    uint64    `ch:"user_id"`
	EventType string    `ch:"event_type"`
}

// QueryEvents 结构体查询：Select 按 ch tag 映射列
func (c *ClickHouse) QueryEvents(ctx context.Context, userID uint64, limit int) ([]Event, error) {
	var events []Event
	err := c.conn.Select(ctx, &events, `
		SELECT event_date, event_time, user_id, event_type
		FROM events
		WHERE user_id = ?
		ORDER BY event_time DESC
		LIMIT ?
	`, userID, limit)
	if err != nil {
		return nil, fmt.Errorf("select events: %w", err)
	}
	return events, nil
}
```

---

## 分页

Go 方法不能带类型参数，`QueryPage` 写成普通泛型函数。`ORDER BY` 只接受白名单列，`LIMIT/OFFSET` 是整数格式化，不拼接用户字符串。

```go
type PageOptions struct {
	Page     int64
	PageSize int64
	OrderBy  string // "column" 或 "column DESC"
}

type PageResult[T any] struct {
	Data       []T
	Total      int64
	Page       int64
	PageSize   int64
	TotalPages int64
}

// allowedColumns 排序列白名单，防止 ORDER BY 注入
var allowedColumns = map[string]bool{
	"event_date": true, "event_time": true, "user_id": true,
	"created_at": true, "updated_at": true, "id": true,
}

func validateOrderBy(orderBy string) error {
	parts := strings.Fields(orderBy)
	if len(parts) == 0 || len(parts) > 2 {
		return fmt.Errorf("invalid order by: %q", orderBy)
	}
	if !allowedColumns[parts[0]] {
		return fmt.Errorf("column not allowed for sorting: %q", parts[0])
	}
	if len(parts) == 2 {
		dir := strings.ToUpper(parts[1])
		if dir != "ASC" && dir != "DESC" {
			return fmt.Errorf("invalid sort direction: %q", parts[1])
		}
	}
	return nil
}

// QueryPage Offset 分页。Go 方法不能带类型参数，因此写成普通泛型函数
func QueryPage[T any](ctx context.Context, conn driver.Conn, baseQuery string, opts PageOptions, args ...any) (*PageResult[T], error) {
	if err := validateOrderBy(opts.OrderBy); err != nil {
		return nil, fmt.Errorf("validate order by: %w", err)
	}
	if opts.Page < 1 {
		opts.Page = 1
	}
	if opts.PageSize <= 0 {
		opts.PageSize = 100
	}

	var total uint64
	countQuery := fmt.Sprintf("SELECT count() FROM (%s)", baseQuery)
	if err := conn.QueryRow(ctx, countQuery, args...).Scan(&total); err != nil {
		return nil, fmt.Errorf("count: %w", err)
	}

	offset := (opts.Page - 1) * opts.PageSize
	pageQuery := fmt.Sprintf("%s ORDER BY %s LIMIT %d OFFSET %d",
		baseQuery, opts.OrderBy, opts.PageSize, offset)

	var data []T
	if err := conn.Select(ctx, &data, pageQuery, args...); err != nil {
		return nil, fmt.Errorf("select: %w", err)
	}

	return &PageResult[T]{
		Data:       data,
		Total:      int64(total),
		Page:       opts.Page,
		PageSize:   opts.PageSize,
		TotalPages: (int64(total) + opts.PageSize - 1) / opts.PageSize,
	}, nil
}
```

---

## 批量插入

ClickHouse 每次 INSERT 生成一个 part，单条插入会造成 `Too many parts`。批量大小建议 1 万到 10 万行，或按时间窗口攒批。

```go
// BatchInsert 列式批量写入：一个 Batch 只发一次网络请求
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

// BatchInsertStruct 按 ch tag 追加整个结构体
func (c *ClickHouse) BatchInsertStruct(ctx context.Context, table string, data []Event) error {
	batch, err := c.conn.PrepareBatch(ctx, "INSERT INTO "+table)
	if err != nil {
		return fmt.Errorf("prepare batch: %w", err)
	}
	for i := range data {
		if err := batch.AppendStruct(&data[i]); err != nil {
			return fmt.Errorf("append struct: %w", err)
		}
	}
	return batch.Send()
}

// BatchInsertChunked 大数据量分批，每批独立提交
func (c *ClickHouse) BatchInsertChunked(ctx context.Context, table string, data []Event, chunkSize int) error {
	if chunkSize <= 0 {
		chunkSize = 10000
	}
	for start := 0; start < len(data); start += chunkSize {
		if err := ctx.Err(); err != nil {
			return err
		}
		end := min(start+chunkSize, len(data))
		if err := c.BatchInsert(ctx, table, data[start:end]); err != nil {
			return fmt.Errorf("batch chunk %d: %w", start/chunkSize, err)
		}
	}
	return nil
}
```

---

## 异步插入

```go
// AsyncInsert 小批量高频写入：交给服务端缓冲合并（async_insert）
func (c *ClickHouse) AsyncInsert(ctx context.Context, query string, wait bool, args ...any) error {
	return c.conn.AsyncInsert(ctx, query, wait, args...)
}
```

---

## Schema

```go
// EventRow Go 类型与 ClickHouse 类型映射
type EventRow struct {
	EventDate time.Time `ch:"event_date"` // Date
	EventTime time.Time `ch:"event_time"` // DateTime / DateTime64
	UserID    uint64    `ch:"user_id"`    // UInt64
	Count     int32     `ch:"count"`      // Int32
	SmallNum  uint8     `ch:"small_num"`  // UInt8
	Name      string    `ch:"name"`       // String
	FixedID   string    `ch:"fixed_id"`   // FixedString(32)
	Tags      []string  `ch:"tags"`       // Array(String)
	Optional  *string   `ch:"optional"`   // Nullable(String)
	Status    string    `ch:"status"`     // LowCardinality(String)
}
```

---

## 表引擎 DDL

### MergeTree（通用 OLAP、时序、日志）

```sql
CREATE TABLE events (
    event_date Date,
    event_time DateTime,
    user_id UInt64,
    event_type LowCardinality(String),
    properties String,
    INDEX idx_user_id user_id TYPE minmax GRANULARITY 4
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(event_date)
ORDER BY (event_date, user_id, event_time)
TTL event_date + INTERVAL 90 DAY
SETTINGS index_granularity = 8192;
```

### ReplacingMergeTree（按版本去重）

```sql
CREATE TABLE user_profiles (
    user_id UInt64,
    name String,
    email String,
    updated_at DateTime
) ENGINE = ReplacingMergeTree(updated_at)
ORDER BY user_id;

-- 合并是异步的，查询时用 FINAL 强制去重
SELECT * FROM user_profiles FINAL WHERE user_id = 123;
```

### AggregatingMergeTree + 物化视图（预聚合）

```sql
CREATE TABLE events_raw (
    event_date Date,
    user_id UInt64,
    event_type String,
    value UInt64
) ENGINE = MergeTree()
PARTITION BY toYYYYMM(event_date)
ORDER BY (event_date, user_id);

CREATE TABLE events_daily (
    event_date Date,
    event_type String,
    total_value AggregateFunction(sum, UInt64),
    event_count AggregateFunction(count, UInt64),
    unique_users AggregateFunction(uniq, UInt64)
) ENGINE = AggregatingMergeTree()
PARTITION BY toYYYYMM(event_date)
ORDER BY (event_date, event_type);

CREATE MATERIALIZED VIEW events_daily_mv TO events_daily AS
SELECT
    event_date,
    event_type,
    sumState(value) AS total_value,
    countState() AS event_count,
    uniqState(user_id) AS unique_users
FROM events_raw
GROUP BY event_date, event_type;

-- 查询时用 -Merge 合并中间状态
SELECT
    event_date,
    event_type,
    sumMerge(total_value) AS total,
    countMerge(event_count) AS count,
    uniqMerge(unique_users) AS users
FROM events_daily
GROUP BY event_date, event_type;
```

### SummingMergeTree（计数器自动求和）

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

## 聚合与窗口函数 SQL

```sql
-- 基础聚合
SELECT
    toStartOfDay(event_time) AS day,
    event_type,
    count() AS total,
    uniq(user_id) AS unique_users,
    sum(value) AS total_value,
    avg(value) AS avg_value
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

-- 累计求和
SELECT event_date, value,
    sum(value) OVER (ORDER BY event_date) AS cumulative
FROM daily_stats;

-- 排名
SELECT user_id, score,
    rank() OVER (ORDER BY score DESC) AS rnk,
    dense_rank() OVER (ORDER BY score DESC) AS dense_rnk
FROM leaderboard;

-- 7 日移动平均
SELECT date, value,
    avg(value) OVER (ORDER BY date ROWS BETWEEN 6 PRECEDING AND CURRENT ROW) AS ma7
FROM daily_stats;
```

---

## 查询优化 SQL

```sql
-- 跳数索引
ALTER TABLE events ADD INDEX idx_event_type event_type TYPE set(100) GRANULARITY 4;
-- 布隆过滤器（高基数列）
ALTER TABLE events ADD INDEX idx_user_id user_id TYPE bloom_filter() GRANULARITY 4;
-- 新增索引只对新数据生效，历史分区需要物化
ALTER TABLE events MATERIALIZE INDEX idx_user_id;

-- PREWHERE：先按小列过滤，再读取其余列
SELECT * FROM events
PREWHERE event_type = 'click'
WHERE event_date >= '2024-01-01' AND user_id = 123;

-- 执行计划
EXPLAIN SELECT * FROM events WHERE user_id = 123;
EXPLAIN PIPELINE SELECT * FROM events WHERE user_id = 123;
EXPLAIN indexes = 1 SELECT * FROM events WHERE user_id = 123;

-- IN 替代多个 OR
SELECT * FROM events WHERE user_id IN (1, 2, 3, 4, 5);

-- LIMIT BY：每个分组取前 N
SELECT * FROM events ORDER BY event_time DESC LIMIT 10 BY user_id;

-- 物化列减少重复计算
ALTER TABLE events ADD COLUMN event_hour UInt8 MATERIALIZED toHour(event_time);
```

---

## 数据管理 SQL

```sql
-- 行级 TTL
ALTER TABLE events MODIFY TTL event_date + INTERVAL 90 DAY;
-- 列级 TTL
ALTER TABLE events MODIFY COLUMN properties String TTL event_date + INTERVAL 30 DAY;
-- 冷热分层
ALTER TABLE events MODIFY TTL
    event_date + INTERVAL 7 DAY TO VOLUME 'hot',
    event_date + INTERVAL 30 DAY TO VOLUME 'cold';

-- 分区管理
SELECT partition, name, rows, bytes_on_disk
FROM system.parts WHERE table = 'events' AND active;
ALTER TABLE events DROP PARTITION '202401';
ALTER TABLE events DETACH PARTITION '202401';
ALTER TABLE events ATTACH PARTITION '202401';

-- 去重（OPTIMIZE 代价高，只在低峰期做）
OPTIMIZE TABLE events FINAL DEDUPLICATE;
OPTIMIZE TABLE events FINAL DEDUPLICATE BY user_id, event_type;

-- 表大小
SELECT table, formatReadableSize(sum(bytes)) AS size, sum(rows) AS rows
FROM system.parts WHERE active GROUP BY table ORDER BY sum(bytes) DESC;

-- 慢查询
SELECT query, query_duration_ms, read_rows, read_bytes
FROM system.query_log
WHERE type = 'QueryFinish' AND query_duration_ms > 1000
ORDER BY query_duration_ms DESC LIMIT 10;
```
