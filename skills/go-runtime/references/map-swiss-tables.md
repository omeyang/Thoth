# Map 实现：Swiss Tables（Go 1.24+）

聚焦 SKILL.md §4 的细节：新旧实现差异、迁移影响、性能特征。

---

## 1. 旧实现（Go 1.23 及以前）

### 1.1 结构

```
hmap
 ├── count      (当前元素数)
 ├── B          (2^B = bucket 数)
 ├── buckets    (bucket 数组指针)
 ├── oldbuckets (增量扩容用)
 └── ...

每个 bucket:
  ├── tophash[8]   (高位哈希，快速比较)
  ├── keys[8]
  ├── values[8]
  └── overflow *bmap (溢出链)
```

### 1.2 查找

```
h := hash(key)
bucketIdx := h & ((1<<B) - 1)
topHash := h >> 56

bucket := buckets[bucketIdx]
loop:
    for i in 0..8:
        if bucket.tophash[i] == topHash:
            if bucket.keys[i] == key:
                return bucket.values[i]
    if bucket.overflow == nil: return notFound
    bucket = *bucket.overflow    // 链表后继
    goto loop
```

### 1.3 装填因子

负载因子 6.5（意味 bucket 平均含 6.5 个元素时触发扩容）。扩容是**增量**的（每次 map 操作迁移 1-2 个 bucket，避免单次卡顿）。

### 1.4 问题

- 极端哈希冲突：overflow 链变长 → 查找退化到 O(链长)
- cache 局部性差：一个 bucket 8 个 key，遍历线性扫，但 overflow 链跨 cache line
- tophash 比较是一一对比，现代 CPU SIMD 闲置

---

## 2. 新实现（Go 1.24+）：Swiss Tables

### 2.1 设计来源

Google Abseil `flat_hash_map`。核心思想：

- **groups of 8 slots**（或 16，架构相关）
- 每个 group 一个 **control byte 数组**（1 byte/slot）存元数据
- **SIMD 并行比较** 8 个 control byte

### 2.2 结构（简化）

```
table
 ├── ctrl[]      (control bytes，1 字节/slot)
 │                  0xFE=空, 0x80=墓碑(已删除), 其他=哈希低 7 位 h2(hash)
 ├── slots[]     (kv pairs)
 └── growthLeft  (还能容纳多少次插入)
```

### 2.3 查找

```
h := hash(key)
h1 := h >> 7              // 用于定位 group
h2 := h & 0x7F            // 用于匹配 ctrl

groupIdx := h1 mod numGroups
loop:
    group := ctrl[groupIdx * 8 .. +8]   // 8 bytes

    // SIMD：一次比较 8 个 ctrl 是否等于 h2
    matches := SIMD_cmpeq(group, h2)

    // matches 是 8 位 mask，每 1 代表一个候选 slot
    for i in matches.bits():
        if slots[groupIdx*8 + i].key == key:
            return slots[groupIdx*8 + i].value

    // 若 group 有空 slot（ctrl == 0xFE）→ 未找到
    if SIMD_hasEmpty(group): return notFound

    // 否则继续下一个 group（开放寻址探测）
    groupIdx = (groupIdx + 1) mod numGroups
```

**关键收益**：
1. ctrl 很紧凑（1 字节/slot），一个 cache line（64B）容纳 64 个 ctrl
2. SIMD 比较 8 个 ctrl 只 1 条指令（x86 AVX2、ARM NEON）
3. 空 slot 检测也 SIMD 化，探测终止快

### 2.4 装填因子

默认 ~87.5%（比旧实现 6.5/8 = 81% 略高）。空间更省。

---

## 3. 性能对比

基于 Go 官方 benchmark 和社区测试（值类型 key，典型数字）：

| 操作 | 小 map (<16) | 中 map (16-10K) | 大 map (>10^6) |
|---|---|---|---|
| 查找命中 | 持平 | -15% | -25% |
| 查找 miss | 持平 | -20% | -30% |
| 插入 | 略慢 | -10% | -20% |
| 删除 | 持平 | -10% | -15% |
| 遍历 | -5% | -15% | -25% |
| 内存占用 | 持平 | -5% | -10% |

### 3.1 为什么小 map 略慢

Swiss Tables 的固定元数据（ctrl 数组、growth counter 等）有最低开销。<16 个元素时，8-slot bucket 的旧实现足够紧凑。

对于极小 map，社区讨论过"静态分配 array-map"（如 `runtime.hashKeyType`），但目前没有。

### 3.2 为什么大 map 收益大

- 探测链短（负载高仍保持低探测步数）
- cache 友好（ctrl 聚集 → 一次 load 拿多次比较的数据）
- SIMD 吞吐高

---

## 4. 迁移影响

### 4.1 绝大多数代码无需改动

升级 Go 到 1.24+ 即得性能改善，**无源码变动**。

### 4.2 可能变化的行为

