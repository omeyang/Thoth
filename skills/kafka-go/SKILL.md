---
name: kafka-go
description: "Go Kafka 专家 - 使用 confluent-kafka-go v2 进行生产消费(同步/异步/批量)、分区策略、消费者组(cooperative-sticky Rebalance)、Exactly-Once 事务、死信队列(DLQ + retry-go 退避)、OpenTelemetry 链路追踪(headers 传播)与指标。适用：事件驱动架构、日志收集、流处理管道、消息顺序保证。不适用：低延迟 RPC(用 gRPC)；小规模简单队列(用 Redis Pub/Sub)；复杂路由/延迟队列(用 RabbitMQ/Pulsar)。触发词：kafka, 消息队列, producer, consumer, 消费者组, 分区, partition, DLQ, 死信, exactly-once, 事务, confluent, librdkafka"
---

# Go Kafka 专家

使用 Go confluent-kafka-go 开发 Kafka 功能：$ARGUMENTS

---

## 0. 版本与依赖

基线 go1.24.6。go.mod：

```text
github.com/confluentinc/confluent-kafka-go/v2 v2.14.1
github.com/avast/retry-go/v5 v5.0.0
go.opentelemetry.io/otel v1.41.0
golang.org/x/sync v0.19.0
```

- confluent-kafka-go v2 内置 librdkafka 静态库，构建需要 `CGO_ENABLED=1` 与 C 工具链；
  Alpine 镜像使用 `-tags musl`，动态链接系统 librdkafka 使用 `-tags dynamic`。
- 不再封装 `Produce`/`ReadMessage`；直接使用 `*kafka.Producer`、`*kafka.Consumer`，
  追踪、DLQ、指标以独立函数或轻量包装（嵌入指针）叠加。

---

## 1. 客户端管理

### 创建生产者

```go
package kafkax

import "github.com/confluentinc/confluent-kafka-go/v2/kafka"

func NewProducer(brokers string) (*kafka.Producer, error) {
    return kafka.NewProducer(&kafka.ConfigMap{
        "bootstrap.servers":                     brokers,
        "acks":                                  "all",
        "enable.idempotence":                    true,
        "retries":                               3,
        "linger.ms":                             5,
        "batch.size":                            16384,
        "compression.type":                      "lz4",
        "max.in.flight.requests.per.connection": 5,
    })
}
```

### 创建消费者

```go
package kafkax

import "github.com/confluentinc/confluent-kafka-go/v2/kafka"

func NewConsumer(brokers, groupID string) (*kafka.Consumer, error) {
    return kafka.NewConsumer(&kafka.ConfigMap{
        "bootstrap.servers":             brokers,
        "group.id":                      groupID,
        "auto.offset.reset":             "earliest",
        "enable.auto.commit":            false, // 手动提交
        "session.timeout.ms":            30000,
        "max.poll.interval.ms":          300000,
        "partition.assignment.strategy": "cooperative-sticky",
    })
}
```

两种提交模式：

| 模式 | 配置 | 提交方式 | 适用 |
|------|------|----------|------|
| 手动提交 | `enable.auto.commit=false` | 处理成功后 `CommitMessage(msg)` | 吞吐一般，语义直观 |
| 手动存储 + 自动提交 | `enable.auto.commit=true`, `enable.auto.offset.store=false` | 处理成功后 `StoreMessage(msg)` | 高吞吐、并发消费 |

### 关闭顺序

```go
package kafkax

import "github.com/confluentinc/confluent-kafka-go/v2/kafka"

func Close(p *kafka.Producer, c *kafka.Consumer) error {
    p.Flush(15000) // 等待队列中的消息投递完成
    p.Close()
    return c.Close() // 触发最后一次 rebalance 并提交已存储 offset
}
```

---

## 2. 生产者

### 同步发送

```go
package kafkax

import (
    "context"
    "fmt"

    "github.com/confluentinc/confluent-kafka-go/v2/kafka"
)

func ProduceSync(ctx context.Context, p *kafka.Producer, msg *kafka.Message) error {
    deliveryChan := make(chan kafka.Event, 1) // 不要 close，librdkafka 会写入
    if err := p.Produce(msg, deliveryChan); err != nil {
        return fmt.Errorf("produce: %w", err)
    }
    select {
    case <-ctx.Done():
        return ctx.Err()
    case e := <-deliveryChan:
        if m, ok := e.(*kafka.Message); ok && m.TopicPartition.Error != nil {
            return fmt.Errorf("delivery: %w", m.TopicPartition.Error)
        }
        return nil
    }
}
```

### 异步发送

```go
package kafkax

import (
    "context"
    "log/slog"

    "github.com/confluentinc/confluent-kafka-go/v2/kafka"
)

// deliveryChan 为 nil 时结果经 p.Events() 投递，必须有 goroutine 消费它。
func ProduceAsync(p *kafka.Producer, msg *kafka.Message) error { return p.Produce(msg, nil) }

func HandleDeliveryReports(ctx context.Context, p *kafka.Producer) {
    for {
        select {
        case <-ctx.Done():
            return
        case e := <-p.Events():
            switch ev := e.(type) {
            case *kafka.Message:
                if ev.TopicPartition.Error != nil {
                    slog.Error("delivery failed", slog.Any("error", ev.TopicPartition.Error))
                }
            case kafka.Error:
                slog.Error("kafka error", slog.Bool("fatal", ev.IsFatal()), slog.Any("error", ev))
            }
        }
    }
}
```

