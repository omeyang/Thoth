# Go Kafka - 完整代码示例

## 目录

- [客户端管理实现](#客户端管理实现)
- [生产者实现](#生产者实现)
- [消费者实现](#消费者实现)
- [死信队列实现](#死信队列实现)
- [链路追踪实现](#链路追踪实现)
- [事务实现](#事务实现)
- [消费者组管理实现](#消费者组管理实现)
- [健康检查实现](#健康检查实现)

---

## 客户端管理实现

### 创建生产者

```go
import (
    "github.com/confluentinc/confluent-kafka-go/v2/kafka"
)

func NewKafkaProducer(brokers string) (*kafka.Producer, error) {
    producer, err := kafka.NewProducer(&kafka.ConfigMap{
        "bootstrap.servers":   brokers,
        "acks":                "all",           // 最强持久性
        "enable.idempotence":  true,            // 幂等生产者
        "retries":             3,
        "retry.backoff.ms":    100,
        "linger.ms":           5,               // 批量发送延迟
        "batch.size":          16384,           // 批量大小
        "compression.type":    "lz4",           // 压缩
        "max.in.flight.requests.per.connection": 5,
    })
    if err != nil {
        return nil, fmt.Errorf("create producer: %w", err)
    }

    return producer, nil
}
```

### 创建消费者

```go
func NewKafkaConsumer(brokers, groupID string) (*kafka.Consumer, error) {
    consumer, err := kafka.NewConsumer(&kafka.ConfigMap{
        "bootstrap.servers":        brokers,
        "group.id":                 groupID,
        "auto.offset.reset":        "earliest",
        "enable.auto.commit":       false,        // 手动提交
        "session.timeout.ms":       30000,
        "heartbeat.interval.ms":    10000,
        "max.poll.interval.ms":     300000,
        "fetch.min.bytes":          1,
        "fetch.max.wait.ms":        500,
        "max.partition.fetch.bytes": 1048576,
    })
    if err != nil {
        return nil, fmt.Errorf("create consumer: %w", err)
    }

    return consumer, nil
}
```

### 包装器模式

```go
type Kafka struct {
    producer *kafka.Producer
}

func New(producer *kafka.Producer) *Kafka {
    return &Kafka{producer: producer}
}

// Producer 暴露底层生产者
func (k *Kafka) Producer() *kafka.Producer {
    return k.producer
}

// Close 关闭生产者
func (k *Kafka) Close() {
    k.producer.Flush(15000) // 等待消息发送完成
    k.producer.Close()
}
```

---

## 生产者实现

### 同步发送

```go
func (k *Kafka) Send(ctx context.Context, topic string, key, value []byte) error {
    deliveryChan := make(chan kafka.Event, 1)
    // 注意: 不要 close(deliveryChan)，Kafka 内部会写入该 channel，
    // 提前关闭会导致 panic。channel 会在函数返回后被 GC 回收。

    err := k.producer.Produce(&kafka.Message{
        TopicPartition: kafka.TopicPartition{Topic: &topic, Partition: kafka.PartitionAny},
        Key:            key,
        Value:          value,
        Headers:        headersFromContext(ctx),
    }, deliveryChan)

    if err != nil {
        return fmt.Errorf("produce: %w", err)
    }

    // 等待确认
    select {
    case <-ctx.Done():
        return ctx.Err()
    case e := <-deliveryChan:
        m := e.(*kafka.Message)
        if m.TopicPartition.Error != nil {
            return fmt.Errorf("delivery: %w", m.TopicPartition.Error)
        }
        return nil
    }
}
```

### 异步发送

```go
import "log/slog"

func (k *Kafka) SendAsync(ctx context.Context, topic string, key, value []byte) error {
    return k.producer.Produce(&kafka.Message{
        TopicPartition: kafka.TopicPartition{Topic: &topic, Partition: kafka.PartitionAny},
        Key:            key,
        Value:          value,
        Headers:        headersFromContext(ctx),
    }, nil) // nil 表示结果通过 producer.Events() channel 投递
}

// 处理投递报告
func (k *Kafka) HandleDeliveryReports(ctx context.Context) {
    for {
        select {
        case <-ctx.Done():
            return
        case e := <-k.producer.Events():
            switch ev := e.(type) {
            case *kafka.Message:
                if ev.TopicPartition.Error != nil {
                    slog.Error("delivery failed",
                        slog.String("topic", *ev.TopicPartition.Topic),
                        slog.Any("error", ev.TopicPartition.Error),
                    )
                }
            case kafka.Error:
                slog.Error("kafka error", slog.Any("error", ev))
            }
        }
    }
}
```

### 批量发送

```go
type Message struct {
    Topic   string
    Key     []byte
    Value   []byte
    Headers map[string]string
}

func (k *Kafka) SendBatch(ctx context.Context, messages []Message) error {
    deliveryChan := make(chan kafka.Event, len(messages))

    for _, msg := range messages {
        topic := msg.Topic
        err := k.producer.Produce(&kafka.Message{
            TopicPartition: kafka.TopicPartition{Topic: &topic, Partition: kafka.PartitionAny},
            Key:            msg.Key,
            Value:          msg.Value,
            Headers:        toKafkaHeaders(msg.Headers),
        }, deliveryChan)

        if err != nil {
            return fmt.Errorf("produce: %w", err)
        }
    }

    // 等待所有确认
    var errs []error
    for i := 0; i < len(messages); i++ {
        select {
        case <-ctx.Done():
            return ctx.Err()
        case e := <-deliveryChan:
            m := e.(*kafka.Message)
            if m.TopicPartition.Error != nil {
                errs = append(errs, m.TopicPartition.Error)
            }
        }
    }

    close(deliveryChan)

    if len(errs) > 0 {
        return fmt.Errorf("batch delivery failed: %d errors", len(errs))
    }

    return nil
}
```

### 分区策略

```go
// 自定义分区
func (k *Kafka) SendToPartition(ctx context.Context, topic string, partition int32, key, value []byte) error {
    return k.producer.Produce(&kafka.Message{
        TopicPartition: kafka.TopicPartition{Topic: &topic, Partition: partition},
        Key:            key,
        Value:          value,
    }, nil)
}

// 按 Key 路由（相同 Key 到同一分区）
func (k *Kafka) SendWithKey(ctx context.Context, topic, key string, value []byte) error {
    return k.producer.Produce(&kafka.Message{
        TopicPartition: kafka.TopicPartition{Topic: &topic, Partition: kafka.PartitionAny},
        Key:            []byte(key), // Key 相同则分区相同
        Value:          value,
    }, nil)
}
```

---

## 消费者实现

### 基础消费

```go
import "log/slog"

type Handler func(ctx context.Context, msg *kafka.Message) error

func (k *Kafka) Consume(ctx context.Context, consumer *kafka.Consumer, topics []string, handler Handler) error {
    if err := consumer.SubscribeTopics(topics, nil); err != nil {
        return fmt.Errorf("subscribe: %w", err)
    }

    for {
        select {
        case <-ctx.Done():
            return ctx.Err()
        default:
        }

        msg, err := consumer.ReadMessage(100 * time.Millisecond)
        if err != nil {
            var kerr kafka.Error
            if errors.As(err, &kerr) && kerr.Code() == kafka.ErrTimedOut {
                continue
            }
            return fmt.Errorf("read message: %w", err)
        }

        // 处理消息
        msgCtx := contextFromHeaders(ctx, msg.Headers)
        if err := handler(msgCtx, msg); err != nil {
            slog.ErrorContext(msgCtx, "handle message failed",
                slog.String("topic", *msg.TopicPartition.Topic),
                slog.Any("error", err),
            )
            // 继续处理（或实现重试逻辑）
            continue
        }

        // 手动提交
        if _, err := consumer.CommitMessage(msg); err != nil {
            slog.ErrorContext(msgCtx, "commit failed", slog.Any("error", err))
        }
    }
}
```

### 批量消费

```go
func (k *Kafka) ConsumeBatch(ctx context.Context, consumer *kafka.Consumer, topics []string, batchSize int, timeout time.Duration, handler func(context.Context, []*kafka.Message) error) error {
    if err := consumer.SubscribeTopics(topics, nil); err != nil {
        return err
    }

    batch := make([]*kafka.Message, 0, batchSize)
    timer := time.NewTimer(timeout)

    for {
        select {
        case <-ctx.Done():
            return ctx.Err()

        case <-timer.C:
            if len(batch) > 0 {
                if err := k.processBatch(ctx, consumer, batch, handler); err != nil {
                    return err
                }
                batch = batch[:0]
            }
            timer.Reset(timeout)

        default:
            msg, err := consumer.ReadMessage(100 * time.Millisecond)
            if err != nil {
                var kerr kafka.Error
                if errors.As(err, &kerr) && kerr.Code() == kafka.ErrTimedOut {
                    continue
                }
                return err
            }

            batch = append(batch, msg)

            if len(batch) >= batchSize {
                if err := k.processBatch(ctx, consumer, batch, handler); err != nil {
                    return err
                }
                batch = batch[:0]
                timer.Reset(timeout)
            }
        }
    }
}

func (k *Kafka) processBatch(ctx context.Context, consumer *kafka.Consumer, batch []*kafka.Message, handler func(context.Context, []*kafka.Message) error) error {
    if err := handler(ctx, batch); err != nil {
        return err
    }

    // 提交最后一条消息的 offset
    if _, err := consumer.CommitMessage(batch[len(batch)-1]); err != nil {
        return fmt.Errorf("commit batch: %w", err)
    }

    return nil
}
```

### 并发消费

```go
func (k *Kafka) ConsumeParallel(ctx context.Context, consumer *kafka.Consumer, topics []string, workers int, handler Handler) error {
    if err := consumer.SubscribeTopics(topics, nil); err != nil {
        return err
    }

    jobs := make(chan *kafka.Message, workers*2)
    results := make(chan error, workers)

    // 启动 worker
    var wg sync.WaitGroup
    for i := 0; i < workers; i++ {
        wg.Add(1)
        go func() {
            defer wg.Done()
            for msg := range jobs {
                msgCtx := contextFromHeaders(ctx, msg.Headers)
                if err := handler(msgCtx, msg); err != nil {
                    results <- err
                    continue
                }
                // 注意：并发时不能简单提交，需要追踪 offset
            }
        }()
    }

    // 读取消息
    go func() {
        for {
            select {
            case <-ctx.Done():
                close(jobs)
                return
            default:
            }

            msg, err := consumer.ReadMessage(100 * time.Millisecond)
            if err != nil {
                continue
            }

            select {
            case jobs <- msg:
            case <-ctx.Done():
                close(jobs)
                return
            }
        }
    }()

    wg.Wait()
    return nil
}
```

---

## 死信队列实现

```go
import "strconv"

type DLQConfig struct {
    Topic      string
    MaxRetries int
}

type ConsumerWithDLQ struct {
    *Kafka
    consumer *kafka.Consumer
    dlq      DLQConfig
}

func (c *ConsumerWithDLQ) ConsumeWithDLQ(ctx context.Context, topics []string, handler Handler) error {
    if err := c.consumer.SubscribeTopics(topics, nil); err != nil {
        return err
    }

    for {
        select {
        case <-ctx.Done():
            return ctx.Err()
        default:
        }

        msg, err := c.consumer.ReadMessage(100 * time.Millisecond)
        if err != nil {
            continue
        }

        msgCtx := contextFromHeaders(ctx, msg.Headers)
        retryCount := getRetryCount(msg.Headers)

        if err := handler(msgCtx, msg); err != nil {
            if retryCount >= c.dlq.MaxRetries {
                // 发送到 DLQ
                if err := c.sendToDLQ(ctx, msg, err); err != nil {
                    slog.ErrorContext(msgCtx, "send to DLQ failed", slog.Any("error", err))
                }
            } else {
                // 重试
                if err := c.retry(ctx, msg, retryCount+1); err != nil {
                    slog.ErrorContext(msgCtx, "retry failed", slog.Any("error", err))
                }
            }
        }

        c.consumer.CommitMessage(msg)
    }
}

func (c *ConsumerWithDLQ) sendToDLQ(ctx context.Context, msg *kafka.Message, originalErr error) error {
    // 复制 headers 切片，避免污染原始消息
    headers := make([]kafka.Header, len(msg.Headers), len(msg.Headers)+3)
    copy(headers, msg.Headers)
    headers = append(headers,
        kafka.Header{Key: "dlq-original-topic", Value: []byte(*msg.TopicPartition.Topic)},
        kafka.Header{Key: "dlq-error", Value: []byte(originalErr.Error())},
        kafka.Header{Key: "dlq-timestamp", Value: []byte(time.Now().Format(time.RFC3339))},
    )

    return c.producer.Produce(&kafka.Message{
        TopicPartition: kafka.TopicPartition{Topic: &c.dlq.Topic, Partition: kafka.PartitionAny},
        Key:            msg.Key,
        Value:          msg.Value,
        Headers:        headers,
    }, nil)
}

func (c *ConsumerWithDLQ) retry(ctx context.Context, msg *kafka.Message, retryCount int) error {
    headers := setRetryCount(msg.Headers, retryCount)

    return c.producer.Produce(&kafka.Message{
        TopicPartition: msg.TopicPartition,
        Key:            msg.Key,
        Value:          msg.Value,
        Headers:        headers,
    }, nil)
}

func getRetryCount(headers []kafka.Header) int {
    for _, h := range headers {
        if h.Key == "retry-count" {
            count, _ := strconv.Atoi(string(h.Value))
            return count
        }
    }
    return 0
}

func setRetryCount(headers []kafka.Header, count int) []kafka.Header {
    for i, h := range headers {
        if h.Key == "retry-count" {
            headers[i].Value = []byte(strconv.Itoa(count))
            return headers
        }
    }
    return append(headers, kafka.Header{Key: "retry-count", Value: []byte(strconv.Itoa(count))})
}
```

---

## 链路追踪实现

### OpenTelemetry 集成

```go
import (
    "go.opentelemetry.io/otel"
    "go.opentelemetry.io/otel/attribute"
    "go.opentelemetry.io/otel/codes"
    "go.opentelemetry.io/otel/propagation"
    "go.opentelemetry.io/otel/trace"
)

func headersFromContext(ctx context.Context) []kafka.Header {
    carrier := make(propagation.MapCarrier)
    otel.GetTextMapPropagator().Inject(ctx, carrier)

    var headers []kafka.Header
    for k, v := range carrier {
        headers = append(headers, kafka.Header{Key: k, Value: []byte(v)})
    }

    return headers
}

func contextFromHeaders(ctx context.Context, headers []kafka.Header) context.Context {
    carrier := make(propagation.MapCarrier)
    for _, h := range headers {
        carrier[h.Key] = string(h.Value)
    }

    return otel.GetTextMapPropagator().Extract(ctx, carrier)
}

// 生产者追踪包装
func (k *Kafka) SendWithTrace(ctx context.Context, topic string, key, value []byte) error {
    tracer := otel.Tracer("kafka")
    ctx, span := tracer.Start(ctx, "kafka.produce",
        trace.WithSpanKind(trace.SpanKindProducer),
        trace.WithAttributes(
            attribute.String("messaging.system", "kafka"),
            attribute.String("messaging.destination.name", topic),
        ),
    )
    defer span.End()

    if err := k.Send(ctx, topic, key, value); err != nil {
        span.RecordError(err)
        span.SetStatus(codes.Error, err.Error())
        return err
    }

    span.SetStatus(codes.Ok, "")
    return nil
}

// 消费者追踪包装
func (k *Kafka) ConsumeWithTrace(ctx context.Context, consumer *kafka.Consumer, topics []string, handler Handler) error {
    tracer := otel.Tracer("kafka")

    return k.Consume(ctx, consumer, topics, func(ctx context.Context, msg *kafka.Message) error {
        ctx, span := tracer.Start(ctx, "kafka.consume",
            trace.WithSpanKind(trace.SpanKindConsumer),
            trace.WithAttributes(
                attribute.String("messaging.system", "kafka"),
                attribute.String("messaging.destination.name", *msg.TopicPartition.Topic),
                attribute.Int64("messaging.kafka.partition", int64(msg.TopicPartition.Partition)),
            ),
        )
        defer span.End()

        if err := handler(ctx, msg); err != nil {
            span.RecordError(err)
            span.SetStatus(codes.Error, err.Error())
            return err
        }

        span.SetStatus(codes.Ok, "")
        return nil
    })
}
```

---

## 事务实现

```go
func NewTransactionalProducer(brokers, transactionalID string) (*kafka.Producer, error) {
    producer, err := kafka.NewProducer(&kafka.ConfigMap{
        "bootstrap.servers":  brokers,
        "transactional.id":   transactionalID,
        "enable.idempotence": true,
    })
    if err != nil {
        return nil, err
    }

    // 初始化事务
    if err := producer.InitTransactions(context.Background()); err != nil {
        producer.Close()
        return nil, fmt.Errorf("init transactions: %w", err)
    }

    return producer, nil
}

func (k *Kafka) SendInTransaction(ctx context.Context, messages []Message) error {
    if err := k.producer.BeginTransaction(); err != nil {
        return fmt.Errorf("begin transaction: %w", err)
    }

    for _, msg := range messages {
        topic := msg.Topic
        err := k.producer.Produce(&kafka.Message{
            TopicPartition: kafka.TopicPartition{Topic: &topic, Partition: kafka.PartitionAny},
            Key:            msg.Key,
            Value:          msg.Value,
        }, nil)
        if err != nil {
            k.producer.AbortTransaction(ctx)
            return fmt.Errorf("produce: %w", err)
        }
    }

    if err := k.producer.CommitTransaction(ctx); err != nil {
        k.producer.AbortTransaction(ctx)
        return fmt.Errorf("commit transaction: %w", err)
    }

    return nil
}
```

---

## 消费者组管理实现

### Rebalance 回调

```go
func (k *Kafka) ConsumeWithRebalance(ctx context.Context, consumer *kafka.Consumer, topics []string, handler Handler) error {
    rebalanceCb := func(c *kafka.Consumer, event kafka.Event) error {
        switch e := event.(type) {
        case kafka.AssignedPartitions:
            slog.Info("partitions assigned", slog.Any("partitions", e.Partitions))
            return c.Assign(e.Partitions)
        case kafka.RevokedPartitions:
            slog.Info("partitions revoked", slog.Any("partitions", e.Partitions))
            // 提交已处理的 offset
            c.Commit()
            return c.Unassign()
        }
        return nil
    }

    if err := consumer.SubscribeTopics(topics, rebalanceCb); err != nil {
        return err
    }

    // ... 消费逻辑
    return nil
}
```

### 手动分区分配

```go
func (k *Kafka) AssignPartitions(consumer *kafka.Consumer, topic string, partitions []int32) error {
    var tps []kafka.TopicPartition
    for _, p := range partitions {
        tps = append(tps, kafka.TopicPartition{
            Topic:     &topic,
            Partition: p,
            Offset:    kafka.OffsetStored, // 从存储的 offset 开始
        })
    }

    return consumer.Assign(tps)
}
```

---

## 健康检查实现

```go
func (k *Kafka) Health(ctx context.Context) error {
    // 获取集群元数据
    metadata, err := k.producer.GetMetadata(nil, true, 5000)
    if err != nil {
        return fmt.Errorf("get metadata: %w", err)
    }

    if len(metadata.Brokers) == 0 {
        return fmt.Errorf("no brokers available")
    }

    return nil
}

func (k *Kafka) TopicExists(topic string) (bool, error) {
    metadata, err := k.producer.GetMetadata(&topic, false, 5000)
    if err != nil {
        return false, err
    }

    _, exists := metadata.Topics[topic]
    return exists, nil
}
```
