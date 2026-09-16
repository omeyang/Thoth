---
name: kafka-go
description: "Go Kafka 专家 - 使用 confluent-kafka-go 进行生产消费(同步/异步/批量)、分区策略、消费者组(Rebalance)、Exactly-Once 事务、死信队列(DLQ)、OpenTelemetry 链路追踪。适用：事件驱动架构、日志收集、流处理管道、消息顺序保证。不适用：低延迟 RPC(用 gRPC)；小规模简单队列(用 Redis Pub/Sub)；复杂路由/延迟队列(用 RabbitMQ/Pulsar)。触发词：kafka, 消息队列, producer, consumer, 消费者组, 分区, partition, DLQ, 死信, exactly-once, 事务, confluent"
user-invocable: true
allowed-tools: Bash, Read, Write, Edit, Grep, Glob
---

# Go Kafka 专家

使用 Go confluent-kafka-go 开发 Kafka 功能：$ARGUMENTS

---

## 1. 客户端管理

### 创建生产者

```go
func NewKafkaProducer(brokers string) (*kafka.Producer, error) {
    return kafka.NewProducer(&kafka.ConfigMap{
        "bootstrap.servers":   brokers,
        "acks":                "all",
        "enable.idempotence":  true,
        "retries":             3,
        "linger.ms":           5,
        "batch.size":          16384,
        "compression.type":    "lz4",
        "max.in.flight.requests.per.connection": 5,
    })
}
```

### 创建消费者

```go
func NewKafkaConsumer(brokers, groupID string) (*kafka.Consumer, error) {
    return kafka.NewConsumer(&kafka.ConfigMap{
        "bootstrap.servers":  brokers,
        "group.id":           groupID,
        "auto.offset.reset":  "earliest",
        "enable.auto.commit": false,  // 手动提交
        "session.timeout.ms": 30000,
        "max.poll.interval.ms": 300000,
    })
}
```

### 包装器模式

XKit 的 xkafka 使用**两层包装**架构：基础包装器 + 增强包装器（Tracing/DLQ）。

```go
// 基础包装器 - 暴露底层客户端，提供健康检查和统计
type producerWrapper struct {
    producer *kafka.Producer  // 线程安全
    mu       sync.Mutex       // 保护管理操作(Health/Flush/Close)
    // atomic 统计: MessagesProduced, BytesProduced, Errors, QueueLength
}

// Producer() 暴露底层生产者用于直接 Produce() 调用
func (w *producerWrapper) Producer() *kafka.Producer
func (w *producerWrapper) Health(ctx context.Context) error
func (w *producerWrapper) Stats() ProducerStats
func (w *producerWrapper) Close() error  // Flush + Close
```

**关键设计**：不包装 Produce 调用，而是暴露底层 `Producer()` 让调用方直接使用 confluent-kafka-go API。增值功能在增强包装器中提供。

---

## 2. 生产者

### 直接使用 producer.Produce()

confluent-kafka-go 的 Produce 是核心 API，不要再封装：

```go
// 同步发送（deliveryChan 等待确认）
func ProduceSync(ctx context.Context, p *kafka.Producer, topic string, key, value []byte) error {
    deliveryChan := make(chan kafka.Event, 1)
    // 注意: 不要 close(deliveryChan)，Kafka 内部会写入
    err := p.Produce(&kafka.Message{
        TopicPartition: kafka.TopicPartition{Topic: &topic, Partition: kafka.PartitionAny},
        Key: key, Value: value,
    }, deliveryChan)
    if err != nil { return fmt.Errorf("produce: %w", err) }
    select {
    case <-ctx.Done(): return ctx.Err()
    case e := <-deliveryChan:
        m := e.(*kafka.Message)
        if m.TopicPartition.Error != nil { return fmt.Errorf("delivery: %w", m.TopicPartition.Error) }
        return nil
    }
}

// 异步发送（nil deliveryChan，结果通过 producer.Events() 投递）
err := p.Produce(&kafka.Message{...}, nil)
```

