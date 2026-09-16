# GMP 调度器深度（Go 1.25.9+）

聚焦 SKILL.md §1 没展开的细节：数据结构、work-stealing 算法、sysmon、netpoll 融合。

---

## 1. 关键数据结构

### 1.1 G（goroutine）

```go
type g struct {
    stack       stack       // 栈区间 [lo, hi]
    stackguard0 uintptr     // 栈溢出检查点
    m           *m          // 当前绑定的 M
    sched       gobuf       // 上下文（保存 SP/PC/BP）
    atomicstatus uint32     // 运行状态
    goid        uint64
    waitreason  waitReason  // 阻塞原因（用于 goroutine dump）
    ...
}
```

状态机：
- `_Gidle` → `_Grunnable` → `_Grunning` → `_Gsyscall`/`_Gwaiting` → 回到 `_Grunnable` 或 `_Gdead`

### 1.2 M（OS 线程）

```go
type m struct {
    g0      *g           // 调度栈（不是用户 goroutine）
    curg    *g           // 当前运行的 G
    p       puintptr     // 绑定的 P
    nextp   puintptr     // 即将绑定的 P
    oldp    puintptr     // syscall 前的 P
    spinning bool        // 正在找活
    ...
}
```

**g0 栈**：每个 M 有专用 g0，运行时/调度器代码跑在 g0 上（栈更大，~8KB）。

### 1.3 P（调度上下文）

```go
type p struct {
    id          int32
    status      uint32
    m           muintptr
    runqhead    uint32
    runqtail    uint32
    runq        [256]guintptr   // 本地 runqueue，无锁 MPSC
    runnext     guintptr        // "下一个" G，优先级最高
    gFree       gList           // 空闲 g 缓存
    mcache      *mcache         // 分配器本地缓存
    ...
}
```

**runq 是固定 256 容量的环形队列**。满了就把一半（128）推到全局队列。

---

## 2. Work-Stealing 算法

调度核心函数 `findRunnable()`：

```
findRunnable():
  1. 看 P.runnext  （最高优先级 slot）
  2. 看 P.runq     （本地队列）
  3. 每 61 次调度，先检查全局队列一次（防饥饿）
  4. 从 sched.runq 全局队列取
  5. 尝试 poll netpoll（非阻塞）
  6. 随机偷：
     a. 选一个其他 P
     b. 从它的 runq 偷一半（128 个槽）
     c. 失败则换下一个
  7. 所有 P 偷完都没有 → 确认真的空：
     a. 重新检查全局队列
     b. 重新 poll netpoll（阻塞，等到新事件）
     c. 停下 M（park）
```

### 2.1 为什么是"偷一半"

- 偷一个 → 被偷者的其他 goroutine 立刻又空闲偷者
- 偷太多 → 被偷者马上空闲
- 偷一半 → 两边大致均衡

### 2.2 runnext slot

runnext 是"刚唤醒就想运行"的 G，插队到 runq 前面。典型场景：

```go
ch <- v         // 发送方唤醒 recvq 中的 G
                // 这个 G 被置入当前 P 的 runnext，下一轮调度立即跑
```

这让 channel 接力延迟极低（生产者→消费者瞬间切换）。

---

## 3. sysmon（系统监视线程）

一个不绑 P 的特殊 M，专门做"背景"工作：

1. **抢占长时间运行的 G**（>10ms）→ 设置抢占标志，等下一次函数调用或发 SIGURG
2. **回收 syscall 阻塞的 M**：如果 M 在 syscall 超过 20μs，抢走它的 P
3. **触发 GC**（如果太久没 GC 了）
4. **netpoll 轮询**（作为兜底，防止主调度器没 poll 到）
5. **归还多余堆栈内存给 OS**（scavenger）

sysmon 自身频率动态：空闲时 10ms 一次，活跃时可到 5μs。

---

## 4. netpoll 融合

### 4.1 非阻塞 I/O 模型

```go
conn.Read(buf):
  1. syscall.Read（非阻塞）
  2. 返回 EAGAIN/EWOULDBLOCK
  3. G 注册到 netpoll（epoll_ctl），park
  4. M 继续跑其他 G
  ...
  5. epoll_wait 返回可读事件
  6. 对应 G 被唤醒，放回某 P 的 runq
  7. goroutine 继续 Read
```

### 4.2 netpoll poll 点

- 调度循环主动 poll（非阻塞）
- 调度循环发现无活 → 阻塞 poll
- sysmon 兜底

### 4.3 HTTP server 的魔法

```go
http.HandleFunc("/", handler)
http.ListenAndServe(":8080", nil)
```

每个连接一个 goroutine（数十 KB 栈 + netpoll 挂起）。10 万并发 = 几 GB 内存，完全可行。

