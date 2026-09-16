# Go gRPC - 完整代码示例

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

option go_package = "github.com/example/api/user/v1;userv1";

import "google/protobuf/timestamp.proto";
import "google/protobuf/empty.proto";

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

```bash
# 安装插件
go install google.golang.org/protobuf/cmd/protoc-gen-go@latest
go install google.golang.org/grpc/cmd/protoc-gen-go-grpc@latest

# 生成代码
protoc --go_out=. --go_opt=paths=source_relative \
       --go-grpc_out=. --go-grpc_opt=paths=source_relative \
       api/user/v1/*.proto
```

---

## 服务端实现

```go
package server

import (
    "context"

    "google.golang.org/grpc/codes"
    "google.golang.org/grpc/status"
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
    if req.Id == "" {
        return nil, status.Error(codes.InvalidArgument, "id is required")
    }

    user, err := s.repo.GetByID(ctx, req.Id)
    if err != nil {
        if errors.Is(err, ErrNotFound) {
            return nil, status.Error(codes.NotFound, "user not found")
        }
        return nil, status.Error(codes.Internal, "failed to get user")
    }

    return &userv1.GetUserResponse{
        User: toProtoUser(user),
    }, nil
}

// Server streaming
func (s *UserServer) ListUsers(req *userv1.ListUsersRequest, stream userv1.UserService_ListUsersServer) error {
    ctx := stream.Context()

    users, err := s.repo.List(ctx, int(req.PageSize), req.PageToken)
    if err != nil {
        return status.Error(codes.Internal, "failed to list users")
    }

    for _, user := range users {
        if err := stream.Send(toProtoUser(user)); err != nil {
            return err
        }
    }

    return nil
}

// Client streaming
func (s *UserServer) BatchCreateUsers(stream userv1.UserService_BatchCreateUsersServer) error {
    ctx := stream.Context()
    var count int32

    for {
        req, err := stream.Recv()
        if err == io.EOF {
            return stream.SendAndClose(&userv1.BatchCreateUsersResponse{
                CreatedCount: count,
            })
        }
        if err != nil {
            return err
        }

        if err := s.repo.Create(ctx, req.Name, req.Email); err != nil {
            return status.Error(codes.Internal, "failed to create user")
        }
        count++
    }
}

// Bidirectional streaming
func (s *UserServer) Chat(stream userv1.UserService_ChatServer) error {
    for {
        msg, err := stream.Recv()
        if err == io.EOF {
            return nil
        }
        if err != nil {
            return err
        }

        // Echo back
        response := &userv1.ChatMessage{
            UserId:    "server",
            Content:   "Echo: " + msg.Content,
            Timestamp: timestamppb.Now(),
        }

        if err := stream.Send(response); err != nil {
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
```

---

## 启动服务

```go
func main() {
    lis, err := net.Listen("tcp", ":50051")
    if err != nil {
        log.Fatalf("failed to listen: %v", err)
    }

    server := grpc.NewServer(
        grpc.ChainUnaryInterceptor(
            LoggingInterceptor(),
            RecoveryInterceptor(),
            TracingInterceptor(),
        ),
        grpc.ChainStreamInterceptor(
            StreamLoggingInterceptor(),
            StreamRecoveryInterceptor(),
        ),
    )

    userv1.RegisterUserServiceServer(server, NewUserServer(repo))

    // 注册反射服务（调试用）
    reflection.Register(server)

    log.Printf("server listening at %v", lis.Addr())
    if err := server.Serve(lis); err != nil {
        log.Fatalf("failed to serve: %v", err)
    }
}
```

---

## 客户端实现

### 创建客户端

