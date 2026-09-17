---
name: go-test
description: "Go 测试专家 - 表驱动测试、httptest HTTP测试、基准测试(b.Loop/benchmem)、模糊测试(fuzz)、mock生成(go.uber.org/mock)、testcontainers集成测试、golden files、goroutine泄漏检测(goleak)、testify断言。适用：编写单元/集成测试、修复失败测试、提高覆盖率、性能基准测试、TDD开发。不适用：非Go语言测试、E2E端到端测试(应使用专用框架)、纯手动QA测试流程。触发词：go test, 测试, test, 表驱动, table driven, benchmark, 基准测试, fuzz, mock, mockgen, testcontainers, 覆盖率, coverage, httptest, goleak"
---

# Go 测试专家

为 Go 代码编写高质量测试：$ARGUMENTS

---

## 0. 版本基线

- Go：go1.24.6。可用 `for b.Loop()`、`t.Context()`、`t.Chdir()`、`testing.B.Loop` 自动排除 setup 时间。
- `testing/synctest` 在 Go 1.24 仅为实验特性，需 `GOEXPERIMENT=synctest`，本 skill 不依赖它。
- 库版本：`github.com/stretchr/testify v1.12.1`、`go.uber.org/mock v0.6.0`、`go.uber.org/goleak v1.3.0`、
  `github.com/testcontainers/testcontainers-go v0.40.0`（及 `modules/postgres` 同版本）。

---

## 1. 表驱动测试（必须使用）

对于任何逻辑函数，使用表驱动模式，易于扩展。

```go
import (
    "math"
    "testing"
)

func TestAdd(t *testing.T) {
    tests := []struct {
        name    string
        a, b    int
        want    int
        wantErr bool
    }{
        {"positive", 1, 2, 3, false},
        {"negative", -1, -1, -2, false},
        {"overflow", math.MaxInt, 1, 0, true},
    }

    for _, tt := range tests {
        t.Run(tt.name, func(t *testing.T) {
            got, err := Add(tt.a, tt.b)
            if (err != nil) != tt.wantErr {
                t.Fatalf("Add() error = %v, wantErr %v", err, tt.wantErr)
            }
            if got != tt.want {
                t.Errorf("Add() = %v, want %v", got, tt.want)
            }
        })
    }
}
```

### 测试覆盖率目标
- 核心业务逻辑：≥95%
- 整体覆盖率：≥90%
- 必须覆盖：正常路径、边界条件、错误路径

### 测试命名规范
- 函数：`Test<Function>_<Scenario>`
- 子测试：清晰描述意图
- 示例：`TestParse_EmptyInput`, `TestConnect_Timeout`

---

## 2. HTTP 测试（httptest）

**不要**启动完整服务器，直接测试 handler。

```go
import (
    "encoding/json"
    "net/http"
    "net/http/httptest"
    "strings"
    "testing"
)

func TestHandleCreateUser(t *testing.T) {
    srv := NewServer(mockDB, mockLogger) // 注入 mock 依赖

    body := `{"name":"Alice","email":"alice@example.com"}`
    req := httptest.NewRequest(http.MethodPost, "/users", strings.NewReader(body))
    req.Header.Set("Content-Type", "application/json")
    w := httptest.NewRecorder()

    srv.ServeHTTP(w, req) // 直接调用 handler

    if w.Code != http.StatusCreated {
        t.Fatalf("expected status 201, got %d", w.Code)
    }

    var resp User
    if err := json.NewDecoder(w.Body).Decode(&resp); err != nil {
        t.Fatalf("decode response: %v", err)
    }
    if resp.Name != "Alice" {
        t.Errorf("expected name Alice, got %s", resp.Name)
    }
}
```

---

## 3. 基准测试（Benchmarking）

Go 1.24 使用 `for b.Loop()`：setup 自动排除在计时之外，且编译器不会把被测调用优化掉，不再需要 `b.ResetTimer()` 和 sink 变量。

```go
import (
    "strings"
    "testing"
)

func BenchmarkMatch(b *testing.B) {
    input := strings.Repeat("a", 1000) // setup 不计入计时

    for b.Loop() {
        Match(input)
    }
}

// 带内存分配统计
func BenchmarkWithAllocs(b *testing.B) {
    b.ReportAllocs()
    for b.Loop() {
        ProcessData(largeInput)
    }
}

// 并行基准测试（RunParallel 仍使用 pb.Next）
func BenchmarkParallel(b *testing.B) {
    b.RunParallel(func(pb *testing.PB) {
        for pb.Next() {
            DoWork()
        }
    })
}
```

