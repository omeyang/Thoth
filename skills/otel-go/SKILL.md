---
name: otel-go
description: "Go OpenTelemetry 可观测性专家 - 使用 otel SDK 直接实现分布式追踪、指标收集、日志关联（otelslog Bridge + slog trace_id 注入）、上下文传播（otelhttp/otelgrpc/手动 propagator）、采样策略（ParentBased/TraceIDRatio/自定义与组合采样器）、Baggage 传递。适用：微服务链路追踪、APM 监控、多信号（traces/metrics/logs）统一采集、vendor-neutral 遥测方案、gRPC/HTTP 自动 instrumentation。不适用：单体应用仅需简单日志排障、性能极敏感热路径（SDK 有微量开销）、已深度绑定特定 APM 厂商 SDK 且无迁移计划。触发词：opentelemetry, otel, tracing, span, metric, 可观测性, 链路追踪, 指标, 采样, propagation, baggage, jaeger, tempo, otlp, otelslog, semconv"
---

# Go OpenTelemetry 专家

使用 Go OpenTelemetry SDK 开发可观测性功能：$ARGUMENTS

---

## 0. 版本与依赖

基线 go1.24.6。go.mod：

```text
go.opentelemetry.io/otel v1.41.0                 // otel、metric、trace、sdk、sdk/metric、semconv/v1.37.0
go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracegrpc v1.41.0
go.opentelemetry.io/otel/exporters/otlp/otlpmetric/otlpmetricgrpc v1.41.0
go.opentelemetry.io/otel/log v0.17.0             // Logs API 仍为 beta，全局入口 otel/log/global
go.opentelemetry.io/otel/sdk/log v0.17.0
go.opentelemetry.io/otel/exporters/otlp/otlplog/otlploggrpc v0.17.0
go.opentelemetry.io/contrib/bridges/otelslog v0.16.0
go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp v0.66.0
go.opentelemetry.io/contrib/instrumentation/google.golang.org/grpc/otelgrpc v0.66.0
```

原则：业务代码直接使用 `otel.Tracer` / `otel.Meter` / `slog`，不引入额外抽象层；
测试或禁用观测时不设置全局 Provider，默认即为 no-op。

---

## 1. SDK 初始化

```go
package otelx

import (
    "context"
    "errors"

    "go.opentelemetry.io/otel"
    "go.opentelemetry.io/otel/log/global"
    "go.opentelemetry.io/otel/propagation"
    "go.opentelemetry.io/otel/sdk/resource"
    semconv "go.opentelemetry.io/otel/semconv/v1.37.0"
)

type Config struct {
    ServiceName, ServiceVersion, Environment string
    OTLPEndpoint                             string  // "otel-collector:4317"
    SampleRatio                              float64 // 根 span 采样比例
    Insecure                                 bool
}

func Init(ctx context.Context, cfg Config) (shutdown func(context.Context) error, err error) {
    var fns []func(context.Context) error
    shutdown = func(ctx context.Context) error {
        var errs error
        for i := len(fns) - 1; i >= 0; i-- {
            errs = errors.Join(errs, fns[i](ctx))
        }
        return errs
    }

    // resource.New 合并探测器结果，避免 resource.Merge 的 schema URL 冲突
    res, err := resource.New(ctx,
        resource.WithFromEnv(), resource.WithTelemetrySDK(), resource.WithHost(),
        resource.WithAttributes(
            semconv.ServiceName(cfg.ServiceName),
            semconv.ServiceVersion(cfg.ServiceVersion),
            semconv.DeploymentEnvironmentName(cfg.Environment),
        ),
    )
    if err != nil {
        return shutdown, err
    }

    tp, err := newTracerProvider(ctx, res, cfg)
    if err != nil {
        return shutdown, err
    }
    fns = append(fns, tp.Shutdown)
    otel.SetTracerProvider(tp)

    mp, err := newMeterProvider(ctx, res, cfg)
    if err != nil {
        return shutdown, err
    }
    fns = append(fns, mp.Shutdown)
    otel.SetMeterProvider(mp)

    lp, err := newLoggerProvider(ctx, res, cfg)
    if err != nil {
        return shutdown, err
    }
    fns = append(fns, lp.Shutdown)
    global.SetLoggerProvider(lp) // Logs API beta：全局入口在 otel/log/global，不在 otel 包

    otel.SetTextMapPropagator(propagation.NewCompositeTextMapPropagator(
        propagation.TraceContext{}, propagation.Baggage{},
    ))
    return shutdown, nil
}
```

