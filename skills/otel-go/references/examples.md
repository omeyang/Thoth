# Go OpenTelemetry 完整代码示例

## 目录

- [1. SDK 初始化](#1-sdk-初始化)
  - [完整初始化](#完整初始化推荐)
  - [Tracer Provider](#tracer-provider)
  - [Meter Provider](#meter-provider)
  - [Logger Provider](#logger-provider)
- [2. 分布式追踪](#2-分布式追踪)
  - [创建 Span](#创建-span)
  - [Span 属性规范](#span-属性规范)
  - [错误记录](#错误记录)
- [3. 指标收集](#3-指标收集)
  - [创建指标](#创建指标)
  - [记录指标](#记录指标)
  - [异步指标（回调）](#异步指标回调)
- [4. 日志关联](#4-日志关联)
  - [slog + OTel Bridge](#slog--otel-bridge)
  - [手动注入 Trace 信息](#手动注入-trace-信息)
- [5. 上下文传播](#5-上下文传播)
  - [HTTP 客户端/服务端](#http-客户端)
  - [gRPC 客户端/服务端](#grpc-客户端)
  - [手动传播](#手动传播)
- [6. 采样策略](#6-采样策略)
  - [内置采样器](#内置采样器)
  - [自定义采样器](#自定义采样器)
- [7. 健康检查过滤](#7-健康检查过滤)
- [8. Baggage 传递业务数据](#8-baggage-传递业务数据)

---

## 1. SDK 初始化

### 完整初始化（推荐）

```go
import (
    "context"
    "errors"
    "time"

    "go.opentelemetry.io/otel"
    "go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracegrpc"
    "go.opentelemetry.io/otel/exporters/otlp/otlpmetric/otlpmetricgrpc"
    "go.opentelemetry.io/otel/exporters/otlp/otlplog/otlploggrpc"
    "go.opentelemetry.io/otel/log/global"
    "go.opentelemetry.io/otel/propagation"
    "go.opentelemetry.io/otel/sdk/log"
    "go.opentelemetry.io/otel/sdk/metric"
    "go.opentelemetry.io/otel/sdk/resource"
    "go.opentelemetry.io/otel/sdk/trace"
    semconv "go.opentelemetry.io/otel/semconv/v1.26.0"
)

type OTelConfig struct {
    ServiceName    string
    ServiceVersion string
    Environment    string
    OTLPEndpoint   string
}

func InitOTel(ctx context.Context, cfg OTelConfig) (shutdown func(context.Context) error, err error) {
    var shutdownFuncs []func(context.Context) error

    shutdown = func(ctx context.Context) error {
        var err error
        for _, fn := range shutdownFuncs {
            err = errors.Join(err, fn(ctx))
        }
        return err
    }

    // 创建 Resource
    res, err := newResource(cfg)
    if err != nil {
        return shutdown, err
    }

    // 初始化 Tracer
    tracerProvider, err := newTracerProvider(ctx, res, cfg.OTLPEndpoint)
    if err != nil {
        return shutdown, err
    }
    shutdownFuncs = append(shutdownFuncs, tracerProvider.Shutdown)
    otel.SetTracerProvider(tracerProvider)

    // 初始化 Meter
    meterProvider, err := newMeterProvider(ctx, res, cfg.OTLPEndpoint)
    if err != nil {
        return shutdown, err
    }
    shutdownFuncs = append(shutdownFuncs, meterProvider.Shutdown)
    otel.SetMeterProvider(meterProvider)

    // 初始化 Logger
    loggerProvider, err := newLoggerProvider(ctx, res, cfg.OTLPEndpoint)
    if err != nil {
        return shutdown, err
    }
    shutdownFuncs = append(shutdownFuncs, loggerProvider.Shutdown)
    global.SetLoggerProvider(loggerProvider)

    // 设置 Propagator
    otel.SetTextMapPropagator(propagation.NewCompositeTextMapPropagator(
        propagation.TraceContext{},
        propagation.Baggage{},
    ))

    return shutdown, nil
}

func newResource(cfg OTelConfig) (*resource.Resource, error) {
    return resource.Merge(
        resource.Default(),
        resource.NewWithAttributes(
            semconv.SchemaURL,
            semconv.ServiceName(cfg.ServiceName),
            semconv.ServiceVersion(cfg.ServiceVersion),
            semconv.DeploymentEnvironmentName(cfg.Environment),
        ),
    )
}
```

### Tracer Provider

```go
func newTracerProvider(ctx context.Context, res *resource.Resource, endpoint string) (*trace.TracerProvider, error) {
    exporter, err := otlptracegrpc.New(ctx,
        otlptracegrpc.WithEndpoint(endpoint),
        otlptracegrpc.WithInsecure(),
    )
    if err != nil {
        return nil, fmt.Errorf("create trace exporter: %w", err)
    }

    return trace.NewTracerProvider(
        trace.WithResource(res),
        trace.WithBatcher(exporter,
            trace.WithBatchTimeout(5*time.Second),
            trace.WithMaxExportBatchSize(512),
        ),
        trace.WithSampler(trace.ParentBased(trace.TraceIDRatioBased(0.1))), // 10% 采样
    ), nil
}
```

### Meter Provider

```go
func newMeterProvider(ctx context.Context, res *resource.Resource, endpoint string) (*metric.MeterProvider, error) {
    exporter, err := otlpmetricgrpc.New(ctx,
        otlpmetricgrpc.WithEndpoint(endpoint),
        otlpmetricgrpc.WithInsecure(),
    )
    if err != nil {
        return nil, fmt.Errorf("create metric exporter: %w", err)
    }

    return metric.NewMeterProvider(
        metric.WithResource(res),
        metric.WithReader(metric.NewPeriodicReader(exporter,
            metric.WithInterval(30*time.Second),
        )),
    ), nil
}
```

### Logger Provider

```go
func newLoggerProvider(ctx context.Context, res *resource.Resource, endpoint string) (*log.LoggerProvider, error) {
    exporter, err := otlploggrpc.New(ctx,
        otlploggrpc.WithEndpoint(endpoint),
        otlploggrpc.WithInsecure(),
    )
    if err != nil {
        return nil, fmt.Errorf("create log exporter: %w", err)
    }

    return log.NewLoggerProvider(
        log.WithResource(res),
        log.WithProcessor(log.NewBatchProcessor(exporter)),
    ), nil
}
```

---

## 2. 分布式追踪

### 创建 Span

```go
import (
    "go.opentelemetry.io/otel"
    "go.opentelemetry.io/otel/attribute"
    "go.opentelemetry.io/otel/codes"
    "go.opentelemetry.io/otel/trace"
)

func ProcessOrder(ctx context.Context, orderID string) error {
    tracer := otel.Tracer("order-service")

    ctx, span := tracer.Start(ctx, "ProcessOrder",
        trace.WithAttributes(
            attribute.String("order.id", orderID),
        ),
        trace.WithSpanKind(trace.SpanKindInternal),
    )
    defer span.End()

    // 添加事件
    span.AddEvent("order.validated", trace.WithAttributes(
        attribute.Int("items.count", 5),
    ))

    // 调用子操作（自动关联）
    if err := validateOrder(ctx, orderID); err != nil {
        span.RecordError(err)
        span.SetStatus(codes.Error, err.Error())
        return err
    }

    span.SetStatus(codes.Ok, "")
    return nil
}

func validateOrder(ctx context.Context, orderID string) error {
    tracer := otel.Tracer("order-service")
    _, span := tracer.Start(ctx, "ValidateOrder")
    defer span.End()

    // ... 验证逻辑
    return nil
}
```

### Span 属性规范

```go
// 常用语义属性
import semconv "go.opentelemetry.io/otel/semconv/v1.26.0"

// HTTP 请求
span.SetAttributes(
    semconv.HTTPRequestMethodKey.String("GET"),
    semconv.HTTPResponseStatusCode(200),
    semconv.URLFull("https://api.example.com/users"),
    semconv.HTTPRoute("/users/{id}"),
)

// 数据库操作
span.SetAttributes(
    semconv.DBSystemKey.String("mongodb"),
    semconv.DBNamespace("users"),
    semconv.DBOperationName("find"),
)

// 消息队列
span.SetAttributes(
    semconv.MessagingSystem("kafka"),
    semconv.MessagingDestinationName("orders"),
    semconv.MessagingOperationTypePublish,
)
```

### 错误记录

```go
import (
    "go.opentelemetry.io/otel"
    "go.opentelemetry.io/otel/attribute"
    "go.opentelemetry.io/otel/codes"
    "go.opentelemetry.io/otel/trace"
)

func handleRequest(ctx context.Context) error {
    _, span := otel.Tracer("service").Start(ctx, "handleRequest")
    defer span.End()

    if err := doWork(); err != nil {
        // 记录错误详情
        span.RecordError(err, trace.WithAttributes(
            attribute.String("error.type", "validation"),
            attribute.Bool("error.retryable", true),
        ))
        span.SetStatus(codes.Error, err.Error())
        return err
    }

    span.SetStatus(codes.Ok, "")
    return nil
}
```

---

## 3. 指标收集

### 创建指标

```go
var (
    meter = otel.Meter("order-service")

    orderCounter metric.Int64Counter
    orderDuration metric.Float64Histogram
    activeOrders metric.Int64UpDownCounter
    orderValue metric.Float64Gauge
)

func initMetrics() error {
    var err error

    // 计数器（只增）
    orderCounter, err = meter.Int64Counter("orders.total",
        metric.WithDescription("Total number of orders processed"),
        metric.WithUnit("{order}"),
    )
    if err != nil {
        return err
    }

    // 直方图（分布）
    orderDuration, err = meter.Float64Histogram("orders.duration",
        metric.WithDescription("Order processing duration"),
        metric.WithUnit("ms"),
        metric.WithExplicitBucketBoundaries(10, 50, 100, 250, 500, 1000, 2500, 5000),
    )
    if err != nil {
        return err
    }

    // 上下计数器（可增可减）
    activeOrders, err = meter.Int64UpDownCounter("orders.active",
        metric.WithDescription("Number of orders currently being processed"),
        metric.WithUnit("{order}"),
    )
    if err != nil {
        return err
    }

    return nil
}
```

### 记录指标

```go
func ProcessOrder(ctx context.Context, order *Order) error {
    start := time.Now()

    // 增加活跃订单数
    activeOrders.Add(ctx, 1, metric.WithAttributes(
        attribute.String("order.type", order.Type),
    ))
    defer activeOrders.Add(ctx, -1, metric.WithAttributes(
        attribute.String("order.type", order.Type),
    ))

    err := doProcess(ctx, order)

    // 记录处理时长
    duration := float64(time.Since(start).Milliseconds())
    orderDuration.Record(ctx, duration, metric.WithAttributes(
        attribute.String("order.type", order.Type),
        attribute.Bool("success", err == nil),
    ))

    // 增加计数
    orderCounter.Add(ctx, 1, metric.WithAttributes(
        attribute.String("order.type", order.Type),
        attribute.String("status", statusFromError(err)),
    ))

    return err
}
```

### 异步指标（回调）

```go
func initAsyncMetrics() error {
    // Gauge（当前值）
    _, err := meter.Int64ObservableGauge("cache.size",
        metric.WithDescription("Current cache size"),
        metric.WithUnit("{item}"),
        metric.WithInt64Callback(func(_ context.Context, o metric.Int64Observer) error {
            o.Observe(cache.Size())
            return nil
        }),
    )
    if err != nil {
        return err
    }

    // 异步计数器（单调递增）
    _, err = meter.Int64ObservableCounter("cache.hits",
        metric.WithDescription("Total cache hits"),
        metric.WithInt64Callback(func(_ context.Context, o metric.Int64Observer) error {
            o.Observe(cache.Hits())
            return nil
        }),
    )

    return err
}
```

---

## 4. 日志关联

### slog + OTel Bridge

```go
import (
    "log/slog"

    "go.opentelemetry.io/contrib/bridges/otelslog"
    "go.opentelemetry.io/otel/log/global"
)

func NewLogger() *slog.Logger {
    // 创建 OTel Handler
    handler := otelslog.NewHandler("my-service",
        otelslog.WithLoggerProvider(global.GetLoggerProvider()),
    )

    return slog.New(handler)
}

// 使用
func ProcessOrder(ctx context.Context, orderID string) {
    logger := slog.Default()

    // 自动关联 Trace ID
    logger.InfoContext(ctx, "processing order",
        slog.String("order_id", orderID),
    )
}
```

### 手动注入 Trace 信息

```go
import "go.opentelemetry.io/otel/trace"

func LogWithTrace(ctx context.Context, logger *slog.Logger, msg string, attrs ...slog.Attr) {
    spanCtx := trace.SpanContextFromContext(ctx)

    if spanCtx.IsValid() {
        attrs = append(attrs,
            slog.String("trace_id", spanCtx.TraceID().String()),
            slog.String("span_id", spanCtx.SpanID().String()),
        )
    }

    logger.LogAttrs(ctx, slog.LevelInfo, msg, attrs...)
}
```

---

## 5. 上下文传播

### HTTP 客户端

```go
import (
    "go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp"
)

// 自动注入 trace headers
client := &http.Client{
    Transport: otelhttp.NewTransport(http.DefaultTransport),
}

// 使用
resp, err := client.Do(req.WithContext(ctx))
```

### HTTP 服务端

```go
import (
    "go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp"
)

// 自动提取 trace headers
handler := otelhttp.NewHandler(myHandler, "my-service",
    otelhttp.WithSpanNameFormatter(func(operation string, r *http.Request) string {
        return fmt.Sprintf("%s %s", r.Method, r.URL.Path)
    }),
)

http.ListenAndServe(":8080", handler)
```

### gRPC 客户端

```go
import (
    "go.opentelemetry.io/contrib/instrumentation/google.golang.org/grpc/otelgrpc"
)

conn, err := grpc.NewClient(target,
    grpc.WithStatsHandler(otelgrpc.NewClientHandler()),
)
```

### gRPC 服务端

```go
server := grpc.NewServer(
    grpc.StatsHandler(otelgrpc.NewServerHandler()),
)
```

### 手动传播

```go
// 注入到 HTTP 请求
func InjectToRequest(ctx context.Context, req *http.Request) {
    otel.GetTextMapPropagator().Inject(ctx, propagation.HeaderCarrier(req.Header))
}

// 从 HTTP 请求提取
func ExtractFromRequest(ctx context.Context, req *http.Request) context.Context {
    return otel.GetTextMapPropagator().Extract(ctx, propagation.HeaderCarrier(req.Header))
}

// 注入到 Map
func InjectToMap(ctx context.Context, m map[string]string) {
    otel.GetTextMapPropagator().Inject(ctx, propagation.MapCarrier(m))
}

// 从 Map 提取
func ExtractFromMap(ctx context.Context, m map[string]string) context.Context {
    return otel.GetTextMapPropagator().Extract(ctx, propagation.MapCarrier(m))
}
```

---

## 6. 采样策略

### 内置采样器

```go
import "go.opentelemetry.io/otel/sdk/trace"

// 全部采样
trace.AlwaysSample()

// 不采样
trace.NeverSample()

// 比例采样
trace.TraceIDRatioBased(0.1) // 10%

// 父级决定（推荐）
trace.ParentBased(trace.TraceIDRatioBased(0.1),
    trace.WithLocalParentSampled(trace.AlwaysSample()),
    trace.WithLocalParentNotSampled(trace.NeverSample()),
    trace.WithRemoteParentSampled(trace.AlwaysSample()),
    trace.WithRemoteParentNotSampled(trace.TraceIDRatioBased(0.1)),
)
```

### 自定义采样器

```go
type ErrorSampler struct {
    baseSampler trace.Sampler
}

func (s *ErrorSampler) ShouldSample(p trace.SamplingParameters) trace.SamplingResult {
    // 错误请求总是采样
    for _, attr := range p.Attributes {
        if attr.Key == "error" && attr.Value.AsBool() {
            return trace.SamplingResult{
                Decision:   trace.RecordAndSample,
                Tracestate: p.ParentContext.TraceState(),
            }
        }
    }

    return s.baseSampler.ShouldSample(p)
}

func (s *ErrorSampler) Description() string {
    return "ErrorSampler"
}
```

---

## 7. 健康检查过滤

```go
// 排除健康检查端点
otelhttp.NewHandler(handler, "my-service",
    otelhttp.WithFilter(func(r *http.Request) bool {
        // 返回 false 表示不追踪
        return r.URL.Path != "/health" && r.URL.Path != "/ready"
    }),
)

// Tracer 层面过滤
trace.WithSampler(trace.ParentBased(
    &PathFilterSampler{
        ignorePaths: []string{"/health", "/ready", "/metrics"},
        baseSampler: trace.TraceIDRatioBased(0.1),
    },
))
```

---

## 8. Baggage 传递业务数据

```go
import "go.opentelemetry.io/otel/baggage"

// 设置 Baggage
func SetTenantID(ctx context.Context, tenantID string) (context.Context, error) {
    member, err := baggage.NewMember("tenant_id", tenantID)
    if err != nil {
        return ctx, err
    }

    bag, err := baggage.New(member)
    if err != nil {
        return ctx, err
    }

    return baggage.ContextWithBaggage(ctx, bag), nil
}

// 读取 Baggage
func GetTenantID(ctx context.Context) string {
    bag := baggage.FromContext(ctx)
    return bag.Member("tenant_id").Value()
}
```
