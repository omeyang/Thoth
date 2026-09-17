---
name: pulsar-go
description: "Go Pulsar 消息队列专家 - 使用 pulsar-client-go 进行消息生产消费、订阅模式（Exclusive/Shared/Failover/KeyShared）、死信队列与重试主题、NackBackoffPolicy、OpenTelemetry 链路追踪（Properties 传播）、Schema 管理、延迟消息、Reader 回放。适用：多租户消息系统、延迟/定时投递、海量 Topic 场景、跨地域复制、多种订阅模式灵活切换。不适用：团队已深度使用 Kafka 且无迁移计划、仅需简单 Pub/Sub（用 Redis Streams/NATS）、运维资源有限（Pulsar 依赖 BookKeeper+ZooKeeper）。触发词：pulsar, 消息队列, producer, consumer, 订阅, DLQ, 死信, 延迟消息, schema, topic, 多租户, ReconsumeLater"
---

# Go Pulsar 专家

使用 Go pulsar-client-go 开发消息队列功能：$ARGUMENTS

---

## 0. 版本与依赖

基线 go1.24.6。go.mod：

```text
github.com/apache/pulsar-client-go v0.20.0
go.opentelemetry.io/otel v1.41.0
```

纯 Go 客户端，无 cgo 依赖。直接使用 `pulsar.Client` / `pulsar.Producer` / `pulsar.Consumer` 接口，
不做二次封装；追踪与 DLQ 以独立函数叠加。

---

## 1. 客户端管理

```go
package pulsarx

import (
    "time"

    "github.com/apache/pulsar-client-go/pulsar"
)

func NewClient(serviceURL string) (pulsar.Client, error) {
    return pulsar.NewClient(pulsar.ClientOptions{
        URL:                     serviceURL, // pulsar://host:6650
        OperationTimeout:        30 * time.Second,
        ConnectionTimeout:       10 * time.Second,
        MaxConnectionsPerBroker: 5,
        // Authentication: pulsar.NewAuthenticationToken(token),
    })
}
```

- 一个进程一个 `Client`，多个 Producer/Consumer 共享连接池
- 退出顺序：`producer.Flush()` → `producer.Close()` → `consumer.Close()` → `client.Close()`