---

## 5. 信号抢占机制（Go 1.14+）

### 5.1 问题

协作式抢占依赖函数序言检查抢占标志：

```go
for { x++ }    // 无函数调用 → 永远抢不了
```

早期必须手动加 `runtime.Gosched()`。

### 5.2 解决

1. 全局 sysmon 发现 G 运行超 10ms
2. 向 M 的 OS 线程发 `SIGURG` 信号
3. 信号 handler 把 G 上下文保存到 gobuf，切换到 g0，调用 `preemptPark`
4. G 变 runnable 回队列

**代价**：每次抢占一次信号开销（~几μs），但避免了无限卡死。

### 5.3 关闭抢占

```bash
GODEBUG=asyncpreemptoff=1 ./app   # 调试用！
```

关闭后无限循环会永远跑下去，但某些精确测时场景（micro-benchmark）可能需要。

---

## 6. goroutine 创建成本

```go
go func() { ... }()
```

开销：
1. 分配 g struct（先查 P 的 gFree 缓存，没有就从 mheap 分配）
2. 分配栈（2KB 起）
3. 设置上下文
4. 放入 runnext 或 runq

**~300ns/创建**（现代 CPU）。创建百万 goroutine ≈ 300ms + 2GB 栈。

---

## 7. 常见诊断

### 7.1 goroutine 激增排查

```bash
curl 'http://127.0.0.1:6060/debug/pprof/goroutine?debug=2' > g.txt
```

按"等待原因"聚合：

```bash
grep -A1 '^goroutine' g.txt | grep -oE '\[[^]]+\]' | sort | uniq -c | sort -rn
```

典型模式：
- `[select]` 大量 → channel 无人发送/接收
- `[chan receive]` 大量 → 消费者没起来
- `[IO wait]` 大量 → 后端慢
- `[semacquire]` 大量 → 锁竞争

### 7.2 调度延迟排查

`go tool trace trace.out` → Scheduler latency 面板

某 G 从 runnable 到实际 run 的间隔（= 调度延迟）。p99 > 1ms 说明 P 不够或被 GC / 系统调用打扰。

### 7.3 P 利用率

```bash
GODEBUG=schedtrace=1000 ./app 2>&1 | head -100
```

持续 `idleprocs > 0` + QPS 低 = 未饱和 → 扩 goroutine 数或去除阻塞点。

---

## 8. GOMAXPROCS 设置（Go 1.25+ 自动）

### 8.1 历史

- 1.4 前：默认 1
- 1.5+：默认 `runtime.NumCPU()`
- 容器时代：`NumCPU` = 宿主机核数，不等于容器 quota
- 1.25+：自动读 cgroup CPU quota

### 8.2 1.25 新行为

Linux cgroup v1/v2 检测：`/sys/fs/cgroup/cpu.max`（v2）或 `cpu.cfs_quota_us` / `cpu.cfs_period_us`（v1）。

```bash
GODEBUG=containermaxprocs=1 ./app
# 输出：runtime: GOMAXPROCS set to 4 from container CPU quota (quota=400000, period=100000)
```

### 8.3 手动覆盖

```bash
GOMAXPROCS=8 ./app
```

或代码：

```go
runtime.GOMAXPROCS(8)
```

**几乎不需要手动设**。1.25 的自动检测覆盖 99% 场景。

---

## 9. 常见误解

### 9.1 "更多 goroutine 更快"

不一定。goroutine 多到一定程度，调度开销 > 并行收益。经验：
- CPU bound: goroutine 数 ≈ GOMAXPROCS
- I/O bound: goroutine 数 ≈ 并发 I/O 数（可达万级）

### 9.2 "runtime.Gosched() 能提高吞吐"

几乎总是相反。手动 Gosched 打断本地 runq，迫使调度器重找。只在极少情况（协作式让出长任务）有用。

### 9.3 "GOMAXPROCS=1 是单线程"

不完全。只是 P=1，M 数仍可 > 1（因为 syscall 阻塞会开新 M）。真正的单线程要 `GOMAXPROCS=1 + 避免阻塞 syscall`。

### 9.4 "channel 无锁"

错。hchan 内部有 `lock mutex`。只是 close-to-metal 的 FIFO 交接在无竞争时走快速路径（无系统调用）。

---

## 10. 调度器演进时间线

- **1.0**: GM model（无 P，全局 runq + 全局锁）
- **1.1**: 引入 P，work-stealing
- **1.14**: 信号抢占
- **1.19**: soft memory limit 改变 GC pacer 与调度协作
- **1.22**: 更平滑的 pacer，sysmon 频率调整
- **1.25**: 容器感知 GOMAXPROCS；Flight Recorder 给 trace 更细粒度
