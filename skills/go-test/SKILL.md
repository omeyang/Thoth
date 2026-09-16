---
name: go-test
description: "Go 测试专家 - 表驱动测试、httptest HTTP测试、基准测试(benchmem)、模糊测试(fuzz)、mock生成(gomock)、testcontainers集成测试、golden files、goroutine泄漏检测(goleak)、testify断言。适用：编写单元/集成测试、修复失败测试、提高覆盖率、性能基准测试、TDD开发。不适用：非Go语言测试、E2E端到端测试(应使用专用框架)、纯手动QA测试流程。触发词：go test, 测试, test, 表驱动, table driven, benchmark, 基准测试, fuzz, mock, testcontainers, 覆盖率, coverage, httptest, goleak"
user-invocable: true
allowed-tools: Bash, Read, Write, Edit, Grep, Glob
---

# Go 测试专家

为 Go 代码编写高质量测试：$ARGUMENTS

---

## 1. 表驱动测试（必须使用）

对于任何逻辑函数，使用表驱动模式，易于扩展。

```go
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
func TestHandleCreateUser(t *testing.T) {
    // 注入 mock 依赖
    srv := NewServer(mockDB, mockLogger)

    // 构造请求
    body := `{"name":"Alice","email":"alice@example.com"}`
    req := httptest.NewRequest("POST", "/users", strings.NewReader(body))
    req.Header.Set("Content-Type", "application/json")

    // 记录响应
    w := httptest.NewRecorder()

    // 直接调用 handler
    srv.ServeHTTP(w, req)

    // 断言
    if w.Code != http.StatusCreated {
        t.Errorf("expected status 201, got %d", w.Code)
    }

    // 验证响应体
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

验证性能优化效果。

```go
func BenchmarkMatch(b *testing.B) {
    input := strings.Repeat("a", 1000)
    b.ResetTimer() // 重置计时器，排除 setup 时间

    for i := 0; i < b.N; i++ {
        Match(input)
    }
}

// 带内存分配统计
func BenchmarkWithAllocs(b *testing.B) {
    b.ReportAllocs()
    for i := 0; i < b.N; i++ {
        ProcessData(largeInput)
    }
}

// 并行基准测试
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

### 使用 go.uber.org/mock

```bash
# 生成 mock
mockgen -source=interface.go -destination=mock_interface.go -package=pkg

# 或使用 go:generate
//go:generate mockgen -source=interface.go -destination=mock_interface.go -package=pkg
```

### Mock 使用示例

```go
func TestServiceWithMock(t *testing.T) {
    ctrl := gomock.NewController(t)
    defer ctrl.Finish()

    mockRepo := NewMockUserRepository(ctrl)

    // 设置期望
    mockRepo.EXPECT().
        FindByID(gomock.Any(), "user-123").
        Return(&User{ID: "user-123", Name: "Alice"}, nil).
        Times(1)

    // 注入 mock
    svc := NewUserService(mockRepo)

    // 测试
    user, err := svc.GetUser(context.Background(), "user-123")
    require.NoError(t, err)
    assert.Equal(t, "Alice", user.Name)
}
```

---

## 6. 集成测试（testcontainers）

使用真实依赖进行集成测试。

```go
//go:build integration

package user_test

import (
    "context"
    "testing"

    "github.com/testcontainers/testcontainers-go"
    "github.com/testcontainers/testcontainers-go/modules/postgres"
)

func TestUserRepository_Integration(t *testing.T) {
    ctx := context.Background()

    // 启动 PostgreSQL 容器
    pgC, err := postgres.Run(ctx,
        "postgres:16",
        postgres.WithDatabase("testdb"),
        postgres.WithUsername("test"),
        postgres.WithPassword("test"),
    )
    require.NoError(t, err)
    defer pgC.Terminate(ctx)

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

---

## 7. 高级测试模式

### Golden Files（黄金文件）

适合复杂输出（HTML、JSON）的测试。

```go
var update = flag.Bool("update", false, "update golden files")

func TestRender(t *testing.T) {
    got := Render(input)
    golden := filepath.Join("testdata", t.Name()+".golden")

    if *update {
        os.WriteFile(golden, got, 0644)
        return
    }

    want, err := os.ReadFile(golden)
    require.NoError(t, err)

    if !bytes.Equal(got, want) {
        t.Errorf("output mismatch, run with -update to update golden file")
    }
}
```

**更新**：`go test -update ./...`

### 子进程测试（exec.Command）

测试调用外部命令的代码。

```go
func TestCommand(t *testing.T) {
    if os.Getenv("GO_WANT_HELPER_PROCESS") == "1" {
        // 这是子进程，模拟命令输出
        fmt.Println("mocked output")
        os.Exit(0)
    }

    // 主测试进程
    cmd := exec.Command(os.Args[0], "-test.run=TestCommand")
    cmd.Env = append(os.Environ(), "GO_WANT_HELPER_PROCESS=1")

    output, err := cmd.Output()
    require.NoError(t, err)
    assert.Contains(t, string(output), "mocked output")
}
```

### 测试 Helper

```go
func setupTestDB(t *testing.T) *sql.DB {
    t.Helper() // 错误报告在调用处

    db, err := sql.Open("sqlite3", ":memory:")
    require.NoError(t, err)

    t.Cleanup(func() {
        db.Close()
    })

    return db
}
```

---

## 8. 测试辅助工具

### testify 断言

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

### goroutine 泄漏检测

```go
import "go.uber.org/goleak"

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

import "myapp/user"

func TestUser(t *testing.T) {
    u := user.New("Alice") // 只能访问导出的
}
```

---

## 10. 质量门禁（Definition of Done）

**任务完成前必须满足**：

1. **编译通过**：`go build ./...`
2. **测试通过**：`go test -race ./...`
3. **Lint 通过**：`golangci-lint run ./...`
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
- [ ] 超时和取消（context）
- [ ] 无 goroutine 泄漏（goleak）
