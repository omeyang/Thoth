# 分配优化模式集（Go 1.25.9+）

从"每次 op 分配多少字节"压到 0。每个模式含可验证的 benchmark 预期。

---

## 1. 内存对齐

### 1.1 Go 对齐规则

| 类型 | size | alignment |
|---|---|---|
| `bool`, `int8`, `uint8`, `byte` | 1 | 1 |
| `int16`, `uint16` | 2 | 2 |
| `int32`, `uint32`, `float32`, `rune` | 4 | 4 |
| `int64`, `uint64`, `float64`, `complex64` | 8 | 8 (32 位平台为 4) |
| `complex128` | 16 | 8 |
| `*T`, `unsafe.Pointer` | 8 (64 位) | 8 |
| `string` | 16 | 8 |
| `slice` | 24 | 8 |
| `interface` | 16 | 8 |
| `map`, `chan`, `func` | 8 (指针) | 8 |

**结构体对齐** = 所有字段中最大的对齐要求。结构体总 size 会按自身对齐向上取整。

### 1.2 排列规则

**字段按 size 降序放**。bool/byte 这些小字段凑到最后合并。

```go
// 反模式 —— 24 bytes
type Bad struct {
    A bool      // 1
                // 7 pad
    B int64     // 8
    C bool      // 1
                // 7 pad
}

// 正确 —— 16 bytes
type Good struct {
    B int64     // 8
    A bool      // 1
    C bool      // 1
                // 6 pad
}
```

查看实际布局：

```go
import "unsafe"

fmt.Println(unsafe.Sizeof(Good{}))              // 16
fmt.Println(unsafe.Offsetof(Good{}.B))          // 0
fmt.Println(unsafe.Offsetof(Good{}.A))          // 8
fmt.Println(unsafe.Offsetof(Good{}.C))          // 9
```

### 1.3 自动工具

```bash
go install golang.org/x/tools/go/analysis/passes/fieldalignment/cmd/fieldalignment@latest

fieldalignment ./...           # 报告
fieldalignment -fix ./...      # 自动修
```

### 1.4 什么时候值得管

- 结构体数组/切片（`[]T`）巨大（10^5 以上）
- 频繁创建/销毁的小对象
- 缓存行关键（如 hot counter）

**单个对象不关键**。对齐优化是**累积收益**。

### 1.5 False Sharing（伪共享）

多核高频写入的字段要放在**不同 cache line**（64 字节）：

```go
import "sync/atomic"

// 反模式：两个 counter 在同一 cache line
type Counter struct {
    ReqCount  atomic.Uint64
    ErrCount  atomic.Uint64
}

// 正确：填充
type Counter struct {
    ReqCount atomic.Uint64
    _        [56]byte      // padding 到下一 cache line
    ErrCount atomic.Uint64
    _        [56]byte
}
```

用 Go 1.24+ 的 `//go:align 64` 编译指令（实验性，看版本支持）或手动 padding。

---

## 2. 空结构体 5 种用法

### 2.1 信号 channel（0 字节载荷）

```go
done := make(chan struct{})         // 不是 make(chan bool)，节约 1 字节/元素
close(done)                          // 广播
```

### 2.2 Set 语义

```go
set := map[string]struct{}{}
set["key"] = struct{}{}              // 比 map[string]bool 省 1 字节/entry
if _, ok := set["key"]; ok { ... }
```

### 2.3 类型标记（Sentinel types）

```go
type contextKey struct{ name string }
var userKey = contextKey{"user"}
ctx = context.WithValue(ctx, userKey, user)
```

避免使用 string 作为 key（避免碰撞、类型安全）。

### 2.4 零成本方法接收者

```go
type Marker struct{}
func (Marker) Valid() bool { return true }

var m Marker       // 0 字节，无分配
m.Valid()
```

### 2.5 Phantom type / 占位

```go
type ReadOnly  struct{}
type ReadWrite struct{}

type DB[Mode any] struct { conn *sql.DB }

var ro DB[ReadOnly]
var rw DB[ReadWrite]
// 编译期区分模式，运行时零开销
```

---

## 3. sync.Pool 深入

### 3.1 最小正确模板

```go
var bufPool = sync.Pool{
    New: func() any { return new(bytes.Buffer) },
}

func Use() {
    buf := bufPool.Get().(*bytes.Buffer)
    defer func() {
        buf.Reset()      // ← 必须 Reset，否则下次 Get 带脏数据
        bufPool.Put(buf)
    }()
    // ... 使用 buf ...
}
```

### 3.2 大小差异大 → 分级 Pool

