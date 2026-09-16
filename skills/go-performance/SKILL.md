---
name: go-performance
description: "Go 性能优化工作台（Go 1.25.9+ 基线）- 决策优先的性能任务 runbook：基准测试（for b.Loop）、pprof/trace/flight recorder、逃逸分析、内联、内存对齐、sync.Pool、零分配模式（unsafe.String/Slice）、weak.Pointer 缓存、GOMEMLIMIT/容器感知 GOMAXPROCS、PGO、Green Tea GC、编译产物瘦身。适用：代码路径性能调优、内存/CPU 瓶颈定位、高吞吐服务调参、基准回归分析、降低 GC 压力、减小二进制体积。不适用：算法选型（用 algorithms）、业务架构重构（用 backend-patterns）、未测量前的预优化（违反决策优先原则）、运行时原理学习（用 go-runtime）。触发词：performance, 性能, optimize, 优化, benchmark, 基准, pprof, profile, profiling, escape analysis, 逃逸分析, inline, 内联, 内存对齐, alignment, fieldalignment, sync.Pool, 零分配, allocation, zero-alloc, PGO, GOMEMLIMIT, GOMAXPROCS, trace, flight recorder, synctest, weak pointer, 瓶颈, 调优, ldflags"
user-invocable: true
allowed-tools: Bash, Read, Write, Edit, Grep, Glob
---

# Go 性能优化工作台

执行性能优化任务：$ARGUMENTS

**基线 Go 1.25.9+。示例默认用最新语法；旧写法仅在对比中出现。**

---

## 决策优先：先别优化

任何"优化这段代码"的请求，必须先走这三步，跳过任何一步都不合格：

1. **有 benchmark 吗？** 没有 → 先写 baseline（§1）
2. **有 profile 证据吗？** 没有 → 先 pprof/trace（§2）
3. **有数字目标吗？** 没有 → 明确"X µs/op → Y µs/op"

**禁止预优化**。任何改动必须有 `benchstat` 前后对比（p<0.05，幅度≥3%）。

### 诊断决策树

```
收到"优化 X"请求
├─ 有 baseline benchmark？ 无 → §1
├─ 有 profile 证据？       无 → §2
├─ 热点属于哪一类？
│   ├─ CPU 热点     → §3 逃逸/内联/算法
│   ├─ 分配热点     → §4 sync.Pool/预分配/unsafe/weak
│   ├─ 锁/并发      → §5 sync 选型/atomic COW/synctest
│   ├─ GC 停顿      → §6 GOMEMLIMIT/对齐/Green Tea
│   └─ 启动/镜像    → §7 ldflags/PGO
└─ 必做：benchstat + profile 前后对比 + 正确性回归
```

---

## §1 基准测试 —— Go 1.24+ `for b.Loop()` 是新默认

**新代码必须用 `for b.Loop()`**。它解决旧写法两大坑：编译器不 DCE 循环体；setup/teardown 自动排除。

```go
func BenchmarkParse(b *testing.B) {
    data := loadTestData()      // setup 自动排除
    b.ReportAllocs()
    for b.Loop() {              // Go 1.24+
        _, _ = Parse(data)
    }
}
```

反模式（Go 1.23 及以前）：

```go
// 编译器可能消除无副作用调用；setup 放错位置进入循环
for i := 0; i < b.N; i++ { _, _ = Parse(data) }
```

### 基准矩阵（规模 × 实现）

用 `b.Run` 两层嵌套：外层规模（100 / 10k / 1M），内层候选实现，每 iter 内 `StopTimer/StartTimer` 排除数据生成。完整样板见 `go-test` 技能的"基准矩阵"章节。

### benchstat 对比（优化验证唯一权威）

```bash
go test -run=^$ -bench=BenchmarkParse -count=10 -benchmem > old.txt
# --- 修改 ---
go test -run=^$ -bench=BenchmarkParse -count=10 -benchmem > new.txt
go install golang.org/x/perf/cmd/benchstat@latest
benchstat old.txt new.txt
```

**判读规则**：只接受 `p<0.05` 且幅度 ≥3% 的结论。否则视为噪声。

