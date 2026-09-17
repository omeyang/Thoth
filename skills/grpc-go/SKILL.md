---
name: grpc-go
description: "Go gRPC 专家 - 服务定义(Proto)、Unary/Stream RPC、拦截器(日志/恢复/认证/租户传播/x/time/rate 限流)、otelgrpc stats handler 追踪、错误处理与错误码映射(errdetails)、元数据传播、负载均衡与服务配置、健康检查(grpc/health)、优雅关闭。适用：微服务通信、API 网关、内部服务间调用、流式数据传输。不适用：浏览器直连(用 gRPC-Web 或 REST)；简单 CRUD API(REST 更轻量)；消息队列场景(用 Kafka/Pulsar)。触发词：grpc, gRPC, protobuf, proto, 拦截器, interceptor, streaming, 流式, metadata, 元数据, service-config, otelgrpc, health check"
---

# Go gRPC 专家

使用 Go gRPC 开发高性能 RPC 服务：$ARGUMENTS

---

## 0. 版本与依赖

基线 go1.24.6。go.mod：

```text
google.golang.org/grpc v1.80.0
google.golang.org/protobuf v1.36.12
google.golang.org/genproto/googleapis/rpc（errdetails，跟随 grpc 的间接依赖）
go.opentelemetry.io/contrib/instrumentation/google.golang.org/grpc/otelgrpc v0.66.0
golang.org/x/time v0.14.0
```

代码生成插件用 go.mod `tool` 指令钉住：`protoc-gen-go v1.36.12`、`protoc-gen-go-grpc v1.6.1`。

---

## 1. 服务定义

### Proto 文件

版本化包名，请求/响应独立 message，使用 `google.protobuf` 标准类型。

```protobuf
syntax = "proto3";
package user.v1;
option go_package = "github.com/example/api/user/v1;userv1";

service UserService {
    rpc GetUser(GetUserRequest) returns (GetUserResponse);          // Unary
    rpc ListUsers(ListUsersRequest) returns (stream User);          // Server streaming
    rpc BatchCreateUsers(stream CreateUserRequest) returns (BatchCreateUsersResponse); // Client streaming
    rpc Chat(stream ChatMessage) returns (stream ChatMessage);      // Bidirectional
}
```

### 生成代码

```bash
go get -tool google.golang.org/protobuf/cmd/protoc-gen-go@v1.36.12
go get -tool google.golang.org/grpc/cmd/protoc-gen-go-grpc@v1.6.1
protoc --plugin=protoc-gen-go="$(go tool -n protoc-gen-go)" \
       --plugin=protoc-gen-go-grpc="$(go tool -n protoc-gen-go-grpc)" \
       --go_out=. --go_opt=paths=source_relative \
       --go-grpc_out=. --go-grpc_opt=paths=source_relative \
       api/user/v1/*.proto
```

