# Go Kafka - 完整代码示例

基线：go1.24.6，`github.com/confluentinc/confluent-kafka-go/v2 v2.14.1`（内置 librdkafka，需要 `CGO_ENABLED=1`），
追踪与指标使用 `go.opentelemetry.io/otel v1.41.0`，进程内重试使用 `github.com/avast/retry-go/v5 v5.0.0`。
所有片段同属一个包，可按需拆分文件。

## 目录

- [客户端管理实现](#客户端管理实现)
- [生产者实现](#生产者实现)
- [消费者实现](#消费者实现)
- [死信队列实现](#死信队列实现)
- [链路追踪与指标实现](#链路追踪与指标实现)
- [事务实现](#事务实现)
- [消费者组管理实现](#消费者组管理实现)
- [健康检查实现](#健康检查实现)

---

## 客户端管理实现

### 创建生产者

```go
package kafkax

import (
    "fmt"

    "github.com/confluentinc/confluent-kafka-go/v2/kafka"
)

// NewProducer 创建幂等生产者。不做二次封装，调用方直接使用 *kafka.Producer。
func NewProducer(brokers string) (*kafka.Producer, error) {
    p, err := kafka.NewProducer(&kafka.ConfigMap{
        "bootstrap.servers":                     brokers,
        "acks":                                  "all", // 最强持久性
        "enable.idempotence":                    true,  // 幂等生产者
        "retries":                               3,
        "retry.backoff.ms":                      100,
        "linger.ms":                             5,     // 批量发送延迟
        "batch.size":                            16384, // 批量大小
        "compression.type":                      "lz4",
        "max.in.flight.requests.per.connection": 5,
    })
    if err != nil {
        return nil, fmt.Errorf("create producer: %w", err)
    }
    return p, nil
}

// CloseProducer 先 Flush 再 Close，避免丢失队列中的消息。
func CloseProducer(p *kafka.Producer, flushTimeoutMs int) {
    if remaining := p.Flush(flushTimeoutMs); remaining > 0 {
        // 仍有未投递消息，按业务决定是否记录告警
        _ = remaining
    }
    p.Close()
}
```

### 创建消费者

```go
package kafkax

import (
    "fmt"

    "github.com/confluentinc/confluent-kafka-go/v2/kafka"
)

// NewConsumer 创建手动提交 offset 的消费者。
func NewConsumer(brokers, groupID string) (*kafka.Consumer, error) {
    c, err := kafka.NewConsumer(&kafka.ConfigMap{
        "bootstrap.servers":             brokers,
        "group.id":                      groupID,
        "auto.offset.reset":             "earliest",
        "enable.auto.commit":            false, // 手动提交
        "session.timeout.ms":            30000,
        "heartbeat.interval.ms":         10000,
        "max.poll.interval.ms":          300000,
        "fetch.min.bytes":               1,
        "fetch.max.wait.ms":             500,
        "max.partition.fetch.bytes":     1048576,
        "partition.assignment.strategy": "cooperative-sticky",
    })
    if err != nil {
        return nil, fmt.Errorf("create consumer: %w", err)
    }
    return c, nil
}

// NewStoreOffsetConsumer 创建"自动提交 + 手动存储 offset"的消费者。
// 处理完成后调用 StoreMessage，librdkafka 会定期提交已存储的 offset，
// 既保证 at-least-once，又避免每条消息一次同步提交。
func NewStoreOffsetConsumer(brokers, groupID string) (*kafka.Consumer, error) {
    c, err := kafka.NewConsumer(&kafka.ConfigMap{
        "bootstrap.servers":        brokers,
        "group.id":                 groupID,
        "auto.offset.reset":        "earliest",
        "enable.auto.commit":       true,
        "auto.commit.interval.ms":  5000,
        "enable.auto.offset.store": false, // 由业务代码决定何时 StoreMessage
    })
    if err != nil {
        return nil, fmt.Errorf("create consumer: %w", err)
    }
    return c, nil
}
```

---

## 生产者实现

### 同步发送

```go
package kafkax

import (
    "context"
    "fmt"

    "github.com/confluentinc/confluent-kafka-go/v2/kafka"
)

// ProduceSync 发送并等待投递确认。
func ProduceSync(ctx context.Context, p *kafka.Producer, msg *kafka.Message) error {
    // 不要 close(deliveryChan)：librdkafka 会在后台写入，提前关闭会 panic。
    deliveryChan := make(chan kafka.Event, 1)

    if err := p.Produce(msg, deliveryChan); err != nil {
        return fmt.Errorf("produce: %w", err)
    }

    select {
    case <-ctx.Done():
        return ctx.Err()
    case e := <-deliveryChan:
        m, ok := e.(*kafka.Message)
        if !ok {
            return fmt.Errorf("unexpected event: %s", e)
        }
        if m.TopicPartition.Error != nil {
            return fmt.Errorf("delivery: %w", m.TopicPartition.Error)
        }
        return nil
    }
}

// NewMessage 构造按 Key 路由的消息。Key 相同则分区相同，保证顺序。
func NewMessage(topic string, key, value []byte, headers []kafka.Header) *kafka.Message {
    return &kafka.Message{
        TopicPartition: kafka.TopicPartition{Topic: &topic, Partition: kafka.PartitionAny},
        Key:            key,
        Value:          value,
        Headers:        headers,
    }
}
```

### 异步发送与投递报告

```go
package kafkax

import (
    "context"
    "log/slog"

    "github.com/confluentinc/confluent-kafka-go/v2/kafka"
)

// ProduceAsync 异步发送，deliveryChan 为 nil 时结果通过 p.Events() 投递。
func ProduceAsync(p *kafka.Producer, msg *kafka.Message) error {
    return p.Produce(msg, nil)
}

// HandleDeliveryReports 消费 Events()，异步发送时必须运行该循环，否则事件队列会堆积。
func HandleDeliveryReports(ctx context.Context, p *kafka.Producer) {
    for {
        select {
        case <-ctx.Done():
            return
        case e, ok := <-p.Events():
            if !ok {
                return
            }
            switch ev := e.(type) {
            case *kafka.Message:
                if ev.TopicPartition.Error != nil {
                    slog.Error("delivery failed",
                        slog.String("topic", *ev.TopicPartition.Topic),
                        slog.Any("error", ev.TopicPartition.Error),
                    )
                }
            case kafka.Error:
                // IsFatal 时生产者已不可用（例如幂等序列错乱），需要重建
                slog.Error("kafka error", slog.Bool("fatal", ev.IsFatal()), slog.Any("error", ev))
            }
        }
    }
}
```

### 批量发送

```go
package kafkax

import (
    "context"
    "errors"
    "fmt"

    "github.com/confluentinc/confluent-kafka-go/v2/kafka"
)

// ProduceBatch 一次性投递多条消息，等待全部确认后汇总错误。
func ProduceBatch(ctx context.Context, p *kafka.Producer, msgs []*kafka.Message) error {
    deliveryChan := make(chan kafka.Event, len(msgs))
    sent := 0
    for _, msg := range msgs {
        if err := p.Produce(msg, deliveryChan); err != nil {
            // 已入队的消息仍会投递，继续等待它们的报告后再返回
            errs := []error{fmt.Errorf("produce: %w", err)}
            errs = append(errs, waitDeliveries(ctx, deliveryChan, sent)...)
            return errors.Join(errs...)
        }
        sent++
    }
    return errors.Join(waitDeliveries(ctx, deliveryChan, sent)...)
}

func waitDeliveries(ctx context.Context, ch <-chan kafka.Event, n int) []error {
    var errs []error
    for range n {
        select {
        case <-ctx.Done():
            return append(errs, ctx.Err())
        case e := <-ch:
            if m, ok := e.(*kafka.Message); ok && m.TopicPartition.Error != nil {
                errs = append(errs, fmt.Errorf("delivery %s[%d]: %w",
                    *m.TopicPartition.Topic, m.TopicPartition.Partition, m.TopicPartition.Error))
            }
        }
    }
    return errs
}
```

### 分区策略

```go
package kafkax

import (
    "github.com/confluentinc/confluent-kafka-go/v2/kafka"
)

// ToPartition 指定分区发送。
func ToPartition(topic string, partition int32, key, value []byte) *kafka.Message {
    return &kafka.Message{
        TopicPartition: kafka.TopicPartition{Topic: &topic, Partition: partition},
        Key:            key,
        Value:          value,
    }
}

// 默认分区器为 murmur2_random（与 Java 客户端一致），
// 设置 "partitioner": "murmur2" 可让空 Key 也走确定性哈希。
```

---

## 消费者实现

### 基础消费循环

```go
package kafkax

import (
    "context"
    "errors"
    "fmt"
    "log/slog"
    "time"

    "github.com/confluentinc/confluent-kafka-go/v2/kafka"
)

// Handler 处理单条消息。返回 error 表示处理失败，由调用方决定重试或 DLQ。
type Handler func(ctx context.Context, msg *kafka.Message) error

// ConsumeLoop 订阅 topics 并持续消费，处理成功后同步提交 offset。
// ctx 取消后返回，调用方负责 consumer.Close()。
func ConsumeLoop(ctx context.Context, c *kafka.Consumer, topics []string, handler Handler) error {
    if err := c.SubscribeTopics(topics, nil); err != nil {
        return fmt.Errorf("subscribe: %w", err)
    }

    for {
        if err := ctx.Err(); err != nil {
            return err
        }

        msg, err := c.ReadMessage(100 * time.Millisecond)
        if err != nil {
            var kerr kafka.Error
            if errors.As(err, &kerr) {
                if kerr.Code() == kafka.ErrTimedOut {
                    continue // 无消息，继续轮询
                }
                if kerr.IsFatal() {
                    return fmt.Errorf("fatal consumer error: %w", err)
                }
            }
            slog.WarnContext(ctx, "read message failed", slog.Any("error", err))
            continue
        }

        msgCtx := ExtractTraceContext(ctx, msg)
        if err := handler(msgCtx, msg); err != nil {
            slog.ErrorContext(msgCtx, "handle message failed",
                slog.String("topic", *msg.TopicPartition.Topic),
                slog.Int64("offset", int64(msg.TopicPartition.Offset)),
                slog.Any("error", err),
            )
            // 未提交 offset，重启后会重新消费；持续失败请配合 DLQ
            continue
        }

        if _, err := c.CommitMessage(msg); err != nil {
            slog.ErrorContext(msgCtx, "commit failed", slog.Any("error", err))
        }
    }
}
```

### 批量消费

```go
package kafkax

import (
    "context"
    "errors"
    "fmt"
    "time"

    "github.com/confluentinc/confluent-kafka-go/v2/kafka"
)

// BatchHandler 处理一批消息，失败时整批不提交。
type BatchHandler func(ctx context.Context, msgs []*kafka.Message) error

// ConsumeBatch 攒够 batchSize 或超过 flushEvery 后交给 handler。
func ConsumeBatch(ctx context.Context, c *kafka.Consumer, topics []string, batchSize int, flushEvery time.Duration, handler BatchHandler) error {
    if err := c.SubscribeTopics(topics, nil); err != nil {
        return fmt.Errorf("subscribe: %w", err)
    }

    batch := make([]*kafka.Message, 0, batchSize)
    deadline := time.Now().Add(flushEvery)

    flush := func() error {
        if len(batch) == 0 {
            return nil
        }
        if err := handler(ctx, batch); err != nil {
            return err
        }
        // 提交每个分区最后一条消息的 offset
        if _, err := c.CommitMessage(batch[len(batch)-1]); err != nil {
            return fmt.Errorf("commit batch: %w", err)
        }
        batch = batch[:0]
        deadline = time.Now().Add(flushEvery)
        return nil
    }

    for {
        if err := ctx.Err(); err != nil {
            return err
        }

        msg, err := c.ReadMessage(100 * time.Millisecond)
        if err != nil {
            var kerr kafka.Error
            if errors.As(err, &kerr) && kerr.Code() == kafka.ErrTimedOut {
                if time.Now().After(deadline) {
                    if err := flush(); err != nil {
                        return err
                    }
                }
                continue
            }
            return fmt.Errorf("read message: %w", err)
        }

        batch = append(batch, msg)
        if len(batch) >= batchSize || time.Now().After(deadline) {
            if err := flush(); err != nil {
                return err
            }
        }
    }
}
```

> 批量提交只对单分区顺序安全。多分区混批时 `CommitMessage(last)` 只提交最后一条所在分区，
> 需要改为按分区收集 `TopicPartition` 后调用 `CommitOffsets`。

### 并发消费（按分区分发，保序）

```go
package kafkax

import (
    "context"
    "errors"
    "fmt"
    "log/slog"
    "time"

    "github.com/confluentinc/confluent-kafka-go/v2/kafka"
    "golang.org/x/sync/errgroup"
)

// ConsumeParallel 按分区取模分发到 workers 个 goroutine，同一分区始终由同一 worker 处理，
// 保证分区内顺序。消费者需用 NewStoreOffsetConsumer 创建（enable.auto.offset.store=false）。
func ConsumeParallel(ctx context.Context, c *kafka.Consumer, topics []string, workers int, handler Handler) error {
    if err := c.SubscribeTopics(topics, nil); err != nil {
        return fmt.Errorf("subscribe: %w", err)
    }

    g, gctx := errgroup.WithContext(ctx)
    queues := make([]chan *kafka.Message, workers)
    for i := range queues {
        queues[i] = make(chan *kafka.Message, 64)
        q := queues[i]
        g.Go(func() error {
            for msg := range q {
                msgCtx := ExtractTraceContext(gctx, msg)
                if err := handler(msgCtx, msg); err != nil {
                    slog.ErrorContext(msgCtx, "handle failed", slog.Any("error", err))
                    continue
                }
                // 处理成功后再存储 offset，由 auto.commit 定期提交
                if _, err := c.StoreMessage(msg); err != nil {
                    slog.ErrorContext(msgCtx, "store offset failed", slog.Any("error", err))
                }
            }
            return nil
        })
    }

    g.Go(func() error {
        defer func() {
            for _, q := range queues {
                close(q)
            }
        }()
        for {
            if err := gctx.Err(); err != nil {
                return err
            }
            msg, err := c.ReadMessage(100 * time.Millisecond)
            if err != nil {
                var kerr kafka.Error
                if errors.As(err, &kerr) && kerr.Code() == kafka.ErrTimedOut {
                    continue
                }
                return fmt.Errorf("read message: %w", err)
            }
            idx := int(msg.TopicPartition.Partition) % workers
            select {
            case queues[idx] <- msg:
            case <-gctx.Done():
                return gctx.Err()
            }
        }
    })

    return g.Wait()
}
```

---

## 死信队列实现

进程内先用 retry-go 做有限次退避重试（应对瞬时错误），仍失败则发往 DLQ 并提交 offset，
避免单条毒消息阻塞分区。

```go
package kafkax

import (
    "context"
    "errors"
    "fmt"
    "log/slog"
    "strconv"
    "time"

    "github.com/avast/retry-go/v5"
    "github.com/confluentinc/confluent-kafka-go/v2/kafka"
)

const (
    HeaderRetryCount        = "x-retry-count"
    HeaderOriginalTopic     = "x-original-topic"
    HeaderOriginalPartition = "x-original-partition"
    HeaderOriginalOffset    = "x-original-offset"
    HeaderFirstFailTime     = "x-first-fail-time"
    HeaderLastFailTime      = "x-last-fail-time"
    HeaderFailureReason     = "x-failure-reason"
)

// DLQPolicy 定义失败消息的处理策略。
type DLQPolicy struct {
    DLQTopic     string        // 死信 topic（必需）
    MaxAttempts  uint          // 进程内最大尝试次数（含首次），默认 3
    InitialDelay time.Duration // 首次退避，默认 200ms
    MaxDelay     time.Duration // 最大退避，默认 5s
    OnDLQ        func(ctx context.Context, msg *kafka.Message, err error)
}

func (p DLQPolicy) withDefaults() DLQPolicy {
    if p.MaxAttempts == 0 {
        p.MaxAttempts = 3
    }
    if p.InitialDelay == 0 {
        p.InitialDelay = 200 * time.Millisecond
    }
    if p.MaxDelay == 0 {
        p.MaxDelay = 5 * time.Second
    }
    return p
}

// DLQConsumer 组合消费者与用于写 DLQ 的生产者。
type DLQConsumer struct {
    consumer *kafka.Consumer
    producer *kafka.Producer
    policy   DLQPolicy
}

func NewDLQConsumer(c *kafka.Consumer, p *kafka.Producer, policy DLQPolicy) *DLQConsumer {
    return &DLQConsumer{consumer: c, producer: p, policy: policy.withDefaults()}
}

// ConsumeLoop 持续消费；handler 失败 → 退避重试 → 仍失败发 DLQ → 提交 offset。
func (d *DLQConsumer) ConsumeLoop(ctx context.Context, topics []string, handler Handler) error {
    if err := d.consumer.SubscribeTopics(topics, nil); err != nil {
        return fmt.Errorf("subscribe: %w", err)
    }

    for {
        if err := ctx.Err(); err != nil {
            return err
        }

        msg, err := d.consumer.ReadMessage(100 * time.Millisecond)
        if err != nil {
            var kerr kafka.Error
            if errors.As(err, &kerr) && kerr.Code() == kafka.ErrTimedOut {
                continue
            }
            return fmt.Errorf("read message: %w", err)
        }

        msgCtx := ExtractTraceContext(ctx, msg)
        if err := d.handleWithRetry(msgCtx, msg, handler); err != nil {
            if dlqErr := d.SendToDLQ(msgCtx, msg, err); dlqErr != nil {
                // DLQ 写入失败时不提交 offset，下次重新消费
                slog.ErrorContext(msgCtx, "send to DLQ failed", slog.Any("error", dlqErr))
                continue
            }
        }

        if _, err := d.consumer.CommitMessage(msg); err != nil {
            slog.ErrorContext(msgCtx, "commit failed", slog.Any("error", err))
        }
    }
}

func (d *DLQConsumer) handleWithRetry(ctx context.Context, msg *kafka.Message, handler Handler) error {
    attempts := 0
    r := retry.New(
        retry.Context(ctx),
        retry.Attempts(d.policy.MaxAttempts),
        retry.Delay(d.policy.InitialDelay),
        retry.MaxDelay(d.policy.MaxDelay),
        retry.DelayType(retry.BackOffDelay),
        retry.LastErrorOnly(true),
        retry.OnRetry(func(n uint, err error) {
            attempts = int(n) + 1
            slog.WarnContext(ctx, "retrying message",
                slog.Uint64("attempt", uint64(n+1)), slog.Any("error", err))
        }),
    )
    err := r.Do(func() error { return handler(ctx, msg) })
    if err != nil {
        msg.Headers = setHeader(msg.Headers, HeaderRetryCount, strconv.Itoa(attempts))
    }
    return err
}

// SendToDLQ 复制消息到 DLQ topic，并附带失败元数据。
func (d *DLQConsumer) SendToDLQ(ctx context.Context, msg *kafka.Message, cause error) error {
    now := time.Now().UTC().Format(time.RFC3339)
    headers := make([]kafka.Header, len(msg.Headers), len(msg.Headers)+6)
    copy(headers, msg.Headers) // 不污染原消息

    headers = setHeader(headers, HeaderOriginalTopic, *msg.TopicPartition.Topic)
    headers = setHeader(headers, HeaderOriginalPartition, strconv.Itoa(int(msg.TopicPartition.Partition)))
    headers = setHeader(headers, HeaderOriginalOffset, strconv.FormatInt(int64(msg.TopicPartition.Offset), 10))
    headers = setHeader(headers, HeaderLastFailTime, now)
    headers = setHeader(headers, HeaderFailureReason, cause.Error())
    if getHeader(headers, HeaderFirstFailTime) == "" {
        headers = setHeader(headers, HeaderFirstFailTime, now)
    }

    dlqMsg := &kafka.Message{
        TopicPartition: kafka.TopicPartition{Topic: &d.policy.DLQTopic, Partition: kafka.PartitionAny},
        Key:            msg.Key,
        Value:          msg.Value,
        Headers:        headers,
    }
    if err := ProduceSync(ctx, d.producer, dlqMsg); err != nil {
        return err
    }
    if d.policy.OnDLQ != nil {
        d.policy.OnDLQ(ctx, msg, cause)
    }
    return nil
}

func getHeader(headers []kafka.Header, key string) string {
    for _, h := range headers {
        if h.Key == key {
            return string(h.Value)
        }
    }
    return ""
}

func setHeader(headers []kafka.Header, key, value string) []kafka.Header {
    for i, h := range headers {
        if h.Key == key {
            headers[i].Value = []byte(value)
            return headers
        }
    }
    return append(headers, kafka.Header{Key: key, Value: []byte(value)})
}

// RetryCount 读取消息已重试次数（例如 DLQ 消费者据此决定是否回放）。
func RetryCount(msg *kafka.Message) int {
    n, _ := strconv.Atoi(getHeader(msg.Headers, HeaderRetryCount))
    return n
}
```

---

## 链路追踪与指标实现

### Trace Context 通过 Headers 传播

```go
package kafkax

import (
    "context"

    "github.com/confluentinc/confluent-kafka-go/v2/kafka"
    "go.opentelemetry.io/otel"
    "go.opentelemetry.io/otel/propagation"
)

// InjectTraceContext 把当前 span 的 traceparent/tracestate/baggage 写入消息 headers。
func InjectTraceContext(ctx context.Context, msg *kafka.Message) {
    carrier := propagation.MapCarrier{}
    otel.GetTextMapPropagator().Inject(ctx, carrier)
    for k, v := range carrier {
        msg.Headers = setHeader(msg.Headers, k, v)
    }
}

// ExtractTraceContext 从消息 headers 恢复上游 trace context。
func ExtractTraceContext(ctx context.Context, msg *kafka.Message) context.Context {
    carrier := propagation.MapCarrier{}
    for _, h := range msg.Headers {
        carrier[h.Key] = string(h.Value)
    }
    return otel.GetTextMapPropagator().Extract(ctx, carrier)
}
```

### 带 Span 与指标的生产者

```go
package kafkax

import (
    "context"
    "fmt"
    "time"

    "github.com/confluentinc/confluent-kafka-go/v2/kafka"
    "go.opentelemetry.io/otel"
    "go.opentelemetry.io/otel/attribute"
    "go.opentelemetry.io/otel/codes"
    "go.opentelemetry.io/otel/metric"
    "go.opentelemetry.io/otel/trace"
)

// TracedProducer 在 Produce 前创建 producer span、注入 headers、记录指标。
type TracedProducer struct {
    *kafka.Producer
    tracer   trace.Tracer
    produced metric.Int64Counter
    latency  metric.Float64Histogram
}

func NewTracedProducer(p *kafka.Producer) (*TracedProducer, error) {
    meter := otel.Meter("kafkax")
    produced, err := meter.Int64Counter("messaging.client.sent.messages",
        metric.WithDescription("Number of messages producer attempted to send"),
        metric.WithUnit("{message}"))
    if err != nil {
        return nil, err
    }
    latency, err := meter.Float64Histogram("messaging.client.operation.duration",
        metric.WithDescription("Duration of produce operation"),
        metric.WithUnit("s"))
    if err != nil {
        return nil, err
    }
    return &TracedProducer{
        Producer: p,
        tracer:   otel.Tracer("kafkax"),
        produced: produced,
        latency:  latency,
    }, nil
}

// ProduceSync 同步发送并记录 span/指标。
func (tp *TracedProducer) ProduceSync(ctx context.Context, msg *kafka.Message) (err error) {
    topic := *msg.TopicPartition.Topic
    attrs := []attribute.KeyValue{
        attribute.String("messaging.system", "kafka"),
        attribute.String("messaging.destination.name", topic),
        attribute.String("messaging.operation.type", "send"),
    }

    ctx, span := tp.tracer.Start(ctx, topic+" send",
        trace.WithSpanKind(trace.SpanKindProducer),
        trace.WithAttributes(attrs...),
    )
    start := time.Now()
    defer func() {
        if err != nil {
            span.RecordError(err)
            span.SetStatus(codes.Error, err.Error())
            attrs = append(attrs, attribute.String("error.type", fmt.Sprintf("%T", err)))
        }
        // 用 WithoutCancel 保证 ctx 已取消时指标仍能记录
        mctx := context.WithoutCancel(ctx)
        tp.produced.Add(mctx, 1, metric.WithAttributes(attrs...))
        tp.latency.Record(mctx, time.Since(start).Seconds(), metric.WithAttributes(attrs...))
        span.End()
    }()

    InjectTraceContext(ctx, msg)
    return ProduceSync(ctx, tp.Producer, msg)
}
```

### 带 Span 的消费处理

```go
package kafkax

import (
    "context"

    "github.com/confluentinc/confluent-kafka-go/v2/kafka"
    "go.opentelemetry.io/otel"
    "go.opentelemetry.io/otel/attribute"
    "go.opentelemetry.io/otel/codes"
    "go.opentelemetry.io/otel/trace"
)

// WithConsumerSpan 包装 Handler：以消息 headers 中的 trace 为父级创建 consumer span。
func WithConsumerSpan(handler Handler) Handler {
    tracer := otel.Tracer("kafkax")
    return func(ctx context.Context, msg *kafka.Message) error {
        ctx = ExtractTraceContext(ctx, msg)
        topic := *msg.TopicPartition.Topic
        ctx, span := tracer.Start(ctx, topic+" process",
            trace.WithSpanKind(trace.SpanKindConsumer),
            trace.WithAttributes(
                attribute.String("messaging.system", "kafka"),
                attribute.String("messaging.destination.name", topic),
                attribute.String("messaging.operation.type", "process"),
                attribute.Int("messaging.destination.partition.id", int(msg.TopicPartition.Partition)),
                attribute.Int64("messaging.kafka.offset", int64(msg.TopicPartition.Offset)),
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
    }
}
```

---

## 事务实现

### 事务生产者

```go
package kafkax

import (
    "context"
    "errors"
    "fmt"

    "github.com/confluentinc/confluent-kafka-go/v2/kafka"
)

// NewTransactionalProducer 创建事务生产者。transactional.id 需在实例间唯一且重启后稳定。
func NewTransactionalProducer(ctx context.Context, brokers, transactionalID string) (*kafka.Producer, error) {
    p, err := kafka.NewProducer(&kafka.ConfigMap{
        "bootstrap.servers":  brokers,
        "transactional.id":   transactionalID,
        "enable.idempotence": true,
        "acks":               "all",
    })
    if err != nil {
        return nil, fmt.Errorf("create producer: %w", err)
    }
    if err := p.InitTransactions(ctx); err != nil {
        p.Close()
        return nil, fmt.Errorf("init transactions: %w", err)
    }
    return p, nil
}

// ProduceInTransaction 把一批消息原子地写入（全部可见或全部不可见）。
func ProduceInTransaction(ctx context.Context, p *kafka.Producer, msgs []*kafka.Message) error {
    if err := p.BeginTransaction(); err != nil {
        return fmt.Errorf("begin transaction: %w", err)
    }

    for _, msg := range msgs {
        if err := p.Produce(msg, nil); err != nil {
            return abortTxn(ctx, p, fmt.Errorf("produce: %w", err))
        }
    }

    if err := p.CommitTransaction(ctx); err != nil {
        return abortTxn(ctx, p, fmt.Errorf("commit transaction: %w", err))
    }
    return nil
}

func abortTxn(ctx context.Context, p *kafka.Producer, cause error) error {
    var kerr kafka.Error
    if errors.As(cause, &kerr) && kerr.IsFatal() {
        return cause // 生产者已失效，需要重建
    }
    if err := p.AbortTransaction(ctx); err != nil {
        return errors.Join(cause, fmt.Errorf("abort transaction: %w", err))
    }
    return cause
}
```

### 消费-转换-生产（Exactly-Once）

```go
package kafkax

import (
    "context"
    "errors"
    "fmt"
    "time"

    "github.com/confluentinc/confluent-kafka-go/v2/kafka"
)

// Transform 把输入消息转换为输出消息。
type Transform func(ctx context.Context, in *kafka.Message) ([]*kafka.Message, error)

// ConsumeTransformProduce 用事务把"消费 offset 提交"和"输出写入"绑定在一起。
// 消费者需配置 enable.auto.commit=false、isolation.level=read_committed。
func ConsumeTransformProduce(ctx context.Context, c *kafka.Consumer, p *kafka.Producer, topics []string, transform Transform) error {
    if err := c.SubscribeTopics(topics, nil); err != nil {
        return fmt.Errorf("subscribe: %w", err)
    }

    for {
        if err := ctx.Err(); err != nil {
            return err
        }

        in, err := c.ReadMessage(100 * time.Millisecond)
        if err != nil {
            var kerr kafka.Error
            if errors.As(err, &kerr) && kerr.Code() == kafka.ErrTimedOut {
                continue
            }
            return fmt.Errorf("read message: %w", err)
        }

        outs, err := transform(ctx, in)
        if err != nil {
            return fmt.Errorf("transform: %w", err)
        }

        if err := p.BeginTransaction(); err != nil {
            return fmt.Errorf("begin transaction: %w", err)
        }
        for _, out := range outs {
            if err := p.Produce(out, nil); err != nil {
                return abortTxn(ctx, p, fmt.Errorf("produce: %w", err))
            }
        }

        // 把输入 offset 作为事务的一部分提交
        position, err := c.Position([]kafka.TopicPartition{in.TopicPartition})
        if err != nil {
            return abortTxn(ctx, p, fmt.Errorf("position: %w", err))
        }
        meta, err := c.GetConsumerGroupMetadata()
        if err != nil {
            return abortTxn(ctx, p, fmt.Errorf("group metadata: %w", err))
        }
        if err := p.SendOffsetsToTransaction(ctx, position, meta); err != nil {
            return abortTxn(ctx, p, fmt.Errorf("send offsets: %w", err))
        }
        if err := p.CommitTransaction(ctx); err != nil {
            return abortTxn(ctx, p, fmt.Errorf("commit transaction: %w", err))
        }
    }
}
```

---

## 消费者组管理实现

### Rebalance 回调（cooperative-sticky）

```go
package kafkax

import (
    "fmt"
    "log/slog"

    "github.com/confluentinc/confluent-kafka-go/v2/kafka"
)

// RebalanceCallback 在分区分配/撤销时记录日志并提交已处理 offset。
// partition.assignment.strategy=cooperative-sticky 时必须使用 Incremental* 方法。
func RebalanceCallback(c *kafka.Consumer, ev kafka.Event) error {
    switch e := ev.(type) {
    case kafka.AssignedPartitions:
        slog.Info("partitions assigned", slog.Int("count", len(e.Partitions)))
        return c.IncrementalAssign(e.Partitions)
    case kafka.RevokedPartitions:
        slog.Info("partitions revoked", slog.Int("count", len(e.Partitions)))
        if c.AssignmentLost() {
            // 分配已丢失（例如 session 超时），提交会失败，直接释放
            return c.IncrementalUnassign(e.Partitions)
        }
        if _, err := c.Commit(); err != nil {
            var kerr kafka.Error
            // 没有待提交 offset 时返回 ErrNoOffset，属正常情况
            if !(asKafkaError(err, &kerr) && kerr.Code() == kafka.ErrNoOffset) {
                slog.Warn("commit on revoke failed", slog.Any("error", err))
            }
        }
        return c.IncrementalUnassign(e.Partitions)
    default:
        return fmt.Errorf("unexpected rebalance event: %s", ev)
    }
}

func asKafkaError(err error, target *kafka.Error) bool {
    kerr, ok := err.(kafka.Error)
    if ok {
        *target = kerr
    }
    return ok
}

// SubscribeWithRebalance 订阅并挂载回调。
func SubscribeWithRebalance(c *kafka.Consumer, topics []string) error {
    return c.SubscribeTopics(topics, RebalanceCallback)
}
```

### 手动分区分配（不使用消费者组协调）

```go
package kafkax

import (
    "github.com/confluentinc/confluent-kafka-go/v2/kafka"
)

// AssignPartitions 直接分配分区，从已提交 offset 开始。
func AssignPartitions(c *kafka.Consumer, topic string, partitions []int32) error {
    tps := make([]kafka.TopicPartition, 0, len(partitions))
    for _, p := range partitions {
        tps = append(tps, kafka.TopicPartition{
            Topic:     &topic,
            Partition: p,
            Offset:    kafka.OffsetStored,
        })
    }
    return c.Assign(tps)
}
```

---

## 健康检查实现

```go
package kafkax

import (
    "context"
    "errors"
    "fmt"

    "github.com/confluentinc/confluent-kafka-go/v2/kafka"
)

// ProducerHealth 通过拉取元数据确认 broker 可达；同时检查生产者是否已进入 fatal 状态。
func ProducerHealth(ctx context.Context, p *kafka.Producer) error {
    if err := p.GetFatalError(); err != nil {
        return fmt.Errorf("producer fatal: %w", err)
    }
    timeoutMs := 5000
    if dl, ok := ctx.Deadline(); ok {
        if ms := int(dl.Sub(nowFn()).Milliseconds()); ms > 0 && ms < timeoutMs {
            timeoutMs = ms
        }
    }
    md, err := p.GetMetadata(nil, false, timeoutMs)
    if err != nil {
        return fmt.Errorf("get metadata: %w", err)
    }
    if len(md.Brokers) == 0 {
        return errors.New("no brokers available")
    }
    return nil
}

// ConsumerHealth 检查 broker 连接，并在已订阅时确认拿到了分区分配。
func ConsumerHealth(c *kafka.Consumer, requireAssignment bool) error {
    md, err := c.GetMetadata(nil, false, 5000)
    if err != nil {
        return fmt.Errorf("get metadata: %w", err)
    }
    if len(md.Brokers) == 0 {
        return errors.New("no brokers available")
    }
    if requireAssignment {
        assigned, err := c.Assignment()
        if err != nil {
            return fmt.Errorf("assignment: %w", err)
        }
        if len(assigned) == 0 {
            return errors.New("no partitions assigned")
        }
    }
    return nil
}

// TopicExists 检查 topic 是否存在（不存在时 metadata.Topics[topic].Error 非 nil）。
func TopicExists(p *kafka.Producer, topic string) (bool, error) {
    md, err := p.GetMetadata(&topic, false, 5000)
    if err != nil {
        return false, err
    }
    t, ok := md.Topics[topic]
    if !ok {
        return false, nil
    }
    return t.Error.Code() == kafka.ErrNoError, nil
}
```

```go
package kafkax

import "time"

// nowFn 便于测试时替换时间源。
var nowFn = time.Now
```