### 并发 + 时序测试：`testing/synctest`（Go 1.25 GA）

替代手写 mock clock。涉及 `time.Sleep`/`time.After`/`context.WithTimeout` 的测试都应迁移。

```go
import "testing/synctest"

func TestRetryBackoff(t *testing.T) {
    synctest.Test(t, func(t *testing.T) {
        client := NewClient(WithRetry(3, 100*time.Millisecond))
        done := make(chan error, 1)
        go func() { done <- client.Do(ctx) }()
        synctest.Wait()   // 等 goroutine 稳态；bubble 内时间 fast-forward
        if err := <-done; err != nil { t.Fatal(err) }
    })
}
```

---

## §2 Profile 分析

### 采样矩阵

| 类型 | 采样 | 用于 |
|---|---|---|
| CPU | `-cpuprofile` 或 `/debug/pprof/profile?seconds=30` | 函数热点 |
| Heap | `-memprofile` 或 `/debug/pprof/heap` | 分配热点（alloc_space）、泄漏（inuse_space） |
| Block | `runtime.SetBlockProfileRate(1)` + `/debug/pprof/block` | channel/mutex 阻塞 |
| Mutex | `runtime.SetMutexProfileFraction(1)` + `/debug/pprof/mutex` | 锁竞争 |
| Goroutine | `/debug/pprof/goroutine?debug=2` | 泄漏、死锁 |
| Trace | `-trace` 或 `/debug/pprof/trace?seconds=5` | 调度/GC/网络时间线 |

### Flame Graph 阅读

```bash
go tool pprof -http=:8080 cpu.pb.gz    # Flame/Graph/Source 视图
go tool trace t.out                    # Trace 视图
```

**快速定位规则**：
- `runtime.mallocgc` 宽 → §4 分配热点
- `runtime.gcBgMarkWorker` / `runtime.gcAssistAlloc` 宽 → §6 GC 压力
- `runtime.chanrecv` / `runtime.semacquire` 宽 → §5 同步热点

详见 [`references/pprof-cookbook.md`](references/pprof-cookbook.md)。

### Flight Recorder（Go 1.25 新增）—— 排查偶发

持续缓冲最近 N 字节 trace，事件触发时 dump：

```go
import "runtime/trace"
fr := trace.NewFlightRecorder(trace.FlightRecorderConfig{MaxBytes: 10 << 20})
_ = fr.Start(); defer fr.Stop()
http.HandleFunc("/debug/dump-trace", func(w http.ResponseWriter, r *http.Request) {
    _, _ = fr.WriteTo(w)
})
```

### 生产 profile 接入

```go
import _ "net/http/pprof"
go func() { _ = http.ListenAndServe("127.0.0.1:6060", nil) }()   // 仅内网
```

```bash
go tool pprof -http=:8080 http://prod:6060/debug/pprof/profile?seconds=30
```

---

## §3 CPU 热点：逃逸 / 内联 / 算法

### 逃逸分析

```bash
go build -gcflags="-m=2" ./... 2>&1 | grep -E "escapes|moved to heap"
```

**最常见场景**（完整列表见 [`references/escape-analysis-cases.md`](references/escape-analysis-cases.md)）：

| 现象 | 根因 | 修复 |
|---|---|---|
| `return &x` 返回局部地址 | 指针逃出作用域 | 改值返回；或调用方传 `*T` |
| `fmt.Println(v)` 热路径 | `...interface{}` 参数装箱 | `strconv.Append*` + `io.Writer` |
| goroutine 闭包捕获大对象 | 捕获变量逃堆 | 参数显式传入 `go func(v Heavy) {...}(v)` |
| 赋给 interface 非指针类型 | 大于字长装箱 | 热路径用具体类型或泛型（1.18+） |
| `append` 超容量 | 重分配到堆 | 准确预分配 `make([]T, 0, n)` |
| map key 拼接 string | 临时 string 逃逸 | `[N]byte` key，或 `fmt.Appendf` |
| `reflect.Value.Call` 参数 | 打包为 `[]Value` 强制逃堆 | 代码生成；或泛型替代（见 `go-runtime` §7） |

### 内联