Provider 构造要点：

| Provider | Exporter | 关键选项 |
|----------|----------|----------|
| `sdktrace.NewTracerProvider` | `otlptracegrpc.New` | `WithBatcher(exp, WithBatchTimeout(5s), WithMaxExportBatchSize(512))`、`WithSampler(ParentBased(TraceIDRatioBased(r)))` |
| `sdkmetric.NewMeterProvider` | `otlpmetricgrpc.New` | `WithReader(NewPeriodicReader(exp, WithInterval(30s)))` |
| `sdklog.NewLoggerProvider` | `otlploggrpc.New` | `WithProcessor(NewBatchProcessor(exp))` |

main 中 `defer shutdown(ctx)`（带 10s 超时）确保缓冲数据导出。

> 完整初始化见 [references/examples.md](references/examples.md#1-sdk-初始化)

---

## 2. 分布式追踪

```go
package otelx

import (
    "context"

    "go.opentelemetry.io/otel"
    "go.opentelemetry.io/otel/attribute"
    "go.opentelemetry.io/otel/codes"
    "go.opentelemetry.io/otel/trace"
)

var tracer = otel.Tracer("github.com/example/order-service/order") // 包级创建一次

func ProcessOrder(ctx context.Context, orderID string, do func(context.Context) error) error {
    ctx, span := tracer.Start(ctx, "ProcessOrder",
        trace.WithSpanKind(trace.SpanKindInternal),
        trace.WithAttributes(attribute.String("order.id", orderID)),
    )
    defer span.End()

    if err := do(ctx); err != nil { // 子调用传 ctx，自动成为子 span
        span.RecordError(err)
        span.SetStatus(codes.Error, err.Error())
        return err
    }
    span.SetStatus(codes.Ok, "")
    return nil
}
```

- `span.AddEvent()` 记录事件；`span.RecordError()` + `SetStatus(codes.Error)` 记录失败
- SpanKind：入站 `Server` / `Consumer`，出站 `Client` / `Producer`，其余 `Internal`
- 异步任务用 `trace.WithNewRoot()` + `trace.WithLinks(trace.LinkFromContext(ctx))`，不阻塞父 span

### Span 属性规范（semconv v1.37.0）

| 领域 | 常量 / 函数 |
|------|------------|
| HTTP | `HTTPRequestMethodGet`、`HTTPResponseStatusCode(n)`、`URLFull(s)`、`HTTPRoute(s)` |
| DB | `DBSystemNameMongoDB`、`DBNamespace(s)`、`DBOperationName(s)`、`DBCollectionName(s)` |
| 消息 | `MessagingSystemKafka`、`MessagingDestinationName(s)`、`MessagingOperationTypeSend` |

> 完整追踪示例见 [references/examples.md](references/examples.md#2-分布式追踪)

---

## 3. 指标收集

```go
package otelx

import (
    "context"
    "time"

    "go.opentelemetry.io/otel"
    "go.opentelemetry.io/otel/attribute"
    "go.opentelemetry.io/otel/metric"
)

var meter = otel.Meter("github.com/example/order-service/order")

type Metrics struct {
    total    metric.Int64Counter
    duration metric.Float64Histogram
}

func NewMetrics() (*Metrics, error) {
    total, err := meter.Int64Counter("orders.total", metric.WithUnit("{order}"))
    if err != nil {
        return nil, err
    }
    duration, err := meter.Float64Histogram("orders.duration", metric.WithUnit("s"),
        metric.WithExplicitBucketBoundaries(0.005, 0.01, 0.05, 0.1, 0.5, 1, 5))
    if err != nil {
        return nil, err
    }
    return &Metrics{total: total, duration: duration}, nil
}

func (m *Metrics) Record(ctx context.Context, start time.Time, orderType string, err error) {
    status := "ok"
    if err != nil {
        status = "error"
    }
    attrs := metric.WithAttributeSet(attribute.NewSet( // 预构造属性集，减少分配
        attribute.String("order.type", orderType), attribute.String("status", status)))
    mctx := context.WithoutCancel(ctx) // ctx 已取消时仍记录
    m.total.Add(mctx, 1, attrs)
    m.duration.Record(mctx, time.Since(start).Seconds(), attrs)
}
```

| 类型 | 函数 | 用途 |
|------|------|------|
| Counter | `meter.Int64Counter()` | 只增计数（请求总数） |
| Histogram | `meter.Float64Histogram()` | 分布（延迟，单位 s） |
| UpDownCounter | `meter.Int64UpDownCounter()` | 可增减（活跃连接） |
| Gauge | `meter.Float64Gauge()` | 同步当前值 |
| ObservableGauge / Counter | `meter.Int64ObservableGauge()` + `RegisterCallback` | 采集时回调读取（缓存大小） |

属性必须低基数：不要把 user_id、URL 全路径放进指标属性。

> 完整指标与"Span + 指标一体"的 `Instrument` 辅助见 [references/examples.md](references/examples.md#3-指标收集)

---

## 4. 日志关联

两条路径按需组合：

| 路径 | 实现 | 效果 |
|------|------|------|
| 日志导出到 OTLP | `otelslog.NewHandler(name, otelslog.WithLoggerProvider(global.GetLoggerProvider()))` | LogRecord 自动携带 trace_id / span_id，与 trace 在后端关联 |
| 本地 JSON 日志 | 自定义 `slog.Handler` 从 `trace.SpanContextFromContext(ctx)` 注入字段 | stdout / 文件日志可按 trace_id 检索 |

```go
package otelx

import (
    "context"
    "log/slog"

    "go.opentelemetry.io/otel/trace"
)

// TraceHandler 包装任意 slog.Handler，追加 trace_id / span_id。
type TraceHandler struct{ slog.Handler }

func (h *TraceHandler) Handle(ctx context.Context, r slog.Record) error {
    if sc := trace.SpanContextFromContext(ctx); sc.IsValid() {
        r = r.Clone()
        r.AddAttrs(
            slog.String("trace_id", sc.TraceID().String()),
            slog.String("span_id", sc.SpanID().String()),
        )
    }
    return h.Handler.Handle(ctx, r)
}

func (h *TraceHandler) WithAttrs(a []slog.Attr) slog.Handler { return &TraceHandler{h.Handler.WithAttrs(a)} }
func (h *TraceHandler) WithGroup(n string) slog.Handler     { return &TraceHandler{h.Handler.WithGroup(n)} }
```

- 日志调用始终用 `logger.InfoContext(ctx, ...)`，无 ctx 拿不到 span
- 运行时调级用 `slog.LevelVar`
- 双路输出（stdout + OTLP）用 fan-out handler

> otelslog、双路输出、动态调级见 [references/examples.md](references/examples.md#5-日志关联)

---

## 5. 上下文传播

### 自动 Instrumentation

| 组件 | 用法 | 说明 |
|------|------|------|
| HTTP 客户端 | `&http.Client{Transport: otelhttp.NewTransport(http.DefaultTransport)}` | 注入 traceparent / baggage |
| HTTP 服务端 | `otelhttp.NewHandler(mux, "http.server", otelhttp.WithSpanNameFormatter(...))` | span 名用 `r.Pattern`，避免高基数 |
| gRPC 客户端 | `grpc.WithStatsHandler(otelgrpc.NewClientHandler())` | 拦截器方式已废弃 |
| gRPC 服务端 | `grpc.StatsHandler(otelgrpc.NewServerHandler())` | `otelgrpc.WithFilter` 排除健康检查 |

### 手动传播

```go
package otelx

import (
    "context"
    "net/http"

    "go.opentelemetry.io/otel"
    "go.opentelemetry.io/otel/propagation"
)

func Inject(ctx context.Context, req *http.Request) {
    otel.GetTextMapPropagator().Inject(ctx, propagation.HeaderCarrier(req.Header))
}

func Extract(ctx context.Context, req *http.Request) context.Context {
    return otel.GetTextMapPropagator().Extract(ctx, propagation.HeaderCarrier(req.Header))
}

// 消息队列 headers / properties 用 MapCarrier
func InjectMap(ctx context.Context, m map[string]string) {
    otel.GetTextMapPropagator().Inject(ctx, propagation.MapCarrier(m))
}
```

W3C Trace Context 格式：`traceparent: 00-{trace-id}-{parent-id}-{flags}`，`tracestate` 承载厂商数据。

> 完整传播示例见 [references/examples.md](references/examples.md#6-上下文传播)

---

## 6. 采样策略

```go
package otelx

import sdktrace "go.opentelemetry.io/otel/sdk/trace"

func productionSampler(ratio float64) sdktrace.Sampler {
    // 尊重上游决策；根 span 按 trace ID 哈希比例采样（跨服务一致）
    return sdktrace.ParentBased(sdktrace.TraceIDRatioBased(ratio))
}
```

| 采样器 | 说明 |
|--------|------|
| `AlwaysSample()` / `NeverSample()` | 开发 / 关闭 |
| `TraceIDRatioBased(r)` | 按 trace ID 确定性哈希，同一 trace 各服务决策一致 |
| `ParentBased(root, opts...)` | 推荐：有父 span 时跟随父决策，根 span 用 `root` |
| 自定义 `sdktrace.Sampler` | 实现 `ShouldSample(SamplingParameters)` + `Description()` |

自定义采样器只能依据 span **起始**属性（route、method）；错误 / 慢请求全采属于尾采样，
在 Collector 用 `tailsampling` processor 实现。按 tenant 等业务 key 一致采样：key 放入 Baggage，
采样器读取后哈希。组合采样（AND / OR）自行实现 `Sampler` 包装。

> 自定义、组合、Baggage key 采样器见 [references/examples.md](references/examples.md#7-采样策略)

---

## 7. Baggage 传递业务数据

```go
package otelx

import (
    "context"

    "go.opentelemetry.io/otel/baggage"
)

func WithTenantID(ctx context.Context, tenantID string) (context.Context, error) {
    member, err := baggage.NewMember("tenant_id", tenantID)
    if err != nil {
        return ctx, err
    }
    bag, err := baggage.FromContext(ctx).SetMember(member) // 保留已有成员
    if err != nil {
        return ctx, err
    }
    return baggage.ContextWithBaggage(ctx, bag), nil
}

func TenantIDFromBaggage(ctx context.Context) string {
    return baggage.FromContext(ctx).Member("tenant_id").Value()
}
```

- Baggage 明文随请求头传播，只放低基数、非敏感值
- Baggage 不自动成为 span 属性，需要检索时显式 `span.SetAttributes`

---

## 8. 健康检查过滤

- Instrumentation 层：`otelhttp.WithFilter(func(r *http.Request) bool { return r.URL.Path != "/healthz" })`，不创建 span 也不记指标
- gRPC：`otelgrpc.WithFilter(func(info *stats.RPCTagInfo) bool { ... })` 排除 `grpc.health.v1.Health/Check`
- 采样器层：按 `http.route` 属性 Drop，span 仍创建但不导出

> 完整实现见 [references/examples.md](references/examples.md#8-健康检查过滤)

---

## 最佳实践

### 初始化
- `main()` 开头 `Init`，`defer shutdown(ctx)` 带超时
- Resource 用 `resource.New` + `WithFromEnv`，支持 `OTEL_SERVICE_NAME`、`OTEL_RESOURCE_ATTRIBUTES` 覆盖
- Provider 通过 `otel.SetTracerProvider` 等设为全局，业务代码用 `otel.Tracer(name)` 获取

### 追踪
- instrumentation name 用模块路径，包级变量创建一次
- 始终传递 ctx；HTTP / gRPC 用官方 instrumentation，不手写 span

### 指标
- 时长单位秒，名称遵循 semconv（`http.server.request.duration`）
- 属性低基数；预构造 `attribute.NewSet` 减少分配
- 记录时用 `context.WithoutCancel(ctx)`

### 日志
- `otelslog` 导出 + 本地 `TraceHandler` 注入，两者互补
- 生产 JSON、开发 text；`slog.LevelVar` 动态调级

### 采样
- 生产 `ParentBased(TraceIDRatioBased)`；边缘服务决定采样率，内部服务跟随
- 尾采样放 Collector

---

## 检查清单

- [ ] Resource 配置 service.name / version / deployment.environment.name？
- [ ] 采样率合理，ParentBased 跟随上游？
- [ ] HTTP / gRPC 使用官方 instrumentation（stats handler）？
- [ ] 日志经 otelslog 或 TraceHandler 关联 trace_id？
- [ ] 健康检查端点排除？
- [ ] 指标属性低基数、单位符合 semconv？
- [ ] shutdown 带超时并在 main 退出前调用？
- [ ] Logs API beta 版本与 SDK 版本匹配（v0.17.0 ↔ v1.41.0）？

---

## 参考资料

- [references/examples.md](references/examples.md) — SDK 初始化、追踪、指标、日志、传播、采样、Baggage 完整实现
- [opentelemetry-go 文档](https://pkg.go.dev/go.opentelemetry.io/otel)
- [opentelemetry-go-contrib 文档](https://pkg.go.dev/go.opentelemetry.io/contrib)
- [OpenTelemetry Go 官方指南](https://opentelemetry.io/docs/languages/go/)
- [Semantic Conventions](https://opentelemetry.io/docs/specs/semconv/)
