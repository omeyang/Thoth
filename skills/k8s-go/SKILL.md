---
name: k8s-go
description: "Kubernetes Go 开发专家 - 使用 client-go 编写 K8s 控制器、Operator、Informer、工作队列。适用：K8s API 交互、controller/operator 开发、CRD 操作、Pod 管理（exec/logs/port-forward）、资源 Watch 监听。不适用：仅需 kubectl 命令行操作（无需编码）、简单 YAML 部署（用 Helm/Kustomize）、非 Go 语言的 K8s 开发（用各语言 SDK）。触发词：kubernetes, k8s, client-go, controller, operator, informer, workqueue, pod, deployment, CRD, watch"
user-invocable: true
allowed-tools: Bash, Read, Write, Edit, Grep, Glob
---

# Kubernetes Go 开发专家

编写 Kubernetes 相关的 Go 代码：$ARGUMENTS

## client-go 基础

### 创建客户端

```go
// 集群内运行（Pod 内）
func inClusterClient() (*kubernetes.Clientset, error)
// 集群外运行（使用 kubeconfig）
func outOfClusterClient(kubeconfig string) (*kubernetes.Clientset, error)
// 自动检测环境（推荐）
func autoClient() (*kubernetes.Clientset, error)
```

> 完整实现见 [references/examples.md](references/examples.md#创建客户端)

### CRUD 操作

```go
// 创建 Pod
client.CoreV1().Pods(ns).Create(ctx, pod, metav1.CreateOptions{})
// 读取
client.CoreV1().Pods(ns).Get(ctx, name, metav1.GetOptions{})
// 列表（带 label 过滤）
client.CoreV1().Pods(ns).List(ctx, metav1.ListOptions{LabelSelector: "app=myapp"})
// 更新
client.CoreV1().Pods(ns).Update(ctx, pod, metav1.UpdateOptions{})
// 删除
client.CoreV1().Pods(ns).Delete(ctx, name, metav1.DeleteOptions{})
```

> 完整实现见 [references/examples.md](references/examples.md#crud-操作)

## Watch 和 Informer

### 使用 Watch

```go
func watchPods(ctx context.Context, client *kubernetes.Clientset, ns string) error
```

- 监听 Added / Modified / Deleted 事件
- 适合简单场景

### 使用 SharedInformer（推荐）

```go
factory := informers.NewSharedInformerFactory(client, 30*time.Second)
podInformer := factory.Core().V1().Pods().Informer()
podInformer.AddEventHandler(cache.ResourceEventHandlerFuncs{
    AddFunc:    func(obj interface{}) { ... },
    UpdateFunc: func(oldObj, newObj interface{}) { ... },
    DeleteFunc: func(obj interface{}) { ... }, // 注意处理 tombstone
})
factory.Start(ctx.Done())
cache.WaitForCacheSync(ctx.Done(), podInformer.HasSynced)
```

> 完整实现见 [references/examples.md](references/examples.md#watch-和-informer)

## Controller 模式

### 工作队列

Controller 核心结构：

```go
type Controller struct {
    client    *kubernetes.Clientset
    informer  cache.SharedIndexInformer
    workqueue workqueue.TypedRateLimitingInterface[string]
}
```

核心方法链：

1. `enqueue(obj)` -- 从事件中提取 key，加入队列
2. `Run(ctx, workers)` -- 启动 informer + worker goroutines
3. `processNextItem(ctx)` -- 从队列取 key 处理
4. `syncHandler(ctx, key)` -- 业务逻辑（获取对象、处理、重试）

> 完整实现见 [references/examples.md](references/examples.md#controller-模式)

## 常用操作

### 执行 Pod 命令

```go
func execInPod(ctx context.Context, config *rest.Config, client *kubernetes.Clientset,
    namespace, podName, container string, command []string) error
```

### 端口转发

```go
func portForward(ctx context.Context, config *rest.Config, client *kubernetes.Clientset,
    namespace, podName string, localPort, podPort int) error
```

### 获取 Pod 日志

```go
func getPodLogs(ctx context.Context, client *kubernetes.Clientset,
    namespace, podName, container string, tailLines int64) (string, error)
```

> 完整实现见 [references/examples.md](references/examples.md#常用操作)

## 错误处理

```go
import apierrors "k8s.io/apimachinery/pkg/api/errors"

apierrors.IsNotFound(err)      // 资源不存在
apierrors.IsConflict(err)      // 版本冲突，需要重试
apierrors.IsAlreadyExists(err) // 资源已存在
apierrors.IsForbidden(err)     // 权限不足

// 重试冲突
retry.RetryOnConflict(retry.DefaultRetry, func() error {
    pod, err := client.CoreV1().Pods(ns).Get(ctx, name, metav1.GetOptions{})
    // ... 修改 + 更新
})
```

> 完整实现见 [references/examples.md](references/examples.md#错误处理)

## 测试

### 使用 fake client

```go
client := fake.NewSimpleClientset(&corev1.Pod{...})
pods, err := client.CoreV1().Pods("default").List(ctx, metav1.ListOptions{})
```

> 完整实现见 [references/examples.md](references/examples.md#测试)

## 常用依赖

| 包 | 用途 |
|----|------|
| `k8s.io/api/core/v1` | Pod, Service 等核心类型 |
| `k8s.io/api/apps/v1` | Deployment, StatefulSet 等 |
| `k8s.io/apimachinery/pkg/apis/meta/v1` | ObjectMeta, ListOptions |
| `k8s.io/client-go/kubernetes` | Clientset |
| `k8s.io/client-go/informers` | SharedInformerFactory |
| `k8s.io/client-go/tools/cache` | Informer, EventHandler |
| `k8s.io/client-go/util/workqueue` | RateLimitingQueue |
| `k8s.io/client-go/util/retry` | RetryOnConflict |
| `k8s.io/apimachinery/pkg/api/errors` | IsNotFound, IsConflict |

---

## 参考资料

- [完整代码示例](references/examples.md) — 客户端创建、CRUD、Informer、Controller、Pod 操作、错误处理、测试完整实现