> 完整实现见 [references/examples.md](references/examples.md#1-客户端管理)

---

## 2. 生产者

```go
package pulsarx

import (
    "time"

    "github.com/apache/pulsar-client-go/pulsar"
)

func NewProducer(client pulsar.Client, topic string) (pulsar.Producer, error) {
    return client.CreateProducer(pulsar.ProducerOptions{
        Topic:                   topic,
        SendTimeout:             10 * time.Second,
        BatchingMaxPublishDelay: 10 * time.Millisecond,
        BatchingMaxMessages:     1000,
        CompressionType:         pulsar.LZ4,
    })
}
```

| 方法 | 签名 | 说明 |
|------|------|------|
| 同步 | `producer.Send(ctx, *ProducerMessage) (MessageID, error)` | 等待 broker 确认 |
| 异步 | `producer.SendAsync(ctx, msg, func(MessageID, *ProducerMessage, error))` | 回调通知 |
| 批量 | `SendBatch(ctx, producer, msgs)` | 并发 `SendAsync` + `sync.WaitGroup` 汇总错误 |

- 默认按 `Key` 哈希路由分区（`HashingScheme`），同 Key 保序；需要自定义时设置 `MessageRouter`
- 随机数用 `math/rand/v2`（`rand.IntN`）

### 延迟消息

```go
package pulsarx

import (
    "context"
    "time"

    "github.com/apache/pulsar-client-go/pulsar"
)

func SendLater(ctx context.Context, p pulsar.Producer, payload []byte, delay time.Duration, at time.Time) error {
    // 延迟投递
    if _, err := p.Send(ctx, &pulsar.ProducerMessage{Payload: payload, DeliverAfter: delay}); err != nil {
        return err
    }
    // 定时投递
    _, err := p.Send(ctx, &pulsar.ProducerMessage{Payload: payload, DeliverAt: at})
    return err
}
```

延迟消息仅对 Shared / KeyShared 订阅生效。

> 完整实现见 [references/examples.md](references/examples.md#2-生产者)

---

## 3. 消费者

### 订阅模式

| 类型 | 值 | 语义 |
|------|----|------|
| Exclusive | `pulsar.Exclusive` | 单消费者独占 |
| Shared | `pulsar.Shared` | 多消费者轮询，无顺序保证 |
| Failover | `pulsar.Failover` | 主备切换 |
| KeyShared | `pulsar.KeyShared` | 按 Key 分配，同 Key 保序；配 `KeySharedPolicy: &pulsar.KeySharedPolicy{Mode: pulsar.KeySharedPolicyModeAutoSplit}` |

### 消费模式

```go
package pulsarx

import (
    "context"
    "fmt"

    "github.com/apache/pulsar-client-go/pulsar"
)

type Handler func(ctx context.Context, msg pulsar.Message) error

func Consume(ctx context.Context, consumer pulsar.Consumer, handler Handler) error {
    for {
        msg, err := consumer.Receive(ctx) // 阻塞直到有消息或 ctx 取消
        if err != nil {
            if ctx.Err() != nil {
                return ctx.Err()
            }
            return fmt.Errorf("receive: %w", err)
        }
        if err := handler(ExtractTraceContext(ctx, msg), msg); err != nil {
            consumer.Nack(msg) // 按 NackRedeliveryDelay / NackBackoffPolicy 重投
            continue
        }
        if err := consumer.Ack(msg); err != nil {
            return fmt.Errorf("ack: %w", err)
        }
    }
}
```

| 模式 | 用法 | 说明 |
|------|------|------|
| 阻塞接收 | `consumer.Receive(ctx)` | 最常用 |
| Channel | `consumer.Chan()` 返回 `ConsumerMessage{Consumer, Message}` | 便于 `select` 与其他信号复用 |
| 批量 | `ConsumeBatch(ctx, consumer, size, flushEvery, handler)` | 攒批处理，失败整批 `Nack` |

`Ack` 返回 error，须处理；`Nack` 无返回值。

> 完整实现见 [references/examples.md](references/examples.md#3-消费者)

---

## 4. 死信队列（DLQ）

```go
package pulsarx

import (
    "fmt"
    "time"

    "github.com/apache/pulsar-client-go/pulsar"
)

func SubscribeWithDLQ(client pulsar.Client, topic, sub string, maxDeliveries uint32) (pulsar.Consumer, error) {
    return client.Subscribe(pulsar.ConsumerOptions{
        Topic:            topic,
        SubscriptionName: sub,
        Type:             pulsar.Shared, // DLQ 仅 Shared / KeyShared 生效
        RetryEnable:      true,          // 启用 ReconsumeLater → <topic>-retry
        DLQ: &pulsar.DLQPolicy{
            MaxDeliveries:    maxDeliveries,
            DeadLetterTopic:  fmt.Sprintf("%s-dlq", topic),
            RetryLetterTopic: fmt.Sprintf("%s-retry", topic),
        },
        NackRedeliveryDelay: time.Minute,
        // NackBackoffPolicy: 自定义类型实现 Next(redeliveryCount uint32) time.Duration
    })
}
```

三种失败处理：

| 方式 | 行为 | 适用 |
|------|------|------|
| `consumer.Nack(msg)` | 按 `NackRedeliveryDelay` 或 `NackBackoffPolicy` 重投 | 瞬时错误，短延迟 |
| `consumer.ReconsumeLater(msg, delay)` | 送入 retry topic，delay 后重投（需 `RetryEnable`） | 瞬时错误，长延迟 |
| `consumer.Ack(msg)` + 记录 | 不再重投 | 永久错误 |

超过 `MaxDeliveries` 自动进入 DLQ topic，单独订阅 `<topic>-dlq` 处理。
客户端没有内置指数退避策略，需自行实现 `pulsar.NackBackoffPolicy` 接口。

> `ExponentialNackBackoff`、`ConsumeWithRetryTopic` 见 [references/examples.md](references/examples.md#4-死信队列dlq)

---

## 5. 链路追踪

Trace context 经 `ProducerMessage.Properties` 传播，直接用 OTel propagator。

```go
package pulsarx

import (
    "context"

    "github.com/apache/pulsar-client-go/pulsar"
    "go.opentelemetry.io/otel"
    "go.opentelemetry.io/otel/propagation"
)

func InjectTraceContext(ctx context.Context, msg *pulsar.ProducerMessage) {
    if msg.Properties == nil {
        msg.Properties = make(map[string]string)
    }
    otel.GetTextMapPropagator().Inject(ctx, propagation.MapCarrier(msg.Properties))
}

func ExtractTraceContext(ctx context.Context, msg pulsar.Message) context.Context {
    return otel.GetTextMapPropagator().Extract(ctx, propagation.MapCarrier(msg.Properties()))
}
```

- 生产者：`SpanKindProducer`，名称 `<topic> send`，属性 `messaging.system=pulsar`
- 消费者：`SpanKindConsumer`，名称 `<topic> process`，追加 `messaging.message.id`、redelivery count

> `TracedProducer`、`WithConsumerSpan` 见 [references/examples.md](references/examples.md#5-链路追踪)

---

## 6. Schema 管理

`NewJSONSchema` / `NewAvroSchema` 接收 Avro 风格 schema 定义字符串，不接收 Go 结构体。

```go
package pulsarx

import (
    "context"

    "github.com/apache/pulsar-client-go/pulsar"
)

const userEventSchema = `{"type":"record","name":"UserEvent","fields":[
  {"name":"user_id","type":"string"},{"name":"event_type","type":"string"}]}`

type UserEvent struct {
    UserID    string `json:"user_id"`
    EventType string `json:"event_type"`
}

func SendTyped(ctx context.Context, client pulsar.Client, topic string, ev *UserEvent) error {
    schema, err := pulsar.NewJSONSchemaWithValidation(userEventSchema, nil)
    if err != nil {
        return err
    }
    p, err := client.CreateProducer(pulsar.ProducerOptions{Topic: topic, Schema: schema})
    if err != nil {
        return err
    }
    defer p.Close()
    _, err = p.Send(ctx, &pulsar.ProducerMessage{Value: ev}) // Value 由 Schema 编码
    return err
}
```

消费侧 `ConsumerOptions.Schema` 同样设置，`msg.GetSchemaValue(&ev)` 解码。

> 完整实现见 [references/examples.md](references/examples.md#6-schema-管理)

---

## 7. Reader（非订阅读取）

```go
package pulsarx

import (
    "github.com/apache/pulsar-client-go/pulsar"
)

func NewReaderFromEarliest(client pulsar.Client, topic string) (pulsar.Reader, error) {
    return client.CreateReader(pulsar.ReaderOptions{
        Topic:          topic,
        StartMessageID: pulsar.EarliestMessageID(), // 或 LatestMessageID() / 指定 MessageID
    })
}
```

- 不创建订阅、不记录位置，适合回放与审计
- `reader.HasNext()` + `reader.Next(ctx)` 顺序读取；`reader.SeekByTime(t)` 按时间定位

> 完整实现见 [references/examples.md](references/examples.md#7-reader非订阅读取)

---

## 8. 多主题订阅

- `ConsumerOptions.Topics: []string{...}` 订阅多个主题
- `ConsumerOptions.TopicsPattern: "persistent://tenant/ns/orders-.*"` 正则订阅（同一 namespace）

> 完整实现见 [references/examples.md](references/examples.md#8-多主题订阅)

---

## 最佳实践

### 生产者
- 异步发送 + 批量（`BatchingMaxMessages`）提高吞吐
- 启用压缩（LZ4/ZSTD）
- 设置 `SendTimeout`，退出前 `Flush`

### 消费者
- 按场景选订阅模式：需要保序用 KeyShared，需要主备用 Failover
- 必须配置 DLQ，区分瞬时错误（Nack/ReconsumeLater）与永久错误（Ack + 记录）
- `ReceiverQueueSize` 与处理能力匹配，避免预取过多导致重投

### 消息设计
- 用 `Key` 保证相关消息顺序
- 设置 `EventTime` 供时间窗口处理
- 用 `Properties` 传递元数据与 trace context
- 用 Schema 保证类型安全

---

## 检查清单

- [ ] 客户端配置连接与操作超时？
- [ ] 生产者启用批量和压缩？
- [ ] 订阅模式与顺序/并发需求匹配？
- [ ] 配置 DLQ 与 RetryEnable？
- [ ] Trace context 经 Properties 注入与提取？
- [ ] 使用 Schema 保证类型安全？
- [ ] `Ack` 返回值已处理，失败路径 `Nack`/`ReconsumeLater`？
- [ ] 优雅关闭顺序正确？

---

## 参考资料

- [references/examples.md](references/examples.md) — 客户端、生产者、消费者、DLQ、追踪、Schema、Reader 完整实现
- [pulsar-client-go 文档](https://pkg.go.dev/github.com/apache/pulsar-client-go/pulsar)
- [Pulsar 官方文档](https://pulsar.apache.org/docs/)
