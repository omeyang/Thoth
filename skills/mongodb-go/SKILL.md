---
name: mongodb-go
description: "Go MongoDB 专家 - 使用 mongo-driver v2 进行 CRUD、聚合管道、索引优化、事务处理、分页查询(Offset/游标)、批量写入、Change Streams。适用：数据库设计、查询优化、性能调优、Schema 建模、聚合统计。不适用：关系型数据库(PostgreSQL/MySQL)操作；Redis 缓存操作；搜索引擎(Elasticsearch)场景。触发词：mongodb, mongo, bson, 聚合, aggregate, 索引, index, collection, 分页, cursor, change-stream, 事务"
user-invocable: true
allowed-tools: Bash, Read, Write, Edit, Grep, Glob
---

# Go MongoDB 专家

使用 Go mongo-driver 开发 MongoDB 功能：$ARGUMENTS

---

## 1. 连接管理

### 创建客户端

```go
func NewMongoClient(ctx context.Context, uri string) (*mongo.Client, error) {
    opts := options.Client().
        ApplyURI(uri).
        SetMaxPoolSize(100).
        SetMinPoolSize(10).
        SetMaxConnIdleTime(30 * time.Minute).
        SetServerSelectionTimeout(5 * time.Second).
        SetConnectTimeout(10 * time.Second)

    client, err := mongo.Connect(opts)
    if err != nil {
        return nil, fmt.Errorf("connect mongo: %w", err)
    }

    if err := client.Ping(ctx, readpref.Primary()); err != nil {
        return nil, fmt.Errorf("ping mongo: %w", err)
    }
    return client, nil
}
```

### 包装器模式

XKit 的 xmongo 采用**最小包装**策略：只提供增值功能（分页、批量写入、慢查询监控、健康检查），其他操作通过 `Client()` 直接使用 mongo-driver API。

```go
type Mongo interface {
    Client() *mongo.Client                                   // 暴露底层客户端
    Health(ctx context.Context) error                        // Ping 健康检查
    Stats() Stats                                            // 统计信息
    Close(ctx context.Context) error                         // 关闭连接
    FindPage(ctx context.Context, coll *mongo.Collection,    // 分页查询
        filter any, opts PageOptions) (*PageResult, error)
    BulkWrite(ctx context.Context, coll *mongo.Collection,   // 批量写入
        docs []any, opts BulkOptions) (*BulkResult, error)
}
```

**设计原则**：不包装所有 API。CRUD、聚合、索引操作通过 `Client()` 直接使用 mongo-driver 原生方法。