```go
var (
    smallBufPool = sync.Pool{New: func() any { b := make([]byte, 0, 256);   return &b }}
    medBufPool   = sync.Pool{New: func() any { b := make([]byte, 0, 4096);  return &b }}
    largeBufPool = sync.Pool{New: func() any { b := make([]byte, 0, 65536); return &b }}
)

func getBuf(hint int) *[]byte {
    switch {
    case hint <= 256:   return smallBufPool.Get().(*[]byte)
    case hint <= 4096:  return medBufPool.Get().(*[]byte)
    default:            return largeBufPool.Get().(*[]byte)
    }
}

func putBuf(b *[]byte) {
    cap := cap(*b)
    *b = (*b)[:0]
    switch {
    case cap <= 256:   smallBufPool.Put(b)
    case cap <= 4096:  medBufPool.Put(b)
    case cap <= 65536: largeBufPool.Put(b)
    // 过大的不 Put，让它 GC 掉（避免 pool 里卡一堆大对象）
    }
}
```

### 3.3 Put 前必须清空引用

```go
// 反模式：struct 有 slice 字段，Reset 不清底层数组引用
type Request struct { Headers []Header }

func (r *Request) Reset() {
    r.Headers = r.Headers[:0]   // ← 元素依然被底层数组持有，阻止 GC
}

// 正确
func (r *Request) Reset() {
    clear(r.Headers)            // Go 1.21+ built-in：把每个元素清零
    r.Headers = r.Headers[:0]
}
```

### 3.4 何时 **不** 用 sync.Pool

- 需要显式 Close 的资源（DB 连接、文件句柄）→ 专用连接池
- 对象稀疏使用（每秒<100 次）→ 让 GC 管理即可
- 对象生命周期不能和请求对齐（如跨 goroutine 传递）
- 对象初始化成本极低（不如省开销而复用）

### 3.5 Pool 命中率监测

标准库没暴露，但可以包一层：

```go
type MonitoredPool struct {
    pool sync.Pool
    hits, misses atomic.Uint64
}

func (p *MonitoredPool) Get() any {
    v := p.pool.Get()
    if v == nil {
        p.misses.Add(1)
        return p.pool.New()
    }
    p.hits.Add(1)
    return v
}
```

命中率 < 50% 说明 pool 没发挥作用，要么用量少，要么大小不均。

---

## 4. unsafe.String / unsafe.Slice（Go 1.20+）

### 4.1 签名

```go
unsafe.String(ptr *byte, len IntegerType) string
unsafe.Slice(ptr *ArbitraryType, len IntegerType) []ArbitraryType
unsafe.StringData(str string) *byte        // 取 string 底层指针
unsafe.SliceData(slice []T) *T             // 取 slice 底层指针
```

### 4.2 `[]byte → string` 零拷贝

```go
// ✅ 仅在 b 之后不被修改时安全
func b2s(b []byte) string {
    return unsafe.String(unsafe.SliceData(b), len(b))
}
```

**不安全条件**：
- b 被其他 goroutine 同时修改 → race
- b 被后续 `append` 扩容（底层数组变）→ string 指向已释放内存 → UB
- b 源自 `bytes.Buffer.Bytes()` 且 buffer 之后会被写 → UB

### 4.3 `string → []byte` 零拷贝

```go
// ✅ 切片只读，写入立即 UB
func s2b(s string) []byte {
    return unsafe.Slice(unsafe.StringData(s), len(s))
}
```

**使用规则**：
- 只读访问（比较、解析、哈希）
- 禁止对切片写入（`b[0] = 'x'` 是 UB）
- 禁止跨 goroutine 传（除非用额外同步）

### 4.4 典型场景

```go
// map 查找（临时 key）
func lookup(m map[string]int, kb []byte) int {
    return m[unsafe.String(unsafe.SliceData(kb), len(kb))]
}

// strings 包函数调用
func contains(haystack []byte, needle string) bool {
    return strings.Contains(unsafe.String(unsafe.SliceData(haystack), len(haystack)), needle)
}
```

### 4.5 不要做

```go
// ❌ 修改 stringToBytes 返回的切片
b := s2b(s)
b[0] = 'X'                  // UB, 现代 CPU 上 string 常驻只读段 → segfault

// ❌ 返回 stringToBytes 给用户
func BadAPI(s string) []byte { return s2b(s) }  // 调用者可能写
```

---

## 5. weak.Pointer 缓存（Go 1.24+）

### 5.1 核心概念

`weak.Pointer[T]` 持有对 T 的**弱引用**：
- 只要有强引用存活，`.Value()` 返回非 nil
- 所有强引用消失后，GC 回收对象，`.Value()` 返回 nil

### 5.2 可丢缓存模式

```go
import (
    "sync"
    "weak"
)

type ResultCache[K comparable, V any] struct {
    mu    sync.Mutex
    m     map[K]weak.Pointer[V]
    load  func(K) *V
}

func NewResultCache[K comparable, V any](load func(K) *V) *ResultCache[K, V] {
    return &ResultCache[K, V]{
        m:    make(map[K]weak.Pointer[V]),
        load: load,
    }
}

func (c *ResultCache[K, V]) Get(k K) *V {
    c.mu.Lock()
    if wp, ok := c.m[k]; ok {
        if v := wp.Value(); v != nil {
            c.mu.Unlock()
            return v
        }
        delete(c.m, k)   // 被回收，清索引
    }
    c.mu.Unlock()

    v := c.load(k)
    c.mu.Lock()
    c.m[k] = weak.Make(v)
    c.mu.Unlock()
    return v
}
```

