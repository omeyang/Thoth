# Go Pulsar 完整代码示例

基线：go1.24.6，`github.com/apache/pulsar-client-go v0.20.0`，追踪使用 `go.opentelemetry.io/otel v1.41.0`。
所有片段同属一个包 `pulsarx`，可按需拆分文件。

## 目录

- [1. 客户端管理](#1-客户端管理)
- [2. 生产者](#2-生产者)
- [3. 消费者](#3-消费者)
- [4. 死信队列（DLQ）](#4-死信队列dlq)
- [5. 链路追踪](#5-链路追踪)
- [6. Schema 管理](#6-schema-管理)
- [7. Reader（非订阅读取）](#7-reader非订阅读取)
- [8. 多主题订阅](#8-多主题订阅)

---

## 1. 客户端管理

### 创建客户端

```go
package pulsarx

import (
    "fmt"
    "time"

    "github.com/apache/pulsar-client-go/pulsar"
)

func NewClient(serviceURL string) (pulsar.Client, error) {
    client, err := pulsar.NewClient(pulsar.ClientOptions{
        URL:                     serviceURL, // pulsar://host:6650 或 pulsar+ssl://host:6651
        OperationTimeout:        30 * time.Second,
        ConnectionTimeout:       10 * time.Second,
        MaxConnectionsPerBroker: 5,
        // Authentication: pulsar.NewAuthenticationToken(os.Getenv("PULSAR_TOKEN")),
    })
    if err != nil {
        return nil, fmt.Errorf("create pulsar client: %w", err)
    }
    return client, nil
}
```

### 消息载体

```go
package pulsarx

// Message 是业务层消息，与 pulsar.ProducerMessage 解耦。
type Message struct {
    Payload    []byte
    Key        string
    Properties map[string]string
}
```

---

## 2. 生产者

### 创建生产者

```go
package pulsarx

import (
    "fmt"
    "hash/fnv"
    "math/rand/v2"
    "time"

    "github.com/apache/pulsar-client-go/pulsar"
)

func NewProducer(client pulsar.Client, topic string) (pulsar.Producer, error) {
    producer, err := client.CreateProducer(pulsar.ProducerOptions{
        Topic:                   topic,
        SendTimeout:             10 * time.Second,
        BatchingMaxPublishDelay: 10 * time.Millisecond,
        BatchingMaxMessages:     1000,
        CompressionType:         pulsar.LZ4,
        // 自定义路由：有 Key 时按 Key 哈希，否则随机分区。
        // 不设置 MessageRouter 时默认已按 Key 哈希（HashingScheme），此处仅示例。
        MessageRouter: func(msg *pulsar.ProducerMessage, tm pulsar.TopicMetadata) int {
            n := int(tm.NumPartitions())
            if n <= 1 {
                return 0
            }
            if msg.Key != "" {
                h := fnv.New32a()
                _, _ = h.Write([]byte(msg.Key))
                return int(h.Sum32() % uint32(n))
            }
            return rand.IntN(n)
        },
    })
    if err != nil {
        return nil, fmt.Errorf("create producer: %w", err)
    }
    return producer, nil
}
```

### 发送消息

```go
package pulsarx

import (
    "context"
    "errors"
    "fmt"
    "sync"
    "time"

    "github.com/apache/pulsar-client-go/pulsar"
)

// Send 同步发送，等待 broker 确认。
func Send(ctx context.Context, producer pulsar.Producer, msg *Message) (pulsar.MessageID, error) {
    msgID, err := producer.Send(ctx, &pulsar.ProducerMessage{
        Payload:    msg.Payload,
        Key:        msg.Key,
        Properties: msg.Properties,
        EventTime:  time.Now(),
    })
    if err != nil {
        return nil, fmt.Errorf("send message: %w", err)
    }
    return msgID, nil
}

// SendAsync 异步发送，结果通过回调通知。
func SendAsync(ctx context.Context, producer pulsar.Producer, msg *Message, callback func(pulsar.MessageID, *pulsar.ProducerMessage, error)) {
    producer.SendAsync(ctx, &pulsar.ProducerMessage{
        Payload:    msg.Payload,
        Key:        msg.Key,
        Properties: msg.Properties,
        EventTime:  time.Now(),
    }, callback)
}

// SendBatch 并发异步发送，等待全部回调后汇总错误。
func SendBatch(ctx context.Context, producer pulsar.Producer, messages []*Message) error {
    var (
        wg   sync.WaitGroup
        mu   sync.Mutex
        errs []error
    )

    for _, msg := range messages {
        wg.Add(1)
        producer.SendAsync(ctx, &pulsar.ProducerMessage{
            Payload:    msg.Payload,
            Key:        msg.Key,
            Properties: msg.Properties,
        }, func(_ pulsar.MessageID, _ *pulsar.ProducerMessage, err error) {
            defer wg.Done()
            if err != nil {
                mu.Lock()
                errs = append(errs, err)
                mu.Unlock()
            }
        })
    }

    wg.Wait()
    if len(errs) > 0 {
        return fmt.Errorf("send batch: %d/%d failed: %w", len(errs), len(messages), errors.Join(errs...))
    }
    return nil
}
```

### 延迟消息

```go
package pulsarx

import (
    "context"
    "time"

    "github.com/apache/pulsar-client-go/pulsar"
)

// SendDelayed 延迟 delay 后投递。仅 Shared / KeyShared 订阅生效。
func SendDelayed(ctx context.Context, producer pulsar.Producer, msg *Message, delay time.Duration) (pulsar.MessageID, error) {
    return producer.Send(ctx, &pulsar.ProducerMessage{
        Payload:      msg.Payload,
        Key:          msg.Key,
        Properties:   msg.Properties,
        DeliverAfter: delay,
    })
}

// SendScheduled 在指定时间点投递。
func SendScheduled(ctx context.Context, producer pulsar.Producer, msg *Message, deliverAt time.Time) (pulsar.MessageID, error) {
    return producer.Send(ctx, &pulsar.ProducerMessage{
        Payload:    msg.Payload,
        Key:        msg.Key,
        Properties: msg.Properties,
        DeliverAt:  deliverAt,
    })
}
```

---

## 3. 消费者

### 订阅模式

```go
package pulsarx

import (
    "github.com/apache/pulsar-client-go/pulsar"
)

// Subscribe 按订阅类型创建消费者。
func Subscribe(client pulsar.Client, topic, subscription string, typ pulsar.SubscriptionType) (pulsar.Consumer, error) {
    opts := pulsar.ConsumerOptions{
        Topic:             topic,
        SubscriptionName:  subscription,
        Type:              typ,
        ReceiverQueueSize: 1000,
    }
    if typ == pulsar.KeyShared {
        opts.KeySharedPolicy = &pulsar.KeySharedPolicy{
            Mode: pulsar.KeySharedPolicyModeAutoSplit,
        }
    }
    return client.Subscribe(opts)
}
```

| 类型 | 值 | 语义 |
|------|----|------|
| Exclusive | `pulsar.Exclusive` | 单消费者独占，多余消费者连接失败 |
| Shared | `pulsar.Shared` | 多消费者轮询，无顺序保证 |
| Failover | `pulsar.Failover` | 主备，主消费者断开后切换 |
| KeyShared | `pulsar.KeyShared` | 按 Key 哈希分配，同 Key 保序 |

### 消费消息

```go
package pulsarx

import (
    "context"
    "fmt"
    "log/slog"

    "github.com/apache/pulsar-client-go/pulsar"
)

// Handler 处理单条消息。
type Handler func(ctx context.Context, msg pulsar.Message) error

// Consume 阻塞式 Receive 循环。
func Consume(ctx context.Context, consumer pulsar.Consumer, handler Handler) error {
    for {
        msg, err := consumer.Receive(ctx)
        if err != nil {
            if ctx.Err() != nil {
                return ctx.Err()
            }
            return fmt.Errorf("receive: %w", err)
        }

        msgCtx := ExtractTraceContext(ctx, msg)
        if err := handler(msgCtx, msg); err != nil {
            slog.ErrorContext(msgCtx, "handle failed",
                slog.String("topic", msg.Topic()),
                slog.Uint64("redelivery", uint64(msg.RedeliveryCount())),
                slog.Any("error", err))
            consumer.Nack(msg) // 按 NackRedeliveryDelay / NackBackoffPolicy 重投
            continue
        }

        if err := consumer.Ack(msg); err != nil {
            slog.ErrorContext(msgCtx, "ack failed", slog.Any("error", err))
        }
    }
}

// ConsumeChannel 用 consumer.Chan() 与 select 组合，便于与其他信号复用。
func ConsumeChannel(ctx context.Context, consumer pulsar.Consumer, handler Handler) error {
    for {
        select {
        case <-ctx.Done():
            return ctx.Err()
        case cm, ok := <-consumer.Chan():
            if !ok {
                return nil // consumer 已关闭
            }
            msgCtx := ExtractTraceContext(ctx, cm.Message)
            if err := handler(msgCtx, cm.Message); err != nil {
                cm.Consumer.Nack(cm.Message)
                continue
            }
            if err := cm.Consumer.Ack(cm.Message); err != nil {
                slog.ErrorContext(msgCtx, "ack failed", slog.Any("error", err))
            }
        }
    }
}
```

### 批量消费

```go
package pulsarx

import (
    "context"
    "log/slog"
    "time"

    "github.com/apache/pulsar-client-go/pulsar"
)

// BatchHandler 处理一批消息；失败整批 Nack。
type BatchHandler func(ctx context.Context, msgs []pulsar.Message) error

// ConsumeBatch 攒够 batchSize 或超过 flushEvery 后交给 handler。
func ConsumeBatch(ctx context.Context, consumer pulsar.Consumer, batchSize int, flushEvery time.Duration, handler BatchHandler) error {
    batch := make([]pulsar.Message, 0, batchSize)
    timer := time.NewTimer(flushEvery)
    defer timer.Stop()

    flush := func() {
        if len(batch) == 0 {
            return
        }
        if err := handler(ctx, batch); err != nil {
            slog.ErrorContext(ctx, "batch handle failed", slog.Int("size", len(batch)), slog.Any("error", err))
            for _, m := range batch {
                consumer.Nack(m)
            }
        } else {
            for _, m := range batch {
                if err := consumer.Ack(m); err != nil {
                    slog.ErrorContext(ctx, "ack failed", slog.Any("error", err))
                }
            }
        }
        batch = batch[:0]
    }

    for {
        select {
        case <-ctx.Done():
            flush()
            return ctx.Err()
        case <-timer.C:
            flush()
            timer.Reset(flushEvery)
        case cm, ok := <-consumer.Chan():
            if !ok {
                flush()
                return nil
            }
            batch = append(batch, cm.Message)
            if len(batch) >= batchSize {
                flush()
                if !timer.Stop() {
                    <-timer.C
                }
                timer.Reset(flushEvery)
            }
        }
    }
}
```

---

## 4. 死信队列（DLQ）

### 配置 DLQ 与退避重投

```go
package pulsarx

import (
    "fmt"
    "math"
    "time"

    "github.com/apache/pulsar-client-go/pulsar"
)

// ExponentialNackBackoff 实现 pulsar.NackBackoffPolicy：按重投次数指数退避。
type ExponentialNackBackoff struct {
    Initial    time.Duration
    Max        time.Duration
    Multiplier float64
}

func (b ExponentialNackBackoff) Next(redeliveryCount uint32) time.Duration {
    d := time.Duration(float64(b.Initial) * math.Pow(b.Multiplier, float64(redeliveryCount)))
    if d > b.Max || d <= 0 {
        return b.Max
    }
    return d
}

// SubscribeWithDLQ 超过 maxDeliveries 次投递仍未 Ack 的消息进入 <topic>-dlq。
// RetryEnable 打开后可用 consumer.ReconsumeLater 把消息送入 <topic>-retry 延迟重试。
func SubscribeWithDLQ(client pulsar.Client, topic, subscription string, maxDeliveries uint32) (pulsar.Consumer, error) {
    return client.Subscribe(pulsar.ConsumerOptions{
        Topic:            topic,
        SubscriptionName: subscription,
        Type:             pulsar.Shared, // DLQ 仅 Shared / KeyShared 生效
        RetryEnable:      true,
        DLQ: &pulsar.DLQPolicy{
            MaxDeliveries:    maxDeliveries,
            DeadLetterTopic:  fmt.Sprintf("%s-dlq", topic),
            RetryLetterTopic: fmt.Sprintf("%s-retry", topic),
        },
        NackRedeliveryDelay: time.Minute, // NackBackoffPolicy 为 nil 时使用
        NackBackoffPolicy: ExponentialNackBackoff{
            Initial:    time.Second,
            Max:        time.Minute,
            Multiplier: 2.0,
        },
    })
}
```

### 区分瞬时错误与永久错误

```go
package pulsarx

import (
    "context"
    "errors"
    "log/slog"
    "time"

    "github.com/apache/pulsar-client-go/pulsar"
)

// ErrPermanent 标记不应重试的错误。
var ErrPermanent = errors.New("permanent failure")

// ConsumeWithRetryTopic 瞬时错误延迟重试，永久错误直接 Ack 并交给业务侧记录。
func ConsumeWithRetryTopic(ctx context.Context, consumer pulsar.Consumer, handler Handler, retryDelay time.Duration) error {
    for {
        msg, err := consumer.Receive(ctx)
        if err != nil {
            if ctx.Err() != nil {
                return ctx.Err()
            }
            return err
        }

        msgCtx := ExtractTraceContext(ctx, msg)
        err = handler(msgCtx, msg)
        switch {
        case err == nil:
            if err := consumer.Ack(msg); err != nil {
                slog.ErrorContext(msgCtx, "ack failed", slog.Any("error", err))
            }
        case errors.Is(err, ErrPermanent):
            slog.ErrorContext(msgCtx, "permanent failure, skip", slog.Any("error", err))
            _ = consumer.Ack(msg) // 不再重投，避免占满重试预算
        default:
            // 进入 <topic>-retry，delay 后重新投递；超过 MaxDeliveries 自动进 DLQ
            consumer.ReconsumeLater(msg, retryDelay)
        }
    }
}
```

### DLQ 消费者

```go
package pulsarx

import (
    "context"
    "fmt"

    "github.com/apache/pulsar-client-go/pulsar"
)

// ConsumeDLQ 单独订阅死信 topic，通常做告警、落库或人工回放。
func ConsumeDLQ(ctx context.Context, client pulsar.Client, topic string, handler Handler) error {
    consumer, err := client.Subscribe(pulsar.ConsumerOptions{
        Topic:            fmt.Sprintf("%s-dlq", topic),
        SubscriptionName: "dlq-processor",
        Type:             pulsar.Shared,
    })
    if err != nil {
        return err
    }
    defer consumer.Close()

    return Consume(ctx, consumer, handler)
}
```

---

## 5. 链路追踪

Trace context 通过 `ProducerMessage.Properties` 传播，直接使用 OTel propagator。

```go
package pulsarx

import (
    "context"

    "github.com/apache/pulsar-client-go/pulsar"
    "go.opentelemetry.io/otel"
    "go.opentelemetry.io/otel/attribute"
    "go.opentelemetry.io/otel/codes"
    "go.opentelemetry.io/otel/propagation"
    "go.opentelemetry.io/otel/trace"
)

// InjectTraceContext 把 traceparent/tracestate/baggage 写入消息属性。
func InjectTraceContext(ctx context.Context, msg *pulsar.ProducerMessage) {
    if msg.Properties == nil {
        msg.Properties = make(map[string]string)
    }
    otel.GetTextMapPropagator().Inject(ctx, propagation.MapCarrier(msg.Properties))
}

// ExtractTraceContext 从消息属性恢复上游 trace context。
func ExtractTraceContext(ctx context.Context, msg pulsar.Message) context.Context {
    return otel.GetTextMapPropagator().Extract(ctx, propagation.MapCarrier(msg.Properties()))
}

// TracedProducer 在 Send 前创建 producer span 并注入属性。
type TracedProducer struct {
    pulsar.Producer
    tracer trace.Tracer
}

func NewTracedProducer(p pulsar.Producer) *TracedProducer {
    return &TracedProducer{Producer: p, tracer: otel.Tracer("pulsarx")}
}

func (p *TracedProducer) Send(ctx context.Context, msg *pulsar.ProducerMessage) (pulsar.MessageID, error) {
    ctx, span := p.tracer.Start(ctx, p.Topic()+" send",
        trace.WithSpanKind(trace.SpanKindProducer),
        trace.WithAttributes(
            attribute.String("messaging.system", "pulsar"),
            attribute.String("messaging.destination.name", p.Topic()),
            attribute.String("messaging.operation.type", "send"),
        ),
    )
    defer span.End()

    InjectTraceContext(ctx, msg)
    id, err := p.Producer.Send(ctx, msg)
    if err != nil {
        span.RecordError(err)
        span.SetStatus(codes.Error, err.Error())
        return nil, err
    }
    span.SetAttributes(attribute.String("messaging.message.id", id.String()))
    return id, nil
}

// WithConsumerSpan 包装 Handler，以消息属性中的 trace 为父级创建 consumer span。
func WithConsumerSpan(handler Handler) Handler {
    tracer := otel.Tracer("pulsarx")
    return func(ctx context.Context, msg pulsar.Message) error {
        ctx = ExtractTraceContext(ctx, msg)
        ctx, span := tracer.Start(ctx, msg.Topic()+" process",
            trace.WithSpanKind(trace.SpanKindConsumer),
            trace.WithAttributes(
                attribute.String("messaging.system", "pulsar"),
                attribute.String("messaging.destination.name", msg.Topic()),
                attribute.String("messaging.operation.type", "process"),
                attribute.String("messaging.message.id", msg.ID().String()),
                attribute.Int("messaging.pulsar.redelivery_count", int(msg.RedeliveryCount())),
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

## 6. Schema 管理

`NewJSONSchema` / `NewAvroSchema` 接收 Avro 风格的 schema 定义字符串，不接收 Go 结构体。

### JSON Schema

```go
package pulsarx

import (
    "context"
    "fmt"
    "time"

    "github.com/apache/pulsar-client-go/pulsar"
)

type UserEvent struct {
    UserID    string `json:"user_id"`
    EventType string `json:"event_type"`
    Timestamp int64  `json:"timestamp"`
}

const userEventSchema = `{
  "type": "record",
  "name": "UserEvent",
  "namespace": "example",
  "fields": [
    {"name": "user_id", "type": "string"},
    {"name": "event_type", "type": "string"},
    {"name": "timestamp", "type": "long"}
  ]
}`

func NewTypedProducer(client pulsar.Client, topic string) (pulsar.Producer, error) {
    schema, err := pulsar.NewJSONSchemaWithValidation(userEventSchema, nil)
    if err != nil {
        return nil, fmt.Errorf("json schema: %w", err)
    }
    return client.CreateProducer(pulsar.ProducerOptions{
        Topic:  topic,
        Schema: schema,
    })
}

func SendTyped(ctx context.Context, producer pulsar.Producer, event *UserEvent) (pulsar.MessageID, error) {
    return producer.Send(ctx, &pulsar.ProducerMessage{
        Value:     event, // 使用 Value 而非 Payload，由 Schema 编码
        EventTime: time.Unix(event.Timestamp, 0),
    })
}

func NewTypedConsumer(client pulsar.Client, topic, subscription string) (pulsar.Consumer, error) {
    schema, err := pulsar.NewJSONSchemaWithValidation(userEventSchema, nil)
    if err != nil {
        return nil, fmt.Errorf("json schema: %w", err)
    }
    return client.Subscribe(pulsar.ConsumerOptions{
        Topic:            topic,
        SubscriptionName: subscription,
        Type:             pulsar.Shared,
        Schema:           schema,
    })
}

// DecodeTyped 从消息解码结构体。
func DecodeTyped(msg pulsar.Message) (*UserEvent, error) {
    var ev UserEvent
    if err := msg.GetSchemaValue(&ev); err != nil {
        return nil, fmt.Errorf("decode: %w", err)
    }
    return &ev, nil
}
```

### Avro Schema

```go
package pulsarx

import (
    "fmt"

    "github.com/apache/pulsar-client-go/pulsar"
)

func NewAvroProducer(client pulsar.Client, topic, avroSchemaDef string) (pulsar.Producer, error) {
    schema, err := pulsar.NewAvroSchemaWithValidation(avroSchemaDef, nil)
    if err != nil {
        return nil, fmt.Errorf("avro schema: %w", err)
    }
    return client.CreateProducer(pulsar.ProducerOptions{
        Topic:  topic,
        Schema: schema,
    })
}
```

---

## 7. Reader（非订阅读取）

Reader 不创建订阅，不保存消费位置，适合回放与审计。

```go
package pulsarx

import (
    "context"
    "io"

    "github.com/apache/pulsar-client-go/pulsar"
)

// NewReader 从指定位置开始读取。startMsgID 可用 pulsar.EarliestMessageID() / LatestMessageID()。
func NewReader(client pulsar.Client, topic string, startMsgID pulsar.MessageID, inclusive bool) (pulsar.Reader, error) {
    return client.CreateReader(pulsar.ReaderOptions{
        Topic:                   topic,
        StartMessageID:          startMsgID,
        StartMessageIDInclusive: inclusive,
    })
}

// ReadAll 顺序读取直到没有更多消息或 ctx 取消。
func ReadAll(ctx context.Context, reader pulsar.Reader, fn func(pulsar.Message) error) error {
    for reader.HasNext() {
        msg, err := reader.Next(ctx)
        if err != nil {
            return err
        }
        if err := fn(msg); err != nil {
            return err
        }
    }
    return io.EOF
}

// ReadSince 按时间回放。
func ReadSince(ctx context.Context, client pulsar.Client, topic string, since int64) (pulsar.Reader, error) {
    reader, err := NewReader(client, topic, pulsar.EarliestMessageID(), true)
    if err != nil {
        return nil, err
    }
    if err := reader.SeekByTime(unixTime(since)); err != nil {
        reader.Close()
        return nil, err
    }
    return reader, nil
}
```

```go
package pulsarx

import "time"

func unixTime(sec int64) time.Time { return time.Unix(sec, 0) }
```

---

## 8. 多主题订阅

```go
package pulsarx

import (
    "github.com/apache/pulsar-client-go/pulsar"
)

// SubscribeMultiTopic 同时订阅多个主题。
func SubscribeMultiTopic(client pulsar.Client, topics []string, subscription string) (pulsar.Consumer, error) {
    return client.Subscribe(pulsar.ConsumerOptions{
        Topics:           topics,
        SubscriptionName: subscription,
        Type:             pulsar.Shared,
    })
}

// SubscribeTopicPattern 按正则订阅同一 namespace 下的主题。
func SubscribeTopicPattern(client pulsar.Client, pattern, subscription string) (pulsar.Consumer, error) {
    return client.Subscribe(pulsar.ConsumerOptions{
        TopicsPattern:    pattern, // 例如 "persistent://tenant/ns/orders-.*"
        SubscriptionName: subscription,
        Type:             pulsar.Shared,
    })
}
```
