---
name: pulsar-go
description: "Go Pulsar 消息队列专家 - 消息生产消费、订阅模式（Exclusive/Shared/Failover/KeyShared）、死信队列、链路追踪、Schema 管理、延迟消息。适用：多租户消息系统、延迟/定时投递、海量 Topic 场景、跨地域复制、多种订阅模式灵活切换。不适用：团队已深度使用 Kafka 且无迁移计划、仅需简单 Pub/Sub（用 Redis Streams/NATS）、运维资源有限（Pulsar 依赖 BookKeeper+ZooKeeper）。触发词：pulsar, 消息队列, producer, consumer, 订阅, DLQ, 死信, 延迟消息, schema, topic, 多租户"
user-invocable: true
allowed-tools: Bash, Read, Write, Edit, Grep, Glob
---

# Go Pulsar 专家

使用 Go pulsar-client-go 开发消息队列功能：$ARGUMENTS

---

## 1. 客户端管理

### 创建客户端

```go
func NewPulsarClient(serviceURL string) (pulsar.Client, error)
```

- 配置：OperationTimeout=30s, ConnectionTimeout=10s, MaxConnectionsPerBroker=5
- 可选认证：`pulsar.NewAuthenticationToken("token")`

### 包装器模式

```go
type Pulsar struct { client pulsar.Client }
func New(client pulsar.Client) *Pulsar
func (p *Pulsar) Client() pulsar.Client
func (p *Pulsar) Close()
```

> 完整实现见 [references/examples.md](references/examples.md#1-客户端管理)

---

## 2. 生产者

### 创建生产者

```go
func (p *Pulsar) CreateProducer(topic string) (pulsar.Producer, error)
```

- 批量发送：BatchingMaxPublishDelay=10ms, BatchingMaxMessages=1000
- 压缩：LZ4
- 分区路由：按 Key 哈希路由到固定分区

### 发送消息

| 方法 | 签名 | 说明 |
|------|------|------|
| 同步 | `Send(ctx, producer, msg) (MessageID, error)` | 等待确认 |
| 异步 | `SendAsync(ctx, producer, msg, callback)` | 回调通知 |
| 批量 | `SendBatch(ctx, producer, messages) error` | 并发异步+WaitGroup |

### 延迟消息

```go
// 延迟投递
producer.Send(ctx, &pulsar.ProducerMessage{Payload: data, DeliverAfter: 5 * time.Minute})
// 定时投递
producer.Send(ctx, &pulsar.ProducerMessage{Payload: data, DeliverAt: targetTime})
```

> 完整实现见 [references/examples.md](references/examples.md#2-生产者)

---

## 3. 消费者

### 订阅模式

| 模式 | 函数 | 特点 |
|------|------|------|
| Exclusive | `SubscribeExclusive()` | 独占，只有一个消费者 |
| Shared | `SubscribeShared()` | 共享，多消费者轮询 |
| Failover | `SubscribeFailover()` | 故障转移 |
| KeyShared | `SubscribeKeyShared()` | 按 Key 分区，保证同 Key 顺序 |

### 消费模式

| 模式 | 函数 | 说明 |
|------|------|------|
| 阻塞接收 | `Consume(ctx, consumer, handler)` | `Receive()` 循环 |
| Channel | `ConsumeChannel(ctx, consumer, handler)` | `consumer.Chan()` + select |
| 批量 | `ConsumeBatch(ctx, consumer, batchSize, timeout, handler)` | 攒批处理 |

- 成功：`consumer.Ack(msg)`
- 失败：`consumer.Nack(msg)` 触发重投

> 完整实现见 [references/examples.md](references/examples.md#3-消费者)

---

## 4. 死信队列（DLQ）

### 配置 DLQ

```go
consumer, err := p.client.Subscribe(pulsar.ConsumerOptions{
    Topic: topic, SubscriptionName: subscription, Type: pulsar.Shared,
    DLQ: &pulsar.DLQPolicy{
        MaxDeliveries:    maxRetries,
        DeadLetterTopic:  fmt.Sprintf("%s-dlq", topic),
        RetryLetterTopic: fmt.Sprintf("%s-retry", topic),
    },
    NackRedeliveryDelay: 1 * time.Minute,
    NackBackoffPolicy: pulsar.NewExponentialNackBackoffPolicy(1*time.Second, 60*time.Second, 2.0),
})
```

### DLQ 消费者

单独订阅 `<topic>-dlq` 主题处理死信消息。

> 完整实现见 [references/examples.md](references/examples.md#4-死信队列dlq)

---

## 5. 链路追踪

### OpenTelemetry 集成

- `TracingProducer`：发送前注入 trace context 到 `msg.Properties`
- `TracingConsumer`：接收后从 `msg.Properties()` 提取 trace context

```go
// 生产者包装
func WrapProducer(producer pulsar.Producer) *TracingProducer
// 消费者包装
func WrapConsumer(consumer pulsar.Consumer) *TracingConsumer
```

> 完整实现见 [references/examples.md](references/examples.md#5-链路追踪)

---

## 6. Schema 管理

### JSON Schema

```go
schema := pulsar.NewJSONSchema(UserEvent{}, nil)
producer, _ := p.client.CreateProducer(pulsar.ProducerOptions{Topic: topic, Schema: schema})
producer.Send(ctx, &pulsar.ProducerMessage{Value: &event})
```

### Avro Schema

```go
schema := pulsar.NewAvroSchema(avroSchemaJSON, nil)
```

> 完整实现见 [references/examples.md](references/examples.md#6-schema-管理)

---

## 7. Reader（非订阅读取）

```go
func (p *Pulsar) CreateReader(topic string, startMsgID pulsar.MessageID) (pulsar.Reader, error)
func (p *Pulsar) CreateReaderFromEarliest(topic string) (pulsar.Reader, error)
func (p *Pulsar) CreateReaderFromLatest(topic string) (pulsar.Reader, error)
```

- 从指定位置 / 最早 / 最新消息开始读取
- `reader.HasNext()` + `reader.Next(ctx)` 消费

> 完整实现见 [references/examples.md](references/examples.md#7-reader非订阅读取)

---

## 8. 多主题订阅

```go
// 订阅多个主题
func (p *Pulsar) SubscribeMultiTopic(topics []string, subscription string) (pulsar.Consumer, error)
// 正则匹配主题
func (p *Pulsar) SubscribeTopicPattern(pattern, subscription string) (pulsar.Consumer, error)
```

---

## 最佳实践

### 生产者
- 使用异步发送提高吞吐量
- 启用批量发送（BatchingMaxMessages）
- 启用压缩（LZ4/ZSTD）
- 设置合理的 SendTimeout

### 消费者
- 根据场景选择订阅模式
- 使用 DLQ 处理持续失败的消息
- 配置合理的 NackRedeliveryDelay
- 批量处理提高效率

### 消息设计
- 使用 Key 保证相关消息顺序
- 设置 EventTime 用于时间窗口处理
- 使用 Properties 传递元数据
- 考虑使用 Schema 保证类型安全

---

## 检查清单

- [ ] 客户端配置连接超时？
- [ ] 生产者启用批量和压缩？
- [ ] 消费者订阅模式选择正确？
- [ ] 配置 DLQ 处理失败消息？
- [ ] 集成链路追踪？
- [ ] 使用 Schema 保证类型安全？
- [ ] 正确处理 Ack/Nack？
- [ ] 优雅关闭释放资源？

---

## 参考资料

- [完整代码示例](references/examples.md) — 客户端、生产者、消费者、DLQ、追踪、Schema、Reader 完整实现
