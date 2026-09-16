---
name: otel-go
description: "Go OpenTelemetry 可观测性专家 - 分布式追踪、指标收集、日志关联、上下文传播、采样策略、Baggage 传递。适用：微服务链路追踪、APM 监控、多信号（traces/metrics/logs）统一采集、vendor-neutral 遥测方案、gRPC/HTTP 自动 instrumentation。不适用：单体应用仅需简单日志排障、性能极敏感热路径（SDK 有微量开销）、已深度绑定特定 APM 厂商 SDK 且无迁移计划。触发词：opentelemetry, otel, tracing, span, metric, 可观测性, 链路追踪, 指标, 采样, propagation, baggage, jaeger, tempo, otlp"
user-invocable: true
allowed-tools: Bash, Read, Write, Edit, Grep, Glob
---

# Go OpenTelemetry 专家

使用 Go OpenTelemetry SDK 开发可观测性功能：$ARGUMENTS

---

## 1. Observer 抽象模式

XKit 使用 `xmetrics.Observer` 统一观测接口，底层可切换 OTel 或 NoOp 实现。

### 核心接口

```go
// Observer - 统一观测接口
type Observer interface {
    Start(ctx context.Context, opts SpanOptions) (context.Context, Span)
}

// Span - 观测区间
type Span interface {
    End(result Result)
}

// SpanOptions - 观测配置
type SpanOptions struct {
    Component string   // 组件名 (如 "user-service")
    Operation string   // 操作名 (如 "GetUser")
    Kind      Kind     // Internal/Server/Client/Producer/Consumer
    Attrs     []Attr   // 自定义属性
}

// Result - 操作结果
type Result struct {
    Status Status  // StatusOK 或 StatusError（未设置时从 Err 推导）
    Err    error
    Attrs  []Attr  // 结果属性
}
```

### 使用示例

```go
ctx, span := observer.Start(ctx, xmetrics.SpanOptions{
    Component: "order-service",
    Operation: "CreateOrder",
    Kind:      xmetrics.KindServer,
    Attrs: []xmetrics.Attr{xmetrics.String("order.id", orderID)},
})
defer span.End(xmetrics.Result{Err: err})
```

### NoOp 实现（用于测试或禁用观测）

```go
type NoopObserver struct{}
func (NoopObserver) Start(ctx context.Context, _ SpanOptions) (context.Context, Span) {
    return ctx, NoopSpan{}
}

// 安全的 nil 检查辅助函数
func Start(ctx context.Context, observer Observer, opts SpanOptions) (context.Context, Span) {
    if observer == nil { return ctx, NoopSpan{} }
    return observer.Start(ctx, opts)
}
```

---

## 2. OTel Observer 实现

### 初始化

```go
// 默认使用全局 OTel Provider
observer, err := xmetrics.NewOTelObserver()

// 自定义 Provider
observer, err := xmetrics.NewOTelObserver(
    xmetrics.WithInstrumentationName("my-service"),
    xmetrics.WithTracerProvider(tp),
    xmetrics.WithMeterProvider(mp),
)
```

### 自动记录的标准指标

| 指标名 | 类型 | 说明 |
|--------|------|------|
| `xkit.operation.total` | Counter | 操作总数（按 component/operation/status 分组） |
| `xkit.operation.duration` | Histogram | 操作耗时（秒） |

### Span 结束时自动行为

```go
func (s *otelSpan) End(result Result) {
    s.endOnce.Do(func() {  // 幂等 - 多次调用只记录一次
        if result.Err != nil {
            s.span.RecordError(result.Err)
            s.span.SetStatus(codes.Error, result.Err.Error())
        }
        // 使用 context.WithoutCancel 确保超时/取消场景下指标也能记录
        metricsCtx := context.WithoutCancel(s.ctx)
        s.observer.total.Add(metricsCtx, 1, ...)
        s.observer.duration.Record(metricsCtx, elapsed, ...)
    })
}
```

### 双向同步（OTel Span ↔ xctx）

```go
// OTel span 创建后，自动同步到 xctx
func syncXctx(ctx context.Context, sc trace.SpanContext) context.Context {
    ctx, _ = xctx.WithTraceID(ctx, sc.TraceID().String())
    ctx, _ = xctx.WithSpanID(ctx, sc.SpanID().String())
    ctx, _ = xctx.WithTraceFlags(ctx, fmt.Sprintf("%02x", sc.TraceFlags()))
    return ctx
}
```

