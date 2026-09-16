# 内存分配器深度（Go 1.25.9+）

聚焦 SKILL.md §3 的底层细节：数据结构、sizeclass 表、arena 布局。

---

## 1. 分配器三级缓存

```
              G 请求分配
                 │
                 ▼
          ┌──────────┐        P 绑定，无锁
          │  mcache  │◄── tiny alloc / 小对象（< 32KB）
          └────┬─────┘
               │ miss / refill
               ▼
          ┌──────────┐        central，有锁（按 sizeclass 独立锁）
          │ mcentral │
          └────┬─────┘
               │ miss / refill
               ▼
          ┌──────────┐        全局 heap，全局锁
          │  mheap   │◄── 大对象（>= 32KB）直达
          └────┬─────┘
               │ grow
               ▼
          ┌──────────┐
          │   OS     │   mmap anon 按 arena（64 MiB）分配
          └──────────┘
```

---

## 2. mspan（分配的最小单位）

mspan 是一段连续的页（每页 8 KiB），切成若干等大 slot 供分配：

```go
type mspan struct {
    next        *mspan
    prev        *mspan
    startAddr   uintptr   // 起始地址
    npages      uintptr   // 多少页
    freeindex   uintptr   // 下一个空闲 slot
    nelems      uintptr   // slot 数
    allocBits   *gcBits   // 哪些 slot 已用（bitmap）
    gcmarkBits  *gcBits   // GC mark bits
    sizeclass   uint8     // 属于哪个 sizeclass
    ...
}
```

### 2.1 分配流程

```
mcache.alloc(sizeclass):
    span = mcache.alloc_list[sizeclass]    // 链表首
    if span.freeindex < span.nelems:
        addr = span.startAddr + span.freeindex * sizeclass.size
        span.freeindex++
        set allocBits[freeindex-1]
        return addr
    else:
        // span 用完，找 mcentral 要新的
        span = mcentral.cacheSpan(sizeclass)
        ...
```

---

## 3. sizeclass 表

Go 有 67 个预定义 sizeclass（0 号是 0 字节，用于 ≤ 16 字节的 tiny allocator）。

节选（实际见 `runtime/sizeclasses.go`）：

| sizeclass | size (B) | 每 mspan 能放几个 | 每 mspan 多少页 | 浪费率 |
|---|---|---|---|---|
| 1 | 8 | 1024 | 1 | 0% |
| 2 | 16 | 512 | 1 | 0% |
| 3 | 32 | 256 | 1 | 0% |
| 4 | 48 | 170 | 1 | 0% |
| 5 | 64 | 128 | 1 | 0% |
| 10 | 128 | 64 | 1 | 0% |
| 15 | 256 | 32 | 1 | 0% |
| 20 | 512 | 16 | 1 | 0% |
| 25 | 1024 | 8 | 1 | 0% |
| 30 | 2048 | 4 | 1 | 0% |
| 40 | 6144 | 5 | 4 | ~10% |
| 50 | 13568 | 4 | 7 | 变化 |
| 67 | 32768 | 1 | 4 | 0% |

**浪费**：对象向上对齐到 sizeclass，最差 ~12% 内部碎片。

### 3.1 对象大小 → sizeclass

```go
import "unsafe"

// 请求 25 字节 → 查 sizeToClass 表 → 返回 sizeclass 4（48 B）
// 实际占用 48 字节
```

**启示**：17 字节和 24 字节一样占 24；47 字节和 48 字节一样占 48。**临界点附近**的字段布局值得优化。

### 3.2 0 字节对象

零大小（`struct{}`）不分配。所有 `&struct{}{}` 指向 `runtime.zerobase` 同一个地址。

---

## 4. mcache（P 本地）

每个 P 绑定一个 mcache，包含：
- 67 个 sizeclass × 2（scan/noscan）= 134 条 mspan 链表
- tiny allocator（为 ≤ 16B 无指针对象合并分配）

**关键**：mcache 操作**无锁**（P 天然独占）。这是分配快的根本。

### 4.1 tiny allocator

`≤ 16B` 的无指针对象不走 sizeclass，放进"tiny block"（16B buffer）：

```
tiny buffer: [□□□□□□□□□□□□□□□□]   16B
分配 3B → [▓▓▓□□□□□□□□□□□□□]     剩 13B
分配 5B → [▓▓▓▓▓▓▓▓□□□□□□□□]     剩 8B（向上对齐）
分配 9B → 新 tiny buffer
```

**效果**：小的 bool/int8/byte/small struct 的分配开销极低。

### 4.2 scan vs noscan

- **scan span**：对象含指针，GC 要扫
- **noscan span**：对象无指针（纯 int/byte），GC 跳过

编译期由类型决定。`*T`、`string`、slice、map、interface、func 含指针 → scan。纯数值类型 + 没指针字段的 struct → noscan。

**启示**：热路径高频对象如果能设计成 noscan，GC 压力明显降低。

---

## 5. mcentral

每个 sizeclass 一个 mcentral 实例，管理该 sizeclass 的所有 mspan：

```go
type mcentral struct {
    spanclass spanClass
    partial   [2]spanSet   // 非满 span（其中一个做清扫）
    full      [2]spanSet   // 满 span
}
```