> 完整包装器实现见 [references/examples.md](references/examples.md#包装器模式实现)

---

## 2. CRUD 操作

通过 `Client()` 直接使用 mongo-driver API：

```go
coll := wrapper.Client().Database("mydb").Collection("users")

// 插入
result, err := coll.InsertOne(ctx, doc)
results, err := coll.InsertMany(ctx, docs)

// 查询
err := coll.FindOne(ctx, bson.M{"_id": id}).Decode(&result)
cursor, err := coll.Find(ctx, filter, findOpts)

// 更新
result, err := coll.UpdateOne(ctx, filter, bson.M{"$set": update})
result, err := coll.UpdateMany(ctx, filter, bson.M{"$set": update})

// Upsert
opts := options.UpdateOne().SetUpsert(true)
_, err := coll.UpdateOne(ctx, filter, bson.M{"$set": doc}, opts)

// 软删除（推荐）
_, err := coll.UpdateOne(ctx, filter, bson.M{"$set": bson.M{"is_deleted": true, "deleted_at": time.Now()}})
```

> 完整 CRUD 实现见 [references/examples.md](references/examples.md#crud-操作实现)

---

## 3. 查询操作符

### 比较操作符

```go
bson.M{"age": bson.M{"$gt": 18}}           // 大于
bson.M{"age": bson.M{"$gte": 18}}          // 大于等于
bson.M{"status": bson.M{"$ne": "deleted"}} // 不等于
bson.M{"role": bson.M{"$in": []string{"admin", "moderator"}}} // 在数组中
```

### 逻辑操作符

```go
bson.M{"$and": []bson.M{{...}, {...}}}  // AND
bson.M{"$or": []bson.M{{...}, {...}}}   // OR
bson.M{"age": bson.M{"$not": bson.M{"$lt": 18}}} // NOT
```

### 数组/正则

```go
bson.M{"tags": "golang"}                                     // 包含元素
bson.M{"tags": bson.M{"$all": []string{"golang", "mongodb"}}} // 包含所有
bson.M{"name": bson.M{"$regex": "^john", "$options": "i"}}   // 正则匹配
```

> 完整操作符参考见 [references/examples.md](references/examples.md#查询操作符参考)

---

## 4. 聚合管道

通过 `Client()` 直接使用 mongo-driver 聚合 API：

```go
coll := wrapper.Client().Database("db").Collection("orders")
pipeline := mongo.Pipeline{
    bson.D{{"$match", bson.D{{"status", "active"}}}},
    bson.D{{"$group", bson.D{{"_id", "$category"}, {"total", bson.D{{"$sum", "$amount"}}}}}},
    bson.D{{"$sort", bson.D{{"total", -1}}}},
}
cursor, err := coll.Aggregate(ctx, pipeline)
```

### 常用阶段

| 阶段 | 作用 |
|------|------|
| `$match` | 筛选文档 |
| `$group` | 分组聚合（sum, avg, push） |
| `$sort` | 排序 |
| `$limit` | 限制数量 |
| `$lookup` | 关联查询（类似 JOIN） |
| `$unwind` | 展开数组 |
| `$project` | 投影/计算字段 |

> 完整聚合示例见 [references/examples.md](references/examples.md#聚合管道示例)

---

## 5. 索引管理

通过 `Client()` 直接使用 Indexes() API：

```go
coll := wrapper.Client().Database("db").Collection("users")

// 单字段唯一索引
coll.Indexes().CreateOne(ctx, mongo.IndexModel{
    Keys: bson.D{{"email", 1}}, Options: options.Index().SetUnique(true),
})

// 复合索引
coll.Indexes().CreateOne(ctx, mongo.IndexModel{
    Keys: bson.D{{"status", 1}, {"created_at", -1}},
})

// TTL 索引（自动过期）
coll.Indexes().CreateOne(ctx, mongo.IndexModel{
    Keys: bson.D{{"expires_at", 1}}, Options: options.Index().SetExpireAfterSeconds(0),
})

// 部分索引
coll.Indexes().CreateOne(ctx, mongo.IndexModel{
    Keys: bson.D{{"email", 1}},
    Options: options.Index().SetPartialFilterExpression(bson.M{"status": "active"}),
})
```

> 完整索引管理实现见 [references/examples.md](references/examples.md#索引管理实现)

---

## 6. 事务处理

单文档操作自动具有原子性（MongoDB 4.0+）。多文档事务：

```go
func WithTransaction(ctx context.Context, client *mongo.Client, fn func(sc mongo.SessionContext) error) error {
    session, err := client.StartSession()
    if err != nil { return err }
    defer session.EndSession(ctx)
    _, err = session.WithTransaction(ctx, func(sc mongo.SessionContext) (any, error) {
        return nil, fn(sc)
    })
    return err
}
```

> 完整事务实现（含转账示例）见 [references/examples.md](references/examples.md#事务处理实现)

---

## 7. 分页查询

### Offset 分页

xmongo 包装器的核心增值方法之一：

```go
// 注意：接受 *mongo.Collection 而非集合名
func (m *Mongo) FindPage(ctx context.Context, coll *mongo.Collection, filter any, opts PageOptions) (*PageResult, error)

type PageOptions struct {
    Page     int64   // 页码，从 1 开始
    PageSize int64   // 每页数量
    Sort     bson.D  // 排序（如 bson.D{{"created_at", -1}}）
}

type PageResult struct {
    Data       []bson.M  // 当前页数据
    Total      int64     // 总记录数（独立 COUNT 查询）
    Page       int64     // 当前页码
    PageSize   int64     // 每页大小
    TotalPages int64     // 总页数
}
```

**注意**：FindPage 使用两个独立查询（COUNT + Find），非原子操作，高并发下可能有一致性偏差。

### 游标分页（推荐大数据量）

基于 `_id` 游标，避免 COUNT 和 SKIP 开销：

```go
filter := bson.M{"_id": bson.M{"$gt": lastID}}
cursor, err := coll.Find(ctx, filter, options.Find().SetLimit(pageSize).SetSort(bson.D{{"_id", 1}}))
```

> 完整分页实现见 [references/examples.md](references/examples.md#分页查询实现)

---

## 8. 批量写入

xmongo 包装器的另一个核心增值方法：

```go
// 注意：接受 *mongo.Collection 而非集合名，返回 *BulkResult
func (m *Mongo) BulkWrite(ctx context.Context, coll *mongo.Collection, docs []any, opts BulkOptions) (*BulkResult, error)

type BulkOptions struct {
    BatchSize int   // 每批大小（默认 1000）
    Ordered   bool  // 是否有序（出错停止 vs 继续）
}

type BulkResult struct {
    InsertedCount int64    // 成功插入数量
    Errors        []error  // 各批次错误列表
}
```

> 完整批量写入实现见 [references/examples.md](references/examples.md#批量写入实现)

---

## 9. Change Streams

```go
coll := wrapper.Client().Database("db").Collection("orders")
pipeline := mongo.Pipeline{bson.D{{"$match", bson.D{{"operationType", "insert"}}}}}
cs, err := coll.Watch(ctx, pipeline)
defer cs.Close(ctx)
for cs.Next(ctx) {
    var event bson.M
    cs.Decode(&event)
    // 处理变更事件
}
```

> 完整 Change Streams 实现见 [references/examples.md](references/examples.md#change-streams-实现)

---

## 10. 慢查询监控

xmongo 内置慢查询检测，支持同步和异步 hook：

```go
type SlowQueryInfo struct {
    Database   string        // 数据库名
    Collection string        // 集合名
    Operation  string        // 操作类型 (findPage, bulkWrite)
    Filter     any           // 查询条件
    Duration   time.Duration // 操作耗时
}

// 配置选项
WithSlowQueryThreshold(threshold time.Duration)           // 慢查询阈值（0=禁用）
WithSlowQueryHook(hook func(ctx context.Context, info SlowQueryInfo))  // 同步 hook（阻塞）
WithAsyncSlowQueryHook(hook func(info SlowQueryInfo))     // 异步 hook（worker pool，非阻塞）
WithAsyncSlowQueryWorkers(n int)                          // Worker 数（默认 10）
WithAsyncSlowQueryQueueSize(n int)                        // 队列大小（默认 1000）
```

**监控范围**：FindPage 和 BulkWrite 自动检测慢查询。直接通过 `Client()` 的操作不会触发慢查询检测。

---

## 11. 最佳实践

### Schema 设计

使用结构体定义 schema，善用 `bson` tag (`omitempty`, 嵌入文档, 软删除字段)。

### 错误处理

```go
// 区分 NotFound / DuplicateKey / Timeout
if errors.Is(err, mongo.ErrNoDocuments) { /* 未找到 */ }
if mongo.IsDuplicateKeyError(err) { /* 重复键 */ }
```

### 索引策略

启动时 `EnsureIndexes` 确保索引存在。

### 接口测试

xmongo 使用接口适配器（clientOperations / collectionOperations）支持 GoMock 测试。

> 完整最佳实践代码见 [references/examples.md](references/examples.md#最佳实践实现)

---

## 常用命令

```bash
mongosh "mongodb://localhost:27017"           # 连接
db.users.getIndexes()                         # 查看索引
db.users.find({email: "test@example.com"}).explain("executionStats")  # 查询计划
```

---

## 检查清单

- [ ] 连接池配置合理？
- [ ] 使用结构体定义 schema？
- [ ] 常用查询字段有索引？
- [ ] 大数据量使用游标分页？
- [ ] 多文档操作使用事务？
- [ ] 错误正确处理（NotFound/DuplicateKey）？
- [ ] 支持 context 取消？
- [ ] 软删除而非硬删除？
- [ ] 慢查询监控已配置？

---

## 参考资料

- [references/examples.md](references/examples.md) - 完整代码实现（连接、CRUD、操作符、聚合、索引、事务、分页、批量写入、Change Streams、最佳实践）