> 完整 OTel Observer 实现见 [references/examples.md](references/examples.md#1-sdk-初始化)

---

## 3. OTel SDK 初始化

### 完整初始化模板

```go
func InitOTel(ctx context.Context, cfg OTelConfig) (shutdown func(context.Context) error, err error) {
    res, err := resource.New(ctx,
        resource.WithAttributes(
            semconv.ServiceNameKey.String(cfg.ServiceName),
            semconv.ServiceVersionKey.String(cfg.Version),
            attribute.String("environment", cfg.Environment),
        ),
    )
    // 创建 TracerProvider + MeterProvider + LoggerProvider
    // 设置 Propagator（TraceContext + Baggage）
    // 返回统一 shutdown 函数
}
```

### Provider 创建

```go
func newTracerProvider(ctx context.Context, res *resource.Resource, endpoint string) (*trace.TracerProvider, error)
func newMeterProvider(ctx context.Context, res *resource.Resource, endpoint string) (*metric.MeterProvider, error)
func newLoggerProvider(ctx context.Context, res *resource.Resource, endpoint string) (*log.LoggerProvider, error)
```

---

## 4. 分布式追踪

### 直接使用 OTel API 创建 Span

```go
tracer := otel.Tracer("order-service")
ctx, span := tracer.Start(ctx, "ProcessOrder",
    trace.WithAttributes(attribute.String("order.id", orderID)),
    trace.WithSpanKind(trace.SpanKindInternal),
)
defer span.End()
```

- `span.AddEvent()` 添加事件
- `span.RecordError()` 记录错误
- `span.SetStatus(codes.Error, msg)` 设置状态

### Span 属性规范（semconv）

- **HTTP**: `HTTPRequestMethodKey`, `HTTPResponseStatusCode`, `URLFull`, `HTTPRoute`
- **DB**: `DBSystemKey`, `DBNamespace`, `DBOperationName`
- **消息队列**: `MessagingSystem`, `MessagingDestinationName`

> 完整追踪示例见 [references/examples.md](references/examples.md#2-分布式追踪)

---

## 5. 指标收集

### 指标类型

| 类型 | 函数 | 用途 |
|------|------|------|
| Counter | `meter.Int64Counter()` | 只增计数（请求总数） |
| Histogram | `meter.Float64Histogram()` | 分布（延迟） |
| UpDownCounter | `meter.Int64UpDownCounter()` | 可增减（活跃连接） |
| ObservableGauge | `meter.Int64ObservableGauge()` | 异步当前值（缓存大小） |

> 完整指标实现见 [references/examples.md](references/examples.md#3-指标收集)

---

## 6. 日志关联（xlog + EnrichHandler）

### xlog Builder 模式

```go
logger, cleanup, err := xlog.New().
    SetOutput(os.Stdout).
    SetLevel(xlog.LevelInfo).
    SetFormat("json").           // "text" 或 "json"
    SetAddSource(true).          // 包含源码位置
    SetEnrich(true).             // 自动注入 trace/identity 信息
    Build()
defer cleanup()
```

### EnrichHandler 自动注入

当 `SetEnrich(true)` 时，日志自动从 context 注入：

```go
// EnrichHandler 在每条日志中自动添加：
// trace_id, span_id, request_id, trace_flags  (来自 xctx.AppendTraceAttrs)
// platform_id, tenant_id, tenant_name         (来自 xctx.AppendIdentityAttrs)

logger.Info(ctx, "processing order", slog.String("order_id", orderID))
// 输出: {"msg":"processing order","order_id":"123","trace_id":"abc","tenant_id":"t1",...}
```

### EnrichHandler 实现原理

```go
func (h *EnrichHandler) Handle(ctx context.Context, r slog.Record) error {
    var buf [6]slog.Attr  // 栈分配，零 GC 开销
    attrs := buf[:0]
    attrs = xctx.AppendTraceAttrs(attrs, ctx)     // 只追加非空字段
    attrs = xctx.AppendIdentityAttrs(attrs, ctx)
    if len(attrs) > 0 {
        r = r.Clone()
        r.AddAttrs(attrs...)
    }
    return h.base.Handle(ctx, r)
}
```

### Logger 接口

```go
type Logger interface {
    Debug(ctx context.Context, msg string, attrs ...slog.Attr)
    Info(ctx context.Context, msg string, attrs ...slog.Attr)
    Warn(ctx context.Context, msg string, attrs ...slog.Attr)
    Error(ctx context.Context, msg string, attrs ...slog.Attr)
    Stack(ctx context.Context, msg string, attrs ...slog.Attr)  // 含完整堆栈
    With(attrs ...slog.Attr) Logger
    WithGroup(name string) Logger
}

type Leveler interface {
    SetLevel(level Level)  // 运行时动态调整日志级别
    GetLevel() Level
}
```

---

## 7. 上下文传播

### 自动 Instrumentation

| 组件 | 包 | 用法 |
|------|-----|------|
| HTTP 客户端 | `otelhttp.NewTransport()` | 自动注入 trace headers |
| HTTP 服务端 | `otelhttp.NewHandler()` | 自动提取 trace headers |
| gRPC 客户端 | `otelgrpc.NewClientHandler()` | `grpc.WithStatsHandler()` |
| gRPC 服务端 | `otelgrpc.NewServerHandler()` | `grpc.StatsHandler()` |

### XKit Trace 传播（xtrace）

```go
// HTTP 中间件自动提取
xtrace.HTTPMiddleware()  // 提取 X-Trace-ID, traceparent 等

// gRPC 拦截器自动提取
xtrace.GRPCUnaryServerInterceptor()  // 提取 metadata 中的 trace 信息

// 支持 W3C Trace Context: 00-{trace-id}-{parent-id}-{trace-flags}
```

### 手动传播

```go
otel.GetTextMapPropagator().Inject(ctx, propagation.HeaderCarrier(req.Header))
otel.GetTextMapPropagator().Extract(ctx, propagation.HeaderCarrier(req.Header))
```

---

## 8. 采样策略（xsampling）

### 内置采样器

```go
// 基础
xsampling.Always()                      // 全部采样
xsampling.Never()                       // 不采样
xsampling.NewRateSampler(0.1)          // 10% 比例采样
xsampling.NewCountSampler(100)         // 每 100 个采样一个
xsampling.NewProbabilitySampler(0.5)   // 50% 概率采样
```

### KeyBasedSampler（跨进程一致采样）

```go
// 相同 trace_id 在所有服务中做出相同采样决策
sampler := xsampling.NewKeyBasedSampler(0.1, func(ctx context.Context) string {
    return xctx.TraceID(ctx)  // 使用 xxhash 确定性哈希
})
```

### CompositeSampler（组合采样器）

```go
// AND：所有条件都满足
sampler := xsampling.All(
    xsampling.NewRateSampler(0.1),
    xsampling.NewKeyBasedSampler(0.5, keyFunc),
)

// OR：任一条件满足
sampler := xsampling.Any(
    xsampling.NewRateSampler(0.01),
    debugModeSampler,
)
```

### OTel 内置采样器

```go
trace.AlwaysSample()
trace.NeverSample()
trace.TraceIDRatioBased(0.1)
trace.ParentBased(trace.TraceIDRatioBased(0.1))  // 推荐
```

---

## 9. Baggage 传递业务数据

```go
member, _ := baggage.NewMember("tenant_id", tenantID)
bag, _ := baggage.New(member)
ctx = baggage.ContextWithBaggage(ctx, bag)

// 读取
bag := baggage.FromContext(ctx)
tenantID := bag.Member("tenant_id").Value()
```

---

## 10. 属性辅助函数

```go
// xmetrics 类型安全属性构造
xmetrics.String(key, value string) Attr
xmetrics.Int(key string, value int) Attr
xmetrics.Int64(key string, value int64) Attr
xmetrics.Float64(key string, value float64) Attr
xmetrics.Bool(key string, value bool) Attr
xmetrics.Duration(key string, value time.Duration) Attr
xmetrics.Any(key string, value any) Attr
```

---

## 最佳实践

### 初始化
- 在 main() 开头初始化 OTel SDK
- 使用 `defer shutdown(ctx)` 确保数据导出
- 统一配置 Resource 属性（service.name, environment）

### Observer 模式
- 业务代码使用 `xmetrics.Observer` 而非直接 OTel API
- 测试时传入 `NoopObserver` 禁用观测开销
- `nil` observer 安全 — 使用 `xmetrics.Start()` 辅助函数

### 日志
- 使用 `SetEnrich(true)` 自动关联 trace
- 日志格式生产用 `json`，开发用 `text`
- 运行时可通过 `Leveler.SetLevel()` 动态调级

### 采样
- 生产环境使用 `ParentBased` 采样器
- 跨服务一致采样使用 `KeyBasedSampler`（xxhash 确定性）
- 控制 cardinality（属性值数量）

---

## 检查清单

- [ ] 配置 Resource（service.name, environment）？
- [ ] 设置合适的采样率？
- [ ] HTTP/gRPC 使用自动 instrumentation？
- [ ] 日志关联 Trace ID（EnrichHandler）？
- [ ] 健康检查端点排除追踪？
- [ ] 指标属性 cardinality 可控？
- [ ] 优雅关闭 OTel Provider？
- [ ] 业务代码使用 Observer 抽象？

---

## 参考资料

- [完整代码示例](references/examples.md) — SDK 初始化、Observer、追踪、指标、日志、传播、采样完整实现