### 5.1 锁竞争

mcentral 有自己的锁。**不同 sizeclass 的 mcentral 独立**，所以不同大小对象分配互不干扰。

### 5.2 refill mcache

```
mcache 空了：
    加 mcentral[sizeclass] 的锁
    从 partial 取一个 span
    若 partial 空 → mheap 要新 span
    放入 mcache
    解锁
```

refill 频率不高（一个 span 能用几百次分配），所以锁开销摊到每次分配是零。

---

## 6. mheap & arena

### 6.1 mheap 结构

全局单例，管理所有 arena：

```go
type mheap struct {
    lock      mutex
    allspans  []*mspan
    arenas    [1 << arenaBits]*heapArena    // arena 索引
    pages     pageAlloc                     // 页粒度空闲管理
    ...
}
```

### 6.2 arena

每个 arena 64 MiB，从 OS `mmap` 获得。Go heap 由若干 arena 组成。

```go
type heapArena struct {
    bitmap    [arenaSize / 64]uintptr   // 每 8 字节 1 bit，标识是否含指针
    spans     [arenaSize / pageSize]*mspan
    pageSpans [...]
    ...
}
```

每 64 MiB arena 元数据约 2 MiB。大 heap 开销可观（10 GB heap ≈ 160 arenas × 2 MiB = 320 MiB 元数据）。

### 6.3 大对象（>= 32 KiB）

不走 sizeclass，mheap 直接分配 `size/8KB` 个连续页组成的 mspan，只放一个对象：

```go
p := make([]byte, 100_000)    // 直接 mheap.alloc(13 pages)
```

每次都走全局锁 → **热路径避免创建大对象**。

---

## 7. 栈分配

goroutine 栈从 **2 KiB** 起（Go 1.4+ 连续栈模型）。栈帧记在专用 mspan（stack span），生命周期由 goroutine 决定，不参与 GC heap。

### 7.1 栈扩张

```
进入函数 → 栈序言检查：SP - frameSize < stackguard → 栈溢出
    1. 分配 2 倍大的新栈
    2. memcpy 旧栈到新栈
    3. 遍历栈帧，重定位所有内部指针（指向本栈的指针）
    4. 释放旧栈
```

**开销**：每次扩张 O(栈深度) 拷贝 + 重定位。一般不是瓶颈，但深递归热路径可能明显。

### 7.2 栈缩减

GC 后如果栈使用率 < 25%，缩一半（到最小 2 KiB）。避免长运行 goroutine 栈永远保持峰值大小。

### 7.3 分段栈（历史）

Go 1.3 及以前：栈由多段不连续组成，函数调用时可能跨段。**频繁跨段开销巨大**（热分裂）。1.4 改为连续栈（copying stack），彻底解决。

---

## 8. 观察分配

### 8.1 runtime/metrics

```go
import "runtime/metrics"

samples := []metrics.Sample{
    {Name: "/gc/heap/allocs:bytes"},        // 累计分配字节
    {Name: "/gc/heap/allocs:objects"},      // 累计分配对象数
    {Name: "/memory/classes/heap/free:bytes"},
    {Name: "/memory/classes/heap/stacks:bytes"},
    {Name: "/memory/classes/heap/objects:bytes"},
    {Name: "/sched/goroutines:goroutines"},
}
metrics.Read(samples)
```

### 8.2 runtime.MemStats（已不推荐）

旧 API，触发 STW。用 `runtime/metrics` 替代。

### 8.3 GODEBUG allocfreetrace=1

```bash
GODEBUG=allocfreetrace=1 ./app 2>&1 | head -50
```

每次 alloc/free 都打 stack。**极慢，仅小测试用**。

---

## 9. 优化映射

| 现象 | 原因 | 应对 |
|---|---|---|
| mcache refill 频繁 | 某 sizeclass 分配热点 | 减少分配或对象池 |
| mcentral 锁热点 | 跨 P 高频同尺寸分配 | 同上 |
| mheap 锁热点 | 大对象频繁 | 避免 >32KB 临时对象，预分配复用 |
| arena 数量大 | heap 大 | GOMEMLIMIT 控上限；对象压缩 |
| scan span 多 | 对象含指针多 | noscan 设计（减少指针字段） |

---

## 10. 常见误解

### 10.1 "内存分配很慢"

在 Go 里，mcache 路径 ~5-10 ns/分配。比大多数语言快。真正慢的是：
- GC 标记扫描（间接代价）
- 大对象（直接走 mheap 锁）
- 指针密集的对象（GC 扫描成本）

### 10.2 "对象池比分配更快"

不一定。简单对象（< 64B）直接分配 ~10 ns，sync.Pool Get/Put ~20 ns。**Pool 只对大对象或昂贵初始化有收益**。

### 10.3 "内存回收立即生效"

错。GC 回收对象 → scavenger 异步归还给 OS。RSS 下降有延迟。

### 10.4 "逃逸到堆 = 性能灾难"

夸张。单次堆分配几十纳秒，几百次也只是微秒级。真正灾难是**累积**：每秒百万次堆分配 = GC 占 CPU > 20%。
