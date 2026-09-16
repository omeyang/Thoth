# pprof / trace Cookbook（Go 1.25.9+）

从"发现慢 → 定位 → 验证"的完整流程。所有示例基于最新工具链。

---

## 1. 采样入口

### 1.1 单元测试/基准里采样

```bash
go test -run=^$ -bench=BenchmarkXxx -benchmem \
    -cpuprofile=cpu.pb.gz \
    -memprofile=mem.pb.gz \
    -blockprofile=block.pb.gz \
    -mutexprofile=mutex.pb.gz \
    -trace=trace.out \
    ./pkg/...
```

### 1.2 生产服务暴露 pprof

```go
import (
    "net/http"
    _ "net/http/pprof"
    "runtime"
)

func init() {
    // 默认值是 0（不采样）
    runtime.SetBlockProfileRate(1)        // 1 纳秒粒度（仅调试开启；生产用 10000 = 10μs）
    runtime.SetMutexProfileFraction(1)    // 1 次 mutex 事件采一次
}

func main() {
    // 仅绑定 localhost，再由 sidecar/kubectl port-forward 访问
    go func() { _ = http.ListenAndServe("127.0.0.1:6060", nil) }()
}
```

**生产安全**：
- 绑定 `127.0.0.1`，通过 port-forward 访问
- 或套一层 auth middleware
- pprof endpoint **不要** 挂在业务端口

### 1.3 采样命令

```bash
# 30 秒 CPU
curl -o cpu.pb.gz 'http://127.0.0.1:6060/debug/pprof/profile?seconds=30'
# 当前 heap
curl -o heap.pb.gz 'http://127.0.0.1:6060/debug/pprof/heap'
# 5 秒 trace
curl -o trace.out 'http://127.0.0.1:6060/debug/pprof/trace?seconds=5'
# Block / mutex（先确保 SetXxx 已开启）
curl -o block.pb.gz 'http://127.0.0.1:6060/debug/pprof/block'
curl -o mutex.pb.gz 'http://127.0.0.1:6060/debug/pprof/mutex'
# goroutine stack（调试死锁/泄漏）
curl 'http://127.0.0.1:6060/debug/pprof/goroutine?debug=2' > goroutines.txt
```

---

## 2. CPU Profile 解读

### 2.1 打开

```bash
go tool pprof -http=:8080 cpu.pb.gz
# 浏览器访问 http://localhost:8080
# 切换视图：Top / Graph / Flame Graph / Source / Peek / Disasm
```

### 2.2 关键指标

- **flat**：函数自身消耗 CPU 时间
- **cum**：函数及其调用子链消耗 CPU 时间
- **sum%**：累积百分比

"**真正的热点**"看 flat，不是 cum。flat 大 = 自身计算重；cum 大 = 调用栈深但自己不一定慢。

### 2.3 Flame Graph 阅读

- 横轴 = 采样数，**宽 = 热**
- 纵轴 = 调用栈深度，上方 = 被调用者
- **找顶端宽格子** = 自身热点
- 点击下钻，Shift+点击上钻到调用者
- 搜索框过滤函数名

### 2.4 典型 flame graph 形状

| 形状 | 含义 | 排查方向 |
|---|---|---|
| `runtime.mallocgc` 宽 | 分配热点 | SKILL §4 —— sync.Pool / 预分配 / weak |
| `runtime.gcBgMarkWorker` 宽 | GC 标记 | §6 —— GOMEMLIMIT、降低分配速率 |
| `runtime.gcAssistAlloc` 宽 | GC 协助（应用协程帮忙扫描） | 同上，减少分配压力 |
| `runtime.chanrecv1` / `chansend1` 宽 | channel 阻塞 | §5 —— channel 大小、Worker Pool 配比 |
| `runtime.semacquire` / `sync.*` 宽 | 锁竞争 | §5 —— 锁选型、分片 |
| `syscall.Syscall` 宽 | 系统调用 | 批量化、io_uring（非 Go 默认）、减少 syscall |
| `reflect.*` 宽 | 反射 | 代码生成替代 |
| `runtime.memmove` 宽 | 大量 copy | 预分配、避免 slice 扩容 |
| `runtime.findRunnable` / `schedule` 宽 | 调度开销 | goroutine 数过多、或多核下 P 争抢 |

