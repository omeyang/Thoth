# 逃逸分析案例集（Go 1.25.9+）

## 为什么关心逃逸

栈分配零成本，堆分配付出：
1. 分配开销（mcache → mcentral → mheap 查找）
2. GC 压力（标记、清扫、写屏障）
3. 局部性下降（栈连续、堆分散）

**逃逸 ≠ 错**。但热路径每一次逃逸都要问："真的必须吗？"

## 观察命令

```bash
# -m 一次：主要决定
go build -gcflags="-m" ./... 2>&1 | grep -E "escape|moved"
# -m=2：详细，含推理
go build -gcflags="-m=2" ./... 2>&1 | less
# 看某个函数
go build -gcflags="-m=2" ./pkg/foo 2>&1 | grep "foo.go:123"
```

典型输出样例：
```
./main.go:15:6: moved to heap: x
./main.go:20:14: &Node{...} escapes to heap
./main.go:25:12: leaking param: s
```

- `moved to heap` —— 局部变量被分配到堆
- `escapes to heap` —— 表达式求值结果逃到堆
- `leaking param` —— 参数逃逸，说明该函数返回/存储了它

---

## 案例 1：返回局部变量的指针

```go
func NewUser(name string) *User {
    u := User{Name: name}
    return &u          // moved to heap: u
}
```

**修复方案**（按优先级）：

```go
// (a) 返回值
func NewUser(name string) User { return User{Name: name} }

// (b) 让调用方持有
func FillUser(u *User, name string) { u.Name = name }

// (c) 确实要指针：接受，不要无谓优化
// 对于工厂函数，返回 *T 是通常做法，单次分配可以接受
```

**判断标准**：函数调用频率 × 对象大小。每秒百万次调用的工厂函数，(a)/(b) 能拿回 1-2 个数量级。

---

## 案例 2：`fmt.Println` / `fmt.Sprintf` 在热路径

```go
func Log(id int) {
    fmt.Println("id=", id)   // id escapes to heap（装箱到 any）
}
```

`fmt.*` 的 `...any` 参数要装箱，每个非指针参数都逃。

**修复**：

```go
// 用 strconv.Append* + 预分配切片（零分配）
var bufPool = sync.Pool{New: func() any { b := make([]byte, 0, 64); return &b }}

func Log(id int) {
    bp := bufPool.Get().(*[]byte)
    buf := (*bp)[:0]
    buf = append(buf, "id="...)
    buf = strconv.AppendInt(buf, int64(id), 10)
    buf = append(buf, '\n')
    _, _ = os.Stderr.Write(buf)
    *bp = buf
    bufPool.Put(bp)
}

// 或直接用 log/slog（1.21+，有 zero-alloc handler 实现）
slog.Info("event", "id", id)
```

---

## 案例 3：goroutine 闭包捕获大对象

```go
func process(data []byte) {
    go func() {
        expensive(data)   // data escapes: captured by goroutine
    }()
}
```

goroutine 生命周期独立 → 所有捕获变量必须逃堆。

**修复**：显式参数传递

```go
func process(data []byte) {
    go func(d []byte) { expensive(d) }(data)
}
```

**注**：切片本身（`reflect.SliceHeader`）仍要传入，但底层数组不因此再逃一次。

---

## 案例 4：赋给 interface

```go
var logger any
func setLog(v SomeStruct) {
    logger = v   // v escapes to heap
}
```

接口值由（type, value pointer）组成：
- 值小且适合字长 → Go 1.4 前内联，现在几乎总是装箱
- 对于非指针大类型，赋给 interface 一定装箱

**修复**：

```go
// (a) 热路径用具体类型
var logger SomeStruct
func setLog(v SomeStruct) { logger = v }

// (b) 泛型（1.18+）
type LoggerHolder[T any] struct{ v T }
func (h *LoggerHolder[T]) Set(v T) { h.v = v }

// (c) 接口但接受装箱代价（冷路径）
```

---

## 案例 5：`append` 超容量触发扩容

```go
func collect(items []Item) []Result {
    var out []Result       // 零值切片
    for _, it := range items {
        out = append(out, transform(it))  // 多次重分配
    }
    return out
}
```

每次 `append` 超容量重分配到堆，底层数组拷贝 O(n log n) 次。

**修复**：

```go
out := make([]Result, 0, len(items))   // 一次分配
for _, it := range items {
    out = append(out, transform(it))
}
```

---

## 案例 6：map key 是拼接字符串

