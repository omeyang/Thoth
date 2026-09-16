---
name: algorithms
description: "Go 算法与数据结构专家 - 实现高效算法、选择合适数据结构、分析时间空间复杂度。适用：性能优化、算法设计、数据结构选择、排序查找实现、图算法、动态规划、字符串匹配。不适用：纯业务逻辑开发（无算法需求）、数据库查询优化（应使用 db 专家）、前端/UI 开发。触发词：algorithm, sort, search, binary search, graph, BFS, DFS, dynamic programming, DP, trie, heap, union-find, KMP, 排序, 查找, 算法, 数据结构, 复杂度"
user-invocable: true
allowed-tools: Bash, Read, Write, Edit, Grep, Glob
---

# 算法与数据结构专家

解决算法问题：$ARGUMENTS

## 时间复杂度速查

| 复杂度 | 名称 | 示例 |
|--------|------|------|
| O(1) | 常数 | 哈希表查找、数组索引访问 |
| O(log n) | 对数 | 二分查找、平衡树操作 |
| O(n) | 线性 | 遍历数组、链表 |
| O(n log n) | 线性对数 | 快速排序、归并排序 |
| O(n²) | 平方 | 冒泡排序、嵌套循环 |
| O(2^n) | 指数 | 递归斐波那契、子集枚举 |

## 排序算法

- **快速排序** `QuickSort[T cmp.Ordered](arr []T)` - 原地排序，平均 O(n log n)，基于分区
- **归并排序** `MergeSort[T cmp.Ordered](arr []T) []T` - 稳定排序，O(n log n)，需要额外空间
- **堆排序** `HeapSort[T cmp.Ordered](arr []T)` - 原地排序，O(n log n)，构建最大堆后逐个提取

## 查找算法

- **二分查找** `BinarySearch[T cmp.Ordered](arr []T, target T) int` - O(log n)，有序数组精确查找
- **LowerBound** `LowerBound[T cmp.Ordered](arr []T, target T) int` - 查找第一个 >= target 的位置
- **UpperBound** `UpperBound[T cmp.Ordered](arr []T, target T) int` - 查找第一个 > target 的位置

## 数据结构

- **链表** `ListNode[T any]` - 反转链表 `ReverseList`、检测环 `HasCycle`、找环入口 `DetectCycle`
- **栈** `Stack[T any]` - Push/Pop/Peek，单调栈 `NextGreaterElement`
- **堆/优先队列** `MinHeap` 实现 `heap.Interface`，TopK 问题
- **Trie（前缀树）** - Insert/Search/StartsWith，前缀匹配查询
- **并查集** `UnionFind` - Find（路径压缩）、Union（按秩合并）、Connected

## 图算法

- **BFS** `BFS(graph map[int][]int, start int) []int` - 层序遍历，最短路径（无权图）
- **DFS** `DFS(graph map[int][]int, start int, visited map[int]bool) []int` - 深度优先递归遍历
- **Dijkstra** `Dijkstra(graph map[int][]Edge, start int, n int) []int` - 单源最短路径（带权图）
- **拓扑排序** `TopologicalSort(graph map[int][]int, n int) ([]int, bool)` - DAG 依赖排序，检测环

## 动态规划

- **0-1 背包** `Knapsack01(weights, values []int, capacity int) int` - 每个物品只能选一次
- **完全背包** `KnapsackComplete(weights, values []int, capacity int) int` - 每个物品可选无限次
- **LCS** `LCS(s1, s2 string) int` - 最长公共子序列
- **LIS** `LIS(nums []int) int` - 最长递增子序列，O(n log n) 解法

## 字符串算法

- **KMP** `KMP(text, pattern string) int` - O(n+m) 模式匹配，构建 next 数组
- **Rabin-Karp** `RabinKarp(text, pattern string) int` - 滚动哈希匹配，整数运算避免精度丢失

## 位运算技巧

- `IsPowerOfTwo(n int) bool` - `n & (n-1) == 0`
- `CountOnes(n int) int` - Brian Kernighan 算法
- `LowestBit(n int) int` - `n & (-n)`
- `IsOdd(n int) bool` - `n & 1 == 1`

## 算法选择指南

| 场景 | 推荐算法/数据结构 |
|------|------------------|
| 有序数据查找 | 二分查找 O(log n) |
| 快速查找/去重 | 哈希表 O(1) |
| 前缀查询 | Trie |
| 动态排序 | 堆 |
| 区间查询 | 线段树、树状数组 |
| 连通性 | 并查集 |
| 最短路径 | Dijkstra、BFS |
| 拓扑依赖 | 拓扑排序 |
| 最优子结构 | 动态规划 |
| 字符串匹配 | KMP、Rabin-Karp |

## 参考资料

- [完整代码实现](references/examples.md) - 所有算法和数据结构的完整 Go 泛型实现