### 2.5 命令行交互

```bash
go tool pprof cpu.pb.gz
(pprof) top20                   # 前 20 热点（按 flat）
(pprof) top20 -cum              # 按 cum 排序
(pprof) list funcName           # 看某函数源码热点
(pprof) web                     # 生成调用图 svg
(pprof) peek funcName           # 看谁调用了 funcName
(pprof) sample_index=alloc_space   # heap profile 切换视图
```

---

## 3. Heap Profile

### 3.1 两种视角

```bash
go tool pprof -http=:8080 heap.pb.gz
# Sample 下拉切换：
#   inuse_space: 当前还活着的字节数 → 定位泄漏
#   inuse_objects: 活对象数
#   alloc_space: 生命周期内累计分配字节 → 定位分配热点
#   alloc_objects: 累计分配对象数
```

**判断**：
- **"优化性能"** —— 看 `alloc_space` / `alloc_objects`，减少总分配压 GC
- **"排查泄漏"** —— 看 `inuse_space` / `inuse_objects`，随时间增长的是泄漏点
- **内存"占用高但没泄漏"** —— `inuse` 稳定但绝对值大，考虑对象压缩（对齐、unsafe.String）

### 3.2 泄漏典型模式

从时间序列看 `inuse_space`：

```
时间 T1 → T2 → T3（每分钟采一次）
   100MB   300MB   900MB     → 线性或加速增长 = 泄漏
   800MB   820MB   815MB     → 波动但稳定 = 正常（GC 调控中）
```

泄漏模式：
- **goroutine 泄漏** → `/debug/pprof/goroutine` 数量单调上升
- **map 单调增长** → 无淘汰策略，用 `weak.Pointer` 或 LRU
- **channel 泄漏** → 发送方阻塞未退出
- **timer/ticker 泄漏** → 未 Stop（Go 1.23 改进：未引用会被 GC，但仍建议显式 Stop）

---

## 4. Block / Mutex Profile

### 4.1 开启

```go
runtime.SetBlockProfileRate(10000)        // 每 10μs 采 1 次
runtime.SetMutexProfileFraction(100)      // 每 100 次 mutex 事件采 1
```

生产环境值要谨慎：太小 = 噪声多；太大 = 采不到。

### 4.2 Block profile 看什么

`block.pb.gz` 记录 goroutine 阻塞时间。热点 = 长时间阻塞在某点。典型：

- `runtime.chanrecv` —— channel 空，消费者等
- `runtime.chansend` —— channel 满，生产者等
- `sync.(*Mutex).Lock` —— 锁竞争
- `sync.(*WaitGroup).Wait` —— 等待者众多
- `runtime.selectgo` —— select 阻塞

### 4.3 Mutex profile

只看锁竞争。比 block 更聚焦。

---

## 5. Trace 视图（`go tool trace`）

```bash
go tool trace trace.out
# 浏览器打开，看 9 个视图
```

### 5.1 关键视图

| 视图 | 看什么 |
|---|---|
| View trace | 时间轴：每个 P、GC、网络、goroutine |
| Goroutine analysis | 单个 goroutine 的生命周期、等待时间 |
| Network blocking profile | 网络 I/O 阻塞 |
| Synchronization blocking | 同步阻塞（锁/channel） |
| Syscall blocking | 系统调用阻塞 |
| Scheduler latency | 调度延迟（可运行但未被执行的时间） |

### 5.2 典型诊断

**STW 明显** → 放大 GC 事件，看是 mark 还是 sweep 慢。配合 `GODEBUG=gctrace=1`。

**P 利用不满** → 可运行 goroutine 少，或阻塞在 I/O。看"Goroutines"轴，应几乎铺满。

**网络/syscall 长** → 反映到 `Network blocking` 或 `Syscall blocking`。如果热点在单次 syscall → 考虑批量化。

**调度延迟高** → 某 goroutine 可运行但长时间不执行，说明 P 被抢占或 GC 打断。

---

## 6. Flight Recorder（Go 1.25 新增）

