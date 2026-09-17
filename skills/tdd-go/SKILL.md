---
name: tdd-go
description: "Go TDD 工作流 - 严格 RED-GREEN-REFACTOR 循环：先写失败测试，再写最小实现，最后在测试保护下重构；主 Agent 写测试，golang-pro 子代理负责实现与重构。适用：新功能实现、Bug 修复（先写复现测试）、行为不变的重构、需要 -race 与 lint 双重把关的 Go 包开发。不适用：非 Go 项目、探索性原型（无稳定契约）、纯配置或文档改动、只需补测试不改实现（用 go-test）。触发词：tdd, TDD, 测试驱动, red green refactor, 先写测试, 失败测试, 最小实现, 重构, test first"
argument-hint: "[包路径或函数名，如 ./pkg/auth 或 pkg/auth.Login]"
---

# Go TDD 工作流

严格遵循 RED-GREEN-REFACTOR 循环的测试驱动开发。目标：$ARGUMENTS

## 前置条件

### 工具

| 工具 | 用途 | 检查命令 |
|------|------|---------|
| `go`（基线 go1.24.6） | 编译和测试 | `go version` |
| `golangci-lint` v2.8.0 | 代码质量检查 | `golangci-lint version` |
| `goimports` | import 整理（可选，缺失时降级到 gofmt） | `which goimports` |

### 组件依赖

| 组件 | 类型 | 必需 |
|------|------|------|
| `golang-pro` | Agent（`thoth:golang-pro`） | 是 |
| `go-test` | Skill | 是 |
| `go-format.sh` | Hook | 推荐 |
| `go-lint.sh` | Hook | 推荐 |
| `go-test-async.sh` | Hook | 推荐 |

## 适用场景

- 新功能实现
- Bug 修复（先写复现测试）
- 重构（确保行为不变）

## 流程定义

```
┌─────────────────────────────────────────────────┐
│  0. 需求理解                                     │
│     明确输入/输出/边界条件                         │
└──────────────────────┬──────────────────────────┘
                       ▼
┌─────────────────────────────────────────────────┐
│  1. RED: 写失败的测试                             │
│     • 表驱动测试 + t.Run subtests                 │
│     • 覆盖 happy path + 至少 2 个边界条件          │
│     • 运行: go test -race -count=1 ./pkg/...      │
│     • 确认测试失败 ✗                               │
└──────────────────────┬──────────────────────────┘
                       ▼
┌─────────────────────────────────────────────────┐
│  2. GREEN: 写最小实现                             │
│     • 只写让测试通过的代码                         │
│     • 不优化、不扩展                               │
│     • 运行: go test -race -count=1 ./pkg/...      │
│     • 确认测试通过 ✓                               │
└──────────────────────┬──────────────────────────┘
                       ▼
┌─────────────────────────────────────────────────┐
│  3. REFACTOR: 改进代码质量                        │
│     • 提取函数、减少重复、改善命名                   │
│     • 运行: golangci-lint run ./pkg/...           │
│     • 运行: go test -race -count=1 ./pkg/...      │
│     • 确认测试仍然通过 ✓                           │
└──────────────────────┬──────────────────────────┘
                       ▼
              ┌────────────────┐
              │  完成一个循环？  │
              │  还需要更多功能？│
              └────┬─────┬─────┘
                   │ 是  │ 否
                   ▼     ▼
              回到 RED   结束
```

## 使用的组件

| 组件 | 类型 | 用途 |
|------|------|------|
| `go-test` | Skill | 测试编写指导 |
| `golang-pro` | Agent | 代码实现与重构 |
| `go-format.sh` | Hook | 自动格式化 |
| `go-lint.sh` | Hook | 自动 lint |
| `go-test-async.sh` | Hook | 异步测试反馈 |

## 规则

1. **绝不**在测试之前写实现代码
2. **绝不**一次写超过一个测试用例的实现
3. 测试文件和实现文件在同一包内
4. 外部依赖（DB、HTTP、MQ）通过接口 mock
5. 安全的测试加 `t.Parallel()`
6. 测试函数命名：`Test<Function>_<Scenario>`
7. 基准测试用 `for b.Loop()`，不写 `for i := 0; i < b.N; i++`