```go
func NewUserClient(target string) (userv1.UserServiceClient, func(), error) {
    conn, err := grpc.NewClient(target,
        grpc.WithTransportCredentials(insecure.NewCredentials()),
        grpc.WithChainUnaryInterceptor(
            ClientLoggingInterceptor(),
            ClientTracingInterceptor(),
        ),
        grpc.WithDefaultServiceConfig(`{
            "loadBalancingConfig": [{"round_robin":{}}],
            "methodConfig": [{
                "name": [{"service": "user.v1.UserService"}],
                "timeout": "5s",
                "retryPolicy": {
                    "maxAttempts": 3,
                    "initialBackoff": "0.1s",
                    "maxBackoff": "1s",
                    "backoffMultiplier": 2,
                    "retryableStatusCodes": ["UNAVAILABLE", "DEADLINE_EXCEEDED"]
                }
            }]
        }`),
    )
    if err != nil {
        return nil, nil, fmt.Errorf("dial: %w", err)
    }

    cleanup := func() { conn.Close() }

    return userv1.NewUserServiceClient(conn), cleanup, nil
}
```

### 调用示例

```go
// Unary
func GetUser(ctx context.Context, client userv1.UserServiceClient, id string) (*userv1.User, error) {
    resp, err := client.GetUser(ctx, &userv1.GetUserRequest{Id: id})
    if err != nil {
        return nil, err
    }
    return resp.User, nil
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
        if err == io.EOF {
            break
        }
        if err != nil {
            return nil, err
        }
        users = append(users, user)
    }

    return users, nil
}

// Client streaming
func BatchCreate(ctx context.Context, client userv1.UserServiceClient, users []CreateUserInput) (int32, error) {
    stream, err := client.BatchCreateUsers(ctx)
    if err != nil {
        return 0, err
    }

    for _, u := range users {
        if err := stream.Send(&userv1.CreateUserRequest{
            Name:  u.Name,
            Email: u.Email,
        }); err != nil {
            return 0, err
        }
    }

    resp, err := stream.CloseAndRecv()
    if err != nil {
        return 0, err
    }

    return resp.CreatedCount, nil
}
```

---

## 拦截器实现

### Unary 服务端拦截器

```go
// 日志拦截器
func LoggingInterceptor() grpc.UnaryServerInterceptor {
    return func(ctx context.Context, req any, info *grpc.UnaryServerInfo, handler grpc.UnaryHandler) (any, error) {
        start := time.Now()

        resp, err := handler(ctx, req)

        duration := time.Since(start)
        code := status.Code(err)

        slog.InfoContext(ctx, "grpc request",
            slog.String("method", info.FullMethod),
            slog.String("code", code.String()),
            slog.Duration("duration", duration),
        )

        return resp, err
    }
}

// 恢复拦截器
func RecoveryInterceptor() grpc.UnaryServerInterceptor {
    return func(ctx context.Context, req any, info *grpc.UnaryServerInfo, handler grpc.UnaryHandler) (resp any, err error) {
        defer func() {
            if r := recover(); r != nil {
                slog.ErrorContext(ctx, "panic recovered",
                    slog.Any("panic", r),
                    slog.String("stack", string(debug.Stack())),
                )
                err = status.Error(codes.Internal, "internal error")
            }
        }()

        return handler(ctx, req)
    }
}

// 认证拦截器
func AuthInterceptor(validator TokenValidator) grpc.UnaryServerInterceptor {
    return func(ctx context.Context, req any, info *grpc.UnaryServerInfo, handler grpc.UnaryHandler) (any, error) {
        // 跳过公开方法
        if isPublicMethod(info.FullMethod) {
            return handler(ctx, req)
        }

        md, ok := metadata.FromIncomingContext(ctx)
        if !ok {
            return nil, status.Error(codes.Unauthenticated, "missing metadata")
        }

        tokens := md.Get("authorization")
        if len(tokens) == 0 {
            return nil, status.Error(codes.Unauthenticated, "missing token")
        }

        claims, err := validator.Validate(tokens[0])
        if err != nil {
            return nil, status.Error(codes.Unauthenticated, "invalid token")
        }

        // 注入用户信息到 context
        ctx = context.WithValue(ctx, userClaimsKey, claims)

        return handler(ctx, req)
    }
}
```

### Stream 服务端拦截器