**场景**：偶发性能问题（延迟毛刺、偶现错误），无法稳定触发 → 持续缓冲，事件来临时 dump 最近 N 秒。

```go
import "runtime/trace"

var flightRecorder *trace.FlightRecorder

func initFlightRecorder() {
    flightRecorder = trace.NewFlightRecorder(trace.FlightRecorderConfig{
        MaxBytes: 16 << 20,  // 16 MiB 环形缓冲（典型 5-10 秒 trace）
        MinAge:   5 * time.Second,
    })
    if err := flightRecorder.Start(); err != nil {
        log.Printf("flight recorder start: %v", err)
    }
}

// 触发点（如告警/错误）
func onAlert(reason string) {
    path := fmt.Sprintf("/tmp/flight-%s-%d.trace", reason, time.Now().UnixNano())
    f, err := os.Create(path)
    if err != nil { return }
    defer f.Close()
    if _, err := flightRecorder.WriteTo(f); err != nil {
        log.Printf("dump trace: %v", err)
    }
    log.Printf("flight trace dumped to %s", path)
}

// HTTP 端点，手动 dump
http.HandleFunc("/debug/flight-trace", func(w http.ResponseWriter, r *http.Request) {
    w.Header().Set("Content-Type", "application/octet-stream")
    _, _ = flightRecorder.WriteTo(w)
})
```

**采样成本**：flight recorder 持续运行，开销低于 `runtime/trace.Start`，可在生产长时间开启。

**触发策略**：
- HTTP 响应 p99 突增
- panic 前捕获
- OOM 前（结合 GC pacer）
- 外部告警来临

---

## 7. 诊断流程（真实案例）

### 场景：服务 p99 从 50ms 涨到 500ms

1. **看 GC** `GODEBUG=gctrace=1 ./app 2>&1 | tail -20`
   - 如果 STW > 50ms 或频率 > 1/s，先 §6 解决 GC 问题
2. **采 CPU profile**
   - 若 `runtime.mallocgc` 占 >20% → §4 分配优化
3. **若非 GC 问题，采 trace**（5 秒）
   - 看 `Synchronization blocking` → 定位锁竞争
   - 看 `Scheduler latency` → 看是否调度不过来
4. **若锁竞争，采 mutex profile**
   - 找到热点锁 → 换 `atomic.Pointer` COW 或分片
5. **验证**：重新压测，benchstat + 同步采 profile 确认热点消失

### 场景：容器 OOMKilled

1. **立即加 `GOMEMLIMIT`**（§6），给 GC 上限提示
2. **采 inuse_space heap profile**，看增长点
3. **对比多个时间点的 heap profile**
   ```bash
   curl -o h1.pb.gz /debug/pprof/heap
   sleep 60
   curl -o h2.pb.gz /debug/pprof/heap
   go tool pprof -base=h1.pb.gz h2.pb.gz    # 只看"增量"
   ```
4. **若是 goroutine 泄漏**，看 `/debug/pprof/goroutine?debug=2` 找阻塞栈

---

## 8. 集成到 CI

```yaml
# .github/workflows/perf.yml
- name: Benchmark
  run: |
    go test -run=^$ -bench=. -benchmem -count=10 \
        -cpuprofile=cpu.pb.gz \
        ./... > bench.txt

- name: Store artifacts
  uses: actions/upload-artifact@v4
  with:
    name: perf-${{ github.sha }}
    path: |
      bench.txt
      cpu.pb.gz

- name: Compare with main
  run: |
    curl -o main.txt https://.../artifacts/main/bench.txt
    benchstat main.txt bench.txt
    # 若 p99 退化 > 5%，CI 失败
```

---

## 9. 不要做

- **不要用 `pprof.StartCPUProfile` 在 main 前 1 秒开启，mimir（Grafana）风格**：启动初期不代表稳态
- **不要信单次采样**：至少 30 秒 CPU、多次 heap（用 `-base` 对比）
- **不要直接看 flame graph 最顶宽块**：可能是 `runtime.*`，要下钻到用户代码
- **不要在低 QPS 下采样**：采样可能漏掉真正热点；加载测试到稳态再采
