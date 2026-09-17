# Go OpenTelemetry 完整代码示例

基线：go1.24.6。模块版本：

```text
go.opentelemetry.io/otel v1.41.0（otel、metric、trace、sdk、sdk/metric、semconv/v1.37.0）
go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracegrpc v1.41.0
go.opentelemetry.io/otel/exporters/otlp/otlpmetric/otlpmetricgrpc v1.41.0
go.opentelemetry.io/otel/log v0.17.0、otel/sdk/log v0.17.0、exporters/otlp/otlplog/otlploggrpc v0.17.0（Logs API 为 beta）
go.opentelemetry.io/contrib/bridges/otelslog v0.16.0
go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp v0.66.0
go.opentelemetry.io/contrib/instrumentation/google.golang.org/grpc/otelgrpc v0.66.0
```

所有片段同属一个包 `otelx`。

## 目录

- [1. SDK 初始化](#1-sdk-初始化)
- [2. 分布式追踪](#2-分布式追踪)
- [3. 指标收集](#3-指标收集)
- [4. 操作观测辅助（Span + 指标一体）](#4-操作观测辅助span--指标一体)
- [5. 日志关联](#5-日志关联)
- [6. 上下文传播](#6-上下文传播)
- [7. 采样策略](#7-采样策略)
- [8. 健康检查过滤](#8-健康检查过滤)
- [9. Baggage 传递业务数据](#9-baggage-传递业务数据)

---

## 1. SDK 初始化

### 完整初始化（推荐）

```go
package otelx

import (
    "context"
    "errors"
    "fmt"
    "time"

    "go.opentelemetry.io/otel"
    "go.opentelemetry.io/otel/attribute"
    "go.opentelemetry.io/otel/exporters/otlp/otlplog/otlploggrpc"
    "go.opentelemetry.io/otel/exporters/otlp/otlpmetric/otlpmetricgrpc"
    "go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracegrpc"
    "go.opentelemetry.io/otel/log/global"
    "go.opentelemetry.io/otel/propagation"
    sdklog "go.opentelemetry.io/otel/sdk/log"
    sdkmetric "go.opentelemetry.io/otel/sdk/metric"
    "go.opentelemetry.io/otel/sdk/resource"
    sdktrace "go.opentelemetry.io/otel/sdk/trace"
    semconv "go.opentelemetry.io/otel/semconv/v1.37.0"
)

type Config struct {
    ServiceName    string
    ServiceVersion string
    Environment    string
    OTLPEndpoint   string  // host:port，例如 "otel-collector:4317"
    SampleRatio    float64 // 0~1，根 span 采样比例
    Insecure       bool    // 开发环境用明文 gRPC
}

// Init 初始化 Trace / Metric / Log 三个 Provider 与 Propagator，返回统一 shutdown。
// 任一步失败时已创建的 Provider 会被关闭。
func Init(ctx context.Context, cfg Config) (shutdown func(context.Context) error, err error) {
    var shutdownFuncs []func(context.Context) error
    shutdown = func(ctx context.Context) error {
        var errs error
        for i := len(shutdownFuncs) - 1; i >= 0; i-- { // 逆序关闭
            errs = errors.Join(errs, shutdownFuncs[i](ctx))
        }
        return errs
    }
    defer func() {
        if err != nil {
            err = errors.Join(err, shutdown(ctx))
        }
    }()

    res, err := newResource(ctx, cfg)
    if err != nil {
        return shutdown, err
    }

    tp, err := newTracerProvider(ctx, res, cfg)
    if err != nil {
        return shutdown, err
    }
    shutdownFuncs = append(shutdownFuncs, tp.Shutdown)
    otel.SetTracerProvider(tp)

    mp, err := newMeterProvider(ctx, res, cfg)
    if err != nil {
        return shutdown, err
    }
    shutdownFuncs = append(shutdownFuncs, mp.Shutdown)
    otel.SetMeterProvider(mp)

    lp, err := newLoggerProvider(ctx, res, cfg)
    if err != nil {
        return shutdown, err
    }
    shutdownFuncs = append(shutdownFuncs, lp.Shutdown)
    global.SetLoggerProvider(lp) // Logs API 为 beta，全局入口在 otel/log/global

    otel.SetTextMapPropagator(propagation.NewCompositeTextMapPropagator(
        propagation.TraceContext{},
        propagation.Baggage{},
    ))

    return shutdown, nil
}

// newResource 使用 resource.New 合并探测器结果，避免 resource.Merge 的 schema URL 冲突。
func newResource(ctx context.Context, cfg Config) (*resource.Resource, error) {
    res, err := resource.New(ctx,
        resource.WithFromEnv(),      // OTEL_RESOURCE_ATTRIBUTES / OTEL_SERVICE_NAME
        resource.WithTelemetrySDK(), // telemetry.sdk.*
        resource.WithHost(),
        resource.WithAttributes(
            semconv.ServiceName(cfg.ServiceName),
            semconv.ServiceVersion(cfg.ServiceVersion),
            semconv.DeploymentEnvironmentName(cfg.Environment),
            attribute.String("service.instance.id", instanceID()),
        ),
    )
    if err != nil {
        return nil, fmt.Errorf("create resource: %w", err)
    }
    return res, nil
}

func newTracerProvider(ctx context.Context, res *resource.Resource, cfg Config) (*sdktrace.TracerProvider, error) {
    opts := []otlptracegrpc.Option{otlptracegrpc.WithEndpoint(cfg.OTLPEndpoint)}
    if cfg.Insecure {
        opts = append(opts, otlptracegrpc.WithInsecure())
    }
    exporter, err := otlptracegrpc.New(ctx, opts...)
    if err != nil {
        return nil, fmt.Errorf("create trace exporter: %w", err)
    }

    return sdktrace.NewTracerProvider(
        sdktrace.WithResource(res),
        sdktrace.WithBatcher(exporter,
            sdktrace.WithBatchTimeout(5*time.Second),
            sdktrace.WithMaxExportBatchSize(512),
        ),
        sdktrace.WithSampler(sdktrace.ParentBased(sdktrace.TraceIDRatioBased(cfg.SampleRatio))),
    ), nil
}

func newMeterProvider(ctx context.Context, res *resource.Resource, cfg Config) (*sdkmetric.MeterProvider, error) {
    opts := []otlpmetricgrpc.Option{otlpmetricgrpc.WithEndpoint(cfg.OTLPEndpoint)}
    if cfg.Insecure {
        opts = append(opts, otlpmetricgrpc.WithInsecure())
    }
    exporter, err := otlpmetricgrpc.New(ctx, opts...)
    if err != nil {
        return nil, fmt.Errorf("create metric exporter: %w", err)
    }

    return sdkmetric.NewMeterProvider(
        sdkmetric.WithResource(res),
        sdkmetric.WithReader(sdkmetric.NewPeriodicReader(exporter,
            sdkmetric.WithInterval(30*time.Second),
        )),
    ), nil
}

func newLoggerProvider(ctx context.Context, res *resource.Resource, cfg Config) (*sdklog.LoggerProvider, error) {
    opts := []otlploggrpc.Option{otlploggrpc.WithEndpoint(cfg.OTLPEndpoint)}
    if cfg.Insecure {
        opts = append(opts, otlploggrpc.WithInsecure())
    }
    exporter, err := otlploggrpc.New(ctx, opts...)
    if err != nil {
        return nil, fmt.Errorf("create log exporter: %w", err)
    }

    return sdklog.NewLoggerProvider(
        sdklog.WithResource(res),
        sdklog.WithProcessor(sdklog.NewBatchProcessor(exporter)),
    ), nil
}
```

```go
package otelx

import (
    "crypto/rand"
    "os"
)

// instanceID 优先使用 HOSTNAME（K8s Pod 名），否则生成随机 ID。
func instanceID() string {
    if h := os.Getenv("HOSTNAME"); h != "" {
        return h
    }
    return rand.Text()
}
```

### main 中的用法

```go
package otelx

import (
    "context"
    "log/slog"
    "os"
    "os/signal"
    "syscall"
    "time"
)

func runMain() {
    ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
    defer stop()

    shutdown, err := Init(ctx, Config{
        ServiceName:    "order-service",
        ServiceVersion: "1.2.3",
        Environment:    "production",
        OTLPEndpoint:   "otel-collector:4317",
        SampleRatio:    0.1,
    })
    if err != nil {
        slog.Error("init otel", slog.Any("error", err))
        os.Exit(1)
    }
    defer func() {
        sctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
        defer cancel()
        if err := shutdown(sctx); err != nil { // 确保缓冲数据导出
            slog.Error("shutdown otel", slog.Any("error", err))
        }
    }()

    slog.SetDefault(NewLogger("order-service"))
    <-ctx.Done()
}
```

---

## 2. 分布式追踪

### 创建 Span

```go
package otelx

import (
    "context"
    "errors"

    "go.opentelemetry.io/otel"
    "go.opentelemetry.io/otel/attribute"
    "go.opentelemetry.io/otel/codes"
    "go.opentelemetry.io/otel/trace"
)

// tracer 以包为单位创建一次；instrumentation name 用模块路径
var tracer = otel.Tracer("github.com/example/order-service/order")

func ProcessOrder(ctx context.Context, orderID string) error {
    ctx, span := tracer.Start(ctx, "ProcessOrder",
        trace.WithSpanKind(trace.SpanKindInternal),
        trace.WithAttributes(attribute.String("order.id", orderID)),
    )
    defer span.End()

    span.AddEvent("order.validating")
    if err := validateOrder(ctx, orderID); err != nil {
        span.RecordError(err)
        span.SetStatus(codes.Error, "validation failed")
        return err
    }

    span.SetStatus(codes.Ok, "")
    return nil
}

func validateOrder(ctx context.Context, orderID string) error {
    _, span := tracer.Start(ctx, "ValidateOrder") // 自动成为 ProcessOrder 的子 span
    defer span.End()

    if orderID == "" {
        return errors.New("empty order id")
    }
    return nil
}
```

### Span 属性规范（semconv）

```go
package otelx

import (
    semconv "go.opentelemetry.io/otel/semconv/v1.37.0"
    "go.opentelemetry.io/otel/trace"
)

func setHTTPAttrs(span trace.Span) {
    span.SetAttributes(
        semconv.HTTPRequestMethodGet,
        semconv.HTTPResponseStatusCode(200),
        semconv.URLFull("https://api.example.com/users/42"),
        semconv.HTTPRoute("/users/{id}"),
    )
}

func setDBAttrs(span trace.Span) {
    span.SetAttributes(
        semconv.DBSystemNameMongoDB,
        semconv.DBNamespace("users"),
        semconv.DBOperationName("find"),
        semconv.DBCollectionName("profiles"),
    )
}

func setMessagingAttrs(span trace.Span) {
    span.SetAttributes(
        semconv.MessagingSystemKafka,
        semconv.MessagingDestinationName("orders"),
        semconv.MessagingOperationTypeSend,
    )
}
```

### 错误记录

```go
package otelx

import (
    "context"
    "errors"
    "fmt"

    "go.opentelemetry.io/otel/attribute"
    "go.opentelemetry.io/otel/codes"
    "go.opentelemetry.io/otel/trace"
)

var ErrRetryable = errors.New("retryable")

func handleRequest(ctx context.Context, do func(context.Context) error) error {
    ctx, span := tracer.Start(ctx, "handleRequest")
    defer span.End()

    if err := do(ctx); err != nil {
        span.RecordError(err, trace.WithAttributes(
            attribute.String("error.type", fmt.Sprintf("%T", err)),
            attribute.Bool("error.retryable", errors.Is(err, ErrRetryable)),
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
package otelx

import (
    "go.opentelemetry.io/otel"
    "go.opentelemetry.io/otel/metric"
)

var meter = otel.Meter("github.com/example/order-service/order")

type OrderMetrics struct {
    Total    metric.Int64Counter
    Duration metric.Float64Histogram
    Active   metric.Int64UpDownCounter
    Value    metric.Float64Gauge
}

func NewOrderMetrics() (*OrderMetrics, error) {
    total, err := meter.Int64Counter("orders.total",
        metric.WithDescription("Total number of orders processed"),
        metric.WithUnit("{order}"),
    )
    if err != nil {
        return nil, err
    }

    duration, err := meter.Float64Histogram("orders.duration",
        metric.WithDescription("Order processing duration"),
        metric.WithUnit("s"),
        metric.WithExplicitBucketBoundaries(0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5),
    )
    if err != nil {
        return nil, err
    }

    active, err := meter.Int64UpDownCounter("orders.active",
        metric.WithDescription("Orders currently being processed"),
        metric.WithUnit("{order}"),
    )
    if err != nil {
        return nil, err
    }

    value, err := meter.Float64Gauge("orders.last_value",
        metric.WithDescription("Value of the most recent order"),
        metric.WithUnit("USD"),
    )
    if err != nil {
        return nil, err
    }

    return &OrderMetrics{Total: total, Duration: duration, Active: active, Value: value}, nil
}
```

### 记录指标

```go
package otelx

import (
    "context"
    "time"

    "go.opentelemetry.io/otel/attribute"
    "go.opentelemetry.io/otel/metric"
)

type Order struct {
    ID    string
    Type  string
    Value float64
}

func (m *OrderMetrics) Observe(ctx context.Context, order *Order, do func(context.Context) error) error {
    // 属性集合预先构造，避免每次分配；低基数（order.type 有限个取值）
    attrs := metric.WithAttributeSet(attribute.NewSet(attribute.String("order.type", order.Type)))

    m.Active.Add(ctx, 1, attrs)
    defer m.Active.Add(ctx, -1, attrs)

    start := time.Now()
    err := do(ctx)

    // ctx 可能已取消，用 WithoutCancel 保证指标仍被记录
    mctx := context.WithoutCancel(ctx)
    status := "ok"
    if err != nil {
        status = "error"
    }
    resultAttrs := metric.WithAttributes(
        attribute.String("order.type", order.Type),
        attribute.String("status", status),
    )
    m.Duration.Record(mctx, time.Since(start).Seconds(), resultAttrs)
    m.Total.Add(mctx, 1, resultAttrs)
    m.Value.Record(mctx, order.Value, attrs)

    return err
}
```

### 异步指标（回调）

```go
package otelx

import (
    "context"

    "go.opentelemetry.io/otel/metric"
)

type Cache interface {
    Size() int64
    Hits() int64
}

// RegisterCacheMetrics 用回调在每次采集时读取当前值，适合 gauge 与单调递增的累计值。
func RegisterCacheMetrics(cache Cache) (metric.Registration, error) {
    size, err := meter.Int64ObservableGauge("cache.size",
        metric.WithDescription("Current cache size"),
        metric.WithUnit("{item}"),
    )
    if err != nil {
        return nil, err
    }
    hits, err := meter.Int64ObservableCounter("cache.hits",
        metric.WithDescription("Total cache hits"),
        metric.WithUnit("{hit}"),
    )
    if err != nil {
        return nil, err
    }

    // 一个回调同时观测多个仪表，减少采集开销
    return meter.RegisterCallback(func(_ context.Context, o metric.Observer) error {
        o.ObserveInt64(size, cache.Size())
        o.ObserveInt64(hits, cache.Hits())
        return nil
    }, size, hits)
}
```

---

## 4. 操作观测辅助（Span + 指标一体）

一个函数同时开 span 并记录 `operation.total` / `operation.duration`，业务代码只需 `defer end(err)`。

```go
package otelx

import (
    "context"
    "sync"
    "time"

    "go.opentelemetry.io/otel"
    "go.opentelemetry.io/otel/attribute"
    "go.opentelemetry.io/otel/codes"
    "go.opentelemetry.io/otel/metric"
    "go.opentelemetry.io/otel/trace"
)

// Instrument 绑定一个组件的 tracer 与两个标准仪表。
type Instrument struct {
    component string
    tracer    trace.Tracer
    total     metric.Int64Counter
    duration  metric.Float64Histogram
}

func NewInstrument(component string) (*Instrument, error) {
    m := otel.Meter(component)
    total, err := m.Int64Counter("operation.total",
        metric.WithDescription("Number of operations by component/operation/status"),
        metric.WithUnit("{operation}"))
    if err != nil {
        return nil, err
    }
    duration, err := m.Float64Histogram("operation.duration",
        metric.WithDescription("Operation duration"),
        metric.WithUnit("s"))
    if err != nil {
        return nil, err
    }
    return &Instrument{
        component: component,
        tracer:    otel.Tracer(component),
        total:     total,
        duration:  duration,
    }, nil
}

// Start 开始一次操作观测；返回的 end 幂等，多次调用只记录一次。
func (in *Instrument) Start(ctx context.Context, operation string, kind trace.SpanKind, attrs ...attribute.KeyValue) (context.Context, func(err error)) {
    ctx, span := in.tracer.Start(ctx, operation,
        trace.WithSpanKind(kind),
        trace.WithAttributes(attrs...),
    )
    start := time.Now()

    var once sync.Once
    end := func(err error) {
        once.Do(func() {
            status := "ok"
            if err != nil {
                status = "error"
                span.RecordError(err)
                span.SetStatus(codes.Error, err.Error())
            } else {
                span.SetStatus(codes.Ok, "")
            }
            span.End()

            mctx := context.WithoutCancel(ctx)
            set := metric.WithAttributeSet(attribute.NewSet(
                attribute.String("component", in.component),
                attribute.String("operation", operation),
                attribute.String("status", status),
            ))
            in.total.Add(mctx, 1, set)
            in.duration.Record(mctx, time.Since(start).Seconds(), set)
        })
    }
    return ctx, end
}

// 使用示例
func (in *Instrument) exampleCreateOrder(ctx context.Context, orderID string) (err error) {
    ctx, end := in.Start(ctx, "CreateOrder", trace.SpanKindServer, attribute.String("order.id", orderID))
    defer func() { end(err) }()

    return ProcessOrder(ctx, orderID)
}
```

测试或禁用观测时无需 NoOp 实现：不调用 `otel.SetTracerProvider` / `SetMeterProvider`，
全局默认即为 no-op provider。

---

## 5. 日志关联

### slog + OTel Bridge（日志导出到 OTLP）

```go
package otelx

import (
    "log/slog"

    "go.opentelemetry.io/contrib/bridges/otelslog"
    "go.opentelemetry.io/otel/log/global"
)

// NewLogger 返回把记录发往 OTel LoggerProvider 的 slog.Logger。
// otelslog 会自动从 ctx 中的 span 提取 trace_id / span_id 写入 LogRecord。
func NewLogger(name string) *slog.Logger {
    handler := otelslog.NewHandler(name,
        otelslog.WithLoggerProvider(global.GetLoggerProvider()),
        otelslog.WithSource(true),
    )
    return slog.New(handler)
}
```

### 双路输出：stdout JSON + OTLP

```go
package otelx

import (
    "context"
    "errors"
    "log/slog"
    "os"

    "go.opentelemetry.io/contrib/bridges/otelslog"
)

// multiHandler 同时写多个 handler，任一失败不影响其他。
type multiHandler []slog.Handler

func (m multiHandler) Enabled(ctx context.Context, l slog.Level) bool {
    for _, h := range m {
        if h.Enabled(ctx, l) {
            return true
        }
    }
    return false
}

func (m multiHandler) Handle(ctx context.Context, r slog.Record) error {
    var errs error
    for _, h := range m {
        if h.Enabled(ctx, r.Level) {
            errs = errors.Join(errs, h.Handle(ctx, r.Clone()))
        }
    }
    return errs
}

func (m multiHandler) WithAttrs(attrs []slog.Attr) slog.Handler {
    out := make(multiHandler, len(m))
    for i, h := range m {
        out[i] = h.WithAttrs(attrs)
    }
    return out
}

func (m multiHandler) WithGroup(name string) slog.Handler {
    out := make(multiHandler, len(m))
    for i, h := range m {
        out[i] = h.WithGroup(name)
    }
    return out
}

func NewDualLogger(name string, level slog.Leveler) *slog.Logger {
    stdout := NewTraceHandler(slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{Level: level}))
    otlp := otelslog.NewHandler(name)
    return slog.New(multiHandler{stdout, otlp})
}
```

### 本地日志注入 trace_id / span_id

stdout / 文件日志不经过 otelslog，需要自行从 context 补充字段：

```go
package otelx

import (
    "context"
    "log/slog"

    "go.opentelemetry.io/otel/trace"
)

// TraceHandler 包装任意 slog.Handler，在每条记录中追加 trace_id、span_id、trace_flags。
type TraceHandler struct {
    slog.Handler
}

func NewTraceHandler(base slog.Handler) *TraceHandler {
    return &TraceHandler{Handler: base}
}

func (h *TraceHandler) Handle(ctx context.Context, r slog.Record) error {
    if sc := trace.SpanContextFromContext(ctx); sc.IsValid() {
        r = r.Clone()
        r.AddAttrs(
            slog.String("trace_id", sc.TraceID().String()),
            slog.String("span_id", sc.SpanID().String()),
            slog.String("trace_flags", sc.TraceFlags().String()),
        )
    }
    return h.Handler.Handle(ctx, r)
}

func (h *TraceHandler) WithAttrs(attrs []slog.Attr) slog.Handler {
    return &TraceHandler{Handler: h.Handler.WithAttrs(attrs)}
}

func (h *TraceHandler) WithGroup(name string) slog.Handler {
    return &TraceHandler{Handler: h.Handler.WithGroup(name)}
}

// 使用：始终传 ctx，否则拿不到 span
func logExample(ctx context.Context, logger *slog.Logger, orderID string) {
    logger.InfoContext(ctx, "processing order", slog.String("order_id", orderID))
}
```

### 运行时动态调整级别

```go
package otelx

import (
    "log/slog"
    "os"
)

// LevelVar 允许运行时通过信号 / 管理接口调级
var LevelVar = new(slog.LevelVar) // 默认 Info

func NewLeveledLogger() *slog.Logger {
    return slog.New(NewTraceHandler(slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{
        Level:     LevelVar,
        AddSource: true,
    })))
}

func SetDebug(on bool) {
    if on {
        LevelVar.Set(slog.LevelDebug)
    } else {
        LevelVar.Set(slog.LevelInfo)
    }
}
```

---

## 6. 上下文传播

### HTTP 客户端

```go
package otelx

import (
    "context"
    "net/http"

    "go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp"
)

// NewHTTPClient 自动注入 traceparent / baggage 并创建 client span。
func NewHTTPClient() *http.Client {
    return &http.Client{
        Transport: otelhttp.NewTransport(http.DefaultTransport),
    }
}

func callDownstream(ctx context.Context, client *http.Client, url string) (*http.Response, error) {
    req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil) // ctx 携带当前 span
    if err != nil {
        return nil, err
    }
    return client.Do(req)
}
```

### HTTP 服务端

```go
package otelx

import (
    "net/http"

    "go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp"
)

// NewHTTPHandler 自动提取 traceparent 并创建 server span。
// 用 http.ServeMux 的方法+路径模式作为 span 名，避免高基数 URL。
func NewHTTPHandler(mux *http.ServeMux) http.Handler {
    return otelhttp.NewHandler(mux, "http.server",
        otelhttp.WithSpanNameFormatter(func(operation string, r *http.Request) string {
            if r.Pattern != "" { // Go 1.22+ ServeMux 匹配到的模式
                return r.Pattern
            }
            return operation
        }),
        otelhttp.WithFilter(func(r *http.Request) bool {
            return r.URL.Path != "/healthz" && r.URL.Path != "/readyz"
        }),
    )
}
```

### gRPC 客户端 / 服务端

```go
package otelx

import (
    "go.opentelemetry.io/contrib/instrumentation/google.golang.org/grpc/otelgrpc"
    "google.golang.org/grpc"
    "google.golang.org/grpc/credentials/insecure"
    "google.golang.org/grpc/health/grpc_health_v1"
    "google.golang.org/grpc/stats"
)

// otelgrpc 拦截器已废弃，统一使用 stats handler。
func NewGRPCClient(target string) (*grpc.ClientConn, error) {
    return grpc.NewClient(target,
        grpc.WithTransportCredentials(insecure.NewCredentials()),
        grpc.WithStatsHandler(otelgrpc.NewClientHandler()),
    )
}

func NewGRPCServer() *grpc.Server {
    return grpc.NewServer(
        grpc.StatsHandler(otelgrpc.NewServerHandler(
            otelgrpc.WithFilter(func(info *stats.RPCTagInfo) bool {
                return info.FullMethodName != grpc_health_v1.Health_Check_FullMethodName
            }),
        )),
    )
}
```

### 手动传播

```go
package otelx

import (
    "context"
    "net/http"

    "go.opentelemetry.io/otel"
    "go.opentelemetry.io/otel/propagation"
)

func InjectToRequest(ctx context.Context, req *http.Request) {
    otel.GetTextMapPropagator().Inject(ctx, propagation.HeaderCarrier(req.Header))
}

func ExtractFromRequest(ctx context.Context, req *http.Request) context.Context {
    return otel.GetTextMapPropagator().Extract(ctx, propagation.HeaderCarrier(req.Header))
}

// 消息队列 headers / properties 用 MapCarrier
func InjectToMap(ctx context.Context, m map[string]string) {
    otel.GetTextMapPropagator().Inject(ctx, propagation.MapCarrier(m))
}

func ExtractFromMap(ctx context.Context, m map[string]string) context.Context {
    return otel.GetTextMapPropagator().Extract(ctx, propagation.MapCarrier(m))
}
```

### 跨 goroutine / 异步任务

```go
package otelx

import (
    "context"

    "go.opentelemetry.io/otel/trace"
)

// 异步任务用 Link 关联而非父子关系：请求 span 不必等待任务完成。
func enqueueAsync(ctx context.Context, run func(context.Context)) {
    link := trace.LinkFromContext(ctx)
    go func() {
        bg := context.WithoutCancel(ctx) // 保留 baggage 等值，脱离请求取消
        bg, span := tracer.Start(bg, "AsyncTask",
            trace.WithNewRoot(),
            trace.WithLinks(link),
            trace.WithSpanKind(trace.SpanKindConsumer),
        )
        defer span.End()
        run(bg)
    }()
}
```

---

## 7. 采样策略

### 内置采样器

```go
package otelx

import (
    sdktrace "go.opentelemetry.io/otel/sdk/trace"
)

func builtinSamplers(ratio float64) []sdktrace.Sampler {
    return []sdktrace.Sampler{
        sdktrace.AlwaysSample(),
        sdktrace.NeverSample(),
        // TraceIDRatioBased 按 trace ID 哈希决定，同一 trace 在所有服务上决策一致
        sdktrace.TraceIDRatioBased(ratio),
        // 推荐：尊重上游决策，根 span 按比例采样
        sdktrace.ParentBased(sdktrace.TraceIDRatioBased(ratio),
            sdktrace.WithRemoteParentSampled(sdktrace.AlwaysSample()),
            sdktrace.WithRemoteParentNotSampled(sdktrace.NeverSample()),
            sdktrace.WithLocalParentSampled(sdktrace.AlwaysSample()),
            sdktrace.WithLocalParentNotSampled(sdktrace.NeverSample()),
        ),
    }
}
```

### 自定义采样器：错误 / 慢请求全采

```go
package otelx

import (
    "go.opentelemetry.io/otel/attribute"
    sdktrace "go.opentelemetry.io/otel/sdk/trace"
)

// AttributeSampler 当 span 起始属性命中 match 时强制采样，否则交给 base。
// 只能依据 Start 时已知的属性（如 http.route、rpc.method）；错误在 span 结束才知道，
// 尾采样需在 Collector 侧用 tailsampling processor。
type AttributeSampler struct {
    base  sdktrace.Sampler
    match func(attrs []attribute.KeyValue) bool
}

func NewAttributeSampler(base sdktrace.Sampler, match func([]attribute.KeyValue) bool) *AttributeSampler {
    return &AttributeSampler{base: base, match: match}
}

func (s *AttributeSampler) ShouldSample(p sdktrace.SamplingParameters) sdktrace.SamplingResult {
    if s.match(p.Attributes) {
        return sdktrace.SamplingResult{
            Decision:   sdktrace.RecordAndSample,
            Tracestate: trace_state(p),
        }
    }
    return s.base.ShouldSample(p)
}

func (s *AttributeSampler) Description() string { return "AttributeSampler{" + s.base.Description() + "}" }
```

```go
package otelx

import (
    sdktrace "go.opentelemetry.io/otel/sdk/trace"
    "go.opentelemetry.io/otel/trace"
)

func trace_state(p sdktrace.SamplingParameters) trace.TraceState {
    return trace.SpanContextFromContext(p.ParentContext).TraceState()
}
```

### 组合采样器（AND / OR）

```go
package otelx

import (
    "strings"

    sdktrace "go.opentelemetry.io/otel/sdk/trace"
)

type compositeSampler struct {
    samplers []sdktrace.Sampler
    all      bool // true=AND，false=OR
}

// AllOf 全部采样器同意才采样；AnyOf 任一同意即采样。
func AllOf(samplers ...sdktrace.Sampler) sdktrace.Sampler { return &compositeSampler{samplers, true} }
func AnyOf(samplers ...sdktrace.Sampler) sdktrace.Sampler { return &compositeSampler{samplers, false} }

func (c *compositeSampler) ShouldSample(p sdktrace.SamplingParameters) sdktrace.SamplingResult {
    result := sdktrace.SamplingResult{Decision: sdktrace.Drop, Tracestate: trace_state(p)}
    for _, s := range c.samplers {
        r := s.ShouldSample(p)
        sampled := r.Decision == sdktrace.RecordAndSample
        if c.all && !sampled {
            return sdktrace.SamplingResult{Decision: sdktrace.Drop, Tracestate: r.Tracestate}
        }
        if !c.all && sampled {
            return r
        }
        result = r
    }
    if c.all {
        return result
    }
    return sdktrace.SamplingResult{Decision: sdktrace.Drop, Tracestate: result.Tracestate}
}

func (c *compositeSampler) Description() string {
    names := make([]string, len(c.samplers))
    for i, s := range c.samplers {
        names[i] = s.Description()
    }
    op := "AnyOf"
    if c.all {
        op = "AllOf"
    }
    return op + "(" + strings.Join(names, ",") + ")"
}
```

### 按 Key 一致采样

`TraceIDRatioBased` 已按 trace ID 做确定性哈希；需要按其他 key（如 tenant_id）一致采样时，
把 key 放进 Baggage，在采样器里读取并哈希：

```go
package otelx

import (
    "hash/fnv"

    "go.opentelemetry.io/otel/baggage"
    sdktrace "go.opentelemetry.io/otel/sdk/trace"
)

type baggageKeySampler struct {
    key       string
    threshold uint64
    fallback  sdktrace.Sampler
}

// NewBaggageKeySampler 对 baggage 中 key 的值做 FNV 哈希，按 ratio 决定；缺失时用 fallback。
func NewBaggageKeySampler(key string, ratio float64, fallback sdktrace.Sampler) sdktrace.Sampler {
    return &baggageKeySampler{key: key, threshold: uint64(ratio * float64(^uint64(0))), fallback: fallback}
}

func (s *baggageKeySampler) ShouldSample(p sdktrace.SamplingParameters) sdktrace.SamplingResult {
    val := baggage.FromContext(p.ParentContext).Member(s.key).Value()
    if val == "" {
        return s.fallback.ShouldSample(p)
    }
    h := fnv.New64a()
    _, _ = h.Write([]byte(val))
    decision := sdktrace.Drop
    if h.Sum64() <= s.threshold {
        decision = sdktrace.RecordAndSample
    }
    return sdktrace.SamplingResult{Decision: decision, Tracestate: trace_state(p)}
}

func (s *baggageKeySampler) Description() string { return "BaggageKeySampler{" + s.key + "}" }
```

---

## 8. 健康检查过滤

```go
package otelx

import (
    "net/http"

    "go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp"
    "go.opentelemetry.io/otel/attribute"
    sdktrace "go.opentelemetry.io/otel/sdk/trace"
    semconv "go.opentelemetry.io/otel/semconv/v1.37.0"
)

var ignoredRoutes = map[string]bool{"/healthz": true, "/readyz": true, "/metrics": true}

// 方式一：instrumentation 层过滤（不创建 span，也不记指标）
func healthFilter(r *http.Request) bool {
    return !ignoredRoutes[r.URL.Path]
}

func newFilteredHandler(h http.Handler) http.Handler {
    return otelhttp.NewHandler(h, "http.server", otelhttp.WithFilter(healthFilter))
}

// 方式二：采样器层过滤（span 仍创建但不导出）
func newRouteFilterSampler(base sdktrace.Sampler) sdktrace.Sampler {
    return sdktrace.ParentBased(AllOf(
        NewAttributeSampler(sdktrace.AlwaysSample(), func(attrs []attribute.KeyValue) bool {
            for _, a := range attrs {
                if a.Key == semconv.HTTPRouteKey || a.Key == semconv.URLPathKey {
                    return !ignoredRoutes[a.Value.AsString()]
                }
            }
            return true
        }),
        base,
    ))
}
```

---

## 9. Baggage 传递业务数据

Baggage 随 traceparent 一起跨进程传播，适合 tenant_id、user_tier 这类低基数、非敏感值。
不要放敏感数据：Baggage 以明文 header 传递。

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

Baggage 不会自动成为 span 属性；需要按 tenant 检索 trace 时，在 span 起始处显式
`span.SetAttributes(attribute.String("tenant.id", TenantIDFromBaggage(ctx)))`，
或在 Collector 侧用 `baggage` 相关 processor 复制。