## Agent 调用方式

TDD 工作流中，`golang-pro` 子代理负责 GREEN（实现）和 REFACTOR（重构）阶段，主循环由人工或主 Agent 驱动。

### 步骤 1：RED — 写失败测试（主 Agent / 人工）

直接使用 `go-test` Skill 编写测试，无需子代理：

```
参考 go-test Skill 中的表驱动测试模板，
为 pkg/xxx/yyy.go 中的 FuncName 编写测试。
覆盖：happy path、空输入、边界条件。
```

运行并确认测试失败：`go test -race -count=1 ./pkg/xxx/...`

### 步骤 2：GREEN — 最小实现（golang-pro 子代理）

用 Agent 工具调用 `thoth:golang-pro` 子代理，prompt 只描述任务与约束：

```
Agent(
  subagent_type = "thoth:golang-pro",
  prompt = """
  ## 任务

  为以下失败测试编写最小实现，仅让测试通过，不做额外优化。

  - 测试文件: pkg/xxx/yyy_test.go
  - 目标函数: FuncName
  - 当前测试输出: <粘贴失败输出>

  ## 约束
  - 只修改 pkg/xxx/yyy.go
  - 不修改测试文件
  - 实现后运行 go test -race -count=1 ./pkg/xxx/... 确认通过
  """
)
```

### 步骤 3：REFACTOR — 重构（golang-pro 子代理）

```
Agent(
  subagent_type = "thoth:golang-pro",
  prompt = """
  ## 任务

  重构 pkg/xxx/yyy.go，改进代码质量。

  ## 约束
  - 不改变外部行为（测试必须仍通过）
  - 运行 golangci-lint run ./pkg/xxx/... 确认无警告
  - 运行 go test -race -count=1 ./pkg/xxx/... 确认通过
  """
)
```

### 串联示例（完整一轮）

```
# 1. RED: 主 Agent 写测试
编写 pkg/breaker/breaker_test.go，测试 Open/HalfOpen/Closed 状态转换。

# 2. GREEN: 子代理实现
Agent(thoth:golang-pro) → 实现 breaker.go 最小逻辑

# 3. REFACTOR: 子代理重构
Agent(thoth:golang-pro) → 提取状态机、优化命名

# 4. 判断: 是否需要下一轮?
#    → 是: 回到 RED，增加超时/并发/指标等测试
#    → 否: 结束
```

## 测试模板

### 表驱动单元测试

```go
package pkg

import (
    "testing"

    "github.com/stretchr/testify/assert"
    "github.com/stretchr/testify/require"
)

func TestXxx(t *testing.T) {
    t.Parallel()

    tests := []struct {
        name    string
        input   InputType
        want    OutputType
        wantErr bool
    }{
        {
            name:  "happy path",
            input: validInput,
            want:  expectedOutput,
        },
        {
            name:    "empty input",
            input:   emptyInput,
            wantErr: true,
        },
        {
            name:    "boundary condition",
            input:   boundaryInput,
            want:    boundaryOutput,
        },
    }

    for _, tt := range tests {
        t.Run(tt.name, func(t *testing.T) {
            t.Parallel()
            got, err := Xxx(tt.input)
            if tt.wantErr {
                require.Error(t, err)
                return
            }
            require.NoError(t, err)
            assert.Equal(t, tt.want, got)
        })
    }
}
```

### 基准测试（REFACTOR 阶段性能敏感路径）

```go
func BenchmarkXxx(b *testing.B) {
    input := validInput
    b.ReportAllocs()

    for b.Loop() {
        _, _ = Xxx(input)
    }
}
```

运行：`go test -run '^$' -bench 'BenchmarkXxx' -benchmem ./pkg/xxx/...`。重构前后各跑一次，用 `benchstat` 比较。

## 参考

- go-test Skill：httptest、mock、testcontainers、fuzz、goleak 等完整示例
- https://pkg.go.dev/testing