**运行**：`go test -bench=. -benchmem ./...`

**分析指标**：
- `ns/op` — 每次操作耗时
- `B/op` — 每次操作分配字节数
- `allocs/op` — 每次操作分配次数（热路径目标：0）

---

## 4. 模糊测试（Fuzz Testing）

发现边界情况和崩溃。

```go
import (
    "reflect"
    "testing"
)

func FuzzParser(f *testing.F) {
    // 添加种子语料
    f.Add("valid input")
    f.Add("")
    f.Add("special\x00chars")

    f.Fuzz(func(t *testing.T, input string) {
        // 1. 不应该 panic
        res, err := Parse(input)

        // 2. 不变性检查
        if err == nil && res == nil {
            t.Errorf("res is nil but err is nil")
        }

        // 3. 往返检查（如适用）
        if err == nil {
            encoded := Encode(res)
            decoded, _ := Parse(encoded)
            if !reflect.DeepEqual(res, decoded) {
                t.Errorf("roundtrip failed")
            }
        }
    })
}
```

**运行**：`go test -fuzz=FuzzParser -fuzztime=30s ./...`

**目标**：崩溃韧性、不变性验证

---

## 5. Mock 生成与使用

### 使用 go.uber.org/mock v0.6.0

用 go.mod `tool` 指令固定 `mockgen` 版本，团队成员无需各自 `go install`。

```bash
# 注册为模块工具（写入 go.mod 的 tool 指令）
go get -tool go.uber.org/mock/mockgen@v0.6.0

# 生成 mock
go tool mockgen -source=interface.go -destination=mock_interface.go -package=pkg
```

```go
//go:generate go tool mockgen -source=interface.go -destination=mock_interface.go -package=pkg
```

### Mock 使用示例

`gomock.NewController(t)` 会通过 `t.Cleanup` 自动调用 `Finish`，不需要再 `defer ctrl.Finish()`。

```go
import (
    "testing"

    "github.com/stretchr/testify/assert"
    "github.com/stretchr/testify/require"
    "go.uber.org/mock/gomock"
)

func TestServiceWithMock(t *testing.T) {
    ctrl := gomock.NewController(t)
    mockRepo := NewMockUserRepository(ctrl)

    // 设置期望
    mockRepo.EXPECT().
        FindByID(gomock.Any(), "user-123").
        Return(&User{ID: "user-123", Name: "Alice"}, nil).
        Times(1)

    svc := NewUserService(mockRepo)

    user, err := svc.GetUser(t.Context(), "user-123")
    require.NoError(t, err)
    assert.Equal(t, "Alice", user.Name)
}
```

---

## 6. 集成测试（testcontainers）

使用真实依赖进行集成测试。testcontainers-go v0.40.0：模块入口是 `postgres.Run`，清理用
`testcontainers.CleanupContainer(t, ctr)`（注册到 `t.Cleanup`，容器为 nil 时安全）。

```go
//go:build integration

package user_test

import (
    "context"
    "testing"

    "github.com/stretchr/testify/assert"
    "github.com/stretchr/testify/require"
    "github.com/testcontainers/testcontainers-go"
    "github.com/testcontainers/testcontainers-go/modules/postgres"
)

func TestUserRepository_Integration(t *testing.T) {
    ctx := context.Background()

    // 启动 PostgreSQL 容器
    pgC, err := postgres.Run(ctx,
        "postgres:16-alpine",
        postgres.WithDatabase("testdb"),
        postgres.WithUsername("test"),
        postgres.WithPassword("test"),
        postgres.BasicWaitStrategies(),
    )
    testcontainers.CleanupContainer(t, pgC)
    require.NoError(t, err)

    // 获取连接字符串
    connStr, err := pgC.ConnectionString(ctx, "sslmode=disable")
    require.NoError(t, err)

    // 创建仓库并测试
    repo := NewUserRepository(connStr)

    user := &User{Name: "Alice"}
    err = repo.Create(ctx, user)
    require.NoError(t, err)
    assert.NotEmpty(t, user.ID)
}
```

**运行**：`go test -tags=integration ./...`

注意：`CleanupContainer` 放在 `require.NoError` 之前，`Run` 失败时也能回收已创建的容器。

