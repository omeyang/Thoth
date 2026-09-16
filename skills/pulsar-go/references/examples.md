# Go Pulsar 完整代码示例

## 目录

- [1. 客户端管理](#1-客户端管理)
  - [创建客户端](#创建客户端)
  - [包装器模式](#包装器模式)
- [2. 生产者](#2-生产者)
  - [创建生产者](#创建生产者)
  - [发送消息](#发送消息)
  - [延迟消息](#延迟消息)
- [3. 消费者](#3-消费者)
  - [订阅模式](#订阅模式)
  - [消费消息](#消费消息)
  - [批量消费](#批量消费)
- [4. 死信队列（DLQ）](#4-死信队列dlq)
  - [配置 DLQ](#配置-dlq)
  - [DLQ 消费者](#dlq-消费者)
- [5. 链路追踪](#5-链路追踪)
  - [OpenTelemetry 集成](#opentelemetry-集成)
- [6. Schema 管理](#6-schema-管理)
  - [JSON Schema](#json-schema)
  - [Avro Schema](#avro-schema)
- [7. Reader（非订阅读取）](#7-reader非订阅读取)
- [8. 多主题订阅](#8-多主题订阅)

---

## 1. 客户端管理

### 创建客户端

```go
import (
    "fmt"
    "time"

    "github.com/apache/pulsar-client-go/pulsar"
)

func NewPulsarClient(serviceURL string) (pulsar.Client, error) {
    client, err := pulsar.NewClient(pulsar.ClientOptions{
        URL:                     serviceURL,
        OperationTimeout:        30 * time.Second,
        ConnectionTimeout:       10 * time.Second,
        MaxConnectionsPerBroker: 5,
        // 认证（可选）
        // Authentication: pulsar.NewAuthenticationToken("token"),
    })
    if err != nil {
        return nil, fmt.Errorf("create pulsar client: %w", err)
    }

    return client, nil
}
```

### 包装器模式

```go
type Pulsar struct {
    client pulsar.Client
}

func New(client pulsar.Client) *Pulsar {
    return &Pulsar{client: client}
}

// Client 暴露底层客户端
func (p *Pulsar) Client() pulsar.Client {
    return p.client
}

// Close 关闭客户端
func (p *Pulsar) Close() {
    p.client.Close()
}
```

---

## 2. 生产者

### 创建生产者

```go
import (
    "hash/fnv"
    "math/rand"
)

func (p *Pulsar) CreateProducer(topic string) (pulsar.Producer, error) {
    producer, err := p.client.CreateProducer(pulsar.ProducerOptions{
        Topic:                   topic,
        Name:                    "my-producer",
        SendTimeout:             10 * time.Second,
        BatchingMaxPublishDelay: 10 * time.Millisecond,
        BatchingMaxMessages:     1000,
        CompressionType:         pulsar.LZ4,
        // 分区路由
        MessageRouter: func(msg *pulsar.ProducerMessage, tm pulsar.TopicMetadata) int {
            // 按 key 路由到固定分区
            if msg.Key != "" {
                h := fnv.New32a()
                h.Write([]byte(msg.Key))
                return int(h.Sum32()) % tm.NumPartitions()
            }
            return rand.Intn(tm.NumPartitions())
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
// 同步发送
func (p *Pulsar) Send(ctx context.Context, producer pulsar.Producer, msg *Message) (pulsar.MessageID, error) {
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

// 异步发送
func (p *Pulsar) SendAsync(ctx context.Context, producer pulsar.Producer, msg *Message, callback func(pulsar.MessageID, *pulsar.ProducerMessage, error)) {
    producer.SendAsync(ctx, &pulsar.ProducerMessage{
        Payload:    msg.Payload,
        Key:        msg.Key,
        Properties: msg.Properties,
        EventTime:  time.Now(),
    }, callback)
}

// 批量发送
func (p *Pulsar) SendBatch(ctx context.Context, producer pulsar.Producer, messages []*Message) error {
    var wg sync.WaitGroup
    var mu sync.Mutex
    var errs []error

    for _, msg := range messages {
        wg.Add(1)
        producer.SendAsync(ctx, &pulsar.ProducerMessage{
            Payload:    msg.Payload,
            Key:        msg.Key,
            Properties: msg.Properties,
        }, func(id pulsar.MessageID, pm *pulsar.ProducerMessage, err error) {
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
        return fmt.Errorf("send batch failed: %d errors", len(errs))
    }
    return nil
}
```

### 延迟消息

```go
// 发送延迟消息
func (p *Pulsar) SendDelayed(ctx context.Context, producer pulsar.Producer, msg *Message, delay time.Duration) (pulsar.MessageID, error) {
    return producer.Send(ctx, &pulsar.ProducerMessage{
        Payload:      msg.Payload,
        Key:          msg.Key,
        DeliverAfter: delay,
    })
}

// 定时投递
func (p *Pulsar) SendScheduled(ctx context.Context, producer pulsar.Producer, msg *Message, deliverAt time.Time) (pulsar.MessageID, error) {
    return producer.Send(ctx, &pulsar.ProducerMessage{
        Payload:   msg.Payload,
        Key:       msg.Key,
        DeliverAt: deliverAt,
    })
}
```

---

## 3. 消费者

### 订阅模式

```go
// Exclusive - 独占模式（只有一个消费者）
func (p *Pulsar) SubscribeExclusive(topic, subscription string) (pulsar.Consumer, error) {
    return p.client.Subscribe(pulsar.ConsumerOptions{
        Topic:            topic,
        SubscriptionName: subscription,
        Type:             pulsar.Exclusive,
    })
}

// Shared - 共享模式（多消费者轮询）
func (p *Pulsar) SubscribeShared(topic, subscription string) (pulsar.Consumer, error) {
    return p.client.Subscribe(pulsar.ConsumerOptions{
        Topic:            topic,
        SubscriptionName: subscription,
        Type:             pulsar.Shared,
    })
}

// Failover - 故障转移模式
func (p *Pulsar) SubscribeFailover(topic, subscription string) (pulsar.Consumer, error) {
    return p.client.Subscribe(pulsar.ConsumerOptions{
        Topic:            topic,
        SubscriptionName: subscription,
        Type:             pulsar.Failover,
    })
}

// KeyShared - 按 Key 分区（保证同 Key 顺序）
func (p *Pulsar) SubscribeKeyShared(topic, subscription string) (pulsar.Consumer, error) {
    return p.client.Subscribe(pulsar.ConsumerOptions{
        Topic:            topic,
        SubscriptionName: subscription,
        Type:             pulsar.KeyShared,
        KeySharedPolicy: pulsar.KeySharedPolicy{
            Mode: pulsar.KeySharedPolicyModeAutoSplit,
        },
    })
}
```

### 消费消息

```go
// 阻塞接收
func (p *Pulsar) Consume(ctx context.Context, consumer pulsar.Consumer, handler func(pulsar.Message) error) error {
    for {
        msg, err := consumer.Receive(ctx)
        if err != nil {
            if ctx.Err() != nil {
                return ctx.Err()
            }
            return fmt.Errorf("receive: %w", err)
        }

        if err := handler(msg); err != nil {
            // 处理失败，稍后重试
            consumer.Nack(msg)
            continue
        }

        // 处理成功，确认消息
        consumer.Ack(msg)
    }
}

// Channel 接收
func (p *Pulsar) ConsumeChannel(ctx context.Context, consumer pulsar.Consumer, handler func(pulsar.Message) error) error {
    msgChan := consumer.Chan()

    for {
        select {
        case <-ctx.Done():
            return ctx.Err()
        case msg := <-msgChan:
            if err := handler(msg); err != nil {
                consumer.Nack(msg)
            } else {
                consumer.Ack(msg)
            }
        }
    }
}
```

### 批量消费

```go
func (p *Pulsar) ConsumeBatch(ctx context.Context, consumer pulsar.Consumer, batchSize int, timeout time.Duration, handler func([]pulsar.Message) error) error {
    batch := make([]pulsar.Message, 0, batchSize)
    timer := time.NewTimer(timeout)
    msgChan := consumer.Chan() // 使用非阻塞 channel 代替阻塞的 Receive

    for {
        select {
        case <-ctx.Done():
            return ctx.Err()

        case <-timer.C:
            if len(batch) > 0 {
                if err := p.processBatch(consumer, batch, handler); err != nil {
                    return err
                }
                batch = batch[:0]
            }
            timer.Reset(timeout)

        case msg := <-msgChan:
            batch = append(batch, msg)

            if len(batch) >= batchSize {
                if err := p.processBatch(consumer, batch, handler); err != nil {
                    return err
                }
                batch = batch[:0]
                timer.Reset(timeout)
            }
        }
    }
}

func (p *Pulsar) processBatch(consumer pulsar.Consumer, batch []pulsar.Message, handler func([]pulsar.Message) error) error {
    if err := handler(batch); err != nil {
        for _, msg := range batch {
            consumer.Nack(msg)
        }
        return err
    }

    for _, msg := range batch {
        consumer.Ack(msg)
    }
    return nil
}
```

---

## 4. 死信队列（DLQ）

### 配置 DLQ

```go
func (p *Pulsar) SubscribeWithDLQ(topic, subscription string, maxRetries uint32) (pulsar.Consumer, error) {
    return p.client.Subscribe(pulsar.ConsumerOptions{
        Topic:            topic,
        SubscriptionName: subscription,
        Type:             pulsar.Shared,
        DLQ: &pulsar.DLQPolicy{
            MaxDeliveries:   maxRetries,
            DeadLetterTopic: fmt.Sprintf("%s-dlq", topic),
            RetryLetterTopic: fmt.Sprintf("%s-retry", topic),
        },
        NackRedeliveryDelay: 1 * time.Minute,
        // 自定义重试延迟
        NackBackoffPolicy: pulsar.NewExponentialNackBackoffPolicy(
            1*time.Second,   // 初始延迟
            60*time.Second,  // 最大延迟
            2.0,             // 倍数
        ),
    })
}
```

### DLQ 消费者

```go
func (p *Pulsar) ConsumeDLQ(ctx context.Context, topic string, handler func(pulsar.Message) error) error {
    dlqTopic := fmt.Sprintf("%s-dlq", topic)

    consumer, err := p.client.Subscribe(pulsar.ConsumerOptions{
        Topic:            dlqTopic,
        SubscriptionName: "dlq-processor",
        Type:             pulsar.Shared,
    })
    if err != nil {
        return err
    }
    defer consumer.Close()

    return p.Consume(ctx, consumer, handler)
}
```

---

## 5. 链路追踪

### OpenTelemetry 集成

```go
import (
    "go.opentelemetry.io/otel"
    "go.opentelemetry.io/otel/propagation"
    "go.opentelemetry.io/otel/trace"
)

type TracingProducer struct {
    pulsar.Producer
    tracer trace.Tracer
}

func WrapProducer(producer pulsar.Producer) *TracingProducer {
    return &TracingProducer{
        Producer: producer,
        tracer:   otel.Tracer("pulsar"),
    }
}

func (p *TracingProducer) Send(ctx context.Context, msg *pulsar.ProducerMessage) (pulsar.MessageID, error) {
    ctx, span := p.tracer.Start(ctx, "pulsar.send",
        trace.WithSpanKind(trace.SpanKindProducer),
    )
    defer span.End()

    // 注入追踪上下文到消息属性
    if msg.Properties == nil {
        msg.Properties = make(map[string]string)
    }
    otel.GetTextMapPropagator().Inject(ctx, propagation.MapCarrier(msg.Properties))

    return p.Producer.Send(ctx, msg)
}

type TracingConsumer struct {
    pulsar.Consumer
    tracer trace.Tracer
}

func WrapConsumer(consumer pulsar.Consumer) *TracingConsumer {
    return &TracingConsumer{
        Consumer: consumer,
        tracer:   otel.Tracer("pulsar"),
    }
}

func (c *TracingConsumer) Receive(ctx context.Context) (pulsar.Message, error) {
    msg, err := c.Consumer.Receive(ctx)
    if err != nil {
        return nil, err
    }

    // 从消息属性提取追踪上下文
    carrier := propagation.MapCarrier(msg.Properties())
    ctx = otel.GetTextMapPropagator().Extract(ctx, carrier)

    _, span := c.tracer.Start(ctx, "pulsar.receive",
        trace.WithSpanKind(trace.SpanKindConsumer),
    )
    defer span.End()

    return msg, nil
}
```

---

## 6. Schema 管理

### JSON Schema

```go
type UserEvent struct {
    UserID    string    `json:"user_id"`
    EventType string    `json:"event_type"`
    Timestamp time.Time `json:"timestamp"`
    Data      any       `json:"data,omitempty"`
}

func (p *Pulsar) CreateTypedProducer(topic string) (pulsar.Producer, error) {
    schema := pulsar.NewJSONSchema(UserEvent{}, nil)

    return p.client.CreateProducer(pulsar.ProducerOptions{
        Topic:  topic,
        Schema: schema,
    })
}

func (p *Pulsar) SendTyped(ctx context.Context, producer pulsar.Producer, event *UserEvent) (pulsar.MessageID, error) {
    return producer.Send(ctx, &pulsar.ProducerMessage{
        Value: event,
    })
}
```

### Avro Schema

```go
func (p *Pulsar) CreateAvroProducer(topic string, avroSchema string) (pulsar.Producer, error) {
    schema := pulsar.NewAvroSchema(avroSchema, nil)

    return p.client.CreateProducer(pulsar.ProducerOptions{
        Topic:  topic,
        Schema: schema,
    })
}
```

---

## 7. Reader（非订阅读取）

```go
import "io"

// 从指定位置读取
func (p *Pulsar) CreateReader(topic string, startMsgID pulsar.MessageID) (pulsar.Reader, error) {
    return p.client.CreateReader(pulsar.ReaderOptions{
        Topic:          topic,
        StartMessageID: startMsgID,
    })
}

// 从最早消息读取
func (p *Pulsar) CreateReaderFromEarliest(topic string) (pulsar.Reader, error) {
    return p.client.CreateReader(pulsar.ReaderOptions{
        Topic:          topic,
        StartMessageID: pulsar.EarliestMessageID(),
    })
}

// 从最新消息读取
func (p *Pulsar) CreateReaderFromLatest(topic string) (pulsar.Reader, error) {
    return p.client.CreateReader(pulsar.ReaderOptions{
        Topic:          topic,
        StartMessageID: pulsar.LatestMessageID(),
    })
}

// 读取消息
func (p *Pulsar) Read(ctx context.Context, reader pulsar.Reader) (pulsar.Message, error) {
    if reader.HasNext() {
        return reader.Next(ctx)
    }
    return nil, io.EOF
}
```

---

## 8. 多主题订阅

```go
// 订阅多个主题
func (p *Pulsar) SubscribeMultiTopic(topics []string, subscription string) (pulsar.Consumer, error) {
    return p.client.Subscribe(pulsar.ConsumerOptions{
        Topics:           topics,
        SubscriptionName: subscription,
        Type:             pulsar.Shared,
    })
}

// 正则匹配主题
func (p *Pulsar) SubscribeTopicPattern(pattern, subscription string) (pulsar.Consumer, error) {
    return p.client.Subscribe(pulsar.ConsumerOptions{
        TopicsPattern:    pattern, // e.g., "persistent://tenant/namespace/topic-.*"
        SubscriptionName: subscription,
        Type:             pulsar.Shared,
    })
}
```
