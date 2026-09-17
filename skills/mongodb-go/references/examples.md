# Go MongoDB - 完整代码示例

## 目录

- [导入与依赖](#导入与依赖)
- [连接](#连接)
- [包装器](#包装器)
- [CRUD](#crud)
- [聚合](#聚合)
- [索引](#索引)
- [事务](#事务)
- [分页](#分页)
- [批量写入](#批量写入)
- [Change Streams](#change-streams)
- [Schema 与错误处理](#schema-与错误处理)

---

所有代码在 go1.24.6 + `go.mongodb.org/mongo-driver/v2 v2.8.2` 下通过 `go vet`。示例合并在一个包里，导入块只列一次。

```text
go get go.mongodb.org/mongo-driver/v2@v2.8.2
```

v2 相对 v1 的关键差异（示例均按 v2 写）：

| v1 | v2 |
|---|---|
| `mongo.Connect(ctx, opts)` | `mongo.Connect(opts)`，连接在后台建立，用 `Ping` 验证 |
| v1 的 `SessionContext` 类型 | 已移除，事务回调只接收 `context.Context` |
| `primitive.ObjectID` | `bson.ObjectID`（`primitive` 包并入 `bson`） |
| `options.Update()` | `options.UpdateOne()` / `options.UpdateMany()` 分离 |
| `opts ...*options.FindOptions` | `opts ...options.Lister[options.FindOptions]` |
| `IndexView.DropOne` 返回 `(bson.Raw, error)` | 只返回 `error` |

---

## 导入与依赖

```go
package mongodb

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"time"

	"go.mongodb.org/mongo-driver/v2/bson"
	"go.mongodb.org/mongo-driver/v2/mongo"
	"go.mongodb.org/mongo-driver/v2/mongo/options"
	"go.mongodb.org/mongo-driver/v2/mongo/readpref"
)
```

---

## 连接

```go
func NewMongoClient(ctx context.Context, uri string) (*mongo.Client, error) {
	opts := options.Client().
		ApplyURI(uri).
		SetMaxPoolSize(100).
		SetMinPoolSize(10).
		SetMaxConnIdleTime(30 * time.Minute).
		SetServerSelectionTimeout(5 * time.Second).
		SetConnectTimeout(10 * time.Second)

	// v2：Connect 不再接收 ctx，连接在后台建立
	client, err := mongo.Connect(opts)
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

---

## 包装器

```go
type MongoDB struct {
	client *mongo.Client
	db     *mongo.Database
}

func New(client *mongo.Client, dbName string) *MongoDB {
	return &MongoDB{client: client, db: client.Database(dbName)}
}

// Client 暴露底层客户端，用于包装器未覆盖的操作
func (m *MongoDB) Client() *mongo.Client { return m.client }

// Collection 获取集合
func (m *MongoDB) Collection(name string) *mongo.Collection { return m.db.Collection(name) }

// Health 健康检查
func (m *MongoDB) Health(ctx context.Context) error {
	return m.client.Ping(ctx, readpref.Primary())
}

// Close 关闭连接
func (m *MongoDB) Close(ctx context.Context) error { return m.client.Disconnect(ctx) }
```

---

## CRUD

```go
var ErrNotFound = errors.New("document not found")

func (m *MongoDB) InsertOne(ctx context.Context, coll string, doc any) (string, error) {
	result, err := m.Collection(coll).InsertOne(ctx, doc)
	if err != nil {
		return "", fmt.Errorf("insert one: %w", err)
	}
	id, ok := result.InsertedID.(bson.ObjectID)
	if !ok {
		return "", fmt.Errorf("unexpected inserted id type %T", result.InsertedID)
	}
	return id.Hex(), nil
}

func (m *MongoDB) InsertMany(ctx context.Context, coll string, docs []any) ([]string, error) {
	result, err := m.Collection(coll).InsertMany(ctx, docs)
	if err != nil {
		return nil, fmt.Errorf("insert many: %w", err)
	}
	ids := make([]string, 0, len(result.InsertedIDs))
	for _, raw := range result.InsertedIDs {
		if id, ok := raw.(bson.ObjectID); ok {
			ids = append(ids, id.Hex())
		}
	}
	return ids, nil
}

func (m *MongoDB) FindOne(ctx context.Context, coll string, filter bson.M, result any) error {
	err := m.Collection(coll).FindOne(ctx, filter).Decode(result)
	if errors.Is(err, mongo.ErrNoDocuments) {
		return ErrNotFound
	}
	return err
}

// Find 查询多个；opts 为 v2 的 options.Lister
func (m *MongoDB) Find(ctx context.Context, coll string, filter bson.M, results any, opts ...options.Lister[options.FindOptions]) error {
	cursor, err := m.Collection(coll).Find(ctx, filter, opts...)
	if err != nil {
		return fmt.Errorf("find: %w", err)
	}
	defer cursor.Close(ctx)
	return cursor.All(ctx, results)
}

func (m *MongoDB) FindByID(ctx context.Context, coll string, id string, result any) error {
	oid, err := bson.ObjectIDFromHex(id)
	if err != nil {
		return fmt.Errorf("invalid object id: %w", err)
	}
	return m.FindOne(ctx, coll, bson.M{"_id": oid}, result)
}

func (m *MongoDB) UpdateOne(ctx context.Context, coll string, filter, update bson.M) (int64, error) {
	result, err := m.Collection(coll).UpdateOne(ctx, filter, bson.M{"$set": update})
	if err != nil {
		return 0, fmt.Errorf("update one: %w", err)
	}
	return result.ModifiedCount, nil
}

func (m *MongoDB) UpdateMany(ctx context.Context, coll string, filter, update bson.M) (int64, error) {
	result, err := m.Collection(coll).UpdateMany(ctx, filter, bson.M{"$set": update})
	if err != nil {
		return 0, fmt.Errorf("update many: %w", err)
	}
	return result.ModifiedCount, nil
}

// Upsert 不存在则插入。v2 中 UpdateOne 与 UpdateMany 的选项类型已分离
func (m *MongoDB) Upsert(ctx context.Context, coll string, filter, update bson.M) error {
	opts := options.UpdateOne().SetUpsert(true)
	_, err := m.Collection(coll).UpdateOne(ctx, filter, bson.M{"$set": update}, opts)
	return err
}

func (m *MongoDB) DeleteOne(ctx context.Context, coll string, filter bson.M) (int64, error) {
	result, err := m.Collection(coll).DeleteOne(ctx, filter)
	if err != nil {
		return 0, fmt.Errorf("delete one: %w", err)
	}
	return result.DeletedCount, nil
}

func (m *MongoDB) DeleteMany(ctx context.Context, coll string, filter bson.M) (int64, error) {
	result, err := m.Collection(coll).DeleteMany(ctx, filter)
	if err != nil {
		return 0, fmt.Errorf("delete many: %w", err)
	}
	return result.DeletedCount, nil
}

// SoftDelete 软删除（推荐）
func (m *MongoDB) SoftDelete(ctx context.Context, coll string, filter bson.M) error {
	_, err := m.UpdateOne(ctx, coll, filter, bson.M{
		"deleted_at": time.Now(),
		"is_deleted": true,
	})
	return err
}
```

---

## 聚合

```go
func (m *MongoDB) Aggregate(ctx context.Context, coll string, pipeline mongo.Pipeline, results any) error {
	cursor, err := m.Collection(coll).Aggregate(ctx, pipeline)
	if err != nil {
		return fmt.Errorf("aggregate: %w", err)
	}
	defer cursor.Close(ctx)
	return cursor.All(ctx, results)
}

type RoleStat struct {
	Role   string   `bson:"_id"`
	Count  int      `bson:"count"`
	AvgAge float64  `bson:"avg_age"`
	Users  []string `bson:"users"`
}

func (m *MongoDB) RoleStats(ctx context.Context) ([]RoleStat, error) {
	pipeline := mongo.Pipeline{
		{{Key: "$match", Value: bson.D{{Key: "status", Value: "active"}}}},
		{{Key: "$group", Value: bson.D{
			{Key: "_id", Value: "$role"},
			{Key: "count", Value: bson.D{{Key: "$sum", Value: 1}}},
			{Key: "avg_age", Value: bson.D{{Key: "$avg", Value: "$age"}}},
			{Key: "users", Value: bson.D{{Key: "$push", Value: "$name"}}},
		}}},
		{{Key: "$sort", Value: bson.D{{Key: "count", Value: -1}}}},
		{{Key: "$limit", Value: 10}},
	}
	var results []RoleStat
	if err := m.Aggregate(ctx, "users", pipeline, &results); err != nil {
		return nil, err
	}
	return results, nil
}

// LookupPipeline 关联查询：用户及其订单
var LookupPipeline = mongo.Pipeline{
	{{Key: "$lookup", Value: bson.D{
		{Key: "from", Value: "orders"},
		{Key: "localField", Value: "_id"},
		{Key: "foreignField", Value: "user_id"},
		{Key: "as", Value: "orders"},
	}}},
	{{Key: "$unwind", Value: bson.D{
		{Key: "path", Value: "$orders"},
		{Key: "preserveNullAndEmptyArrays", Value: true},
	}}},
}

// ProjectPipeline 投影与计算字段
var ProjectPipeline = mongo.Pipeline{
	{{Key: "$project", Value: bson.D{
		{Key: "_id", Value: 1},
		{Key: "name", Value: 1},
		{Key: "email", Value: 1},
		{Key: "full_name", Value: bson.D{{Key: "$concat", Value: bson.A{"$first_name", " ", "$last_name"}}}},
		{Key: "age_group", Value: bson.D{{Key: "$cond", Value: bson.A{
			bson.D{{Key: "$lt", Value: bson.A{"$age", 18}}},
			"minor",
			"adult",
		}}}},
	}}},
}
```

---

## 索引

```go
func (m *MongoDB) CreateIndex(ctx context.Context, coll string, keys bson.D, opts *options.IndexOptionsBuilder) (string, error) {
	model := mongo.IndexModel{Keys: keys, Options: opts}
	return m.Collection(coll).Indexes().CreateOne(ctx, model)
}

func (m *MongoDB) ListIndexes(ctx context.Context, coll string) ([]bson.M, error) {
	cursor, err := m.Collection(coll).Indexes().List(ctx)
	if err != nil {
		return nil, err
	}
	defer cursor.Close(ctx)
	var indexes []bson.M
	if err := cursor.All(ctx, &indexes); err != nil {
		return nil, err
	}
	return indexes, nil
}

// DropIndex v2 的 DropOne 只返回 error
func (m *MongoDB) DropIndex(ctx context.Context, coll, indexName string) error {
	return m.Collection(coll).Indexes().DropOne(ctx, indexName)
}

// EnsureIndexes 启动时确保索引存在（CreateOne 幂等）
func (m *MongoDB) EnsureIndexes(ctx context.Context) error {
	specs := []struct {
		coll string
		keys bson.D
		opts *options.IndexOptionsBuilder
	}{
		{"users", bson.D{{Key: "email", Value: 1}}, options.Index().SetUnique(true)},
		{"users", bson.D{{Key: "status", Value: 1}, {Key: "created_at", Value: -1}}, nil},
		{"articles", bson.D{{Key: "title", Value: "text"}, {Key: "content", Value: "text"}}, nil},
		{"sessions", bson.D{{Key: "expires_at", Value: 1}}, options.Index().SetExpireAfterSeconds(0)},
		{"users", bson.D{{Key: "email", Value: 1}}, options.Index().
			SetName("email_active").
			SetPartialFilterExpression(bson.M{"status": "active"})},
		{"orders", bson.D{{Key: "user_id", Value: 1}, {Key: "created_at", Value: -1}}, nil},
	}
	for _, s := range specs {
		if _, err := m.CreateIndex(ctx, s.coll, s.keys, s.opts); err != nil {
			return fmt.Errorf("ensure index on %s: %w", s.coll, err)
		}
	}
	return nil
}
```

---

## 事务

事务需要副本集或分片集群。`WithTransaction` 内部处理 `TransientTransactionError` 重试，回调可能被多次执行，必须幂等。

```go
// WithTransaction v2：回调只接收 context.Context（SessionContext 已移除）
func (m *MongoDB) WithTransaction(ctx context.Context, fn func(ctx context.Context) error) error {
	session, err := m.client.StartSession()
	if err != nil {
		return fmt.Errorf("start session: %w", err)
	}
	defer session.EndSession(ctx)

	_, err = session.WithTransaction(ctx, func(ctx context.Context) (any, error) {
		return nil, fn(ctx)
	})
	return err
}

// Transfer 转账：两笔更新与一条流水在同一事务
func (m *MongoDB) Transfer(ctx context.Context, fromID, toID bson.ObjectID, amount int64) error {
	return m.WithTransaction(ctx, func(ctx context.Context) error {
		accounts := m.Collection("accounts")
		if _, err := accounts.UpdateOne(ctx,
			bson.M{"_id": fromID, "balance": bson.M{"$gte": amount}},
			bson.M{"$inc": bson.M{"balance": -amount}},
		); err != nil {
			return err
		}
		if _, err := accounts.UpdateOne(ctx,
			bson.M{"_id": toID},
			bson.M{"$inc": bson.M{"balance": amount}},
		); err != nil {
			return err
		}
		_, err := m.Collection("transactions").InsertOne(ctx, bson.M{
			"from": fromID, "to": toID, "amount": amount, "time": time.Now(),
		})
		return err
	})
}
```

---

## 分页

Go 方法不能带类型参数，`FindPage` / `FindAfter` 写成普通泛型函数，接收 `*mongo.Collection`。

```go
type PageOptions struct {
	Page     int64 // 从 1 开始
	PageSize int64
	Sort     bson.D // 如 bson.D{{Key: "created_at", Value: -1}}
}

type PageResult[T any] struct {
	Data       []T
	Total      int64
	Page       int64
	PageSize   int64
	TotalPages int64
}

// FindPage Offset 分页。Go 方法不能带类型参数，因此写成普通泛型函数
func FindPage[T any](ctx context.Context, coll *mongo.Collection, filter bson.M, opts PageOptions) (*PageResult[T], error) {
	if opts.Page < 1 {
		opts.Page = 1
	}
	if opts.PageSize <= 0 {
		opts.PageSize = 20
	}

	// COUNT 与 Find 是两次独立查询，非原子
	total, err := coll.CountDocuments(ctx, filter)
	if err != nil {
		return nil, fmt.Errorf("count: %w", err)
	}

	findOpts := options.Find().
		SetSkip((opts.Page - 1) * opts.PageSize).
		SetLimit(opts.PageSize)
	if len(opts.Sort) > 0 {
		findOpts.SetSort(opts.Sort)
	}

	cursor, err := coll.Find(ctx, filter, findOpts)
	if err != nil {
		return nil, fmt.Errorf("find: %w", err)
	}
	defer cursor.Close(ctx)

	var data []T
	if err := cursor.All(ctx, &data); err != nil {
		return nil, fmt.Errorf("decode: %w", err)
	}

	return &PageResult[T]{
		Data:       data,
		Total:      total,
		Page:       opts.Page,
		PageSize:   opts.PageSize,
		TotalPages: (total + opts.PageSize - 1) / opts.PageSize,
	}, nil
}

// FindAfter 基于 _id 的游标分页，避免 COUNT 与 SKIP 开销
func FindAfter[T any](ctx context.Context, coll *mongo.Collection, filter bson.M, afterID string, limit int64) ([]T, error) {
	f := make(bson.M, len(filter)+1)
	for k, v := range filter {
		f[k] = v
	}
	if afterID != "" {
		oid, err := bson.ObjectIDFromHex(afterID)
		if err != nil {
			return nil, fmt.Errorf("invalid cursor: %w", err)
		}
		f["_id"] = bson.M{"$gt": oid}
	}

	opts := options.Find().SetLimit(limit).SetSort(bson.D{{Key: "_id", Value: 1}})
	cursor, err := coll.Find(ctx, f, opts)
	if err != nil {
		return nil, err
	}
	defer cursor.Close(ctx)

	var data []T
	if err := cursor.All(ctx, &data); err != nil {
		return nil, err
	}
	return data, nil
}
```

---

## 批量写入

`Ordered=false` 时一批内的失败不影响其余文档；`BulkWriteResult` 仍会返回成功计数。

```go
type BulkOptions struct {
	BatchSize int  // 每批大小，默认 1000
	Ordered   bool // 有序：出错即停；无序：继续其余写入
}

type BulkResult struct {
	InsertedCount int64
	Errors        []error
}

func (m *MongoDB) BulkInsert(ctx context.Context, coll string, docs []any, opts BulkOptions) (*BulkResult, error) {
	if opts.BatchSize <= 0 {
		opts.BatchSize = 1000
	}
	collection := m.Collection(coll)
	writeOpts := options.BulkWrite().SetOrdered(opts.Ordered)
	res := &BulkResult{}

	for start := 0; start < len(docs); start += opts.BatchSize {
		if err := ctx.Err(); err != nil {
			return res, err
		}
		end := min(start+opts.BatchSize, len(docs))
		batch := docs[start:end]

		models := make([]mongo.WriteModel, len(batch))
		for i, doc := range batch {
			models[i] = mongo.NewInsertOneModel().SetDocument(doc)
		}

		r, err := collection.BulkWrite(ctx, models, writeOpts)
		if r != nil {
			res.InsertedCount += r.InsertedCount
		}
		if err != nil {
			res.Errors = append(res.Errors, fmt.Errorf("batch %d: %w", start/opts.BatchSize, err))
			if opts.Ordered {
				return res, err
			}
		}
	}
	if len(res.Errors) > 0 {
		return res, errors.Join(res.Errors...)
	}
	return res, nil
}
```

---

## Change Streams

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
			slog.Warn("decode change event", slog.Any("error", err))
			continue
		}
		handler(event)
	}
	return stream.Err()
}

func WatchUsers(ctx context.Context, m *MongoDB) error {
	pipeline := mongo.Pipeline{
		{{Key: "$match", Value: bson.D{
			{Key: "operationType", Value: bson.D{{Key: "$in", Value: bson.A{"insert", "update", "delete"}}}},
		}}},
	}
	return m.Watch(ctx, "users", pipeline, func(event bson.M) {
		slog.Info("user change", slog.Any("op", event["operationType"]))
	})
}
```

---

## Schema 与错误处理

```go
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

var ErrDuplicate = errors.New("duplicate key")

func HandleMongoError(err error) error {
	switch {
	case err == nil:
		return nil
	case errors.Is(err, mongo.ErrNoDocuments):
		return ErrNotFound
	case mongo.IsDuplicateKeyError(err):
		return fmt.Errorf("%w: %w", ErrDuplicate, err)
	case mongo.IsTimeout(err):
		return fmt.Errorf("timeout: %w", err)
	default:
		return err
	}
}

// 查询操作符示例（编译期校验）
var (
	_ = bson.M{"age": bson.M{"$gt": 18}}
	_ = bson.M{"role": bson.M{"$in": []string{"admin", "moderator"}}}
	_ = bson.M{"$and": []bson.M{{"age": bson.M{"$gte": 18}}, {"age": bson.M{"$lte": 65}}}}
	_ = bson.M{"tags": bson.M{"$all": []string{"golang", "mongodb"}}}
	_ = bson.M{"scores": bson.M{"$elemMatch": bson.M{"$gte": 80, "$lte": 100}}}
	_ = bson.M{"name": bson.M{"$regex": "^john", "$options": "i"}}
	_ = bson.M{"email": bson.Regex{Pattern: `gmail\.com$`, Options: "i"}}
)
```
