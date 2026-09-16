# GC 深度（Go 1.25.9+）

聚焦 SKILL.md §2 的细节：屏障正确性、pacer 数学、Green Tea 区别。

---

## 1. 三色标记正确性

### 1.1 白、灰、黑不变式

- **强三色不变式**：黑不直接指向白
- **弱三色不变式**：黑指向白时，白可被某灰对象（或灰对象到它的路径）到达

只要保持其中一个，回收就安全。

### 1.2 违反场景

并发标记中，应用改指针：

```
初始: A(黑) → B(白)     // B 是 A 的字段
      C(灰) → B(白)     // C 等待扫描会扫到 B

操作: A.B = nil          // A 移除对 B 的引用
      C.X = nil          // C 也移除
      → B 没有任何灰对象能到达（弱不变式破坏）
      → 扫描 C 时发现 C 没指向 B
      → B 被误认为不可达 → 错误回收
```

### 1.3 写屏障修正

**Yuasa 屏障**（删除屏障）：移除"原值"时着灰

```go
// *p = q 伪代码
write_barrier(p, q):
    if old := *p; old != nil {
        if old 是白 {
            标记 old 为灰    // 保留原值的可达性
        }
    }
    *p = q
```

**Dijkstra 屏障**（插入屏障）：写入"新值"时着灰

```go
write_barrier(p, q):
    if q 是白 {
        标记 q 为灰    // 保证新增引用不丢失
    }
    *p = q
```

**Go 的混合屏障（1.8+）**：栈保持黑 + 对堆的写同时处理原值和新值。让栈扫描无需 STW。

---

## 2. GC 阶段时间线

```
[Sweep Termination STW]  → 清理上一轮残留
[Mark Setup STW]         → 开启写屏障，扫描全局 root
[Concurrent Mark]        → 应用和 GC 并发运行，扫堆
                           ↓
                           应用分配 → 消耗"分配配额"→ 用完则 assist
[Mark Termination STW]   → 关闭屏障，final check
[Concurrent Sweep]       → 归还 mspan 给 mcentral/mheap
```

两个 STW 各约几十微秒（heap 小）到几百微秒（heap 大，大量 goroutine）。

---

## 3. GC Pacer 数学

### 3.1 触发时机

下一次 GC 在**预测的堆大小 = 当前活堆 × (1 + GOGC/100)** 时启动。

- `GOGC=100`: 堆翻倍时触发
- `GOGC=50`: 堆增长 50% 即触发（更频繁，更小 heap，更多 CPU）
- `GOGC=200`: 堆增长 200% 才触发（更少 GC，更大 heap）
- `GOGC=off`: 不触发自动 GC

### 3.2 Pacer 反馈控制（Go 1.18+ 重写）

旧 Pacer 是 PI 控制器；1.18+ 改为 **PI with soft memory limit**。算法（简化）：

```
分配配额 = heap_goal - 当前 heap
扫描配额 = 预估剩余活对象 × 每字节扫描时间

每次分配 X 字节：
    已用分配配额 += X
    应扫描字节 = 已用分配配额 × (扫描配额 / 分配配额)
    如果应扫描 > 已扫描：
        当前 G 进入 gcAssistAlloc，帮忙扫一段
```

"assist" 就是应用 goroutine 被 pacer 判定为"欠债"时，被拉去帮忙。CPU profile 中 `gcAssistAlloc` 宽 = 分配太快、GC 跟不上。

### 3.3 soft memory limit（1.19+）

`GOMEMLIMIT=4GiB` 给 pacer 另一个目标：**heap 绝不超过 4GB**。

```
当 heap 接近 GOMEMLIMIT：
    pacer 降低"分配速度 × 分配配额"的比例
    → 触发更频繁 GC
    → 即使 GOGC 触发条件未到，也提前 GC
```

代价：GC 频率升高，CPU 占比可能从 5% 升到 15%。但避免 OOMKilled。

**容器部署始终设 GOMEMLIMIT**。

---

## 4. Green Tea GC（Go 1.25 实验）

### 4.1 动机

传统 pacer 在以下场景表现差：
- 大堆（>10GB）+ 高分配率：assist 比例大，应用吞吐下降
- 活对象占比变化剧烈：pacer 估算失准
- NUMA 机器：跨节点扫描慢

### 4.2 Green Tea 改进点

（基于公开提案 + 1.25 release notes）：
- **更聪明的 work distribution**：mark worker 分片更均衡
- **减少 assist**：应用 goroutine 少被拉去帮忙
- **改进的 pacer**：对突发分配更鲁棒

### 4.3 启用和评估

```bash
# Baseline
./app 2>&1 | tee base.log
GODEBUG=gctrace=1 ./app 2>&1 > base-gc.log

# Green Tea
GOEXPERIMENT=greenteagc ./app 2>&1 | tee gt.log
GODEBUG=gctrace=1 GOEXPERIMENT=greenteagc ./app 2>&1 > gt-gc.log

# 对比：STW 分布、GC 占比、p99 延迟
```

