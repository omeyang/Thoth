# Go gRPC - 完整代码示例

基线：go1.24.6，`google.golang.org/grpc v1.80.0`，`google.golang.org/protobuf v1.36.12`，
`go.opentelemetry.io/contrib/instrumentation/google.golang.org/grpc/otelgrpc v0.66.0`，
`golang.org/x/time v0.14.0`。Go 片段同属一个包 `userserver`，生成代码位于 `github.com/example/api/user/v1`。

## 目录

- [Proto 文件完整定义](#proto-文件完整定义)
- [服务端实现](#服务端实现)
- [启动服务](#启动服务)
- [客户端实现](#客户端实现)
- [拦截器实现](#拦截器实现)
- [错误处理实现](#错误处理实现)
- [元数据传播实现](#元数据传播实现)
- [健康检查实现](#健康检查实现)
- [优雅关闭实现](#优雅关闭实现)
- [服务配置实现](#服务配置实现)

---

## Proto 文件完整定义

```protobuf
syntax = "proto3";

package user.v1;

import "google/protobuf/timestamp.proto";

option go_package = "github.com/example/api/user/v1;userv1";

// 用户服务
service UserService {
  // Unary RPC
  rpc GetUser(GetUserRequest) returns (GetUserResponse);
  rpc CreateUser(CreateUserRequest) returns (CreateUserResponse);

  // Server streaming
  rpc ListUsers(ListUsersRequest) returns (stream User);

  // Client streaming
  rpc BatchCreateUsers(stream CreateUserRequest) returns (BatchCreateUsersResponse);

  // Bidirectional streaming
  rpc Chat(stream ChatMessage) returns (stream ChatMessage);
}

message User {
  string id = 1;
  string name = 2;
  string email = 3;
  google.protobuf.Timestamp created_at = 4;
}

message GetUserRequest {
  string id = 1;
}

message GetUserResponse {
  User user = 1;
}

message CreateUserRequest {
  string name = 1;
  string email = 2;
}

message CreateUserResponse {
  User user = 1;
}

message ListUsersRequest {
  int32 page_size = 1;
  string page_token = 2;
}

message BatchCreateUsersResponse {
  int32 created_count = 1;
}

message ChatMessage {
  string user_id = 1;
  string content = 2;
  google.protobuf.Timestamp timestamp = 3;
}
```

### 生成代码

用 go.mod `tool` 指令钉住插件版本，团队成员执行 `go tool` 即可得到一致的生成结果：

```bash
# 一次性：把插件记录到 go.mod 的 tool 块
go get -tool google.golang.org/protobuf/cmd/protoc-gen-go@v1.36.12
go get -tool google.golang.org/grpc/cmd/protoc-gen-go-grpc@v1.6.1

# 生成（protoc 通过 --plugin 指定 go tool 包装的插件）
protoc \
  --plugin=protoc-gen-go="$(go tool -n protoc-gen-go)" \
  --plugin=protoc-gen-go-grpc="$(go tool -n protoc-gen-go-grpc)" \
  --go_out=. --go_opt=paths=source_relative \
  --go-grpc_out=. --go-grpc_opt=paths=source_relative \
  api/user/v1/*.proto
```

使用 buf 时 `buf.gen.yaml`（v2）：

```yaml
version: v2
plugins:
  - local: ["go", "tool", "protoc-gen-go"]
    out: .
    opt: paths=source_relative
  - local: ["go", "tool", "protoc-gen-go-grpc"]
    out: .
    opt: paths=source_relative
```

---

## 服务端实现

### 领域类型与仓储接口

```go
package userserver

import (
    "context"
    "errors"
    "time"
)

type User struct {
    ID        string
    Name      string
    Email     string
    CreatedAt time.Time
}

// 领域错误，由 ToGRPCError 映射为状态码
var (
    ErrNotFound       = errors.New("not found")
    ErrAlreadyExists  = errors.New("already exists")
    ErrInvalidInput   = errors.New("invalid input")
    ErrUnauthorized   = errors.New("unauthorized")
    ErrForbidden      = errors.New("forbidden")
    ErrConflict       = errors.New("conflict")
    ErrRateLimited    = errors.New("rate limited")
    ErrServiceUnavail = errors.New("service unavailable")
)

type UserRepository interface {
    GetByID(ctx context.Context, id string) (*User, error)
    List(ctx context.Context, pageSize int, pageToken string) ([]*User, error)
    Create(ctx context.Context, name, email string) (*User, error)
}
```

### 四种 RPC

```go
package userserver

import (
    "context"
    "errors"
    "io"

    "google.golang.org/grpc"
    "google.golang.org/protobuf/types/known/timestamppb"

    userv1 "github.com/example/api/user/v1"
)

type UserServer struct {
    userv1.UnimplementedUserServiceServer
    repo UserRepository
}

func NewUserServer(repo UserRepository) *UserServer {
    return &UserServer{repo: repo}
}

// Unary RPC
func (s *UserServer) GetUser(ctx context.Context, req *userv1.GetUserRequest) (*userv1.GetUserResponse, error) {
    if req.GetId() == "" {
        return nil, ValidationError("id", "must not be empty")
    }

    user, err := s.repo.GetByID(ctx, req.GetId())
    if err != nil {
        return nil, ToGRPCError(err)
    }

    return &userv1.GetUserResponse{User: toProtoUser(user)}, nil
}

// Server streaming：v1.80 生成代码使用泛型流类型 grpc.ServerStreamingServer[T]
func (s *UserServer) ListUsers(req *userv1.ListUsersRequest, stream grpc.ServerStreamingServer[userv1.User]) error {
    ctx := stream.Context()

    users, err := s.repo.List(ctx, int(req.GetPageSize()), req.GetPageToken())
    if err != nil {
        return ToGRPCError(err)
    }

    for _, user := range users {
        if err := stream.Send(toProtoUser(user)); err != nil {
            return err
        }
    }
    return nil
}

// Client streaming
func (s *UserServer) BatchCreateUsers(stream grpc.ClientStreamingServer[userv1.CreateUserRequest, userv1.BatchCreateUsersResponse]) error {
    ctx := stream.Context()
    var count int32

    for {
        req, err := stream.Recv()
        if errors.Is(err, io.EOF) {
            return stream.SendAndClose(&userv1.BatchCreateUsersResponse{CreatedCount: count})
        }
        if err != nil {
            return err
        }

        if _, err := s.repo.Create(ctx, req.GetName(), req.GetEmail()); err != nil {
            return ToGRPCError(err)
        }
        count++
    }
}

// Bidirectional streaming
func (s *UserServer) Chat(stream grpc.BidiStreamingServer[userv1.ChatMessage, userv1.ChatMessage]) error {
    for {
        msg, err := stream.Recv()
        if errors.Is(err, io.EOF) {
            return nil
        }
        if err != nil {
            return err
        }

        resp := &userv1.ChatMessage{
            UserId:    "server",
            Content:   "Echo: " + msg.GetContent(),
            Timestamp: timestamppb.Now(),
        }
        if err := stream.Send(resp); err != nil {
            return err
        }
    }
}

func toProtoUser(u *User) *userv1.User {
    return &userv1.User{
        Id:        u.ID,
        Name:      u.Name,
        Email:     u.Email,
        CreatedAt: timestamppb.New(u.CreatedAt),
    }
}

// 编译期确认实现了接口
var _ userv1.UserServiceServer = (*UserServer)(nil)
```

---

## 启动服务

追踪与指标由 `otelgrpc` 的 `stats.Handler` 提供（拦截器方式已废弃），
业务拦截器按"恢复 → 租户 → 限流 → 认证 → 日志"链式组合。

```go
package userserver

import (
    "context"
    "fmt"
    "log/slog"
    "net"
    "time"

    "go.opentelemetry.io/contrib/instrumentation/google.golang.org/grpc/otelgrpc"
    "google.golang.org/grpc"
    "google.golang.org/grpc/health"
    "google.golang.org/grpc/health/grpc_health_v1"
    "google.golang.org/grpc/keepalive"
    "google.golang.org/grpc/reflection"
    "google.golang.org/grpc/stats"

    userv1 "github.com/example/api/user/v1"
)

// NewServer 组装拦截器链、健康检查与反射。
func NewServer(repo UserRepository, limiter *KeyedLimiter, validator TokenValidator) (*grpc.Server, *health.Server) {
    server := grpc.NewServer(
        grpc.StatsHandler(otelgrpc.NewServerHandler(
            // 健康检查不产生 span
            otelgrpc.WithFilter(func(info *stats.RPCTagInfo) bool {
                return info.FullMethodName != grpc_health_v1.Health_Check_FullMethodName
            }),
        )),
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
        grpc.KeepaliveParams(keepalive.ServerParameters{
            MaxConnectionIdle: 5 * time.Minute,
            Time:              2 * time.Minute,
            Timeout:           20 * time.Second,
        }),
        grpc.MaxRecvMsgSize(4<<20),
    )

    userv1.RegisterUserServiceServer(server, NewUserServer(repo))

    healthServer := health.NewServer()
    grpc_health_v1.RegisterHealthServer(server, healthServer)
    healthServer.SetServingStatus(userv1.UserService_ServiceDesc.ServiceName, grpc_health_v1.HealthCheckResponse_SERVING)

    reflection.Register(server) // 调试用，生产环境按需关闭

    return server, healthServer
}

// Serve 监听并阻塞，直到 ctx 取消后优雅关闭。
func Serve(ctx context.Context, server *grpc.Server, healthServer *health.Server, addr string) error {
    lis, err := net.Listen("tcp", addr)
    if err != nil {
        return fmt.Errorf("listen %s: %w", addr, err)
    }

    errCh := make(chan error, 1)
    go func() { errCh <- server.Serve(lis) }()
    slog.Info("grpc server listening", slog.String("addr", lis.Addr().String()))

    select {
    case err := <-errCh:
        return err
    case <-ctx.Done():
        return GracefulStop(server, healthServer, 30*time.Second)
    }
}
```

---

## 客户端实现

### 创建客户端

```go
package userserver

import (
    "fmt"

    "go.opentelemetry.io/contrib/instrumentation/google.golang.org/grpc/otelgrpc"
    "google.golang.org/grpc"
    "google.golang.org/grpc/credentials/insecure"

    userv1 "github.com/example/api/user/v1"
)

// NewUserClient 创建带追踪、租户传播、重试与负载均衡的客户端。
// target 使用 dns:///host:port 形式以启用客户端负载均衡。
func NewUserClient(target string) (userv1.UserServiceClient, func() error, error) {
    conn, err := grpc.NewClient(target,
        grpc.WithTransportCredentials(insecure.NewCredentials()), // 生产环境换成 TLS
        grpc.WithStatsHandler(otelgrpc.NewClientHandler()),
        grpc.WithChainUnaryInterceptor(
            TenantClientInterceptor(),
            ClientLoggingInterceptor(),
        ),
        grpc.WithChainStreamInterceptor(
            TenantStreamClientInterceptor(),
        ),
        grpc.WithDefaultServiceConfig(serviceConfig),
    )
    if err != nil {
        return nil, nil, fmt.Errorf("new client: %w", err)
    }

    return userv1.NewUserServiceClient(conn), conn.Close, nil
}
```

### 调用示例

```go
package userserver

import (
    "context"
    "errors"
    "io"

    userv1 "github.com/example/api/user/v1"
)

type CreateUserInput struct {
    Name  string
    Email string
}

// Unary
func GetUser(ctx context.Context, client userv1.UserServiceClient, id string) (*userv1.User, error) {
    resp, err := client.GetUser(ctx, &userv1.GetUserRequest{Id: id})
    if err != nil {
        return nil, err
    }
    return resp.GetUser(), nil
}

// Server streaming
func ListAllUsers(ctx context.Context, client userv1.UserServiceClient) ([]*userv1.User, error) {
    stream, err := client.ListUsers(ctx, &userv1.ListUsersRequest{PageSize: 100})
    if err != nil {
        return nil, err
    }

    var users []*userv1.User
    for {
        user, err := stream.Recv()
        if errors.Is(err, io.EOF) {
            return users, nil
        }
        if err != nil {
            return nil, err
        }
        users = append(users, user)
    }
}

// Client streaming
func BatchCreate(ctx context.Context, client userv1.UserServiceClient, inputs []CreateUserInput) (int32, error) {
    stream, err := client.BatchCreateUsers(ctx)
    if err != nil {
        return 0, err
    }

    for _, in := range inputs {
        if err := stream.Send(&userv1.CreateUserRequest{Name: in.Name, Email: in.Email}); err != nil {
            return 0, err
        }
    }

    resp, err := stream.CloseAndRecv()
    if err != nil {
        return 0, err
    }
    return resp.GetCreatedCount(), nil
}
```

---

## 拦截器实现

### 日志与恢复（Unary）

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

func LoggingInterceptor() grpc.UnaryServerInterceptor {
    return func(ctx context.Context, req any, info *grpc.UnaryServerInfo, handler grpc.UnaryHandler) (any, error) {
        start := time.Now()
        resp, err := handler(ctx, req)

        slog.InfoContext(ctx, "grpc request",
            slog.String("method", info.FullMethod),
            slog.String("code", status.Code(err).String()),
            slog.String("tenant_id", TenantIDFromContext(ctx)),
            slog.Duration("duration", time.Since(start)),
        )
        return resp, err
    }
}

func RecoveryInterceptor() grpc.UnaryServerInterceptor {
    return func(ctx context.Context, req any, info *grpc.UnaryServerInfo, handler grpc.UnaryHandler) (resp any, err error) {
        defer func() {
            if r := recover(); r != nil {
                slog.ErrorContext(ctx, "panic recovered",
                    slog.String("method", info.FullMethod),
                    slog.Any("panic", r),
                    slog.String("stack", string(debug.Stack())),
                )
                err = status.Error(codes.Internal, "internal error")
            }
        }()
        return handler(ctx, req)
    }
}
```

### 认证

```go
package userserver

import (
    "context"
    "strings"

    "google.golang.org/grpc"
    "google.golang.org/grpc/codes"
    "google.golang.org/grpc/metadata"
    "google.golang.org/grpc/status"
)

type Claims struct {
    Subject string
    Roles   []string
}

type TokenValidator interface {
    Validate(ctx context.Context, token string) (*Claims, error)
}

type claimsKey struct{}

func ClaimsFromContext(ctx context.Context) (*Claims, bool) {
    c, ok := ctx.Value(claimsKey{}).(*Claims)
    return c, ok
}

func isPublicMethod(fullMethod string) bool {
    return strings.HasPrefix(fullMethod, "/grpc.health.v1.Health/") ||
        strings.HasPrefix(fullMethod, "/grpc.reflection.")
}

func AuthInterceptor(validator TokenValidator) grpc.UnaryServerInterceptor {
    return func(ctx context.Context, req any, info *grpc.UnaryServerInfo, handler grpc.UnaryHandler) (any, error) {
        if isPublicMethod(info.FullMethod) {
            return handler(ctx, req)
        }

        md, ok := metadata.FromIncomingContext(ctx)
        if !ok {
            return nil, status.Error(codes.Unauthenticated, "missing metadata")
        }
        auth := md.Get("authorization")
        if len(auth) == 0 {
            return nil, status.Error(codes.Unauthenticated, "missing token")
        }
        token, found := strings.CutPrefix(auth[0], "Bearer ")
        if !found {
            return nil, status.Error(codes.Unauthenticated, "invalid authorization scheme")
        }

        claims, err := validator.Validate(ctx, token)
        if err != nil {
            return nil, status.Error(codes.Unauthenticated, "invalid token")
        }

        return handler(context.WithValue(ctx, claimsKey{}, claims), req)
    }
}
```

### 租户传播（服务端提取 / 客户端注入）

```go
package userserver

import (
    "context"

    "google.golang.org/grpc"
    "google.golang.org/grpc/codes"
    "google.golang.org/grpc/metadata"
    "google.golang.org/grpc/status"
)

const (
    MetadataTenantID   = "x-tenant-id"   // gRPC metadata key 必须小写
    MetadataTenantName = "x-tenant-name"
    MetadataRequestID  = "x-request-id"
)

type tenantKey struct{}

type Tenant struct {
    ID   string
    Name string
}

func ContextWithTenant(ctx context.Context, t Tenant) context.Context {
    return context.WithValue(ctx, tenantKey{}, t)
}

func TenantFromContext(ctx context.Context) (Tenant, bool) {
    t, ok := ctx.Value(tenantKey{}).(Tenant)
    return t, ok
}

func TenantIDFromContext(ctx context.Context) string {
    t, _ := TenantFromContext(ctx)
    return t.ID
}

func tenantFromIncoming(ctx context.Context, required bool) (context.Context, error) {
    md, _ := metadata.FromIncomingContext(ctx)
    t := Tenant{
        ID:   firstValue(md, MetadataTenantID),
        Name: firstValue(md, MetadataTenantName),
    }
    if required && t.ID == "" {
        return ctx, status.Error(codes.InvalidArgument, "missing "+MetadataTenantID)
    }
    if t.ID == "" {
        return ctx, nil
    }
    return ContextWithTenant(ctx, t), nil
}

func firstValue(md metadata.MD, key string) string {
    if vals := md.Get(key); len(vals) > 0 {
        return vals[0]
    }
    return ""
}

// TenantServerInterceptor 从 incoming metadata 提取租户并注入 context。
func TenantServerInterceptor(required bool) grpc.UnaryServerInterceptor {
    return func(ctx context.Context, req any, info *grpc.UnaryServerInfo, handler grpc.UnaryHandler) (any, error) {
        ctx, err := tenantFromIncoming(ctx, required && !isPublicMethod(info.FullMethod))
        if err != nil {
            return nil, err
        }
        return handler(ctx, req)
    }
}

// wrappedServerStream 覆盖 Context()，让流式 handler 也能拿到注入后的 context。
type wrappedServerStream struct {
    grpc.ServerStream
    ctx context.Context
}

func (w *wrappedServerStream) Context() context.Context { return w.ctx }

func TenantStreamServerInterceptor(required bool) grpc.StreamServerInterceptor {
    return func(srv any, ss grpc.ServerStream, info *grpc.StreamServerInfo, handler grpc.StreamHandler) error {
        ctx, err := tenantFromIncoming(ss.Context(), required && !isPublicMethod(info.FullMethod))
        if err != nil {
            return err
        }
        return handler(srv, &wrappedServerStream{ServerStream: ss, ctx: ctx})
    }
}

// InjectTenantToOutgoing 使用 Set 覆盖语义，避免上游残留的租户信息泄露到下游。
func InjectTenantToOutgoing(ctx context.Context) context.Context {
    t, ok := TenantFromContext(ctx)
    if !ok {
        return ctx
    }
    md, _ := metadata.FromOutgoingContext(ctx)
    md = md.Copy() // 不修改 context 中的原始 MD
    md.Set(MetadataTenantID, t.ID)
    if t.Name != "" {
        md.Set(MetadataTenantName, t.Name)
    }
    return metadata.NewOutgoingContext(ctx, md)
}

func TenantClientInterceptor() grpc.UnaryClientInterceptor {
    return func(ctx context.Context, method string, req, reply any, cc *grpc.ClientConn, invoker grpc.UnaryInvoker, opts ...grpc.CallOption) error {
        return invoker(InjectTenantToOutgoing(ctx), method, req, reply, cc, opts...)
    }
}

func TenantStreamClientInterceptor() grpc.StreamClientInterceptor {
    return func(ctx context.Context, desc *grpc.StreamDesc, cc *grpc.ClientConn, method string, streamer grpc.Streamer, opts ...grpc.CallOption) (grpc.ClientStream, error) {
        return streamer(InjectTenantToOutgoing(ctx), desc, cc, method, opts...)
    }
}
```

### 限流（x/time/rate，按租户 + 方法）

```go
package userserver

import (
    "context"
    "sync"
    "time"

    "golang.org/x/time/rate"
    "google.golang.org/genproto/googleapis/rpc/errdetails"
    "google.golang.org/grpc"
    "google.golang.org/grpc/codes"
    "google.golang.org/grpc/status"
    "google.golang.org/protobuf/types/known/durationpb"
)

// KeyedLimiter 为每个 key 维护一个令牌桶，并定期清理长期空闲的桶。
type KeyedLimiter struct {
    mu       sync.Mutex
    limiters map[string]*keyedEntry
    limit    rate.Limit
    burst    int
    idle     time.Duration
}

type keyedEntry struct {
    limiter  *rate.Limiter
    lastSeen time.Time
}

func NewKeyedLimiter(perSecond float64, burst int, idle time.Duration) *KeyedLimiter {
    return &KeyedLimiter{
        limiters: make(map[string]*keyedEntry),
        limit:    rate.Limit(perSecond),
        burst:    burst,
        idle:     idle,
    }
}

// Reserve 尝试获取一个令牌；拒绝时返回建议等待时间。
func (k *KeyedLimiter) Reserve(key string) (allowed bool, retryAfter time.Duration) {
    k.mu.Lock()
    defer k.mu.Unlock()

    e, ok := k.limiters[key]
    if !ok {
        e = &keyedEntry{limiter: rate.NewLimiter(k.limit, k.burst)}
        k.limiters[key] = e
    }
    e.lastSeen = time.Now()

    r := e.limiter.Reserve()
    if delay := r.Delay(); delay > 0 {
        r.Cancel() // 不等待，归还预留
        return false, delay
    }
    return true, 0
}

// Sweep 清理空闲桶，建议由 time.Ticker 周期调用。
func (k *KeyedLimiter) Sweep() {
    k.mu.Lock()
    defer k.mu.Unlock()
    cutoff := time.Now().Add(-k.idle)
    for key, e := range k.limiters {
        if e.lastSeen.Before(cutoff) {
            delete(k.limiters, key)
        }
    }
}

// RateLimitInterceptor 按 "<tenant>|<method>" 限流，拒绝时返回 ResourceExhausted + RetryInfo。
func RateLimitInterceptor(limiter *KeyedLimiter) grpc.UnaryServerInterceptor {
    return func(ctx context.Context, req any, info *grpc.UnaryServerInfo, handler grpc.UnaryHandler) (any, error) {
        if isPublicMethod(info.FullMethod) {
            return handler(ctx, req)
        }

        key := TenantIDFromContext(ctx) + "|" + info.FullMethod
        allowed, retryAfter := limiter.Reserve(key)
        if !allowed {
            return nil, rateLimitedError(retryAfter)
        }
        return handler(ctx, req)
    }
}

func rateLimitedError(retryAfter time.Duration) error {
    st := status.New(codes.ResourceExhausted, "rate limit exceeded")
    withDetails, err := st.WithDetails(&errdetails.RetryInfo{RetryDelay: durationpb.New(retryAfter)})
    if err != nil {
        return st.Err()
    }
    return withDetails.Err()
}
```

### Stream 日志与恢复

```go
package userserver

import (
    "log/slog"
    "runtime/debug"
    "time"

    "google.golang.org/grpc"
    "google.golang.org/grpc/codes"
    "google.golang.org/grpc/status"
)

func StreamLoggingInterceptor() grpc.StreamServerInterceptor {
    return func(srv any, ss grpc.ServerStream, info *grpc.StreamServerInfo, handler grpc.StreamHandler) error {
        start := time.Now()
        err := handler(srv, ss)

        slog.InfoContext(ss.Context(), "grpc stream",
            slog.String("method", info.FullMethod),
            slog.String("code", status.Code(err).String()),
            slog.Bool("client_stream", info.IsClientStream),
            slog.Bool("server_stream", info.IsServerStream),
            slog.Duration("duration", time.Since(start)),
        )
        return err
    }
}

func StreamRecoveryInterceptor() grpc.StreamServerInterceptor {
    return func(srv any, ss grpc.ServerStream, info *grpc.StreamServerInfo, handler grpc.StreamHandler) (err error) {
        defer func() {
            if r := recover(); r != nil {
                slog.ErrorContext(ss.Context(), "panic recovered",
                    slog.String("method", info.FullMethod),
                    slog.Any("panic", r),
                    slog.String("stack", string(debug.Stack())),
                )
                err = status.Error(codes.Internal, "internal error")
            }
        }()
        return handler(srv, ss)
    }
}
```

### 客户端日志拦截器

```go
package userserver

import (
    "context"
    "log/slog"
    "time"

    "google.golang.org/grpc"
    "google.golang.org/grpc/status"
)

func ClientLoggingInterceptor() grpc.UnaryClientInterceptor {
    return func(ctx context.Context, method string, req, reply any, cc *grpc.ClientConn, invoker grpc.UnaryInvoker, opts ...grpc.CallOption) error {
        start := time.Now()
        err := invoker(ctx, method, req, reply, cc, opts...)

        slog.InfoContext(ctx, "grpc client call",
            slog.String("method", method),
            slog.String("code", status.Code(err).String()),
            slog.Duration("duration", time.Since(start)),
        )
        return err
    }
}
```

---

## 错误处理实现

### 错误码映射

```go
package userserver

import (
    "context"
    "errors"

    "google.golang.org/grpc/codes"
    "google.golang.org/grpc/status"
)

// 有序切片而非 map，保证匹配顺序稳定。
var domainToGRPC = []struct {
    err  error
    code codes.Code
}{
    {ErrNotFound, codes.NotFound},
    {ErrAlreadyExists, codes.AlreadyExists},
    {ErrInvalidInput, codes.InvalidArgument},
    {ErrUnauthorized, codes.Unauthenticated},
    {ErrForbidden, codes.PermissionDenied},
    {ErrConflict, codes.Aborted},
    {ErrRateLimited, codes.ResourceExhausted},
    {ErrServiceUnavail, codes.Unavailable},
}

// ToGRPCError 把领域错误映射为 gRPC 状态；未知错误统一 Internal，不泄露细节。
func ToGRPCError(err error) error {
    if err == nil {
        return nil
    }
    if _, ok := status.FromError(err); ok {
        return err // 已经是 gRPC 状态
    }
    if errors.Is(err, context.Canceled) {
        return status.Error(codes.Canceled, "request canceled")
    }
    if errors.Is(err, context.DeadlineExceeded) {
        return status.Error(codes.DeadlineExceeded, "deadline exceeded")
    }
    for _, m := range domainToGRPC {
        if errors.Is(err, m.err) {
            return status.Error(m.code, err.Error())
        }
    }
    return status.Error(codes.Internal, "internal error")
}
```

### 错误详情

```go
package userserver

import (
    "log/slog"

    "google.golang.org/genproto/googleapis/rpc/errdetails"
    "google.golang.org/grpc/codes"
    "google.golang.org/grpc/status"
)

// ValidationError 用 BadRequest 详情携带字段级错误。
func ValidationError(field, description string) error {
    st := status.New(codes.InvalidArgument, "validation failed")
    withDetails, err := st.WithDetails(&errdetails.BadRequest{
        FieldViolations: []*errdetails.BadRequest_FieldViolation{
            {Field: field, Description: description},
        },
    })
    if err != nil {
        return st.Err()
    }
    return withDetails.Err()
}

// HandleClientError 客户端解析状态与详情。
func HandleClientError(err error) {
    st, ok := status.FromError(err)
    if !ok {
        slog.Error("non-grpc error", slog.Any("error", err))
        return
    }

    slog.Error("grpc error", slog.String("code", st.Code().String()), slog.String("message", st.Message()))
    for _, detail := range st.Details() {
        switch d := detail.(type) {
        case *errdetails.BadRequest:
            for _, v := range d.GetFieldViolations() {
                slog.Error("field violation", slog.String("field", v.GetField()), slog.String("desc", v.GetDescription()))
            }
        case *errdetails.RetryInfo:
            slog.Warn("retry after", slog.Duration("delay", d.GetRetryDelay().AsDuration()))
        }
    }
}

// IsRetryable 客户端区分可重试错误。
func IsRetryable(err error) bool {
    switch status.Code(err) {
    case codes.Unavailable, codes.DeadlineExceeded, codes.ResourceExhausted, codes.Aborted:
        return true
    default:
        return false
    }
}
```

---

## 元数据传播实现

### 服务端提取

```go
package userserver

import (
    "context"

    "google.golang.org/grpc/metadata"
)

func ExtractRequestID(ctx context.Context) string {
    md, ok := metadata.FromIncomingContext(ctx)
    if !ok {
        return ""
    }
    return firstValue(md, MetadataRequestID)
}
```

### 服务端发送 Header / Trailer

```go
package userserver

import (
    "context"
    "time"

    "google.golang.org/grpc"
    "google.golang.org/grpc/metadata"

    userv1 "github.com/example/api/user/v1"
)

// GetUserWithHeaders 演示在响应中附带 header 与 trailer。
func (s *UserServer) getUserWithHeaders(ctx context.Context, req *userv1.GetUserRequest) (*userv1.GetUserResponse, error) {
    start := time.Now()

    if err := grpc.SendHeader(ctx, metadata.Pairs("x-served-by", "user-service")); err != nil {
        return nil, err
    }
    defer func() {
        _ = grpc.SetTrailer(ctx, metadata.Pairs("x-duration-ms", time.Since(start).String()))
    }()

    return s.GetUser(ctx, req)
}
```

### 客户端读取 Header / Trailer

```go
package userserver

import (
    "context"

    "google.golang.org/grpc"
    "google.golang.org/grpc/metadata"

    userv1 "github.com/example/api/user/v1"
)

func GetUserWithMetadata(ctx context.Context, client userv1.UserServiceClient, id string) (*userv1.User, metadata.MD, error) {
    var header, trailer metadata.MD
    resp, err := client.GetUser(ctx, &userv1.GetUserRequest{Id: id},
        grpc.Header(&header),
        grpc.Trailer(&trailer),
    )
    if err != nil {
        return nil, nil, err
    }
    return resp.GetUser(), metadata.Join(header, trailer), nil
}
```

### Set 与 Append 的区别

```go
package userserver

import (
    "context"

    "google.golang.org/grpc/metadata"
)

// 覆盖：下游只看到本服务设置的值（防止上游 tenant 泄露）
func setOutgoing(ctx context.Context, key, value string) context.Context {
    md, _ := metadata.FromOutgoingContext(ctx)
    md = md.Copy()
    md.Set(key, value)
    return metadata.NewOutgoingContext(ctx, md)
}

// 追加：保留已有值，适合 x-forwarded-for 一类的链路信息
func appendOutgoing(ctx context.Context, key, value string) context.Context {
    return metadata.AppendToOutgoingContext(ctx, key, value)
}
```

---

## 健康检查实现

```go
package userserver

import (
    "context"
    "time"

    "google.golang.org/grpc/health"
    "google.golang.org/grpc/health/grpc_health_v1"
)

// Checker 返回依赖是否健康。
type Checker func(ctx context.Context) error

// RunHealthUpdater 周期检查依赖并更新整体状态（service 为空串表示整个进程）。
// ctx 取消后退出，避免 goroutine 泄漏。
func RunHealthUpdater(ctx context.Context, hs *health.Server, interval time.Duration, checks map[string]Checker) {
    ticker := time.NewTicker(interval)
    defer ticker.Stop()

    for {
        select {
        case <-ctx.Done():
            return
        case <-ticker.C:
            overall := grpc_health_v1.HealthCheckResponse_SERVING
            for name, check := range checks {
                cctx, cancel := context.WithTimeout(ctx, interval/2)
                err := check(cctx)
                cancel()
                st := grpc_health_v1.HealthCheckResponse_SERVING
                if err != nil {
                    st = grpc_health_v1.HealthCheckResponse_NOT_SERVING
                    overall = st
                }
                hs.SetServingStatus(name, st)
            }
            hs.SetServingStatus("", overall)
        }
    }
}
```

客户端启用健康检查（配合 round_robin 剔除不健康实例）：

```go
package userserver

const healthAwareServiceConfig = `{
  "loadBalancingConfig": [{"round_robin": {}}],
  "healthCheckConfig": {"serviceName": ""}
}`
```

---

## 优雅关闭实现

```go
package userserver

import (
    "log/slog"
    "time"

    "google.golang.org/grpc"
    "google.golang.org/grpc/health"
)

// GracefulStop 先把健康状态置为 NOT_SERVING（让负载均衡摘流），再等待在途请求完成，超时后强制关闭。
func GracefulStop(server *grpc.Server, healthServer *health.Server, timeout time.Duration) error {
    healthServer.Shutdown() // 所有服务置为 NOT_SERVING

    stopped := make(chan struct{})
    go func() {
        server.GracefulStop()
        close(stopped)
    }()

    select {
    case <-stopped:
        slog.Info("grpc server stopped gracefully")
    case <-time.After(timeout):
        slog.Warn("graceful stop timed out, forcing")
        server.Stop()
    }
    return nil
}
```

main 中的典型用法：

```go
package userserver

import (
    "context"
    "os"
    "os/signal"
    "syscall"
)

func runMain(repo UserRepository, limiter *KeyedLimiter, validator TokenValidator) error {
    ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
    defer stop()

    server, healthServer := NewServer(repo, limiter, validator)
    return Serve(ctx, server, healthServer, ":50051")
}
```

---

## 服务配置实现

```go
package userserver

// serviceConfig 通过 DefaultServiceConfig 配置负载均衡、每方法超时与重试。
// 重试仅对幂等方法开启；maxAttempts 上限为 5。
const serviceConfig = `{
  "loadBalancingConfig": [{"round_robin": {}}],
  "healthCheckConfig": {"serviceName": ""},
  "methodConfig": [
    {
      "name": [
        {"service": "user.v1.UserService", "method": "GetUser"},
        {"service": "user.v1.UserService", "method": "ListUsers"}
      ],
      "timeout": "5s",
      "retryPolicy": {
        "maxAttempts": 3,
        "initialBackoff": "0.1s",
        "maxBackoff": "1s",
        "backoffMultiplier": 2,
        "retryableStatusCodes": ["UNAVAILABLE"]
      }
    },
    {
      "name": [{"service": "user.v1.UserService", "method": "CreateUser"}],
      "timeout": "10s"
    },
    {
      "name": [{"service": "user.v1.UserService"}],
      "timeout": "30s"
    }
  ]
}`
```

服务端也可通过 `grpc.MaxConcurrentStreams`、`grpc.MaxRecvMsgSize` 等 ServerOption 限制资源；
客户端 `grpc.WithDefaultCallOptions(grpc.MaxCallRecvMsgSize(n))` 调整消息大小上限。