- **map 遍历顺序**：仍是伪随机，但随机分布可能不同。不要依赖特定顺序
- **map 删除时机**：标记为墓碑 + 后台清理，`len(m)` 立刻反映
- **内存占用**：略低（可能影响 pprof heap 数字）

### 4.3 不再必要的优化

```go
// 旧代码的"分片 map"优化
type ShardedMap[K comparable, V any] struct {
    shards [256]struct {
        sync.RWMutex
        m map[K]V
    }
}
```

Swiss Tables 后，**单锁 map 在大多数场景已不再是瓶颈**。分片 map 只在极高争用（>100 万 qps / key）时仍有必要。

复审代码库：

```bash
grep -rn "shards\[.*\]" --include="*.go"
```

能简化回 `sync.Map` 或带锁 `map` 的场景考虑简化。

### 4.4 sync.Map 也受益

`sync.Map` 内部也用新 map 实现。读多写少场景（稳定键集）性能可能和 `atomic.Pointer[map[K]V] + COW` 更接近。但仍推荐：

- 键稳定 → `atomic.Pointer[map[K]V]` COW（无锁读）
- 键不断变 → `sync.Map`（1.24+ 改进）

---

## 5. Map 使用注意（不变）

以下**不受实现变化影响**，仍然重要：

### 5.1 预分配容量

```go
m := make(map[string]int, 10_000)   // 避免反复 rehash
```

### 5.2 删除会留墓碑

```go
for k := range m { delete(m, k) }   // 墓碑可能不立即清理
```

**清空用 `clear(m)`（Go 1.21+ 内置）**，直接重置底层结构：

```go
clear(m)   // O(1)，无墓碑残留
```

### 5.3 复制用 `maps.Clone`

```go
import "maps"

m2 := maps.Clone(m)   // Go 1.21+
```

比手写 for-loop 快（运行时内部按 group 拷贝）。

### 5.4 map 不并发安全

并发读写需要：
- `sync.RWMutex` 保护
- `atomic.Pointer[map[K]V]` COW（适合键稳定）
- `sync.Map`（键变化频繁）

**race detector** 能检测：

```bash
go test -race ./...
go run -race main.go
```

---

## 6. 观察

### 6.1 heap profile 看 map 占用

```bash
go tool pprof -http=:8080 heap.pb.gz
# 搜索 "runtime.mapassign"、"runtime.makemap"
```

### 6.2 len 不等于内存

`len(m)` 是元素数。实际内存：ctrl + slots + 负载因子 overhead。10^6 key/int64 value 的 map 约占 50-60 MiB（1.24+）。

### 6.3 map 遍历分配

```go
for k, v := range m { ... }
```

不分配（迭代器在栈上）。但如果你 `for k := range m { slice = append(slice, k) }` 而没预分配 slice，那是 slice 分配。

---

## 7. 特殊 key 类型

### 7.1 interface 作 key

```go
m := map[any]int{}
m["foo"] = 1
m[42] = 2
```

每次操作走 reflect 路径：hash 和 equal 都通过 `_type` 方法表。比具体 key 慢 **5-10×**。热路径避免。

### 7.2 struct 作 key

```go
type K struct { A, B int64 }
m := map[K]int{}
```

要求**可比较**（字段递归可比较）。字段对齐会影响 hash 计算（未对齐字段不是 key 字段，但内存布局差异可能带来 hash 碰撞）。保持结构体紧凑（对齐见 `go-performance` 对齐章节）。

### 7.3 float 作 key

合法但**小心 NaN**：`NaN != NaN`，所以 `m[NaN] = 1; m[NaN]` 永远取不到。

### 7.4 slice/map/func 不可作 key

编译错误。因为它们不是可比较类型。

---

## 8. 历史演进

- Go 1.0-1.4: 初始 hashmap
- Go 1.5: 引入增量扩容
- Go 1.7: 改进 hash（对 string 用 aeshash）
- Go 1.8: 更好的重哈希（避免 O(n) 峰值）
- Go 1.18: 加入泛型（类型特化内联）
- **Go 1.24: Swiss Tables 全量替换**
- Go 1.25: 对 sync.Map 的连锁改进

---

## 9. 调试

### 9.1 极端 hash 碰撞

理论上 Go hash 被 seed 随机化，无法预测碰撞。但：
- 自定义类型 + 不良 hash → 可能集中在少数 group
- 未来若实现 hash-flooding 攻击防护变更，注意

### 9.2 map 操作罕见慢

单次操作 >1μs（高频场景）应该报警。排查：
- heap 有泄漏 → map 持续增长未清理
- value 是大对象 → load/store 大 memcpy
- rehash 正在进行（大 map 增量扩容中偶发慢）

---

## 10. 最佳实践

- 预分配容量
- 用 `clear()` 而非 `for; delete`
- 键稳定的只读映射用 `atomic.Pointer` + `maps.Clone`
- 并发用 `sync.Map` 或 RWMutex
- 不依赖遍历顺序
- 不要 interface key 在热路径
- 升级到 Go 1.24+ 享受 Swiss Tables