```go
func StreamLoggingInterceptor() grpc.StreamServerInterceptor {
    return func(srv any, ss grpc.ServerStream, info *grpc.StreamServerInfo, handler grpc.StreamHandler) error {
        start := time.Now()

        err := handler(srv, ss)

        duration := time.Since(start)
        code := status.Code(err)

        slog.Info("grpc stream",
            slog.String("method", info.FullMethod),
            slog.String("code", code.String()),
            slog.Duration("duration", duration),
        )

        return err
    }
}

// 包装 Stream 以拦截消息
type wrappedStream struct {
    grpc.ServerStream
    ctx context.Context
}

func (w *wrappedStream) Context() context.Context {
    return w.ctx
}

func (w *wrappedStream) RecvMsg(m any) error {
    // 可在此处拦截接收的消息
    return w.ServerStream.RecvMsg(m)
}

func (w *wrappedStream) SendMsg(m any) error {
    // 可在此处拦截发送的消息
    return w.ServerStream.SendMsg(m)
}
```

### 客户端拦截器

```go
func ClientLoggingInterceptor() grpc.UnaryClientInterceptor {
    return func(ctx context.Context, method string, req, reply any, cc *grpc.ClientConn, invoker grpc.UnaryInvoker, opts ...grpc.CallOption) error {
        start := time.Now()

        err := invoker(ctx, method, req, reply, cc, opts...)

        duration := time.Since(start)
        code := status.Code(err)

        slog.InfoContext(ctx, "grpc client call",
            slog.String("method", method),
            slog.String("code", code.String()),
            slog.Duration("duration", duration),
        )

        return err
    }
}

// 自动注入元数据
func ClientMetadataInterceptor() grpc.UnaryClientInterceptor {
    return func(ctx context.Context, method string, req, reply any, cc *grpc.ClientConn, invoker grpc.UnaryInvoker, opts ...grpc.CallOption) error {
        // 从 context 获取元数据并传播
        md := metadata.Pairs(
            "x-request-id", GetRequestID(ctx),
            "x-tenant-id", GetTenantID(ctx),
        )
        ctx = metadata.NewOutgoingContext(ctx, md)

        return invoker(ctx, method, req, reply, cc, opts...)
    }
}
```

---

## 错误处理实现

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

func ToGRPCError(err error) error {
    if err == nil {
        return nil
    }

    // 已经是 gRPC 错误
    if _, ok := status.FromError(err); ok {
        return err
    }

    // 映射领域错误
    for domainErr, code := range domainToGRPC {
        if errors.Is(err, domainErr) {
            return status.Error(code, err.Error())
        }
    }

    // 默认为内部错误
    return status.Error(codes.Internal, "internal error")
}
```

### 错误详情

```go
import (
    "google.golang.org/genproto/googleapis/rpc/errdetails"
    "google.golang.org/grpc/status"
)

func ValidationError(field, description string) error {
    st := status.New(codes.InvalidArgument, "validation failed")

    st, err := st.WithDetails(&errdetails.BadRequest{
        FieldViolations: []*errdetails.BadRequest_FieldViolation{
            {
                Field:       field,
                Description: description,
            },
        },
    })
    if err != nil {
        return status.Error(codes.InvalidArgument, "validation failed")
    }

    return st.Err()
}