### 分区策略

```go
package kafkax

import "github.com/confluentinc/confluent-kafka-go/v2/kafka"

func KeyedMessage(topic string, key, value []byte) *kafka.Message {
    return &kafka.Message{
        TopicPartition: kafka.TopicPartition{Topic: &topic, Partition: kafka.PartitionAny},
        Key:            key, // Key 相同 → 分区相同 → 顺序保证
        Value:          value,
    }
}
```

指定分区：`TopicPartition.Partition = 3`。默认分区器 `murmur2_random` 与 Java 客户端一致。

> 批量发送、投递报告汇总见 [references/examples.md](references/examples.md#生产者实现)

---

## 3. 消费者

### 基础消费循环

```go
package kafkax

import (
    "context"
    "errors"
    "fmt"
    "time"

    "github.com/confluentinc/confluent-kafka-go/v2/kafka"
)

type Handler func(ctx context.Context, msg *kafka.Message) error

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
            if errors.As(err, &kerr) && kerr.Code() == kafka.ErrTimedOut {
                continue // 无消息
            }
            return fmt.Errorf("read message: %w", err)
        }
        if err := handler(ExtractTraceContext(ctx, msg), msg); err != nil {
            continue // 不提交，交给 DLQ 策略或下次重放
        }
        if _, err := c.CommitMessage(msg); err != nil {
            return fmt.Errorf("commit: %w", err)
        }
    }
}
```

要点：

- `ReadMessage` 超时返回 `kafka.ErrTimedOut`，用 `errors.As` 判断后继续。
- `kerr.IsFatal()` 为真时客户端已不可用，退出并重建。
- 并发消费按分区取模分发到固定 worker，保证分区内顺序；处理完成后 `StoreMessage`。

> 批量消费、并发消费（errgroup + StoreMessage）见 [references/examples.md](references/examples.md#消费者实现)

---

## 4. 死信队列（DLQ）

处理流程：Handler 失败 → retry-go 进程内退避重试 → 仍失败发 DLQ → 提交 offset。
DLQ 写入失败时不提交 offset，等待下次重放。

```go
package kafkax

import (
    "context"
    "time"

    "github.com/avast/retry-go/v5"
    "github.com/confluentinc/confluent-kafka-go/v2/kafka"
)

type DLQPolicy struct {
    DLQTopic     string        // 必需
    MaxAttempts  uint          // 含首次，默认 3
    InitialDelay time.Duration // 默认 200ms
    MaxDelay     time.Duration // 默认 5s
    OnDLQ        func(ctx context.Context, msg *kafka.Message, err error)
}

func handleWithRetry(ctx context.Context, p DLQPolicy, msg *kafka.Message, handler Handler) error {
    return retry.New(
        retry.Context(ctx),
        retry.Attempts(p.MaxAttempts),
        retry.Delay(p.InitialDelay),
        retry.MaxDelay(p.MaxDelay),
        retry.DelayType(retry.BackOffDelay),
        retry.LastErrorOnly(true),
    ).Do(func() error { return handler(ctx, msg) })
}
```

DLQ 消息附带的 Headers：

| Header | 用途 |
|--------|------|
| `x-retry-count` | 进程内重试次数 |
| `x-original-topic` / `x-original-partition` / `x-original-offset` | 原始位置 |
| `x-first-fail-time` / `x-last-fail-time` | RFC3339 时间 |
| `x-failure-reason` | 最后一次错误信息 |

> 完整 `DLQConsumer` 实现见 [references/examples.md](references/examples.md#死信队列实现)

---

## 5. 链路追踪与指标

Trace context 通过消息 headers 传播，直接使用 OTel propagator，无需额外抽象。

```go
package kafkax

import (
    "context"

    "github.com/confluentinc/confluent-kafka-go/v2/kafka"
    "go.opentelemetry.io/otel"
    "go.opentelemetry.io/otel/propagation"
)

func InjectTraceContext(ctx context.Context, msg *kafka.Message) {
    carrier := propagation.MapCarrier{}
    otel.GetTextMapPropagator().Inject(ctx, carrier)
    for k, v := range carrier {
        msg.Headers = append(msg.Headers, kafka.Header{Key: k, Value: []byte(v)})
    }
}

func ExtractTraceContext(ctx context.Context, msg *kafka.Message) context.Context {
    carrier := propagation.MapCarrier{}
    for _, h := range msg.Headers {
        carrier[h.Key] = string(h.Value)
    }
    return otel.GetTextMapPropagator().Extract(ctx, carrier)
}
```

Span 与指标约定（semconv messaging）：

- 生产者：`SpanKindProducer`，名称 `<topic> send`，属性 `messaging.system=kafka`、
  `messaging.destination.name`、`messaging.operation.type=send`。
- 消费者：`SpanKindConsumer`，名称 `<topic> process`，追加 `messaging.destination.partition.id`、
  `messaging.kafka.offset`。
- 指标：`messaging.client.sent.messages`（Counter）、`messaging.client.operation.duration`（Histogram，单位 s）。
  记录时使用 `context.WithoutCancel(ctx)`，保证超时场景仍能上报。

> `TracedProducer`、`WithConsumerSpan` 见 [references/examples.md](references/examples.md#链路追踪与指标实现)

---

## 6. 事务（Exactly-Once）

`transactional.id` + 幂等生产者；消费-转换-生产场景用 `SendOffsetsToTransaction`
把输入 offset 与输出消息绑定到同一事务，消费者设置 `isolation.level=read_committed`。

```go
package kafkax

import (
    "context"
    "fmt"

    "github.com/confluentinc/confluent-kafka-go/v2/kafka"
)

func NewTransactionalProducer(ctx context.Context, brokers, txID string) (*kafka.Producer, error) {
    p, err := kafka.NewProducer(&kafka.ConfigMap{
        "bootstrap.servers":  brokers,
        "transactional.id":   txID, // 实例间唯一，重启后稳定
        "enable.idempotence": true,
    })
    if err != nil {
        return nil, err
    }
    if err := p.InitTransactions(ctx); err != nil {
        p.Close()
        return nil, fmt.Errorf("init transactions: %w", err)
    }
    return p, nil
}
```

事务流程：`BeginTransaction` → `Produce` → `SendOffsetsToTransaction(ctx, position, groupMetadata)` →
`CommitTransaction`；任一步失败调用 `AbortTransaction`，`kerr.IsFatal()` 时重建生产者。

> 完整实现见 [references/examples.md](references/examples.md#事务实现)

---

## 7. 消费者组管理

`cooperative-sticky` 策略下回调必须使用增量分配：

```go
package kafkax

import "github.com/confluentinc/confluent-kafka-go/v2/kafka"

func RebalanceCallback(c *kafka.Consumer, ev kafka.Event) error {
    switch e := ev.(type) {
    case kafka.AssignedPartitions:
        return c.IncrementalAssign(e.Partitions)
    case kafka.RevokedPartitions:
        if !c.AssignmentLost() {
            _, _ = c.Commit() // 提交已处理 offset；无待提交时返回 ErrNoOffset
        }
        return c.IncrementalUnassign(e.Partitions)
    }
    return nil
}
```

`c.SubscribeTopics(topics, RebalanceCallback)`。`range`/`roundrobin` 策略则使用 `Assign`/`Unassign`。

> 手动分区分配见 [references/examples.md](references/examples.md#消费者组管理实现)

---

## 8. 健康检查

```go
package kafkax

import (
    "errors"
    "fmt"

    "github.com/confluentinc/confluent-kafka-go/v2/kafka"
)

func ProducerHealth(p *kafka.Producer) error {
    if err := p.GetFatalError(); err != nil {
        return fmt.Errorf("producer fatal: %w", err)
    }
    md, err := p.GetMetadata(nil, false, 5000)
    if err != nil {
        return fmt.Errorf("get metadata: %w", err)
    }
    if len(md.Brokers) == 0 {
        return errors.New("no brokers available")
    }
    return nil
}
```

消费者额外检查 `c.Assignment()` 非空。

---

## 最佳实践

### 生产者
- `acks=all` + `enable.idempotence=true`
- 相关消息使用同一 Key 保证顺序
- 异步发送必须消费 `Events()`；退出前 `Flush` 再 `Close`

### 消费者
- 手动提交或"手动存储 + 自动提交"，不用默认自动提交
- 消费逻辑幂等（at-least-once 会重复）
- `max.poll.interval.ms` 大于单批最长处理时间，否则被踢出组

### 可靠性
- 持续失败的消息进 DLQ，不阻塞分区
- 监控消费者 lag（`Committed` 与 `QueryWatermarkOffsets` 之差）与 DLQ 写入量

### 性能
- `linger.ms`、`batch.size`、`compression.type=lz4`
- 并发消费按分区分发，避免跨分区乱序

---

## 检查清单

- [ ] 生产者启用幂等？
- [ ] 消费者手动提交 / StoreMessage？
- [ ] 实现 DLQ（含退避重试）？
- [ ] Trace context 经 headers 注入与提取？
- [ ] Rebalance 回调与分配策略匹配（cooperative-sticky ↔ Incremental*）？
- [ ] 设置合理超时（session/poll interval）？
- [ ] 监控消费者 lag？
- [ ] 消费逻辑幂等？

---

## 参考资料

- [references/examples.md](references/examples.md) - 完整代码实现（生产者、消费者、DLQ、链路追踪、事务、消费者组、健康检查）
- [confluent-kafka-go 文档](https://pkg.go.dev/github.com/confluentinc/confluent-kafka-go/v2/kafka)
- [librdkafka 配置项](https://github.com/confluentinc/librdkafka/blob/master/CONFIGURATION.md)