### 5.3 什么时候用

- 去重表（driver 解析同一文件多次 → 缓存 AST）
- 对象规范化（string interning）
- 热数据但允许丢失重算（vs LRU 的显式容量管理）

### 5.4 陷阱

- **不能保证命中**。只要内存压力来临，对象可能立刻被回收
- 每次 `Get` 后不立刻引用，weak 可能在下一次 GC 周期被回收
- 回收在**下次 GC** 发生，不是立即

---

## 6. 零分配 HTTP handler 模板

```go
// 目标：handler 每次请求 allocs/op = 0
var (
    respPool = sync.Pool{New: func() any { return &Response{} }}
    bufPool  = sync.Pool{New: func() any { b := make([]byte, 0, 1024); return &b }}
)

func (s *Server) handleGet(w http.ResponseWriter, r *http.Request) {
    resp := respPool.Get().(*Response)
    bufP := bufPool.Get().(*[]byte)
    defer func() {
        resp.Reset()
        respPool.Put(resp)
        *bufP = (*bufP)[:0]
        bufPool.Put(bufP)
    }()

    // 解析 id，避免 strconv.Atoi 返回 err.Error() 堆分配
    id, err := strconv.Atoi(r.PathValue("id"))    // Go 1.22+ ServeMux PathValue
    if err != nil {
        http.Error(w, "bad id", http.StatusBadRequest)
        return
    }

    s.fill(id, resp)

    // 预分配 buffer + 手动序列化
    *bufP = resp.AppendJSON(*bufP)
    w.Header().Set("Content-Type", "application/json")
    _, _ = w.Write(*bufP)
}
```

`encoding/json` 标准库难做到零分配（反射）。替代方案：
- 手写 `AppendJSON`（`strconv.Append*` + `append`）
- 代码生成（`easyjson`、`go-json`）
- `encoding/json/v2`（Go 1.25 `GOEXPERIMENT=jsonv2`）设计上减少分配

---

## 7. preallocation 速查

| 场景 | 写法 |
|---|---|
| 已知容量 slice | `make([]T, 0, n)` |
| 已知容量 map | `make(map[K]V, n)` |
| 字符串拼接 | `var b strings.Builder; b.Grow(n)` |
| bytes 累积 | `b := make([]byte, 0, n)` + `append` |
| 读 Reader | `buf := make([]byte, n); io.ReadFull(r, buf)` |
| channel 容量 | 估算生产速率 × 期望消费延迟 |

**切片 grow 回收**（Go 1.21+ `slices.Clip`）：

```go
func compact(s []int) []int {
    j := 0
    for _, x := range s {
        if x > 0 { s[j] = x; j++ }
    }
    return slices.Clip(s[:j])   // cap 缩到 j，释放多余容量
}
```

---

## 8. 容易错过的分配点

### 8.1 `fmt.Errorf("...: %w", err)`

`%w` 包装 → 分配 `*fmt.wrapError`。冷路径（错误返回）可以接受；热路径（如每次 request 成功也走 Errorf）要避免。

### 8.2 `time.Time` 通过 `String()`

`time.Time.String()` 每次分配。热路径用 `time.AppendFormat`：

```go
buf = t.AppendFormat(buf, time.RFC3339)
```

### 8.3 `strings.Split` → `[]string`

每次分配新切片。替代：`strings.SplitSeq`（Go 1.24+ 返回 `iter.Seq`，无分配）

```go
import "strings"
for part := range strings.SplitSeq(s, ",") {   // Go 1.24+
    _ = part
}
```

### 8.4 `log.Printf` 的参数

`log.Printf("id=%d", id)` —— id 装箱。热路径用 `log/slog`：

```go
slog.Info("event", "id", id)    // Any 接口但 slog 内部有优化路径
```

---

## 9. benchmark 驱动的优化验证

每个模式都应有 benchmark 验证：

```go
func BenchmarkOriginal(b *testing.B) {
    b.ReportAllocs()
    for b.Loop() { _ = original(input) }
}

func BenchmarkOptimized(b *testing.B) {
    b.ReportAllocs()
    for b.Loop() { _ = optimized(input) }
}
```

对比要看 `B/op` 和 `allocs/op`，不只是 `ns/op`：

```
BenchmarkOriginal-8    1_000_000    1234 ns/op    512 B/op    8 allocs/op
BenchmarkOptimized-8   5_000_000     234 ns/op      0 B/op    0 allocs/op
```

`allocs/op = 0` 是**热路径金标准**。
