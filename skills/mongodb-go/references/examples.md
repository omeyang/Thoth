# Go MongoDB - 完整代码示例

## 目录

- [包装器模式实现](#包装器模式实现)
- [CRUD 操作实现](#crud-操作实现)
- [查询操作符参考](#查询操作符参考)
- [聚合管道示例](#聚合管道示例)
- [索引管理实现](#索引管理实现)
- [事务处理实现](#事务处理实现)
- [分页查询实现](#分页查询实现)
- [批量写入实现](#批量写入实现)
- [Change Streams 实现](#change-streams-实现)
- [最佳实践实现](#最佳实践实现)

---

## 包装器模式实现

参考 xmongo 的设计：不包装所有 API，只提供增值功能。

```go
type MongoDB struct {
    client *mongo.Client
    db     *mongo.Database
}

func New(client *mongo.Client, dbName string) *MongoDB {
    return &MongoDB{
        client: client,
        db:     client.Database(dbName),
    }
}

// Client 暴露底层客户端，用于高级操作
func (m *MongoDB) Client() *mongo.Client {
    return m.client
}

// Collection 获取集合
func (m *MongoDB) Collection(name string) *mongo.Collection {
    return m.db.Collection(name)
}

// Health 健康检查
func (m *MongoDB) Health(ctx context.Context) error {
    return m.client.Ping(ctx, readpref.Primary())
}

// Close 关闭连接
func (m *MongoDB) Close(ctx context.Context) error {
    return m.client.Disconnect(ctx)
}
```

---

## CRUD 操作实现

### 插入

```go
import "go.mongodb.org/mongo-driver/v2/bson"

// 插入单个文档
func (m *MongoDB) InsertOne(ctx context.Context, coll string, doc any) (string, error) {
    result, err := m.Collection(coll).InsertOne(ctx, doc)
    if err != nil {
        return "", fmt.Errorf("insert one: %w", err)
    }
    return result.InsertedID.(bson.ObjectID).Hex(), nil
}

// 批量插入
func (m *MongoDB) InsertMany(ctx context.Context, coll string, docs []any) ([]string, error) {
    result, err := m.Collection(coll).InsertMany(ctx, docs)
    if err != nil {
        return nil, fmt.Errorf("insert many: %w", err)
    }

    ids := make([]string, len(result.InsertedIDs))
    for i, id := range result.InsertedIDs {
        ids[i] = id.(bson.ObjectID).Hex()
    }
    return ids, nil
}
```

### 查询

```go
// 查询单个
func (m *MongoDB) FindOne(ctx context.Context, coll string, filter bson.M, result any) error {
    err := m.Collection(coll).FindOne(ctx, filter).Decode(result)
    if err == mongo.ErrNoDocuments {
        return ErrNotFound
    }
    return err
}

// 查询多个
func (m *MongoDB) Find(ctx context.Context, coll string, filter bson.M, results any, opts ...*options.FindOptions) error {
    cursor, err := m.Collection(coll).Find(ctx, filter, opts...)
    if err != nil {
        return fmt.Errorf("find: %w", err)
    }
    defer cursor.Close(ctx)

    return cursor.All(ctx, results)
}

// 通过 ID 查询
func (m *MongoDB) FindByID(ctx context.Context, coll string, id string, result any) error {
    oid, err := bson.ObjectIDFromHex(id)
    if err != nil {
        return fmt.Errorf("invalid object id: %w", err)
    }
    return m.FindOne(ctx, coll, bson.M{"_id": oid}, result)
}
```

### 更新

```go
// 更新单个
func (m *MongoDB) UpdateOne(ctx context.Context, coll string, filter, update bson.M) (int64, error) {
    result, err := m.Collection(coll).UpdateOne(ctx, filter, bson.M{"$set": update})
    if err != nil {
        return 0, fmt.Errorf("update one: %w", err)
    }
    return result.ModifiedCount, nil
}

// 更新多个
func (m *MongoDB) UpdateMany(ctx context.Context, coll string, filter, update bson.M) (int64, error) {
    result, err := m.Collection(coll).UpdateMany(ctx, filter, bson.M{"$set": update})
    if err != nil {
        return 0, fmt.Errorf("update many: %w", err)
    }
    return result.ModifiedCount, nil
}

// Upsert（不存在则插入）
func (m *MongoDB) Upsert(ctx context.Context, coll string, filter, update bson.M) error {
    opts := options.Update().SetUpsert(true)
    _, err := m.Collection(coll).UpdateOne(ctx, filter, bson.M{"$set": update}, opts)
    return err
}
```

### 删除

```go
// 删除单个
func (m *MongoDB) DeleteOne(ctx context.Context, coll string, filter bson.M) (int64, error) {
    result, err := m.Collection(coll).DeleteOne(ctx, filter)
    if err != nil {
        return 0, fmt.Errorf("delete one: %w", err)
    }
    return result.DeletedCount, nil
}

// 删除多个
func (m *MongoDB) DeleteMany(ctx context.Context, coll string, filter bson.M) (int64, error) {
    result, err := m.Collection(coll).DeleteMany(ctx, filter)
    if err != nil {
        return 0, fmt.Errorf("delete many: %w", err)
    }
    return result.DeletedCount, nil
}

// 软删除（推荐）
func (m *MongoDB) SoftDelete(ctx context.Context, coll string, filter bson.M) error {
    update := bson.M{
        "deleted_at": time.Now(),
        "is_deleted": true,
    }
    _, err := m.UpdateOne(ctx, coll, filter, update)
    return err
}
```

---

## 查询操作符参考

### 比较操作符

```go
// 大于
bson.M{"age": bson.M{"$gt": 18}}

// 大于等于
bson.M{"age": bson.M{"$gte": 18}}

// 小于
bson.M{"age": bson.M{"$lt": 65}}

// 小于等于
bson.M{"age": bson.M{"$lte": 65}}

// 不等于
bson.M{"status": bson.M{"$ne": "deleted"}}

// 在数组中
bson.M{"role": bson.M{"$in": []string{"admin", "moderator"}}}

// 不在数组中
bson.M{"status": bson.M{"$nin": []string{"deleted", "banned"}}}
```

### 逻辑操作符

```go
// AND
bson.M{"$and": []bson.M{
    {"age": bson.M{"$gte": 18}},
    {"age": bson.M{"$lte": 65}},
}}

// OR
bson.M{"$or": []bson.M{
    {"role": "admin"},
    {"role": "moderator"},
}}

// NOT
bson.M{"age": bson.M{"$not": bson.M{"$lt": 18}}}
```

### 数组操作符

```go
// 数组包含元素
bson.M{"tags": "golang"}

// 数组包含所有元素
bson.M{"tags": bson.M{"$all": []string{"golang", "mongodb"}}}

// 数组大小
bson.M{"tags": bson.M{"$size": 3}}

// 数组元素匹配条件
bson.M{"scores": bson.M{"$elemMatch": bson.M{"$gte": 80, "$lte": 100}}}
```

### 正则表达式

```go
// 模糊匹配
bson.M{"name": bson.M{"$regex": "^john", "$options": "i"}}

// 使用 Go 正则
bson.M{"email": bson.Regex{Pattern: `gmail\.com$`, Options: "i"}}
```

---

## 聚合管道示例

### 基本聚合

```go
func (m *MongoDB) Aggregate(ctx context.Context, coll string, pipeline mongo.Pipeline, results any) error {
    cursor, err := m.Collection(coll).Aggregate(ctx, pipeline)
    if err != nil {
        return fmt.Errorf("aggregate: %w", err)
    }
    defer cursor.Close(ctx)

    return cursor.All(ctx, results)
}
```

### 常用聚合阶段

```go
// 统计示例：按角色分组统计用户
pipeline := mongo.Pipeline{
    // $match - 筛选
    {{"$match", bson.D{{"status", "active"}}}},

    // $group - 分组
    {{"$group", bson.D{
        {"_id", "$role"},
        {"count", bson.D{{"$sum", 1}}},
        {"avg_age", bson.D{{"$avg", "$age"}}},
        {"users", bson.D{{"$push", "$name"}}},
    }}},

    // $sort - 排序
    {{"$sort", bson.D{{"count", -1}}}},

    // $limit - 限制
    {{"$limit", 10}},
}

var results []struct {
    ID     string   `bson:"_id"`
    Count  int      `bson:"count"`
    AvgAge float64  `bson:"avg_age"`
    Users  []string `bson:"users"`
}
err := m.Aggregate(ctx, "users", pipeline, &results)
```

### $lookup 关联查询

```go
// 关联查询：获取用户及其订单
pipeline := mongo.Pipeline{
    {{"$lookup", bson.D{
        {"from", "orders"},
        {"localField", "_id"},
        {"foreignField", "user_id"},
        {"as", "orders"},
    }}},
    {{"$unwind", bson.D{
        {"path", "$orders"},
        {"preserveNullAndEmptyArrays", true},
    }}},
}
```

### $project 投影

```go
// 只返回指定字段
pipeline := mongo.Pipeline{
    {{"$project", bson.D{
        {"_id", 1},
        {"name", 1},
        {"email", 1},
        {"full_name", bson.D{{"$concat", bson.A{"$first_name", " ", "$last_name"}}}},
        {"age_group", bson.D{{"$cond", bson.A{
            bson.D{{"$lt", bson.A{"$age", 18}}},
            "minor",
            "adult",
        }}}},
    }}},
}
```

---

## 索引管理实现

### 创建索引

```go
import "go.mongodb.org/mongo-driver/v2/mongo/options"

func (m *MongoDB) CreateIndex(ctx context.Context, coll string, keys bson.D, opts *options.IndexOptions) (string, error) {
    model := mongo.IndexModel{
        Keys:    keys,
        Options: opts,
    }
    return m.Collection(coll).Indexes().CreateOne(ctx, model)
}

// 单字段索引
m.CreateIndex(ctx, "users", bson.D{{"email", 1}}, options.Index().SetUnique(true))

// 复合索引
m.CreateIndex(ctx, "users", bson.D{{"status", 1}, {"created_at", -1}}, nil)

// 文本索引
m.CreateIndex(ctx, "articles", bson.D{{"title", "text"}, {"content", "text"}}, nil)

// TTL 索引（自动过期）
m.CreateIndex(ctx, "sessions", bson.D{{"expires_at", 1}},
    options.Index().SetExpireAfterSeconds(0))

// 部分索引
m.CreateIndex(ctx, "users", bson.D{{"email", 1}},
    options.Index().SetPartialFilterExpression(bson.M{"status": "active"}))
```

### 查看索引

```go
func (m *MongoDB) ListIndexes(ctx context.Context, coll string) ([]bson.M, error) {
    cursor, err := m.Collection(coll).Indexes().List(ctx)
    if err != nil {
        return nil, err
    }
    defer cursor.Close(ctx)

    var indexes []bson.M
    return indexes, cursor.All(ctx, &indexes)
}
```

### 删除索引

```go
func (m *MongoDB) DropIndex(ctx context.Context, coll, indexName string) error {
    _, err := m.Collection(coll).Indexes().DropOne(ctx, indexName)
    return err
}
```

---

## 事务处理实现

### 多文档事务

```go
func (m *MongoDB) WithTransaction(ctx context.Context, fn func(sc mongo.SessionContext) error) error {
    session, err := m.client.StartSession()
    if err != nil {
        return fmt.Errorf("start session: %w", err)
    }
    defer session.EndSession(ctx)

    _, err = session.WithTransaction(ctx, func(sc mongo.SessionContext) (any, error) {
        return nil, fn(sc)
    })
    return err
}

// 使用示例：转账操作
err := m.WithTransaction(ctx, func(sc mongo.SessionContext) error {
    // 扣款
    _, err := m.Collection("accounts").UpdateOne(sc,
        bson.M{"_id": fromID},
        bson.M{"$inc": bson.M{"balance": -amount}},
    )
    if err != nil {
        return err
    }

    // 入账
    _, err = m.Collection("accounts").UpdateOne(sc,
        bson.M{"_id": toID},
        bson.M{"$inc": bson.M{"balance": amount}},
    )
    if err != nil {
        return err
    }

    // 记录交易
    _, err = m.Collection("transactions").InsertOne(sc, bson.M{
        "from":   fromID,
        "to":     toID,
        "amount": amount,
        "time":   time.Now(),
    })
    return err
})
```

---

## 分页查询实现

### Offset 分页

```go
type PageOptions struct {
    Page     int64
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

func (m *MongoDB) FindPage[T any](ctx context.Context, coll string, filter bson.M, opts PageOptions) (*PageResult[T], error) {
    collection := m.Collection(coll)

    // 计算 total（注意：非原子操作）
    total, err := collection.CountDocuments(ctx, filter)
    if err != nil {
        return nil, fmt.Errorf("count: %w", err)
    }

    // 查询数据
    skip := (opts.Page - 1) * opts.PageSize
    findOpts := options.Find().
        SetSkip(skip).
        SetLimit(opts.PageSize).
        SetSort(opts.Sort)

    var data []T
    cursor, err := collection.Find(ctx, filter, findOpts)
    if err != nil {
        return nil, fmt.Errorf("find: %w", err)
    }
    defer cursor.Close(ctx)

    if err := cursor.All(ctx, &data); err != nil {
        return nil, fmt.Errorf("decode: %w", err)
    }

    totalPages := (total + opts.PageSize - 1) / opts.PageSize

    return &PageResult[T]{
        Data:       data,
        Total:      total,
        Page:       opts.Page,
        PageSize:   opts.PageSize,
        TotalPages: totalPages,
    }, nil
}
```

### 游标分页（推荐大数据量）

```go
// 基于 _id 的游标分页，避免 COUNT 开销
func (m *MongoDB) FindAfter[T any](ctx context.Context, coll string, filter bson.M, afterID string, limit int64) ([]T, error) {
    // 复制 filter，避免修改调用方的 map
    f := make(bson.M, len(filter)+1)
    for k, v := range filter {
        f[k] = v
    }

    if afterID != "" {
        oid, err := bson.ObjectIDFromHex(afterID)
        if err != nil {
            return nil, err
        }
        f["_id"] = bson.M{"$gt": oid}
    }
    filter = f

    opts := options.Find().
        SetLimit(limit).
        SetSort(bson.D{{"_id", 1}})

    var data []T
    cursor, err := m.Collection(coll).Find(ctx, filter, opts)
    if err != nil {
        return nil, err
    }
    defer cursor.Close(ctx)

    return data, cursor.All(ctx, &data)
}
```

---

## 批量写入实现

```go
type BulkOptions struct {
    BatchSize int
    Ordered   bool
}

func (m *MongoDB) BulkWrite(ctx context.Context, coll string, docs []any, opts BulkOptions) error {
    if opts.BatchSize <= 0 {
        opts.BatchSize = 1000
    }

    collection := m.Collection(coll)
    writeOpts := options.BulkWrite().SetOrdered(opts.Ordered)

    for i := 0; i < len(docs); i += opts.BatchSize {
        end := i + opts.BatchSize
        if end > len(docs) {
            end = len(docs)
        }

        batch := docs[i:end]
        models := make([]mongo.WriteModel, len(batch))
        for j, doc := range batch {
            models[j] = mongo.NewInsertOneModel().SetDocument(doc)
        }

        _, err := collection.BulkWrite(ctx, models, writeOpts)
        if err != nil {
            return fmt.Errorf("bulk write batch %d: %w", i/opts.BatchSize, err)
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

## Change Streams 实现

```go
func (m *MongoDB) Watch(ctx context.Context, coll string, pipeline mongo.Pipeline, handler func(bson.M)) error {
    opts := options.ChangeStream().SetFullDocument(options.UpdateLookup)

    stream, err := m.Collection(coll).Watch(ctx, pipeline, opts)
    if err != nil {
        return fmt.Errorf("watch: %w", err)
    }
    defer stream.Close(ctx)

    for stream.Next(ctx) {
        var event bson.M
        if err := stream.Decode(&event); err != nil {
            continue
        }
        handler(event)
    }

    return stream.Err()
}

// 使用示例：监听用户变更
pipeline := mongo.Pipeline{
    {{"$match", bson.D{
        {"operationType", bson.D{{"$in", bson.A{"insert", "update", "delete"}}}},
    }}},
}

go m.Watch(ctx, "users", pipeline, func(event bson.M) {
    log.Printf("User change: %v", event["operationType"])
})
```

---

## 最佳实践实现

### Schema 设计

```go
// 使用结构体定义 schema
type User struct {
    ID        bson.ObjectID `bson:"_id,omitempty"`
    Name      string        `bson:"name"`
    Email     string        `bson:"email"`
    Age       int           `bson:"age,omitempty"`
    Role      string        `bson:"role"`
    Tags      []string      `bson:"tags,omitempty"`
    Profile   *Profile      `bson:"profile,omitempty"` // 嵌入文档
    CreatedAt time.Time     `bson:"created_at"`
    UpdatedAt time.Time     `bson:"updated_at"`
    DeletedAt *time.Time    `bson:"deleted_at,omitempty"` // 软删除
}

type Profile struct {
    Avatar string `bson:"avatar,omitempty"`
    Bio    string `bson:"bio,omitempty"`
}
```

### 连接池配置

```go
opts := options.Client().
    ApplyURI(uri).
    SetMaxPoolSize(100).        // 最大连接数
    SetMinPoolSize(10).         // 最小连接数
    SetMaxConnIdleTime(30*time.Minute). // 空闲连接超时
    SetServerSelectionTimeout(5*time.Second). // 服务器选择超时
    SetConnectTimeout(10*time.Second) // 连接超时
```

### 错误处理

```go
import "go.mongodb.org/mongo-driver/v2/mongo"

var ErrNotFound = errors.New("document not found")

func handleMongoError(err error) error {
    if err == nil {
        return nil
    }

    if err == mongo.ErrNoDocuments {
        return ErrNotFound
    }

    // 检查重复键错误
    if mongo.IsDuplicateKeyError(err) {
        return fmt.Errorf("duplicate key: %w", err)
    }

    // 检查超时
    if mongo.IsTimeout(err) {
        return fmt.Errorf("timeout: %w", err)
    }

    return err
}
```

### 索引策略

```go
// 启动时确保索引存在
func (m *MongoDB) EnsureIndexes(ctx context.Context) error {
    // 用户集合
    if _, err := m.CreateIndex(ctx, "users",
        bson.D{{"email", 1}},
        options.Index().SetUnique(true)); err != nil {
        return err
    }

    if _, err := m.CreateIndex(ctx, "users",
        bson.D{{"status", 1}, {"created_at", -1}},
        nil); err != nil {
        return err
    }

    // 订单集合
    if _, err := m.CreateIndex(ctx, "orders",
        bson.D{{"user_id", 1}, {"created_at", -1}},
        nil); err != nil {
        return err
    }

    return nil
}
```