```go
func lookup(m map[string]int, a, b string) int {
    return m[a+"/"+b]    // a+"/"+b escapes: used as map key
}
```

字符串拼接产生新 string，作为 map key 查找，编译器可能无法证明 key 不逃逸。

**修复方案**：

```go
// (a) 用 [N]byte 数组 key（定长场景）
type Key [32]byte
m := map[Key]int{}

// (b) 预分配 buffer + unsafe.String
func lookup(m map[string]int, a, b string) int {
    var buf [64]byte
    n := copy(buf[:], a)
    n += copy(buf[n:], "/")
    n += copy(buf[n:], b)
    return m[unsafe.String(&buf[0], n)]   // 栈上 key
}
```

注：(b) 只在 key 不被 map 内部 clone 时安全；map 实际会 hash 并拷贝，所以 `unsafe.String` 只用于查找（非插入）。

---

## 案例 7：slice 传给 `...interface{}` 参数

```go
func Sum(xs []int) int {
    // 误用 fmt.Sprint 做拼接
    s := fmt.Sprint(xs)   // xs escapes
    _ = len(s)
    // ...
}
```

**修复**：热路径不用 `fmt.*` 变参函数。

---

## 案例 8：方法值（method value）

```go
type S struct{ v int }
func (s *S) Inc() { s.v++ }

func register(fn func()) { ... }

func main() {
    s := &S{}
    register(s.Inc)   // `s.Inc` escapes: method value 需要堆分配闭包
}
```

**修复**：

```go
// (a) 直接传函数
register(func() { s.Inc() })   // 一样会捕获 s，看上下文

// (b) 泛型（完全避免闭包）
func Register[T any](v T, fn func(T)) { ... }
Register(s, (*S).Inc)
```

---

## 案例 9：切片扩容成容量不受控

```go
func process(in []byte) []byte {
    out := in[:0]             // 复用底层数组
    for _, b := range in {
        if valid(b) { out = append(out, b) }
    }
    return out
}
```

`out = in[:0]` 看起来没分配，但如果 `valid(b)` 返回 true 的元素超过 `cap(in)`，`append` 会重分配。

**修复**：明确 cap

```go
out := make([]byte, 0, len(in))
for _, b := range in {
    if valid(b) { out = append(out, b) }
}
```

---

## 案例 10：defer 引发的逃逸（Go 1.14 前）

Go 1.14+ 引入 "open-coded defer"，函数内静态 defer ≤8 个、无 loop → 零开销。但：

```go
func bad(n int) {
    for i := 0; i < n; i++ {
        defer fmt.Println(i)   // defer in loop: 仍走堆分配
    }
}
```

**修复**：把 loop 内 defer 提出来或换结构：

```go
func good(n int) {
    defer func() {
        for i := 0; i < n; i++ { fmt.Println(i) }
    }()
}
```

---

## 案例 11：大数组按值传参（反直觉）

```go
type Matrix [1024][1024]float64

func sum(m Matrix) float64 {   // 按值传参 → 栈上 8 MB，可能栈扩张
    var s float64
    for i := range m { for j := range m[i] { s += m[i][j] } }
    return s
}
```

大数组按值传参 **不一定逃堆**，但会让栈大幅扩张（Go 栈分段可增长，但代价是 memcpy 和拷贝）。

**修复**：传指针

```go
func sum(m *Matrix) float64 { ... }
```

---

## 案例 12：slice growing 通过 `append` with too small hint

```go
func filter(src []int) []int {
    dst := make([]int, 0, 4)   // hint 太小
    for _, x := range src {
        if x > 0 { dst = append(dst, x) }
    }
    return dst
}
```

即使预分配，hint 过小仍导致多次扩容。**用 `len(src)` 作为上界预分配**，回收浪费内存用 `slices.Clip`：

```go
dst := make([]int, 0, len(src))
for _, x := range src { if x > 0 { dst = append(dst, x) } }
return slices.Clip(dst)   // Go 1.21+：缩 cap 到 len
```

---

## 案例 13：`context.WithValue` 传值

```go
ctx = context.WithValue(ctx, "userID", 42)   // 42 boxes to any
```

`WithValue` 的 value 是 `any`，传值一定装箱。

**修复**：

```go
// (a) 自定义 key 类型 + 指针（指针已经是 pointer-size，不额外装箱）
type userIDKey struct{}
ctx = context.WithValue(ctx, userIDKey{}, &user)

// (b) 热路径避免 context.Value，用结构化上下文
type RequestCtx struct { UserID int; TraceID string; ... }
```