// 客户端处理
func HandleError(err error) {
    st, ok := status.FromError(err)
    if !ok {
        log.Printf("unknown error: %v", err)
        return
    }

    log.Printf("gRPC error: code=%s message=%s", st.Code(), st.Message())

    for _, detail := range st.Details() {
        switch d := detail.(type) {
        case *errdetails.BadRequest:
            for _, v := range d.FieldViolations {
                log.Printf("  field %s: %s", v.Field, v.Description)
            }
        case *errdetails.RetryInfo:
            log.Printf("  retry after: %s", d.RetryDelay.AsDuration())
        }
    }
}
```

---

## 元数据传播实现

### 服务端提取

```go
func ExtractMetadata(ctx context.Context) (requestID, tenantID string) {
    md, ok := metadata.FromIncomingContext(ctx)
    if !ok {
        return "", ""
    }

    if vals := md.Get("x-request-id"); len(vals) > 0 {
        requestID = vals[0]
    }
    if vals := md.Get("x-tenant-id"); len(vals) > 0 {
        tenantID = vals[0]
    }

    return
}
```

### 服务端注入响应头

```go
func (s *UserServer) GetUser(ctx context.Context, req *userv1.GetUserRequest) (*userv1.GetUserResponse, error) {
    // 发送响应头
    header := metadata.Pairs("x-custom-header", "value")
    grpc.SendHeader(ctx, header)

    // 发送 trailer
    trailer := metadata.Pairs("x-request-duration", "100ms")
    grpc.SetTrailer(ctx, trailer)

    // ... 业务逻辑
    return resp, nil
}
```

### 客户端接收响应头

```go
var header, trailer metadata.MD

resp, err := client.GetUser(ctx, req,
    grpc.Header(&header),
    grpc.Trailer(&trailer),
)

if customHeader := header.Get("x-custom-header"); len(customHeader) > 0 {
    log.Printf("custom header: %s", customHeader[0])
}
```

---

## 健康检查实现

```go
import (
    "google.golang.org/grpc/health"
    "google.golang.org/grpc/health/grpc_health_v1"
)

func main() {
    server := grpc.NewServer()

    // 注册健康检查服务
    healthServer := health.NewServer()
    grpc_health_v1.RegisterHealthServer(server, healthServer)

    // 设置服务状态
    healthServer.SetServingStatus("user.v1.UserService", grpc_health_v1.HealthCheckResponse_SERVING)

    // 动态更新状态（使用 context 控制生命周期，避免 goroutine 泄漏）
    ctx, cancel := context.WithCancel(context.Background())
    defer cancel() // 在 main 退出时取消
    go func() {
        ticker := time.NewTicker(10 * time.Second)
        defer ticker.Stop()
        for {
            select {
            case <-ctx.Done():
                return
            case <-ticker.C:
                if dbHealthy() {
                    healthServer.SetServingStatus("", grpc_health_v1.HealthCheckResponse_SERVING)
                } else {
                    healthServer.SetServingStatus("", grpc_health_v1.HealthCheckResponse_NOT_SERVING)
                }
            }
        }
    }()
}
```

---

## 优雅关闭实现

```go
func main() {
    server := grpc.NewServer()

    // 注册服务...

    // 启动服务
    go func() {
        if err := server.Serve(lis); err != nil {
            log.Fatalf("failed to serve: %v", err)
        }
    }()

    // 等待中断信号
    quit := make(chan os.Signal, 1)
    signal.Notify(quit, syscall.SIGINT, syscall.SIGTERM)
    <-quit

    log.Println("shutting down server...")

    // 优雅关闭（等待现有请求完成）
    stopped := make(chan struct{})
    go func() {
        server.GracefulStop()
        close(stopped)
    }()

    // 超时强制关闭
    select {
    case <-stopped:
        log.Println("server stopped gracefully")
    case <-time.After(30 * time.Second):
        log.Println("server forced to stop")
        server.Stop()
    }
}
```

---

## 服务配置实现

```go
// 通过 DefaultServiceConfig
serviceConfig := `{
    "loadBalancingConfig": [{"round_robin":{}}],
    "methodConfig": [{
        "name": [
            {"service": "user.v1.UserService", "method": "GetUser"},
            {"service": "user.v1.UserService", "method": "CreateUser"}
        ],
        "timeout": "5s",
        "retryPolicy": {
            "maxAttempts": 3,
            "initialBackoff": "0.1s",
            "maxBackoff": "1s",
            "backoffMultiplier": 2,
            "retryableStatusCodes": ["UNAVAILABLE"]
        }
    }, {
        "name": [{"service": "user.v1.UserService", "method": "ListUsers"}],
        "timeout": "30s"
    }]
}`

conn, err := grpc.NewClient(target,
    grpc.WithDefaultServiceConfig(serviceConfig),
)
```