依赖提示：testcontainers-go v0.40.0 经 otel 导出器间接依赖 grpc-gateway，`go mod tidy` 可能选中要求更新工具链的版本；
此时执行 `go get github.com/grpc-ecosystem/grpc-gateway/v2@v2.27.1` 固定即可。

---

## 7. 高级测试模式

- **Golden Files**：复杂输出（HTML、JSON）与 `testdata/*.golden` 比对，`-update` flag 重新生成，写文件错误必须检查。
- **子进程测试**：用 `GO_WANT_HELPER_PROCESS` 环境变量让测试二进制自身充当被调用命令，`exec.CommandContext(t.Context(), os.Args[0], "-test.run=^TestX$")`。
- **测试 Helper**：`t.Helper()` 让失败定位到调用处，资源用 `t.Cleanup` 释放，避免 `defer` 漏掉子测试。

> 完整代码见 [references/advanced.md](references/advanced.md)

---

## 8. 测试辅助工具

### testify 断言（v1.12.1）

```go
import (
    "github.com/stretchr/testify/assert"
    "github.com/stretchr/testify/require"
)

func TestExample(t *testing.T) {
    // assert：失败后继续
    assert.Equal(t, expected, actual)
    assert.NoError(t, err)
    assert.Contains(t, slice, element)
    assert.Len(t, items, 3)

    // require：失败后立即停止
    require.NotNil(t, obj)
    require.NoError(t, err)
}
```

### goroutine 泄漏检测（goleak v1.3.0）

```go
import (
    "testing"

    "go.uber.org/goleak"
)

func TestMain(m *testing.M) {
    goleak.VerifyTestMain(m)
}

// 或单个测试
func TestNoLeak(t *testing.T) {
    defer goleak.VerifyNone(t)
    // 测试代码
}
```

---

## 9. 测试执行策略

### 并行测试

```go
func TestParallel(t *testing.T) {
    t.Parallel() // 声明可并行

    // 不共享全局状态的测试
}
```

### 黑盒测试

```go
// 使用 _test 后缀强制只用导出 API
package user_test

import (
    "testing"

    "myapp/user"
)

func TestUser(t *testing.T) {
    u := user.New("Alice") // 只能访问导出的
    _ = u
}
```

---

## 10. 质量门禁（Definition of Done）

**任务完成前必须满足**：

1. **编译通过**：`go build ./...`
2. **测试通过**：`go test -race ./...`
3. **Lint 通过**：`golangci-lint run ./...`（v2.8.0，配置 `version: "2"`）
4. **二进制可运行**：`go build -o app ./cmd/... && ./app --help`
5. **回归检查**：运行所有测试，不仅是新增的

---

## 测试工作流

### 修复 Bug

1. **复现**：创建一个失败的测试用例
2. **验证红**：运行测试确认失败
3. **修复**：修改代码
4. **验证绿**：运行测试确认通过
5. **回归**：运行所有相关测试

### 新功能

1. **设计**：定义接口和行为
2. **测试先行**：编写测试用例
3. **实现**：编写代码使测试通过
4. **重构**：优化代码，保持测试绿色

---

## 常用命令

```bash
# 运行所有测试
go test ./...

# 带竞态检测
go test -race ./...

# 运行特定测试
go test -v -run TestFunctionName ./pkg/...

# 覆盖率
go test -coverprofile=coverage.out ./...
go tool cover -html=coverage.out -o coverage.html

# 基准测试
go test -bench=. -benchmem ./...

# 模糊测试
go test -fuzz=FuzzName -fuzztime=30s ./...

# 集成测试
go test -tags=integration ./...
```

---

## 测试检查清单

- [ ] 正常路径（happy path）
- [ ] 边界条件（空值、零值、最大值）
- [ ] 错误处理路径
- [ ] 并发安全性（-race）
- [ ] 资源清理（t.Cleanup）
- [ ] 超时和取消（context / t.Context()）
- [ ] 无 goroutine 泄漏（goleak）

## 参考资料

- [references/advanced.md](references/advanced.md) - Golden files、子进程测试、测试 Helper 完整代码
- [testing 包文档](https://pkg.go.dev/testing)
- [go.uber.org/mock](https://pkg.go.dev/go.uber.org/mock/gomock)
- [testcontainers-go](https://pkg.go.dev/github.com/testcontainers/testcontainers-go)
- [testify](https://pkg.go.dev/github.com/stretchr/testify)
- [goleak](https://pkg.go.dev/go.uber.org/goleak)
