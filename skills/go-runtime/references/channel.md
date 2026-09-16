# Channel 深度（Go 1.25.9+）

聚焦 SKILL.md §5 的细节：全流程、select 内部、close 广播。

---

## 1. hchan 完整结构

```go
type hchan struct {
    qcount   uint           // 当前 buf 中的元素数
    dataqsiz uint           // buf 容量
    buf      unsafe.Pointer // 环形 buffer 指针（指向 elemsize * dataqsiz 字节）
    elemsize uint16         // 单元素大小
    closed   uint32         // 是否 closed
    elemtype *_type         // 元素类型元信息
    sendx    uint           // 发送游标（下一个 send 写入位置）
    recvx    uint           // 接收游标（下一个 recv 读取位置）
    recvq    waitq          // 等待接收的 G 链表
    sendq    waitq          // 等待发送的 G 链表
    lock     mutex
}

type waitq struct {
    first *sudog    // 双向链表
    last  *sudog
}

type sudog struct {
    g           *g
    next        *sudog
    prev        *sudog
    elem        unsafe.Pointer    // 发送/接收的数据位置
    c           *hchan
    isSelect    bool
    success     bool
    ...
}
```

---

## 2. 发送 `ch <- v`

伪代码：

```
chansend(c, v):
    1. if c == nil: 永久阻塞（无 buf 的 nil chan send）
    2. 加 c.lock

    3. if c.closed: 解锁，panic("send on closed channel")

    4. // case A: 有 G 等接收
       if sg := c.recvq.dequeue(); sg != nil:
           direct_send(c, sg, v)       // 直接拷贝到对方 elem，唤醒对方
           解锁
           return

    5. // case B: buf 未满
       if c.qcount < c.dataqsiz:
           把 v 拷贝到 buf[sendx]
           sendx = (sendx + 1) % dataqsiz
           qcount++
           解锁
           return

    6. // case C: buf 满 or 无 buf
       mysg := acquireSudog()
       mysg.g = getg()
       mysg.elem = &v
       c.sendq.enqueue(mysg)
       goparkunlock(&c.lock, "chan send", ...)
       // 被唤醒后继续执行（唤醒者已经把 v 接走）
       releaseSudog(mysg)
       return
```

### 2.1 直接交接（case A）的意义

没有经过 buffer：发送方直接把值写到接收方的 `sudog.elem`（接收方阻塞时预留的地址）。

效果：
- 零拷贝到 buf
- 接收方唤醒后直接读到值
- 生产者 → 消费者延迟最小

CPU profile 中看到 `runtime.send` 自身耗时少说明是 direct send；`runtime.chansend` 栈上有 `runtime.goready` → 刚唤醒对方。

---

## 3. 接收 `v, ok := <-ch`

对称，伪代码：

```
chanrecv(c):
    1. if c == nil: 永久阻塞
    2. 加 c.lock

    3. if c.closed and c.qcount == 0:
           解锁
           return zero, false

    4. // case A: 有 G 等发送（buf 满 or 无 buf）
       if sg := c.sendq.dequeue(); sg != nil:
           if c.dataqsiz == 0:          // 无 buf chan
               v = *sg.elem             // 直接拿 sender 的值
           else:                         // 有 buf 且满
               v = buf[recvx]           // 从 buf 拿老值
               把 sg 的值写入 buf[sendx] // 挪动
           recvx = (recvx + 1) % dataqsiz
           唤醒 sg.g
           解锁
           return v, true

    5. // case B: buf 非空
       if c.qcount > 0:
           v = buf[recvx]
           recvx = (recvx + 1) % dataqsiz
           qcount--
           解锁
           return v, true

    6. // case C: 无数据
       阻塞当前 G 到 recvq
       返回值由唤醒者写入
```

---

## 4. close

```
closechan(c):
    加 c.lock
    if c == nil or c.closed: panic
    c.closed = 1

    // 唤醒所有 recvq 的 G，它们会拿到零值 + false
    for g := range c.recvq:
        g.sudog.elem = zero_value
        g.sudog.success = false
        goready(g)

    // 唤醒所有 sendq 的 G，它们会 panic
    for g := range c.sendq:
        goready(g)    // G 被唤醒后检查 c.closed → panic("send on closed")

    解锁
```

### 4.1 close 的"广播"语义

- 所有 recvq 的等待 G 被唤醒 → 典型"取消/广播"模式
- `done := make(chan struct{}); close(done)` 是最便宜的广播原语

### 4.2 多次 close panic

Go 不支持重复 close。用 `sync.Once` 或 `atomic.CompareAndSwap` 保证只 close 一次：

```go
var once sync.Once
once.Do(func() { close(ch) })
```

---

## 5. select 实现

### 5.1 基本流程

```go
select {
case v := <-c1: ...
case c2 <- x: ...
case <-c3: ...
default: ...
}
```

编译器转换为对 `runtime.selectgo` 的调用：