---

## 案例 14：`json.Marshal` / `json.Unmarshal` 反射

标准 `encoding/json` 用反射 → 大量装箱和逃逸。

**修复**（按效果排序）：

1. 迁移到 `encoding/json/v2`（Go 1.25 实验，`GOEXPERIMENT=jsonv2`）—— 设计上减少反射、更快
2. 代码生成：`easyjson`、`ffjson`、`go-json`
3. 手写序列化（`strconv.Append*`）

---

## 案例 15：`sync.Pool` 内部的 any

```go
pool := sync.Pool{New: func() any { return new(Buffer) }}
buf := pool.Get().(*Buffer)   // *Buffer → any → *Buffer 的装箱
```

`*T` 赋给 `any` 不装箱（指针已经是单字），但 `T`（值类型）赋给 `any` 会装箱。

**规则**：`sync.Pool` 只放指针类型 `*T`。

---

## 案例 16：goroutine 池的 job struct

```go
type Job struct { ID int; Data []byte }
ch := make(chan Job, 100)    // 值传递，无逃逸
ch <- Job{ID: 1, Data: ...}  // copy 进 channel buffer（栈 → 堆，chan 在堆上）
```

channel 元素必进 chan buffer，buffer 在堆上。若 Job 巨大（KB 级），不妨传 `*Job`。

---

## 案例 17：`strings.Builder` 在接口行为

```go
var w io.Writer = &strings.Builder{}   // *Builder 已是指针，不装箱
fmt.Fprintf(w, "hello %d", 42)         // fmt 依然装箱参数
```

`*T` 赋给接口的指针部分不装箱，但 `fmt` 的 `...any` 参数依然装。

**修复**：热路径直接调用 `strings.Builder.WriteString` / `strconv.AppendInt`。

---

## 案例 18：泛型函数内部的类型参数装箱

```go
func Process[T any](v T) { use(v) }
```

Go 泛型用 **GCShape** 实现：相同 GCShape（如所有指针、所有同宽整数）共享代码。**值类型 T 不会装箱，通过 dict 获取类型信息**。

但：

```go
func Process[T any](v T) any { return v }   // v → any 会装箱
```

返回 `any` 或赋给 `any` 仍会装箱。

---

## 案例 19：`errors.Is` / `errors.As` 链长

```go
if errors.Is(err, ErrNotFound) { ... }   // 遍历 error 链
```

本身不逃逸，但每个 `Wrap` 产生的中间 error 可能已在堆上（fmt.Errorf）。

**热路径**：

```go
// 使用哨兵错误直接比较，避免 wrap
if err == ErrNotFound { ... }   // 仅当不需要堆栈信息

// 或用 errors.Join 而非嵌套 Wrap
return errors.Join(ErrNotFound, opErr)   // Go 1.20+
```

---

## 案例 20：反射 `reflect.Value.Interface()`

```go
v := reflect.ValueOf(&obj).Elem()
field := v.Field(0).Interface()   // 装箱
```

每次 `.Interface()` 装箱。减少办法：

1. 缓存 `reflect.Type` / 偏移，直接用 `unsafe.Pointer` + 指针运算读
2. 代码生成消除反射

---

## 检查清单（代码审查用）

- [ ] 函数返回 `*T` 但 T 很小 → 考虑值返回
- [ ] 热路径有 `fmt.*` 调用 → 用 `strconv.Append*`
- [ ] `go func()` 捕获变量 → 改成参数显式传
- [ ] 循环 `append` 无 `make([]T, 0, n)` 预分配 → 修
- [ ] map key 是 `a+b+c` 拼接 → 定长 key 或 builder
- [ ] 值类型赋给 `any` / interface → 换具体类型或泛型
- [ ] channel 元素 > 128B → 考虑传指针
- [ ] `sync.Pool` 元素是值类型 → 改为 `*T`
- [ ] `defer` 在 loop 内 → 重构
- [ ] 大数组按值传参 → 改指针

## 验证方法

每次修改后：

```bash
# 前后对比
go build -gcflags="-m=2" ./pkg/... 2>&1 | grep escape > before.txt
# --- 修改 ---
go build -gcflags="-m=2" ./pkg/... 2>&1 | grep escape > after.txt
diff before.txt after.txt
```

最终以 benchmark `allocs/op` 下降为证据。