典型改善：p99 延迟 -20-40%，吞吐持平或 -1-3%。

### 4.4 何时不启用

- 小堆（<1GB）：效果不明显
- 1.25 早期 patch 版（等到 1.25.6+ 稳定）
- 对 CPU 占比极敏感的后台任务（可能吞吐略降）

---

## 5. GC 相关 GODEBUG 全集

| 标志 | 作用 |
|---|---|
| `gctrace=1` | 每次 GC 打一行简要 |
| `gctrace=2` | 更详细，含 mark 扫描字节数、分配速率 |
| `gcstoptheworld=1` | 全 STW（关闭并发标记，调试用） |
| `gcstoptheworld=2` | 全 STW + 关闭并发清理 |
| `gcpacertrace=1` | Pacer 决策日志（调参用） |
| `madvdontneed=1` | scavenger 用 MADV_DONTNEED（Linux 立即归还） |
| `madvdontneed=0` | 用 MADV_FREE（默认，延迟归还） |

### 5.1 madvdontneed

- `MADV_FREE`: 告诉 kernel 这段内存可以丢，但物理页不一定立即回收；RSS 看起来没降
- `MADV_DONTNEED`: 立即回收物理页；RSS 立刻降

**容器运行时**若按 RSS 限额，设 `madvdontneed=1` 让 kernel 立即归还，避免误判 OOM。

---

## 6. GC 触发的其他原因

除了 heap 增长到 goal：

1. `runtime.GC()` 显式调用
2. 定时触发：2 分钟没 GC 强制一次
3. `debug.SetGCPercent()` 动态修改 GOGC

---

## 7. 诊断 GC 抖动

### 7.1 症状：p99 延迟定期尖刺

```
请求延迟时间序列：
p50  2ms 2ms 2ms 2ms 2ms
p99  5ms 5ms 80ms 5ms 5ms 80ms ...   ← 每隔一段出现高峰
```

### 7.2 排查步骤

1. **开 gctrace 看 GC 频率**
   ```bash
   GODEBUG=gctrace=1 ./app 2>&1 | head -50
   ```
   如果 GC 每 500ms 一次，STW 20ms → 高度可疑
2. **看 STW 分布**
   单次 STW > 10ms → 太多栈要扫，或堆指针密度高
3. **看 goroutine 数**
   10^5 以上 goroutine → 栈扫描成本高
4. **看活对象数**
   `heap goal` 相对 `heap live` 很接近 → 分配速率跟不上
5. **对比 Green Tea**
   `GOEXPERIMENT=greenteagc` 后 STW 是否明显降
6. **最终手段**：降低分配速率（见 go-performance §4）

---

## 8. 栈扫描优化

每个 goroutine 的栈都要扫：

- 栈小（2KB-8KB 典型）→ 扫描极快
- 栈大（MB 级长时间运行）→ 扫描慢

goroutine 泄漏或深递归 → 栈大 → GC 慢。每次 GC 都要扫。

### 8.1 防止栈过大

```go
// 反模式：深递归
func traverse(n *Node) {
    if n == nil { return }
    traverse(n.Left)
    traverse(n.Right)
}

// 正确：迭代 + 栈切片
func traverse(root *Node) {
    stack := []*Node{root}
    for len(stack) > 0 {
        n := stack[len(stack)-1]
        stack = stack[:len(stack)-1]
        if n == nil { continue }
        stack = append(stack, n.Left, n.Right)
    }
}
```

---

## 9. 归还内存给 OS (scavenger)

GC 释放 mspan 但物理页不立即还给 OS。scavenger 负责：

1. 持续扫描空闲 mspan
2. 对连续 >= runtime.physHugePageSize 的空闲区域，调用 `madvise(DONTNEED/FREE)`
3. RSS 下降

**观察**：

```bash
GODEBUG=gctrace=1 ./app 2>&1 | grep -oE '[0-9]+ MB released'
```

或 `runtime/metrics`：

```go
import "runtime/metrics"

samples := []metrics.Sample{
    {Name: "/memory/classes/heap/released:bytes"},
    {Name: "/memory/classes/heap/unused:bytes"},
}
metrics.Read(samples)
```

---

## 10. 常见误解

### 10.1 "GOGC=off 关闭 GC"

错。它只关闭**自动 GC**，手动 `runtime.GC()` 仍然运行；`GOMEMLIMIT` 压到上限也会强制 GC。

### 10.2 "GC 越少越快"

错。GC 少 = heap 大 = cache miss 多 = 单次 alloc 更慢 + 内存压力。需平衡。

### 10.3 "sync.Pool 避免 GC"

部分对。Pool 复用避免频繁分配，但 Pool 本身在 GC 时可能被清空（1.13 后是两次 GC 清空一次）。真正避免 GC 还是降低分配速率。

### 10.4 "大对象不触发 GC"

错。所有堆分配都算入 pacer。大对象从 mheap 直接分配，GC 扫描时也扫它。
