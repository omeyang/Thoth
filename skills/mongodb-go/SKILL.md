---
name: mongodb-go
description: "Go MongoDB 专家 - 使用 mongo-driver v2 进行 CRUD、聚合管道、索引优化、事务处理、分页查询(Offset/游标)、批量写入、Change Streams。适用：数据库设计、查询优化、性能调优、Schema 建模、聚合统计。不适用：关系型数据库(PostgreSQL/MySQL)操作；Redis 缓存操作；搜索引擎(Elasticsearch)场景。触发词：mongodb, mongo, bson, 聚合, aggregate, 索引, index, collection, 分页, cursor, change-stream, 事务"
---

# Go MongoDB 专家

使用 Go mongo-driver v2 开发 MongoDB 功能：$ARGUMENTS

基线：go1.24.6，`go.mongodb.org/mongo-driver/v2 v2.8.2`。所有示例按 v2 API 编写，完整可编译代码见 [references/examples.md](references/examples.md)。

---

## 0. v1 到 v2 的关键差异

| v1 | v2 | 说明 |
|---|---|---|
| `mongo.Connect(ctx, opts)` | `mongo.Connect(opts)` | 连接在后台建立，用 `Ping` 验证 |
| v1 的 `SessionContext` 类型 | 已移除 | 事务回调签名 `func(ctx context.Context) (any, error)` |
| `primitive.ObjectID` | `bson.ObjectID` | `primitive` 包并入 `bson` |
| `options.Update()` | `options.UpdateOne()` / `options.UpdateMany()` | 选项类型分离 |
| `...*options.FindOptions` | `...options.Lister[options.FindOptions]` | 透传选项时用 Lister |
| `IndexView.DropOne` 返回 `(bson.Raw, error)` | 只返回 `error` | |

导入路径统一为 `go.mongodb.org/mongo-driver/v2/{bson,mongo,mongo/options,mongo/readpref}`。

---

## 1. 连接管理

```go
func NewMongoClient(ctx context.Context, uri string) (*mongo.Client, error) {
    opts := options.Client().
        ApplyURI(uri).
        SetMaxPoolSize(100).
        SetMinPoolSize(10).
        SetMaxConnIdleTime(30 * time.Minute).
        SetServerSelectionTimeout(5 * time.Second).
        SetConnectTimeout(10 * time.Second)

    client, err := mongo.Connect(opts) // v2：不接收 ctx
    if err != nil {
        return nil, fmt.Errorf("connect mongo: %w", err)
    }
    if err := client.Ping(ctx, readpref.Primary()); err != nil {
        _ = client.Disconnect(ctx)
        return nil, fmt.Errorf("ping mongo: %w", err)
    }
    return client, nil
}
```

### 包装器策略

只包装增值功能（分页、批量写入、健康检查、索引初始化），其余操作通过 `Client()` 直接使用 driver API。包装所有 CRUD 只会增加维护成本。

```go
type MongoDB struct {
    client *mongo.Client
    db     *mongo.Database
}

func (m *MongoDB) Client() *mongo.Client                    { return m.client }
func (m *MongoDB) Collection(name string) *mongo.Collection { return m.db.Collection(name) }
func (m *MongoDB) Health(ctx context.Context) error         { return m.client.Ping(ctx, readpref.Primary()) }
func (m *MongoDB) Close(ctx context.Context) error          { return m.client.Disconnect(ctx) }
```

---

## 2. CRUD 操作

```go
coll := m.Collection("users")

result, err := coll.InsertOne(ctx, doc)
id, _ := result.InsertedID.(bson.ObjectID)

err = coll.FindOne(ctx, bson.M{"_id": id}).Decode(&user)
cursor, err := coll.Find(ctx, filter, options.Find().SetLimit(20))

_, err = coll.UpdateOne(ctx, filter, bson.M{"$set": update})
_, err = coll.UpdateMany(ctx, filter, bson.M{"$set": update})

// Upsert：v2 用 options.UpdateOne()
_, err = coll.UpdateOne(ctx, filter, bson.M{"$set": doc}, options.UpdateOne().SetUpsert(true))

// 软删除（推荐）
_, err = coll.UpdateOne(ctx, filter, bson.M{"$set": bson.M{"is_deleted": true, "deleted_at": time.Now()}})
```

错误判定用 `errors.Is(err, mongo.ErrNoDocuments)`，不要用 `==`。