### TracingProducer（自动注入链路追踪）

```go
// TracingProducer 内嵌 producerWrapper，自动注入 trace headers
type TracingProducer struct {
    *producerWrapper
    tracer   Tracer             // 注入/提取 trace context
    observer xmetrics.Observer  // 记录操作指标
}

// Produce 在发送前自动注入 trace，记录 metrics
func (tp *TracingProducer) Produce(ctx context.Context, msg *kafka.Message, deliveryChan chan kafka.Event) error

// 配置选项
WithProducerTracer(tracer Tracer)
WithProducerObserver(observer xmetrics.Observer)
WithProducerFlushTimeout(duration)
```

### 分区策略

```go
// 相同 Key 路由到同一分区（保证顺序）
msg := &kafka.Message{
    TopicPartition: kafka.TopicPartition{Topic: &topic, Partition: kafka.PartitionAny},
    Key:   []byte(orderID),  // Key 相同 → 分区相同
    Value: data,
}

// 指定分区
msg.TopicPartition.Partition = 3
```

> 完整生产者实现见 [references/examples.md](references/examples.md#生产者实现)

---

## 3. 消费者

### 基础消费循环

```go
type MessageHandler func(ctx context.Context, msg *kafka.Message) error
```

### TracingConsumer（推荐）

```go
type TracingConsumer struct {
    *consumerWrapper
    tracer   Tracer
    observer xmetrics.Observer
}

// ReadMessage 读取消息并自动提取 trace context
func (tc *TracingConsumer) ReadMessage(ctx context.Context) (context.Context, *kafka.Message, error)

// Consume 处理单条消息（读取 + 提取 trace + 调用 handler）
func (tc *TracingConsumer) Consume(ctx context.Context, handler MessageHandler) error

// ConsumeLoop 持续消费循环（推荐用于生产环境）
func (tc *TracingConsumer) ConsumeLoop(ctx context.Context, handler MessageHandler) error

// ConsumeLoopWithPolicy 带退避策略的消费循环
func (tc *TracingConsumer) ConsumeLoopWithPolicy(ctx context.Context, handler MessageHandler, backoff BackoffPolicy) error
```

### 手动提交模式

```go
// enable.auto.commit=false 时手动提交
consumer.CommitMessage(msg)  // 提交单条
consumer.Commit()            // 提交所有已读取
```

> 完整消费者实现见 [references/examples.md](references/examples.md#消费者实现)

---

## 4. 死信队列（DLQ）

### DLQ 策略配置

```go
type DLQPolicy struct {
    DLQTopic      string                // 死信 topic（必需）
    RetryTopic    string                // 重试 topic（可选，空=原始 topic）
    RetryPolicy   xretry.RetryPolicy    // 重试策略（必需）
    BackoffPolicy xretry.BackoffPolicy  // 退避延迟（可选）
    ProducerConfig *kafka.ConfigMap     // DLQ 生产者配置（可选）
    OnDLQ         func(msg, err, metadata) // 进入 DLQ 回调
    OnRetry       func(msg, attempt, err)  // 重试回调
}
```

### DLQ 消息元数据 Headers

| Header | 用途 |
|--------|------|
| `x-retry-count` | 当前重试次数 |
| `x-original-topic` | 原始 topic |
| `x-original-partition` | 原始分区 |
| `x-original-offset` | 原始 offset |
| `x-first-fail-time` | 首次失败时间 (RFC3339) |
| `x-last-fail-time` | 最近失败时间 (RFC3339) |
| `x-failure-reason` | 错误信息 |

### DLQ 消费者

```go
type ConsumerWithDLQ interface {
    ConsumeWithRetry(ctx context.Context, handler MessageHandler) error
    ConsumeLoop(ctx context.Context, handler MessageHandler) error
    SendToDLQ(ctx context.Context, msg *kafka.Message, reason error) error
    DLQStats() DLQStats
}
```

**处理流程**：Handler 失败 → 检查 RetryPolicy.ShouldRetry() → 重试或发送 DLQ → 提交 offset

> 完整 DLQ 实现见 [references/examples.md](references/examples.md#死信队列实现)

---

## 5. 链路追踪

### Tracer 接口

```go
// 通用接口，支持 OTel 或其他追踪系统
type Tracer interface {
    Inject(ctx context.Context, carrier map[string]string)
    Extract(carrier map[string]string) context.Context
}
```

### Trace 注入/提取

```go
// Kafka headers ↔ map[string]string 转换
func injectKafkaTrace(ctx context.Context, tracer Tracer, msg *kafka.Message)
func extractKafkaTrace(ctx context.Context, tracer Tracer, msg *kafka.Message) context.Context
```

### Metrics 属性

```go
// 通过 xmetrics.Observer 记录
attrs := []xmetrics.Attr{
    xmetrics.String("messaging.system", "kafka"),
    xmetrics.String("messaging.destination", topic),
}
ctx, span := observer.Start(ctx, xmetrics.SpanOptions{
    Component: "xkafka", Operation: "produce", Kind: xmetrics.KindProducer,
    Attrs: attrs,
})
defer span.End(xmetrics.Result{Err: err})
```

> 完整追踪实现见 [references/examples.md](references/examples.md#链路追踪实现)

---

## 6. 事务（Exactly-Once）

使用 transactional.id + 幂等生产者实现 Exactly-Once 语义。

```go
func NewTransactionalProducer(brokers, transactionalID string) (*kafka.Producer, error)
func (k *Kafka) SendInTransaction(ctx context.Context, messages []Message) error
```

> 完整事务实现见 [references/examples.md](references/examples.md#事务实现)

---

## 7. 消费者组管理

### Rebalance 回调

分区分配/撤销时自动提交 offset。

```go
rebalanceCb := func(c *kafka.Consumer, event kafka.Event) error {
    switch e := event.(type) {
    case kafka.AssignedPartitions:
        return c.Assign(e.Partitions)
    case kafka.RevokedPartitions:
        c.Commit()  // 提交已处理 offset
        return c.Unassign()
    }
    return nil
}
consumer.SubscribeTopics(topics, rebalanceCb)
```

> 完整消费者组管理见 [references/examples.md](references/examples.md#消费者组管理实现)

---

## 8. 健康检查

```go
func (w *producerWrapper) Health(ctx context.Context) error  // 通过 GetMetadata 检查 broker 可用
func (w *consumerWrapper) Health(ctx context.Context) error  // 检查分区分配或 broker 连接
```

---

## 最佳实践

### 生产者
- 使用 `acks=all` 确保持久性
- 启用幂等生产者 (`enable.idempotence=true`)
- 使用 Key 保证相关消息顺序
- 使用 TracingProducer 自动注入 trace

### 消费者
- 手动提交 offset（`enable.auto.commit=false`）
- 使用 ConsumeLoop 而非手动 ReadMessage 循环
- 实现幂等消费（消息可能重复）
- 合理设置 `max.poll.interval.ms`

### 可靠性
- 使用 DLQPolicy + RetryPolicy 处理持续失败消息
- At-least-once 语义（`enable.auto.offset.store=false`）
- 监控消费者 lag 和 DLQStats

### 性能
- 批量发送：调整 `linger.ms` 和 `batch.size`
- 启用压缩 (lz4/snappy)
- ConsumeLoopWithPolicy 使用 BackoffPolicy 避免空转

---

## 检查清单

- [ ] 生产者启用幂等？
- [ ] 消费者手动提交？
- [ ] 实现 DLQ（含 RetryPolicy）？
- [ ] 使用 TracingProducer/TracingConsumer？
- [ ] 处理 rebalance？
- [ ] 设置合理超时？
- [ ] 监控消费者 lag？
- [ ] 消费逻辑幂等？

---

## 参考资料

- [references/examples.md](references/examples.md) - 完整代码实现（生产者、消费者、DLQ、链路追踪、事务、消费者组、健康检查）