```bash
go build -gcflags="-m=2" 2>&1 | grep -E "can inline|cannot inline"
```

- 内联预算默认 80；回调/interface 阻止内联
- `//go:noinline` 防内联（benchmark 防 DCE 用）
- **没有"强制内联"指令**；让函数足够小即可

### 算法优先于微优化

O(n²) → O(n log n) 胜过所有常数优化。见 `algorithms` 技能。

### 热路径首选标准库（Go 1.21+）

```go
import ("cmp"; "slices")

slices.SortFunc(xs, func(a, b Item) int { return cmp.Compare(a.Score, b.Score) })
idx, found := slices.BinarySearchFunc(xs, target, cmpFunc)
```

`slices`/`maps`/`cmp` 比自己写泛型工具函数内联友好、版本稳定。

---

## §4 分配热点：目标 allocs/op → 0

### sync.Pool 正确用法

```go
var bufPool = sync.Pool{New: func() any { return new(bytes.Buffer) }}

func Encode(v any) ([]byte, error) {
    buf := bufPool.Get().(*bytes.Buffer)
    buf.Reset()                 // 必须 Reset
    defer bufPool.Put(buf)
    if err := json.NewEncoder(buf).Encode(v); err != nil { return nil, err }
    // 不能返回 buf.Bytes() 底层切片：Put 后会被复用
    out := make([]byte, buf.Len()); copy(out, buf.Bytes())
    return out, nil
}
```

**陷阱**：
1. GC 会清空 Pool，但 Go 1.13+ 有 **victim cache**（GC 时 local → victim，再下一轮才真丢）→ 单次 GC 不会全丢，两次连续 GC 才会；冷启动依旧无加速
2. Put 对象大小差异大 → 命中率低（分级 pool）
3. 不适合需 Close 的资源（用专用连接池）
4. **Put 前必须 Reset**，否则下次 Get 带脏状态（安全/正确性风险）

### 预分配

```go
out := make([]int, 0, len(src))   // 已知容量
for _, x := range src { out = append(out, transform(x)) }

var b strings.Builder
b.Grow(estimatedSize)             // 一次分配
```

### 零拷贝 string ↔ []byte（Go 1.20+ `unsafe.String`/`unsafe.Slice`）

```go
import "unsafe"

// []byte → string 不拷贝。仅当 b 之后不修改时安全
func bytesToString(b []byte) string {
    return unsafe.String(unsafe.SliceData(b), len(b))
}
// string → []byte 不拷贝。切片只读，写入即 UB
func stringToBytes(s string) []byte {
    return unsafe.Slice(unsafe.StringData(s), len(s))
}
```

热路径（JSON 解析、日志）省一次 O(n) 拷贝。**禁止对返回切片写入；禁止跨 goroutine 共享**。

### weak.Pointer 缓存（Go 1.24+）

`weak.Make(ptr)` 生成弱引用；`.Value()` 拿回 `*T`，GC 回收后返回 nil。典型用法：`sync.Map[K, weak.Pointer[V]]`，Get 时 Value 为 nil 则 Delete + 回源。**不保证存活**，必须有 fallback。完整 Cache 代码与陷阱见 `references/allocation-patterns.md`。

典型场景：大对象反序列化缓存、去重表、interning 池。反模式：当作常驻缓存用（GC 一压就丢）。

### 内存对齐

```bash
go install golang.org/x/tools/go/analysis/passes/fieldalignment/cmd/fieldalignment@latest
fieldalignment -fix ./...     # 自动按 size 降序
```

```go
// 反模式 24 bytes
type Event struct { Enabled bool; ID int64; Active bool }
// 正确 16 bytes
type Event struct { ID int64; Enabled, Active bool }
```

10^6 对象数组：24→16 省 8 MB，cache line 利用率 ↑，遍历吞吐 +15-30%。

### 空结构体的 5 种用法

```go
done := make(chan struct{})              // 信号 channel（0 字节）
set  := map[string]struct{}{}            // set 语义
type Marker struct{}                     // 类型标记
func (Marker) Method() {}                // 零成本方法接收者
```

详见 [`references/allocation-patterns.md`](references/allocation-patterns.md)。