```
selectgo(scases []scase):
    1. 如果有 default 且其他 case 都不 ready → default
    2. 将所有非 default case 的 chan 指针收集、按地址排序
    3. 按顺序加所有 chan 的 lock （避免死锁）
    4. 快速路径：扫描一次看是否任一 case 可立即完成
       - 找到 ready 的 case → 执行并解锁，返回
       - 没有 → 进入慢速路径
    5. 慢速路径：为每个 case 创建 sudog，分别挂到对应 chan 的 recvq/sendq
    6. 解锁所有 chan，park 当前 G
    7. 被唤醒（某 chan 事件到来）
    8. 重新加所有锁
    9. 清理：把 sudog 从未触发的 chan 的 waitq 中移除
    10. 返回触发的 case index
```

### 5.2 随机选择

多个 case 同时 ready：

```go
shuffleOrder := randPermutation(N)
for _, i := range shuffleOrder {
    case := scases[i]
    if ready(case): return i
}
```

保证公平性，避免单一 case starvation。

### 5.3 default 的快速路径

有 default 的 select 不 park：检查一轮没有 ready 就走 default。常用于非阻塞尝试：

```go
select {
case v := <-ch: use(v)
default:
    // 没数据立即走
}
```

### 5.4 select 代价

- **2 个 case**：加 2 把锁，慢路径要扫两个 waitq
- **10 个 case**：排序 + 10 把锁 + 扫 10 个 waitq

**启示**：超过 4-5 个 case 的 select 在热路径昂贵。拆分或用专门的事件循环。

---

## 6. 无缓冲 vs 有缓冲

### 6.1 无缓冲 `make(chan T)`

- 每次 send 必须配对 recv，否则阻塞
- 直接交接（零拷贝）
- 同步原语：生产者 → 消费者有 **happens-before** 关系

### 6.2 有缓冲 `make(chan T, N)`

- buffer 未满时 send 不阻塞
- 仅 send 入 buffer → recv 从 buffer 取是 happens-before
- 批量场景更快（减少 park/唤醒）

### 6.3 选择

- 同步点 / 信号：无缓冲 or `chan struct{}`
- 流水线：有缓冲（N ≈ 并发生产者数）
- 生产者远快于消费者 → 有限缓冲 + 背压

---

## 7. 性能特征

### 7.1 无争用时

- send/recv ~30-50 ns（直接交接）
- buffer 路径 ~60-80 ns（拷贝到 buf）

### 7.2 高争用

- 多 P send 竞争同一 chan → 串行化在 hchan.lock
- 替代：多个 chan（sharding）或专用无锁队列

### 7.3 rangeOverChannel 的优化

```go
for v := range ch { ... }
```

编译为循环 + `v, ok := <-ch; if !ok break; ...`。没有额外开销。

---

## 8. 常见陷阱

### 8.1 未初始化的 nil chan

```go
var ch chan int
ch <- 1         // 永久阻塞，不 panic
<-ch            // 永久阻塞
close(ch)       // panic: close of nil channel
```

### 8.2 关闭后 send

```go
close(ch)
ch <- 1         // panic: send on closed channel
```

**谁 close**：一般由唯一的 sender 或 broadcast 控制端。多 sender 场景用 `sync.WaitGroup` 等全部结束再 close。

### 8.3 range over closed buffered channel

```go
ch := make(chan int, 3)
ch <- 1; ch <- 2; ch <- 3
close(ch)
for v := range ch { fmt.Println(v) }   // 输出 1, 2, 3 然后退出
```

close 后 **buffer 中的元素仍能被 recv**。for-range 取完 buffer 才退出。

### 8.4 goroutine 泄漏

```go
func bad() {
    ch := make(chan int)
    go func() {
        ch <- compute()   // 如果没人接收，永久阻塞
    }()
    // 如果提前 return，goroutine 泄漏
}
```

**修复**：buffered channel（容量 1）或 context 控制：

```go
ch := make(chan int, 1)
go func() { ch <- compute() }()    // 即使没人接收也不阻塞
```

---

## 9. 替代品

### 9.1 sync.Cond

信号量型等待。通常 channel 更清晰，除非需要批量唤醒同一条件。

### 9.2 atomic.Bool / atomic.Pointer

简单标志位用 atomic 更快（~3 ns vs ~30 ns）。

### 9.3 内部高性能队列

有限场景（如日志批处理）自研 MPMC 队列可达 ns 级开销。但 channel 提供 select/close 语义，通常值得保留。

---

## 10. 观察 channel

### 10.1 block profile

```go
runtime.SetBlockProfileRate(1000)   // 每 1μs 采 1 次
```

查看 `/debug/pprof/block` → 定位 chan 阻塞热点（`runtime.chanrecv1` / `runtime.chansend1` 宽）。

### 10.2 trace

`go tool trace` → 看 Synchronization blocking，每个 chan 阻塞事件可视。

### 10.3 GODEBUG

无专用 channel 标志，但 `schedtrace` 能间接看：如果 `runqueue` 长 + `idleprocs` > 0 = 消费者不够快或 chan 争抢。