> 完整实现见 [references/examples.md#crud](references/examples.md#crud)

---

## 3. 查询操作符

```go
bson.M{"age": bson.M{"$gt": 18}}                                // 比较
bson.M{"role": bson.M{"$in": []string{"admin", "moderator"}}}   // 集合
bson.M{"$and": []bson.M{{"age": bson.M{"$gte": 18}}, {"age": bson.M{"$lte": 65}}}}
bson.M{"tags": bson.M{"$all": []string{"golang", "mongodb"}}}   // 数组包含所有
bson.M{"scores": bson.M{"$elemMatch": bson.M{"$gte": 80, "$lte": 100}}}
bson.M{"name": bson.M{"$regex": "^john", "$options": "i"}}      // 正则
bson.M{"email": bson.Regex{Pattern: `gmail\.com$`, Options: "i"}}
```

`bson.M` 无序，适合过滤条件；`bson.D` 有序，用于管道阶段、排序键和需要字段顺序的命令。

---

## 4. 聚合管道

```go
pipeline := mongo.Pipeline{
    {{Key: "$match", Value: bson.D{{Key: "status", Value: "active"}}}},
    {{Key: "$group", Value: bson.D{
        {Key: "_id", Value: "$role"},
        {Key: "count", Value: bson.D{{Key: "$sum", Value: 1}}},
        {Key: "avg_age", Value: bson.D{{Key: "$avg", Value: "$age"}}},
    }}},
    {{Key: "$sort", Value: bson.D{{Key: "count", Value: -1}}}},
    {{Key: "$limit", Value: 10}},
}
cursor, err := coll.Aggregate(ctx, pipeline)
```

| 阶段 | 作用 | 注意 |
|------|------|------|
| `$match` | 筛选 | 放最前面，能用索引 |
| `$group` | 分组聚合 | `$sum`/`$avg`/`$push`/`$addToSet` |
| `$sort` | 排序 | 内存上限 100MB，大数据集需要 `allowDiskUse` |
| `$lookup` | 关联 | 关联字段要有索引 |
| `$unwind` | 展开数组 | `preserveNullAndEmptyArrays` 保留空数组 |
| `$project` | 投影/计算字段 | `$concat`、`$cond` |

> `$lookup`、`$project` 示例见 [references/examples.md#聚合](references/examples.md#聚合)

---

## 5. 索引管理

```go
coll.Indexes().CreateOne(ctx, mongo.IndexModel{
    Keys:    bson.D{{Key: "email", Value: 1}},
    Options: options.Index().SetUnique(true),
})
// 复合索引：等值字段在前，范围/排序字段在后
coll.Indexes().CreateOne(ctx, mongo.IndexModel{Keys: bson.D{{Key: "status", Value: 1}, {Key: "created_at", Value: -1}}})
// TTL 索引
coll.Indexes().CreateOne(ctx, mongo.IndexModel{
    Keys: bson.D{{Key: "expires_at", Value: 1}}, Options: options.Index().SetExpireAfterSeconds(0),
})
// 部分索引
coll.Indexes().CreateOne(ctx, mongo.IndexModel{
    Keys:    bson.D{{Key: "email", Value: 1}},
    Options: options.Index().SetPartialFilterExpression(bson.M{"status": "active"}),
})
```

- 启动时调用 `EnsureIndexes`，`CreateOne` 对已存在的同定义索引幂等
- 同一字段两个不同选项的索引必须用 `SetName` 区分
- 用 `explain("executionStats")` 确认 `IXSCAN` 而非 `COLLSCAN`

> 完整实现见 [references/examples.md#索引](references/examples.md#索引)

---

## 6. 事务处理

单文档写入天然原子。多文档事务需要副本集或分片集群。

```go
func (m *MongoDB) WithTransaction(ctx context.Context, fn func(ctx context.Context) error) error {
    session, err := m.client.StartSession()
    if err != nil {
        return fmt.Errorf("start session: %w", err)
    }
    defer session.EndSession(ctx)

    _, err = session.WithTransaction(ctx, func(ctx context.Context) (any, error) {
        return nil, fn(ctx) // 回调内的操作必须使用这个 ctx
    })
    return err
}
```

- `WithTransaction` 遇到 `TransientTransactionError` 会自动重试回调，回调必须幂等
- 事务默认 60 秒超时，不要在事务内做网络调用或长计算
- 转账示例见 [references/examples.md#事务](references/examples.md#事务)

---

## 7. 分页查询

Go 方法不能带类型参数，分页函数写成普通泛型函数：

```go
type PageOptions struct {
    Page     int64  // 从 1 开始
    PageSize int64
    Sort     bson.D
}

type PageResult[T any] struct {
    Data       []T
    Total      int64
    Page       int64
    PageSize   int64
    TotalPages int64
}

func FindPage[T any](ctx context.Context, coll *mongo.Collection, filter bson.M, opts PageOptions) (*PageResult[T], error)
```

| 方式 | 适用 | 代价 |
|------|------|------|
| Offset（`CountDocuments` + `Skip/Limit`） | 后台管理页、需要总页数 | 两次查询非原子；深翻页 `Skip` 线性扫描 |
| 游标（`_id > lastID` + `Limit`） | 无限滚动、大数据量 | 不能跳页；排序键必须唯一且有索引 |

```go
// 游标分页核心
filter["_id"] = bson.M{"$gt": lastID}
cursor, err := coll.Find(ctx, filter, options.Find().SetLimit(pageSize).SetSort(bson.D{{Key: "_id", Value: 1}}))
```

> 完整实现见 [references/examples.md#分页](references/examples.md#分页)

---

## 8. 批量写入

```go
type BulkOptions struct {
    BatchSize int  // 每批大小，默认 1000
    Ordered   bool // 有序：出错即停；无序：并行且继续
}

func (m *MongoDB) BulkInsert(ctx context.Context, coll string, docs []any, opts BulkOptions) (*BulkResult, error)
```

- 每批构造 `[]mongo.WriteModel`，用 `mongo.NewInsertOneModel().SetDocument(doc)`
- `Ordered=false` 吞吐更高；`BulkWriteException` 仍会带回成功计数
- 每批开始前检查 `ctx.Err()`，避免取消后继续写

> 完整实现见 [references/examples.md#批量写入](references/examples.md#批量写入)

---

## 9. Change Streams

```go
pipeline := mongo.Pipeline{{{Key: "$match", Value: bson.D{{Key: "operationType", Value: "insert"}}}}}
stream, err := coll.Watch(ctx, pipeline, options.ChangeStream().SetFullDocument(options.UpdateLookup))
defer stream.Close(ctx)
for stream.Next(ctx) {
    var event bson.M
    if err := stream.Decode(&event); err != nil { continue }
    // 处理 event["operationType"], event["fullDocument"]
}
return stream.Err()
```

- 需要副本集；断线后用 `SetResumeAfter(stream.ResumeToken())` 续接
- `UpdateLookup` 让 update 事件带回完整文档

> 完整实现见 [references/examples.md#change-streams](references/examples.md#change-streams)

---

## 10. 最佳实践

### Schema

```go
type User struct {
    ID        bson.ObjectID `bson:"_id,omitempty"`
    Email     string        `bson:"email"`
    Profile   *Profile      `bson:"profile,omitempty"`    // 嵌入文档
    CreatedAt time.Time     `bson:"created_at"`
    DeletedAt *time.Time    `bson:"deleted_at,omitempty"` // 软删除
}
```

- 一起读的数据嵌入，独立增长的数据引用；单文档上限 16MB
- 时间统一 UTC `time.Time`，不要存字符串

### 错误处理

```go
switch {
case errors.Is(err, mongo.ErrNoDocuments):
    return ErrNotFound
case mongo.IsDuplicateKeyError(err):
    return fmt.Errorf("%w: %w", ErrDuplicate, err)
case mongo.IsTimeout(err):
    return fmt.Errorf("timeout: %w", err)
}
```

### 慢查询

- driver 层：`options.Client().SetMonitor(&event.CommandMonitor{...})` 记录 `CommandSucceededEvent.Duration` 超阈值的命令
- 服务端：`db.setProfilingLevel(1, {slowms: 100})` 后查 `system.profile`

### 测试

Repository 依赖 `*mongo.Collection` 具体类型，单元测试用 `mtest`（driver 自带 mock）或 testcontainers 起真实实例；接口抽象只在需要替换存储时引入。

---

## 常用命令

```bash
mongosh "mongodb://localhost:27017"
db.users.getIndexes()
db.users.find({email: "test@example.com"}).explain("executionStats")
db.currentOp({"secs_running": {$gt: 3}})
```

---

## 检查清单

- [ ] `mongo.Connect(opts)` 后 `Ping` 验证，连接池参数按并发量配置？
- [ ] 常用查询字段有索引，复合索引顺序符合 ESR（等值、排序、范围）？
- [ ] 大数据量列表用游标分页？
- [ ] 多文档写入用事务，回调幂等？
- [ ] `errors.Is(err, mongo.ErrNoDocuments)` / `IsDuplicateKeyError` 分类处理？
- [ ] 所有操作接收并透传 `ctx`？
- [ ] 软删除而非硬删除？
- [ ] Change Streams 有断线续接？

---

## 参考资料

- [references/examples.md](references/examples.md) - 完整可编译代码（连接、CRUD、聚合、索引、事务、分页、批量写入、Change Streams）
- [mongo-driver v2 pkg.go.dev](https://pkg.go.dev/go.mongodb.org/mongo-driver/v2/mongo)
- [MongoDB Go Driver 文档](https://www.mongodb.com/docs/drivers/go/current/)