---

## §5 并发与锁：选型矩阵

| 场景 | 首选 | 避免 |
|---|---|---|
| 读多写少，键集稳定 | `atomic.Pointer[map[K]V]` + COW | `sync.Map`（键稳定不占优） |
| 读多写少，键不断变 | `sync.Map`（1.24 Swiss Tables） | 单锁 map |
| 读写均衡 | `sync.Mutex` | `sync.RWMutex`（写多反而慢） |
| 初始化一次 | `sync.OnceFunc`/`OnceValue`/`OnceValues`（1.21+） | 手写 double-check |
| 生产消费 | buffered channel | 忙轮询 |
| 计数器/统计 | `atomic.Int64`/`atomic.Pointer[T]` | Mutex 保护原子变量 |

### `sync.OnceValue` —— 新代码默认（Go 1.21+）

```go
// 新写法
var GetConfig = sync.OnceValue(loadConfig)
var GetCreds  = sync.OnceValues(func() (string, error) { return loadCreds() })
```

比 `sync.Once` 更少样板、不会忘调 Do。

### `atomic.Pointer[T]` COW 模式

```go
type Router struct{ routes atomic.Pointer[map[string]Handler] }

func (r *Router) Update(k string, h Handler) {
    for {
        old := r.routes.Load()
        next := maps.Clone(*old)       // Go 1.21+ maps.Clone
        next[k] = h
        if r.routes.CompareAndSwap(old, &next) { return }
    }
}
func (r *Router) Lookup(k string) Handler { return (*r.routes.Load())[k] }
```

适合启动后基本只读、偶尔批量更新（路由表、配置）。

### goroutine 泄漏预防

每个 `go func()` 必须回答：**谁、何时、怎么让它退出？**

```go
func worker(ctx context.Context, jobs <-chan Job) {
    for {
        select {
        case <-ctx.Done(): return
        case j, ok := <-jobs:
            if !ok { return }
            process(j)
        }
    }
}
```

测试加 `goleak.VerifyTestMain(m)` 自动检测。

---

## §6 GC 与内存压力

### `GOMEMLIMIT`（Go 1.19+）软内存上限 —— 容器必设

```bash
GOMEMLIMIT=4GiB ./myapp
```

比 `GOGC` 更可控：指定目标内存，GC 自动贴近上限。典型：`GOMEMLIMIT=<容器 limit × 0.9>`。

### 容器感知 `GOMAXPROCS`（Go 1.25 默认）

Go 1.25 自动读取 Linux cgroup CPU quota。**删除 `uber/automaxprocs` 依赖**。验证：

```bash
GODEBUG=containermaxprocs=1 ./app 2>&1 | head
```

### Green Tea GC（Go 1.25 实验）

```bash
GOEXPERIMENT=greenteagc ./app
```

大堆、高分配速率场景 p99 明显改善。上生产前必须 A/B 对比 `GODEBUG=gctrace=1` 输出。

### gctrace 解读

```
gc 12 @1.234s 5%: 0.1+2.3+0.02 ms clock, ..., 45->48->50 MB, 90 MB goal
     ↑启动秒 ↑GC 占比 ↑STW+并发+STW ms      ↑heap 变化    ↑heap 目标
```

**红灯**：STW >10 ms、GC 占比 >25%、heap goal 持续增长（泄漏 → heap profile）。

---

## §7 编译期优化与 PGO

### 二进制瘦身

```bash
go build -ldflags="-s -w" -trimpath -o app ./cmd/app
# -s 去符号表；-w 去 DWARF；-trimpath 去绝对路径。典型 15→10 MB
```

**不要**用 UPX：启动时解压反而慢、杀软误报。

### PGO —— Profile-Guided Optimization（Go 1.21 GA）

编译器依据生产 CPU profile 做"带证据的"内联/布局决策。典型 **2-14% CPU 降低，零代码改动**。最小落地：生产抓 60s profile → 命名 `default.pgo` 丢进 main 包目录 → `go build` 自动启用。验证：`-pgo=off` 与 `-pgo=auto` 各构建一次，benchstat 对比。

