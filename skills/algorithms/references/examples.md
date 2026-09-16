# 算法与数据结构 - 完整代码实现

## 目录

- [排序算法](#排序算法)
  - [快速排序](#快速排序)
  - [归并排序](#归并排序)
  - [堆排序](#堆排序)
- [查找算法](#查找算法)
  - [二分查找](#二分查找)
- [数据结构](#数据结构)
  - [链表](#链表)
  - [栈和队列](#栈和队列)
  - [堆/优先队列](#堆优先队列)
  - [Trie（前缀树）](#trie前缀树)
  - [并查集（Union-Find）](#并查集union-find)
- [图算法](#图算法)
  - [BFS/DFS](#bfsdfs)
  - [Dijkstra 最短路径](#dijkstra-最短路径)
  - [拓扑排序](#拓扑排序)
- [动态规划](#动态规划)
  - [背包问题](#背包问题)
  - [最长公共子序列（LCS）](#最长公共子序列lcs)
  - [最长递增子序列（LIS）](#最长递增子序列lis)
- [字符串算法](#字符串算法)
  - [KMP 模式匹配](#kmp-模式匹配)
  - [Rabin-Karp 字符串哈希](#rabin-karp-字符串哈希)
- [位运算技巧](#位运算技巧)

---

## 排序算法

### 快速排序

```go
func QuickSort[T cmp.Ordered](arr []T) {
    if len(arr) <= 1 {
        return
    }
    quickSort(arr, 0, len(arr)-1)
}

func quickSort[T cmp.Ordered](arr []T, low, high int) {
    if low < high {
        pivot := partition(arr, low, high)
        quickSort(arr, low, pivot-1)
        quickSort(arr, pivot+1, high)
    }
}

func partition[T cmp.Ordered](arr []T, low, high int) int {
    pivot := arr[high]
    i := low - 1

    for j := low; j < high; j++ {
        if arr[j] <= pivot {
            i++
            arr[i], arr[j] = arr[j], arr[i]
        }
    }
    arr[i+1], arr[high] = arr[high], arr[i+1]
    return i + 1
}
```

### 归并排序

```go
func MergeSort[T cmp.Ordered](arr []T) []T {
    if len(arr) <= 1 {
        return arr
    }

    mid := len(arr) / 2
    left := MergeSort(arr[:mid])
    right := MergeSort(arr[mid:])

    return merge(left, right)
}

func merge[T cmp.Ordered](left, right []T) []T {
    result := make([]T, 0, len(left)+len(right))
    i, j := 0, 0

    for i < len(left) && j < len(right) {
        if left[i] <= right[j] {
            result = append(result, left[i])
            i++
        } else {
            result = append(result, right[j])
            j++
        }
    }

    result = append(result, left[i:]...)
    result = append(result, right[j:]...)
    return result
}
```

### 堆排序

```go
func HeapSort[T cmp.Ordered](arr []T) {
    n := len(arr)

    // 构建最大堆
    for i := n/2 - 1; i >= 0; i-- {
        heapify(arr, n, i)
    }

    // 逐个提取元素
    for i := n - 1; i > 0; i-- {
        arr[0], arr[i] = arr[i], arr[0]
        heapify(arr, i, 0)
    }
}

func heapify[T cmp.Ordered](arr []T, n, i int) {
    largest := i
    left := 2*i + 1
    right := 2*i + 2

    if left < n && arr[left] > arr[largest] {
        largest = left
    }
    if right < n && arr[right] > arr[largest] {
        largest = right
    }

    if largest != i {
        arr[i], arr[largest] = arr[largest], arr[i]
        heapify(arr, n, largest)
    }
}
```

---

## 查找算法

### 二分查找

```go
func BinarySearch[T cmp.Ordered](arr []T, target T) int {
    left, right := 0, len(arr)-1

    for left <= right {
        mid := left + (right-left)/2

        if arr[mid] == target {
            return mid
        } else if arr[mid] < target {
            left = mid + 1
        } else {
            right = mid - 1
        }
    }
    return -1
}

// 查找第一个 >= target 的位置（lower_bound）
func LowerBound[T cmp.Ordered](arr []T, target T) int {
    left, right := 0, len(arr)

    for left < right {
        mid := left + (right-left)/2
        if arr[mid] < target {
            left = mid + 1
        } else {
            right = mid
        }
    }
    return left
}

// 查找第一个 > target 的位置（upper_bound）
func UpperBound[T cmp.Ordered](arr []T, target T) int {
    left, right := 0, len(arr)

    for left < right {
        mid := left + (right-left)/2
        if arr[mid] <= target {
            left = mid + 1
        } else {
            right = mid
        }
    }
    return left
}
```

---

## 数据结构

### 链表

```go
type ListNode[T any] struct {
    Val  T
    Next *ListNode[T]
}

// 反转链表
func ReverseList[T any](head *ListNode[T]) *ListNode[T] {
    var prev *ListNode[T]
    curr := head

    for curr != nil {
        next := curr.Next
        curr.Next = prev
        prev = curr
        curr = next
    }
    return prev
}

// 检测环
func HasCycle[T any](head *ListNode[T]) bool {
    if head == nil {
        return false
    }

    slow, fast := head, head
    for fast != nil && fast.Next != nil {
        slow = slow.Next
        fast = fast.Next.Next
        if slow == fast {
            return true
        }
    }
    return false
}

// 找到环的入口
func DetectCycle[T any](head *ListNode[T]) *ListNode[T] {
    if head == nil {
        return nil
    }

    slow, fast := head, head
    for fast != nil && fast.Next != nil {
        slow = slow.Next
        fast = fast.Next.Next
        if slow == fast {
            slow = head
            for slow != fast {
                slow = slow.Next
                fast = fast.Next
            }
            return slow
        }
    }
    return nil
}
```

### 栈和队列

```go
// 使用 slice 实现栈
type Stack[T any] struct {
    items []T
}

func (s *Stack[T]) Push(item T) {
    s.items = append(s.items, item)
}

func (s *Stack[T]) Pop() (T, bool) {
    if len(s.items) == 0 {
        var zero T
        return zero, false
    }
    item := s.items[len(s.items)-1]
    s.items = s.items[:len(s.items)-1]
    return item, true
}

func (s *Stack[T]) Peek() (T, bool) {
    if len(s.items) == 0 {
        var zero T
        return zero, false
    }
    return s.items[len(s.items)-1], true
}

// 单调栈 - 找下一个更大元素
func NextGreaterElement(nums []int) []int {
    n := len(nums)
    result := make([]int, n)
    for i := range result {
        result[i] = -1
    }

    stack := []int{} // 存储索引

    for i := 0; i < n; i++ {
        for len(stack) > 0 && nums[i] > nums[stack[len(stack)-1]] {
            idx := stack[len(stack)-1]
            stack = stack[:len(stack)-1]
            result[idx] = nums[i]
        }
        stack = append(stack, i)
    }
    return result
}
```

### 堆/优先队列

```go
import "container/heap"

// 实现 heap.Interface
type MinHeap []int

func (h MinHeap) Len() int           { return len(h) }
func (h MinHeap) Less(i, j int) bool { return h[i] < h[j] }
func (h MinHeap) Swap(i, j int)      { h[i], h[j] = h[j], h[i] }

func (h *MinHeap) Push(x any) {
    *h = append(*h, x.(int))
}

func (h *MinHeap) Pop() any {
    old := *h
    n := len(old)
    x := old[n-1]
    *h = old[:n-1]
    return x
}

// 使用
func TopK(nums []int, k int) []int {
    h := &MinHeap{}
    heap.Init(h)

    for _, num := range nums {
        heap.Push(h, num)
        if h.Len() > k {
            heap.Pop(h)
        }
    }

    result := make([]int, k)
    for i := k - 1; i >= 0; i-- {
        result[i] = heap.Pop(h).(int)
    }
    return result
}
```

### Trie（前缀树）

```go
type TrieNode struct {
    children [26]*TrieNode
    isEnd    bool
}

type Trie struct {
    root *TrieNode
}

func NewTrie() *Trie {
    return &Trie{root: &TrieNode{}}
}

func (t *Trie) Insert(word string) {
    node := t.root
    for _, ch := range word {
        idx := ch - 'a'
        if node.children[idx] == nil {
            node.children[idx] = &TrieNode{}
        }
        node = node.children[idx]
    }
    node.isEnd = true
}

func (t *Trie) Search(word string) bool {
    node := t.findNode(word)
    return node != nil && node.isEnd
}

func (t *Trie) StartsWith(prefix string) bool {
    return t.findNode(prefix) != nil
}

func (t *Trie) findNode(s string) *TrieNode {
    node := t.root
    for _, ch := range s {
        idx := ch - 'a'
        if node.children[idx] == nil {
            return nil
        }
        node = node.children[idx]
    }
    return node
}
```

### 并查集（Union-Find）

```go
type UnionFind struct {
    parent []int
    rank   []int
}

func NewUnionFind(n int) *UnionFind {
    parent := make([]int, n)
    rank := make([]int, n)
    for i := range parent {
        parent[i] = i
    }
    return &UnionFind{parent: parent, rank: rank}
}

func (uf *UnionFind) Find(x int) int {
    if uf.parent[x] != x {
        uf.parent[x] = uf.Find(uf.parent[x]) // 路径压缩
    }
    return uf.parent[x]
}

func (uf *UnionFind) Union(x, y int) bool {
    rootX, rootY := uf.Find(x), uf.Find(y)
    if rootX == rootY {
        return false
    }

    // 按秩合并
    if uf.rank[rootX] < uf.rank[rootY] {
        rootX, rootY = rootY, rootX
    }
    uf.parent[rootY] = rootX
    if uf.rank[rootX] == uf.rank[rootY] {
        uf.rank[rootX]++
    }
    return true
}

func (uf *UnionFind) Connected(x, y int) bool {
    return uf.Find(x) == uf.Find(y)
}
```

---

## 图算法

### BFS/DFS

```go
// BFS - 层序遍历
func BFS(graph map[int][]int, start int) []int {
    visited := make(map[int]bool)
    queue := []int{start}
    result := []int{}

    for len(queue) > 0 {
        node := queue[0]
        queue = queue[1:]

        if visited[node] {
            continue
        }
        visited[node] = true
        result = append(result, node)

        for _, neighbor := range graph[node] {
            if !visited[neighbor] {
                queue = append(queue, neighbor)
            }
        }
    }
    return result
}

// DFS - 递归
func DFS(graph map[int][]int, start int, visited map[int]bool) []int {
    if visited[start] {
        return nil
    }
    visited[start] = true
    result := []int{start}

    for _, neighbor := range graph[start] {
        result = append(result, DFS(graph, neighbor, visited)...)
    }
    return result
}
```

### Dijkstra 最短路径

```go
type Edge struct {
    to, weight int
}

func Dijkstra(graph map[int][]Edge, start int, n int) []int {
    dist := make([]int, n)
    for i := range dist {
        dist[i] = math.MaxInt
    }
    dist[start] = 0

    // 优先队列: (距离, 节点)
    pq := &PriorityQueue{}
    heap.Init(pq)
    heap.Push(pq, &Item{priority: 0, value: start})

    for pq.Len() > 0 {
        item := heap.Pop(pq).(*Item)
        node := item.value
        d := item.priority

        if d > dist[node] {
            continue
        }

        for _, edge := range graph[node] {
            newDist := dist[node] + edge.weight
            if newDist < dist[edge.to] {
                dist[edge.to] = newDist
                heap.Push(pq, &Item{priority: newDist, value: edge.to})
            }
        }
    }
    return dist
}
```

### 拓扑排序

```go
func TopologicalSort(graph map[int][]int, n int) ([]int, bool) {
    inDegree := make([]int, n)
    for _, neighbors := range graph {
        for _, v := range neighbors {
            inDegree[v]++
        }
    }

    queue := []int{}
    for i := 0; i < n; i++ {
        if inDegree[i] == 0 {
            queue = append(queue, i)
        }
    }

    result := []int{}
    for len(queue) > 0 {
        node := queue[0]
        queue = queue[1:]
        result = append(result, node)

        for _, neighbor := range graph[node] {
            inDegree[neighbor]--
            if inDegree[neighbor] == 0 {
                queue = append(queue, neighbor)
            }
        }
    }

    if len(result) != n {
        return nil, false // 存在环
    }
    return result, true
}
```

---

## 动态规划

### 背包问题

```go
// 0-1 背包
func Knapsack01(weights, values []int, capacity int) int {
    n := len(weights)
    dp := make([]int, capacity+1)

    for i := 0; i < n; i++ {
        for w := capacity; w >= weights[i]; w-- {
            dp[w] = max(dp[w], dp[w-weights[i]]+values[i])
        }
    }
    return dp[capacity]
}

// 完全背包
func KnapsackComplete(weights, values []int, capacity int) int {
    n := len(weights)
    dp := make([]int, capacity+1)

    for i := 0; i < n; i++ {
        for w := weights[i]; w <= capacity; w++ {
            dp[w] = max(dp[w], dp[w-weights[i]]+values[i])
        }
    }
    return dp[capacity]
}
```

### 最长公共子序列（LCS）

```go
func LCS(s1, s2 string) int {
    m, n := len(s1), len(s2)
    dp := make([][]int, m+1)
    for i := range dp {
        dp[i] = make([]int, n+1)
    }

    for i := 1; i <= m; i++ {
        for j := 1; j <= n; j++ {
            if s1[i-1] == s2[j-1] {
                dp[i][j] = dp[i-1][j-1] + 1
            } else {
                dp[i][j] = max(dp[i-1][j], dp[i][j-1])
            }
        }
    }
    return dp[m][n]
}
```

### 最长递增子序列（LIS）

```go
// O(n log n) 解法
func LIS(nums []int) int {
    tails := []int{}

    for _, num := range nums {
        pos := sort.SearchInts(tails, num)
        if pos == len(tails) {
            tails = append(tails, num)
        } else {
            tails[pos] = num
        }
    }
    return len(tails)
}
```

---

## 字符串算法

### KMP 模式匹配

```go
func KMP(text, pattern string) int {
    if len(pattern) == 0 {
        return 0
    }

    // 构建 next 数组
    next := buildNext(pattern)
    j := 0

    for i := 0; i < len(text); i++ {
        for j > 0 && text[i] != pattern[j] {
            j = next[j-1]
        }
        if text[i] == pattern[j] {
            j++
        }
        if j == len(pattern) {
            return i - j + 1
        }
    }
    return -1
}

func buildNext(pattern string) []int {
    next := make([]int, len(pattern))
    j := 0

    for i := 1; i < len(pattern); i++ {
        for j > 0 && pattern[i] != pattern[j] {
            j = next[j-1]
        }
        if pattern[i] == pattern[j] {
            j++
        }
        next[i] = j
    }
    return next
}
```

### Rabin-Karp 字符串哈希

```go
func RabinKarp(text, pattern string) int {
    if len(pattern) > len(text) {
        return -1
    }

    const base = 31
    const mod = 1_000_000_007 // 使用 int 避免 float64 精度丢失

    hashStr := func(s string) int {
        h := 0
        for _, c := range s {
            h = (h*base + int(c)) % mod
        }
        return h
    }

    patternHash := hashStr(pattern)
    windowHash := hashStr(text[:len(pattern)])

    if windowHash == patternHash && text[:len(pattern)] == pattern {
        return 0
    }

    // 预计算 base^(m-1) % mod
    pow := 1
    for i := 0; i < len(pattern)-1; i++ {
        pow = (pow * base) % mod
    }

    for i := len(pattern); i < len(text); i++ {
        // 滚动哈希（使用整数运算）
        windowHash = ((windowHash-int(text[i-len(pattern)])*pow)*base + int(text[i])) % mod
        if windowHash < 0 {
            windowHash += mod // 处理负数取模
        }
        if windowHash == patternHash && text[i-len(pattern)+1:i+1] == pattern {
            return i - len(pattern) + 1
        }
    }
    return -1
}
```

---

## 位运算技巧

```go
// 判断是否为 2 的幂
func IsPowerOfTwo(n int) bool {
    return n > 0 && n&(n-1) == 0
}

// 计算 1 的个数
func CountOnes(n int) int {
    count := 0
    for n != 0 {
        count++
        n &= n - 1
    }
    return count
}

// 获取最低位的 1
func LowestBit(n int) int {
    return n & (-n)
}

// 交换两个数（使用标准方式，XOR swap 在 a==b 时会归零）
func Swap(a, b *int) {
    *a, *b = *b, *a
}

// 判断奇偶
func IsOdd(n int) bool {
    return n&1 == 1
}
```
