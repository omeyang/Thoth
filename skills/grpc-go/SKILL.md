---
name: grpc-go
description: "Go gRPC 专家 - 服务定义(Proto)、Unary/Stream RPC、拦截器(日志/认证/恢复/限流/租户/追踪)、错误处理与错误码映射、元数据传播、负载均衡、健康检查、优雅关闭。适用：微服务通信、API 网关、内部服务间调用、流式数据传输。不适用：浏览器直连(用 gRPC-Web 或 REST)；简单 CRUD API(REST 更轻量)；消息队列场景(用 Kafka/Pulsar)。触发词：grpc, gRPC, protobuf, proto, 拦截器, interceptor, streaming, 流式, metadata, 元数据, service-config"
user-invocable: true
allowed-tools: Bash, Read, Write, Edit, Grep, Glob
---

# Go gRPC 专家

使用 Go gRPC 开发高性能 RPC 服务：$ARGUMENTS

---

## 1. 服务定义

### Proto 文件

使用版本化包名，请求/响应独立 message，使用 google.protobuf 标准类型。

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

> 完整 Proto 定义和代码生成命令见 [references/examples.md](references/examples.md#proto-文件完整定义)

### 生成代码

```bash
protoc --go_out=. --go_opt=paths=source_relative \
       --go-grpc_out=. --go-grpc_opt=paths=source_relative \
       api/user/v1/*.proto
```

---

## 2. 服务端实现

### 核心结构

```go
type UserServer struct {
    userv1.UnimplementedUserServiceServer
    repo UserRepository
}
```

### RPC 类型签名

| RPC 类型 | 签名 |
|---------|------|
| Unary | `GetUser(ctx, *GetUserRequest) (*GetUserResponse, error)` |
| Server Stream | `ListUsers(*ListUsersRequest, UserService_ListUsersServer) error` |
| Client Stream | `BatchCreateUsers(UserService_BatchCreateUsersServer) error` |
| Bidi Stream | `Chat(UserService_ChatServer) error` |

> 完整四种 RPC 实现见 [references/examples.md](references/examples.md#服务端实现)

### 启动服务（含拦截器链）

```go
server := grpc.NewServer(
    grpc.ChainUnaryInterceptor(
        xtenant.GRPCUnaryServerInterceptor(xtenant.WithGRPCRequireTenantID()),
        xtrace.GRPCUnaryServerInterceptor(),
        xlimit.UnaryServerInterceptor(limiter),
        LoggingInterceptor(),
    ),
    grpc.ChainStreamInterceptor(
        xtenant.GRPCStreamServerInterceptor(),
        xtrace.GRPCStreamServerInterceptor(),
        xlimit.StreamServerInterceptor(limiter),
    ),
)
userv1.RegisterUserServiceServer(server, NewUserServer(repo))
reflection.Register(server) // 调试用
```

---

## 3. 客户端实现

### 创建客户端

```go
conn, err := grpc.NewClient(target,
    grpc.WithTransportCredentials(insecure.NewCredentials()),
    grpc.WithChainUnaryInterceptor(
        xtenant.GRPCUnaryClientInterceptor(),   // 自动传播租户信息
        xtrace.GRPCUnaryClientInterceptor(),     // 自动传播 trace 信息
    ),
    grpc.WithChainStreamInterceptor(
        xtenant.GRPCStreamClientInterceptor(),
        xtrace.GRPCStreamClientInterceptor(),
    ),
    grpc.WithDefaultServiceConfig(serviceConfig),
)
```

> 完整客户端创建和调用示例见 [references/examples.md](references/examples.md#客户端实现)

---

## 4. 拦截器

### XKit 提供的拦截器

| 包 | 拦截器 | 功能 |
|------|--------|------|
| `xtenant` | `GRPCUnaryServerInterceptor` | 从 metadata 提取租户信息注入 context |
| `xtenant` | `GRPCUnaryClientInterceptor` | 自动将租户信息注入 outgoing metadata |
| `xtrace` | `GRPCUnaryServerInterceptor` | 提取 trace info（含 W3C traceparent） |
| `xtrace` | `GRPCUnaryClientInterceptor` | 注入 trace info 到 outgoing metadata |
| `xlimit` | `UnaryServerInterceptor` | 多维限流（按 tenant/caller/method） |

所有拦截器同时提供 Unary 和 Stream 版本。

### 租户拦截器选项

```go
WithGRPCRequireTenant()     // 要求 TenantID + TenantName
WithGRPCRequireTenantID()   // 仅要求 TenantID
WithGRPCEnsureTrace()       // 自动生成缺失的 trace 字段
```

### 限流拦截器

```go
xlimit.UnaryServerInterceptor(limiter,
    xlimit.WithGRPCKeyExtractor(extractor),           // 自定义 Key 提取
    xlimit.WithGRPCSkipFunc(func(ctx, info) bool {    // 跳过特定方法
        return info.FullMethod == "/health"
    }),
)
// 限流拒绝返回 codes.ResourceExhausted + retry_after
```

### 自定义拦截器

```go
// Recovery 拦截器
func RecoveryInterceptor() grpc.UnaryServerInterceptor {
    return func(ctx context.Context, req any, info *grpc.UnaryServerInfo, handler grpc.UnaryHandler) (resp any, err error) {
        defer func() {
            if r := recover(); r != nil {
                err = status.Errorf(codes.Internal, "panic: %v", r)
            }
        }()
        return handler(ctx, req)
    }
}

// Logging 拦截器
func LoggingInterceptor() grpc.UnaryServerInterceptor {
    return func(ctx context.Context, req any, info *grpc.UnaryServerInfo, handler grpc.UnaryHandler) (any, error) {
        start := time.Now()
        resp, err := handler(ctx, req)
        slog.InfoContext(ctx, "grpc call", slog.String("method", info.FullMethod),
            slog.Duration("duration", time.Since(start)), slog.Any("error", err))
        return resp, err
    }
}
```

### wrappedServerStream（Stream Context 覆盖）

```go
type wrappedServerStream struct {
    grpc.ServerStream
    ctx context.Context
}
func (w *wrappedServerStream) Context() context.Context { return w.ctx }
```

> 完整拦截器实现见 [references/examples.md](references/examples.md#拦截器实现)

---

## 5. 错误处理

### 错误码映射

```go
var domainToGRPC = map[error]codes.Code{
    ErrNotFound:       codes.NotFound,
    ErrAlreadyExists:  codes.AlreadyExists,
    ErrInvalidInput:   codes.InvalidArgument,
    ErrUnauthorized:   codes.Unauthenticated,
    ErrForbidden:      codes.PermissionDenied,
    ErrConflict:       codes.Aborted,
    ErrRateLimited:    codes.ResourceExhausted,
    ErrServiceUnavail: codes.Unavailable,
}

func ToGRPCError(err error) error
```

### 错误详情

使用 `errdetails.BadRequest` 传递字段级验证错误。

```go
func ValidationError(field, description string) error
```

> 完整错误处理和客户端解析见 [references/examples.md](references/examples.md#错误处理实现)

---

## 6. 元数据传播

### Metadata Keys 规范

| 类别 | Keys | 格式 |
|------|------|------|
| 租户 | `x-tenant-id`, `x-tenant-name`, `x-platform-id` | 小写带连字符 |
| 追踪 | `x-trace-id`, `x-span-id`, `x-request-id` | 小写带连字符 |
| W3C | `traceparent`, `tracestate` | W3C 标准格式 |

### 提取与注入

```go
// 服务端提取
info := xtenant.ExtractFromIncomingContext(ctx)
trace := xtrace.ExtractFromIncomingContext(ctx)

// 客户端注入（自动）
ctx = xtenant.InjectToOutgoingContext(ctx)  // Set 覆盖语义，防止 tenant leakage
```

### 安全注意事项

- 使用 `md.Set()` 覆盖而非 `md.Append()`，防止租户泄露
- gRPC metadata 使用小写 key（`x-tenant-id`），HTTP Header 使用标准格式（`X-Tenant-ID`）
- `md.Copy()` 避免修改原始 metadata

---

## 7. 健康检查

```go
healthServer := health.NewServer()
grpc_health_v1.RegisterHealthServer(server, healthServer)
healthServer.SetServingStatus("user.v1.UserService", grpc_health_v1.HealthCheckResponse_SERVING)
```

动态更新状态时使用 context 控制 goroutine 生命周期，避免泄漏。

> 完整健康检查实现见 [references/examples.md](references/examples.md#健康检查实现)

---

## 8. 优雅关闭

```go
server.GracefulStop()  // 等待现有请求完成
server.Stop()          // 超时后强制关闭
```

> 完整优雅关闭模式见 [references/examples.md](references/examples.md#优雅关闭实现)

---

## 9. 服务配置（重试、超时）

通过 `DefaultServiceConfig` JSON 配置每方法超时和重试策略。

```go
conn, err := grpc.NewClient(target,
    grpc.WithDefaultServiceConfig(serviceConfig),
)
```

> 完整配置 JSON 示例见 [references/examples.md](references/examples.md#服务配置实现)

---

## 最佳实践

### Proto 设计
- 使用版本化包名 (v1, v2)
- 请求/响应使用独立 message
- 使用 google.protobuf 标准类型

### 拦截器
- 使用 `ChainUnaryInterceptor` 组合多个拦截器
- 推荐顺序：租户 → 追踪 → 限流 → 认证 → 日志
- 所有拦截器同时配置 Unary + Stream 版本

### 错误处理
- 使用标准 gRPC 错误码
- 错误详情用于调试
- 客户端区分可重试/不可重试错误

### 可观测性
- 使用 xtenant + xtrace 拦截器自动传播上下文
- xlimit 返回 `codes.ResourceExhausted` + retry_after
- 健康检查端点注册到 gRPC health 服务

---

## 检查清单

- [ ] Proto 文件版本化？
- [ ] 实现健康检查服务？
- [ ] 配置合理超时？
- [ ] 租户/追踪拦截器？
- [ ] 限流拦截器（xlimit）？
- [ ] 错误码映射完整？
- [ ] 客户端启用重试？
- [ ] 优雅关闭？
- [ ] 元数据用 Set 覆盖语义？

---

## 参考资料

- [references/examples.md](references/examples.md) - 完整代码实现（Proto 定义、四种 RPC、拦截器、错误处理、元数据、健康检查、优雅关闭、服务配置）