详见 [`references/pgo-workflow.md`](references/pgo-workflow.md)（多机 profile 合并、CI 集成、profile 老化检测、`-pgo=off` 逃生开关）。

### go.mod `tool` / `ignore`（1.24/1.25）

```gomod
tool ( golang.org/x/tools/cmd/stringer; mvdan.cc/gofumpt )   // 1.24+
ignore ( ./vendor/generated; ./testdata )                    // 1.25+
```

`go tool stringer` 直接可用，CI/dev 工具链一致。

---

## 反模式清单（遇到立刻修）

| 反模式 | 正确做法 |
|---|---|
| 未 benchmark 就"优化" | 先写 benchmark |
| `time.Now()` 手工测时 | `go test -bench` |
| `for i := 0; i < b.N; i++` | Go 1.24+ `for b.Loop()` |
| 生产容器不设 `GOMEMLIMIT` | 必设为 limit × 0.9 |
| 容器内手动 `GOMAXPROCS` | Go 1.25 自动，删代码 |
| 手动 `time.Sleep` 时序测试 | `testing/synctest`（1.25） |
| 所有 map 套 `sync.Map` | 键稳定用 `atomic.Pointer` COW |
| 循环 `s += ...` | `strings.Builder.Grow` |
| 热路径 `fmt.Sprintf` | `strconv.Append*` / Builder |
| 热路径反射 | 代码生成（`go generate`） |
| 热路径 `interface{}` 参数 | 泛型（1.18+）/ 具体类型 |
| `time.After` 在循环 | `time.NewTimer` 复用 + Reset |
| 不看 gctrace 调 `GOGC` | 先 `GODEBUG=gctrace=1` |
| 用 `math/rand` 全局函数 | `math/rand/v2`（1.22+，无全局锁） |
| 日志用 `log`/logrus | `log/slog`（1.21+），结构化 |
| `sync.Once` + 全局变量样板 | `sync.OnceValue` |

---

## 验证闭环（PR 必须包含）

1. baseline benchmark 输出（N≥10）
2. 新 benchmark 输出（N≥10）
3. benchstat 对比（p<0.05）
4. profile 前后截图（热点消失）
5. 正确性回归（`go test ./... -race` 通过）

无此 5 项的"性能优化" PR 视为不合格。

---

## 关键命令速查

```bash
# Benchmark
go test -run=^$ -bench=. -benchmem -count=10 ./... > bench.txt
benchstat old.txt new.txt

# Profile
go test -cpuprofile=cpu.pb.gz -memprofile=mem.pb.gz -bench=. ./...
go tool pprof -http=:8080 cpu.pb.gz
go tool trace t.out

# 逃逸/内联
go build -gcflags="-m=2" ./... 2>&1 | grep -E "escapes|can inline"

# 字段对齐
fieldalignment -fix ./...

# 编译瘦身
go build -ldflags="-s -w" -trimpath -o app ./cmd/app

# PGO
go build -pgo=auto ./cmd/app

# Runtime 调试
GODEBUG=gctrace=1 ./app
GODEBUG=schedtrace=1000 ./app
GODEBUG=containermaxprocs=1 ./app
GOMEMLIMIT=4GiB ./app
GOEXPERIMENT=greenteagc ./app
```

---

## References（按需加载）

- [escape-analysis-cases.md](references/escape-analysis-cases.md) — 20+ 逃逸场景、`-gcflags="-m"` 输出解读、修复模式
- [pprof-cookbook.md](references/pprof-cookbook.md) — Flame Graph 实战、trace 解读、生产 profile 接入
- [pgo-workflow.md](references/pgo-workflow.md) — PGO 落地：采样、合并、CI 集成、profile 老化检测
- [allocation-patterns.md](references/allocation-patterns.md) — 对齐深挖、空结构体、unsafe 安全边界、对象池设计、weak.Pointer

## 相关技能

- `go-runtime` —— 运行时原理（GMP、GC、Channel、Swiss Tables）
- `go-test` —— benchmark、synctest、mock、集成测试
- `golang-patterns` —— Go 惯用法，Modern Go (1.21-1.25) 特性
- `algorithms` —— 算法选型（常数优化前先优化算法）