> 完整 Proto 定义与 buf v2 配置见 [references/examples.md](references/examples.md#proto-文件完整定义)

---

## 2. 服务端实现

### 核心结构

```go
package userserver

import userv1 "github.com/example/api/user/v1"

type UserServer struct {
    userv1.UnimplementedUserServiceServer // 前向兼容：新增 RPC 不破坏编译
    repo UserRepository
}
```

### RPC 类型签名（protoc-gen-go-grpc v1.6 泛型流）

| RPC 类型 | 签名 |
|---------|------|
| Unary | `GetUser(ctx, *GetUserRequest) (*GetUserResponse, error)` |
| Server Stream | `ListUsers(*ListUsersRequest, grpc.ServerStreamingServer[User]) error` |
| Client Stream | `BatchCreateUsers(grpc.ClientStreamingServer[CreateUserRequest, BatchCreateUsersResponse]) error` |
| Bidi Stream | `Chat(grpc.BidiStreamingServer[ChatMessage, ChatMessage]) error` |

流结束用 `errors.Is(err, io.EOF)` 判断。

> 完整四种 RPC 实现见 [references/examples.md](references/examples.md#服务端实现)

### 启动服务（stats handler + 拦截器链）

```go
package userserver

import (
    "go.opentelemetry.io/contrib/instrumentation/google.golang.org/grpc/otelgrpc"
    "google.golang.org/grpc"
    "google.golang.org/grpc/health"
    "google.golang.org/grpc/health/grpc_health_v1"
    "google.golang.org/grpc/reflection"

    userv1 "github.com/example/api/user/v1"
)

func NewServer(repo UserRepository, limiter *KeyedLimiter, validator TokenValidator) *grpc.Server {
    server := grpc.NewServer(
        grpc.StatsHandler(otelgrpc.NewServerHandler()), // 追踪 + 指标，替代已废弃的 otelgrpc 拦截器
        grpc.ChainUnaryInterceptor(
            RecoveryInterceptor(),
            TenantServerInterceptor(true),
            RateLimitInterceptor(limiter),
            AuthInterceptor(validator),
            LoggingInterceptor(),
        ),
        grpc.ChainStreamInterceptor(
            StreamRecoveryInterceptor(),
            TenantStreamServerInterceptor(true),
            StreamLoggingInterceptor(),
        ),
    )
    userv1.RegisterUserServiceServer(server, NewUserServer(repo))

    hs := health.NewServer()
    grpc_health_v1.RegisterHealthServer(server, hs)
    hs.SetServingStatus(userv1.UserService_ServiceDesc.ServiceName, grpc_health_v1.HealthCheckResponse_SERVING)

    reflection.Register(server) // 调试用
    return server
}
```

---

## 3. 客户端实现

```go
package userserver

import (
    "go.opentelemetry.io/contrib/instrumentation/google.golang.org/grpc/otelgrpc"
    "google.golang.org/grpc"
    "google.golang.org/grpc/credentials/insecure"

    userv1 "github.com/example/api/user/v1"
)

func NewUserClient(target string) (userv1.UserServiceClient, func() error, error) {
    conn, err := grpc.NewClient(target, // "dns:///user.svc:50051" 启用客户端负载均衡
        grpc.WithTransportCredentials(insecure.NewCredentials()),
        grpc.WithStatsHandler(otelgrpc.NewClientHandler()), // 自动注入 traceparent
        grpc.WithChainUnaryInterceptor(TenantClientInterceptor(), ClientLoggingInterceptor()),
        grpc.WithChainStreamInterceptor(TenantStreamClientInterceptor()),
        grpc.WithDefaultServiceConfig(serviceConfig),
    )
    if err != nil {
        return nil, nil, err
    }
    return userv1.NewUserServiceClient(conn), conn.Close, nil
}
```

`grpc.NewClient` 惰性建连，首个 RPC 触发连接；`grpc.Dial` 已废弃。

> 完整客户端与调用示例见 [references/examples.md](references/examples.md#客户端实现)

---

## 4. 拦截器

### 拦截器清单

| 拦截器 | 功能 | 实现要点 |
|--------|------|----------|
| Recovery | panic → `codes.Internal` | `defer recover()`，记录 `debug.Stack()` |
| Tenant（服务端） | `x-tenant-id` → context | 缺失时 `codes.InvalidArgument`；健康检查等公开方法跳过 |
| Tenant（客户端） | context → outgoing metadata | `md.Copy()` + `md.Set()` 覆盖语义 |
| RateLimit | 按 `tenant|method` 令牌桶 | `x/time/rate`，拒绝返回 `ResourceExhausted` + `RetryInfo` |
| Auth | `authorization: Bearer <token>` | 校验后把 claims 放入 context |
| Logging | 方法、状态码、耗时 | `slog.InfoContext` |
| 追踪/指标 | 不用拦截器 | `otelgrpc.NewServerHandler()` / `NewClientHandler()` |

所有拦截器同时提供 Unary 与 Stream 版本；Stream 版本用 `wrappedServerStream` 覆盖 `Context()`。

### 自定义拦截器骨架

```go
package userserver

import (
    "context"
    "log/slog"
    "runtime/debug"
    "time"

    "google.golang.org/grpc"
    "google.golang.org/grpc/codes"
    "google.golang.org/grpc/status"
)

func RecoveryInterceptor() grpc.UnaryServerInterceptor {
    return func(ctx context.Context, req any, info *grpc.UnaryServerInfo, handler grpc.UnaryHandler) (resp any, err error) {
        defer func() {
            if r := recover(); r != nil {
                slog.ErrorContext(ctx, "panic", slog.Any("panic", r), slog.String("stack", string(debug.Stack())))
                err = status.Error(codes.Internal, "internal error")
            }
        }()
        return handler(ctx, req)
    }
}

func LoggingInterceptor() grpc.UnaryServerInterceptor {
    return func(ctx context.Context, req any, info *grpc.UnaryServerInfo, handler grpc.UnaryHandler) (any, error) {
        start := time.Now()
        resp, err := handler(ctx, req)
        slog.InfoContext(ctx, "grpc call", slog.String("method", info.FullMethod),
            slog.String("code", status.Code(err).String()), slog.Duration("duration", time.Since(start)))
        return resp, err
    }
}

type wrappedServerStream struct {
    grpc.ServerStream
    ctx context.Context
}

func (w *wrappedServerStream) Context() context.Context { return w.ctx }
```

### 限流拦截器

```go
package userserver

import (
    "context"

    "google.golang.org/genproto/googleapis/rpc/errdetails"
    "google.golang.org/grpc"
    "google.golang.org/grpc/codes"
    "google.golang.org/grpc/status"
    "google.golang.org/protobuf/types/known/durationpb"
)

func RateLimitInterceptor(limiter *KeyedLimiter) grpc.UnaryServerInterceptor {
    return func(ctx context.Context, req any, info *grpc.UnaryServerInfo, handler grpc.UnaryHandler) (any, error) {
        allowed, retryAfter := limiter.Reserve(TenantIDFromContext(ctx) + "|" + info.FullMethod)
        if !allowed {
            st, _ := status.New(codes.ResourceExhausted, "rate limit exceeded").
                WithDetails(&errdetails.RetryInfo{RetryDelay: durationpb.New(retryAfter)})
            return nil, st.Err()
        }
        return handler(ctx, req)
    }
}
```

> `KeyedLimiter`、租户、认证拦截器完整实现见 [references/examples.md](references/examples.md#拦截器实现)

---

## 5. 错误处理

### 错误码映射

```go
package userserver

import (
    "context"
    "errors"

    "google.golang.org/grpc/codes"
    "google.golang.org/grpc/status"
)

func ToGRPCError(err error) error {
    if err == nil {
        return nil
    }
    if _, ok := status.FromError(err); ok {
        return err
    }
    switch {
    case errors.Is(err, context.Canceled):
        return status.Error(codes.Canceled, "request canceled")
    case errors.Is(err, context.DeadlineExceeded):
        return status.Error(codes.DeadlineExceeded, "deadline exceeded")
    case errors.Is(err, ErrNotFound):
        return status.Error(codes.NotFound, err.Error())
    case errors.Is(err, ErrAlreadyExists):
        return status.Error(codes.AlreadyExists, err.Error())
    case errors.Is(err, ErrInvalidInput):
        return status.Error(codes.InvalidArgument, err.Error())
    case errors.Is(err, ErrUnauthorized):
        return status.Error(codes.Unauthenticated, err.Error())
    case errors.Is(err, ErrForbidden):
        return status.Error(codes.PermissionDenied, err.Error())
    case errors.Is(err, ErrConflict):
        return status.Error(codes.Aborted, err.Error())
    case errors.Is(err, ErrRateLimited):
        return status.Error(codes.ResourceExhausted, err.Error())
    case errors.Is(err, ErrServiceUnavail):
        return status.Error(codes.Unavailable, err.Error())
    }
    return status.Error(codes.Internal, "internal error") // 不泄露内部细节
}
```

### 错误详情

`status.New(code, msg).WithDetails(&errdetails.BadRequest{...})` 传递字段级验证错误；
`errdetails.RetryInfo` 告知客户端重试间隔。客户端用 `status.FromError` + `st.Details()` 解析。

> 完整实现见 [references/examples.md](references/examples.md#错误处理实现)

---

## 6. 元数据传播

### Metadata Keys 规范

| 类别 | Keys | 说明 |
|------|------|------|
| 租户 | `x-tenant-id`, `x-tenant-name` | 小写带连字符，gRPC metadata key 强制小写 |
| 请求 | `x-request-id` | 日志关联 |
| 追踪 | `traceparent`, `tracestate`, `baggage` | 由 otelgrpc 自动处理，不手动设置 |

### 提取与注入

```go
package userserver

import (
    "context"

    "google.golang.org/grpc/metadata"
)

func tenantIDFromIncoming(ctx context.Context) string {
    md, _ := metadata.FromIncomingContext(ctx)
    if vals := md.Get("x-tenant-id"); len(vals) > 0 {
        return vals[0]
    }
    return ""
}

func injectTenantToOutgoing(ctx context.Context, tenantID string) context.Context {
    md, _ := metadata.FromOutgoingContext(ctx)
    md = md.Copy()           // 不修改 context 中的原始 MD
    md.Set("x-tenant-id", tenantID) // Set 覆盖，防止上游租户信息泄露到下游
    return metadata.NewOutgoingContext(ctx, md)
}
```

`metadata.AppendToOutgoingContext` 仅用于需要累积的链路信息（如 `x-forwarded-for`）。

> Header/Trailer 收发见 [references/examples.md](references/examples.md#元数据传播实现)

---

## 7. 健康检查

```go
package userserver

import (
    "google.golang.org/grpc"
    "google.golang.org/grpc/health"
    "google.golang.org/grpc/health/grpc_health_v1"
)

func registerHealth(server *grpc.Server) *health.Server {
    hs := health.NewServer()
    grpc_health_v1.RegisterHealthServer(server, hs)
    hs.SetServingStatus("user.v1.UserService", grpc_health_v1.HealthCheckResponse_SERVING)
    hs.SetServingStatus("", grpc_health_v1.HealthCheckResponse_SERVING) // 整体状态
    return hs
}
```

- 依赖检查用 `time.Ticker` + ctx 控制 goroutine 生命周期
- 关闭前 `hs.Shutdown()` 把所有服务置为 `NOT_SERVING`，让负载均衡摘流
- 客户端 service config 加 `"healthCheckConfig": {"serviceName": ""}` 自动剔除不健康实例
- K8s 探针用 `grpc` 探针类型或 `grpc_health_probe`

> 完整实现见 [references/examples.md](references/examples.md#健康检查实现)

---

## 8. 优雅关闭

```go
package userserver

import (
    "time"

    "google.golang.org/grpc"
    "google.golang.org/grpc/health"
)

func GracefulStop(server *grpc.Server, hs *health.Server, timeout time.Duration) {
    hs.Shutdown() // 先摘流
    stopped := make(chan struct{})
    go func() {
        server.GracefulStop() // 等待在途请求完成
        close(stopped)
    }()
    select {
    case <-stopped:
    case <-time.After(timeout):
        server.Stop() // 超时强制关闭
    }
}
```

信号处理用 `signal.NotifyContext(ctx, os.Interrupt, syscall.SIGTERM)`。

> 完整模式见 [references/examples.md](references/examples.md#优雅关闭实现)

---

## 9. 服务配置（重试、超时、负载均衡）

```go
package userserver

const serviceConfig = `{
  "loadBalancingConfig": [{"round_robin": {}}],
  "healthCheckConfig": {"serviceName": ""},
  "methodConfig": [{
    "name": [{"service": "user.v1.UserService", "method": "GetUser"}],
    "timeout": "5s",
    "retryPolicy": {
      "maxAttempts": 3,
      "initialBackoff": "0.1s",
      "maxBackoff": "1s",
      "backoffMultiplier": 2,
      "retryableStatusCodes": ["UNAVAILABLE"]
    }
  }]
}`
```

- 重试只对幂等方法开启；`maxAttempts` 上限 5
- 每方法超时优先于调用方 deadline 中较短者
- `dns:///` target + `round_robin` 实现客户端负载均衡

> 完整配置见 [references/examples.md](references/examples.md#服务配置实现)

---

## 最佳实践

### Proto 设计
- 版本化包名（v1、v2），请求/响应独立 message
- 用 `google.protobuf.Timestamp`、`Duration`、`FieldMask` 标准类型
- 字段只增不删，废弃字段用 `reserved`

### 拦截器
- `ChainUnaryInterceptor` + `ChainStreamInterceptor` 成对配置
- 顺序：恢复 → 租户 → 限流 → 认证 → 日志
- 追踪与指标用 `otelgrpc` stats handler，不写拦截器

### 错误处理
- 领域错误集中映射为标准 gRPC 错误码，未知错误返回 `Internal`
- 字段级错误用 `errdetails.BadRequest`，限流用 `RetryInfo`
- 客户端按状态码区分可重试（`Unavailable`/`DeadlineExceeded`/`ResourceExhausted`）

### 可靠性
- 健康检查注册并在关闭前 `Shutdown`
- keepalive 参数服务端/客户端匹配，避免 `ENHANCE_YOUR_CALM`
- `MaxRecvMsgSize` 限制消息大小

---

## 检查清单

- [ ] Proto 文件版本化？
- [ ] 注册健康检查并在关闭前置为 NOT_SERVING？
- [ ] 配置合理超时（service config 或调用方 deadline）？
- [ ] 租户拦截器 + otelgrpc stats handler？
- [ ] 限流拦截器返回 `ResourceExhausted` + `RetryInfo`？
- [ ] 错误码映射完整、未知错误不泄露细节？
- [ ] 客户端仅对幂等方法启用重试？
- [ ] 优雅关闭带超时兜底？
- [ ] 元数据注入用 `Copy` + `Set` 覆盖语义？

---

## 参考资料

- [references/examples.md](references/examples.md) - 完整代码实现（Proto 定义、四种 RPC、拦截器、错误处理、元数据、健康检查、优雅关闭、服务配置）
- [grpc-go 文档](https://pkg.go.dev/google.golang.org/grpc)
- [otelgrpc 文档](https://pkg.go.dev/go.opentelemetry.io/contrib/instrumentation/google.golang.org/grpc/otelgrpc)
- [gRPC 服务配置规范](https://github.com/grpc/grpc/blob/master/doc/service_config.md)
