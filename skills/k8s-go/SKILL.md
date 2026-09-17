---
name: k8s-go
description: "Kubernetes Go 开发专家 - 使用 client-go 编写 K8s 控制器、Operator、Informer、Lister、工作队列。适用：K8s API 交互、controller/operator 开发、CRD 操作、Pod 管理（exec/logs/port-forward）、资源 Watch 监听、fake clientset 测试。不适用：仅需 kubectl 命令行操作（无需编码）、简单 YAML 部署（用 Helm/Kustomize）、非 Go 语言的 K8s 开发（用各语言 SDK）。触发词：kubernetes, k8s, client-go, controller, operator, informer, lister, workqueue, pod, deployment, CRD, watch"
---

# Kubernetes Go 开发专家

编写 Kubernetes 相关的 Go 代码：$ARGUMENTS

基线：go1.24.6，`k8s.io/client-go v0.34.10`（`k8s.io/api`、`k8s.io/apimachinery` 必须同版本）。`v0.34.11` 起 go.mod 的 go 指令超出 go1.24 基线，Go 1.24 工具链停在 `v0.34.10`。完整可编译代码见 [references/examples.md](references/examples.md)。

```text
go get k8s.io/client-go@v0.34.10 k8s.io/api@v0.34.10 k8s.io/apimachinery@v0.34.10
```

---

## 1. 客户端

```go
// 集群内（ServiceAccount）优先，失败回退到 ~/.kube/config
func AutoConfig() (*rest.Config, error) {
    if config, err := rest.InClusterConfig(); err == nil {
        return config, nil
    }
    home, err := os.UserHomeDir()
    if err != nil {
        return nil, err
    }
    return clientcmd.BuildConfigFromFlags("", filepath.Join(home, ".kube", "config"))
}

config, _ := AutoConfig()
config.QPS, config.Burst = 50, 100 // 默认 5 / 10，控制器场景要调高
client, err := kubernetes.NewForConfig(config)
```

函数签名接收 `kubernetes.Interface` 而非 `*kubernetes.Clientset`，测试时可以传 fake。

> 完整实现见 [references/examples.md#客户端](references/examples.md#客户端)

---

## 2. CRUD

```go
client.CoreV1().Pods(ns).Create(ctx, pod, metav1.CreateOptions{})
client.CoreV1().Pods(ns).Get(ctx, name, metav1.GetOptions{})
client.CoreV1().Pods(ns).List(ctx, metav1.ListOptions{LabelSelector: "app=myapp"})
client.CoreV1().Pods(ns).Update(ctx, pod, metav1.UpdateOptions{})
client.CoreV1().Pods(ns).Delete(ctx, name, metav1.DeleteOptions{})
```

- `Update` 带 `resourceVersion` 乐观锁，冲突返回 409，用 `retry.RetryOnConflict` 重读重写
- 只改部分字段优先 `Patch`（`types.MergePatchType` 或 Server-Side Apply），避免覆盖他人修改
- 修改从缓存取到的对象前先 `DeepCopy()`

> 完整实现见 [references/examples.md#crud](references/examples.md#crud)

---

## 3. Watch 与 Informer

| 方式 | 适用 | 限制 |
|------|------|------|
| `Watch()` | 一次性脚本、简单监听 | 连接断开后 `ResultChan` 关闭，需要自己重建；无本地缓存 |
| `SharedInformer` | 控制器、长期运行的服务 | 自动 list/watch、断线重连、本地缓存、resync |

```go
factory := informers.NewSharedInformerFactory(client, 30*time.Second)
podInformer := factory.Core().V1().Pods().Informer()

_, err := podInformer.AddEventHandler(cache.ResourceEventHandlerFuncs{
    AddFunc: func(obj any) { /* obj.(*corev1.Pod) */ },
    UpdateFunc: func(oldObj, newObj any) {
        if oldObj.(*corev1.Pod).ResourceVersion == newObj.(*corev1.Pod).ResourceVersion {
            return // resync 触发的重复事件
        }
    },
    DeleteFunc: func(obj any) {
        // 缓存过期时收到 cache.DeletedFinalStateUnknown，要取 tombstone.Obj
    },
})
if err != nil {
    return err
}

factory.Start(ctx.Done())
if !cache.WaitForCacheSync(ctx.Done(), podInformer.HasSynced) {
    return fmt.Errorf("failed to sync cache")
}

// 读缓存，不打 API Server
pods, err := factory.Core().V1().Pods().Lister().Pods("default").List(labels.Everything())
```

- `AddEventHandler` 返回 `(registration, error)`，错误要处理
- 事件处理函数不要阻塞，只做入队
- 限定 namespace 用 `informers.WithNamespace(ns)`，减少缓存体积

> 完整实现见 [references/examples.md#informer](references/examples.md#informer)

---

## 4. Controller 模式

```go
type Controller struct {
    client    kubernetes.Interface
    informer  cache.SharedIndexInformer
    workqueue workqueue.TypedRateLimitingInterface[string]
}

workqueue.NewTypedRateLimitingQueueWithConfig(
    workqueue.DefaultTypedControllerRateLimiter[string](),
    workqueue.TypedRateLimitingQueueConfig[string]{Name: "pods"},
)
```

核心链路：

1. `enqueue(obj)`：`cache.DeletionHandlingMetaNamespaceKeyFunc` 取 `namespace/name` 入队（兼容 tombstone）
2. `Run(ctx, workers)`：启动 informer，`WaitForCacheSync`，起 N 个 worker
3. `processNextItem`：`Get` → `syncHandler` → 成功 `Forget`，失败 `AddRateLimited`；`NumRequeues` 超限放弃
4. `syncHandler(ctx, key)`：从 informer 缓存 `GetByKey`，对象不存在视为已删除；写回用 `RetryOnConflict`

设计要点：

- 队列只存 key，不存对象；同一 key 在队列里自动去重
- 处理必须幂等：期望状态与实际状态对账，而不是响应单个事件
- 需要 CRD、Webhook、多资源协调时直接用 controller-runtime，手写 workqueue 只适合单资源小控制器

> 完整实现见 [references/examples.md#controller](references/examples.md#controller)

---

## 5. 常用操作

```go
// exec：需要 *rest.Config
func ExecInPod(ctx context.Context, config *rest.Config, client kubernetes.Interface,
    namespace, podName, container string, command []string, stdout, stderr io.Writer) error

// port-forward：阻塞直到 ctx 结束
func PortForward(ctx context.Context, config *rest.Config, client kubernetes.Interface,
    namespace, podName string, localPort, podPort int) error

// logs：只需要 clientset
func GetPodLogs(ctx context.Context, client kubernetes.Interface,
    namespace, podName, container string, tailLines int64) (string, error)
```

- exec 用 `remotecommand.NewSPDYExecutor` + `StreamWithContext`
- port-forward 用 `spdy.RoundTripperFor` + `portforward.New`，`stopChan` 由 ctx 关闭
- 日志流式读取用 `PodLogOptions{Follow: true}`，边读边处理

> 完整实现见 [references/examples.md#常用操作](references/examples.md#常用操作)

---

## 6. 错误处理

```go
import apierrors "k8s.io/apimachinery/pkg/api/errors"

apierrors.IsNotFound(err)        // 资源不存在
apierrors.IsConflict(err)        // resourceVersion 冲突，重试
apierrors.IsAlreadyExists(err)   // 创建时已存在
apierrors.IsForbidden(err)       // RBAC 不足
apierrors.IsTooManyRequests(err) // 429，退避

err = retry.RetryOnConflict(retry.DefaultRetry, func() error {
    pod, err := client.CoreV1().Pods(ns).Get(ctx, name, metav1.GetOptions{})
    if err != nil {
        return err
    }
    pod.Labels["updated"] = "true"
    _, err = client.CoreV1().Pods(ns).Update(ctx, pod, metav1.UpdateOptions{})
    return err
})
```

> 完整实现见 [references/examples.md#错误处理](references/examples.md#错误处理)

---

## 7. 测试

```go
import "k8s.io/client-go/kubernetes/fake"

client := fake.NewClientset(&corev1.Pod{
    ObjectMeta: metav1.ObjectMeta{Name: "test-pod", Namespace: "default"},
})
pods, err := client.CoreV1().Pods("default").List(ctx, metav1.ListOptions{})
```

- `fake.NewClientset` 替代已弃用的 `NewSimpleClientset`
- fake 不执行准入、默认值和状态子资源逻辑；集成测试用 envtest 或 kind
- Informer 测试：用 fake client 建 factory，`Start` 后 `WaitForCacheSync`，再断言

> 完整实现见 [references/examples.md#测试fake-clientset](references/examples.md#测试fake-clientset)

---

## 常用依赖

| 包 | 用途 |
|----|------|
| `k8s.io/api/core/v1`、`k8s.io/api/apps/v1` | Pod、Service、Deployment 等类型 |
| `k8s.io/apimachinery/pkg/apis/meta/v1` | ObjectMeta、ListOptions |
| `k8s.io/apimachinery/pkg/api/errors` | `IsNotFound`、`IsConflict` |
| `k8s.io/apimachinery/pkg/labels` | `labels.Everything()`、Selector |
| `k8s.io/client-go/kubernetes` | Clientset、`kubernetes.Interface` |
| `k8s.io/client-go/informers`、`tools/cache` | SharedInformerFactory、EventHandler、Lister |
| `k8s.io/client-go/util/workqueue` | `TypedRateLimitingInterface[T]` |
| `k8s.io/client-go/util/retry` | `RetryOnConflict` |
| `k8s.io/client-go/tools/remotecommand`、`tools/portforward`、`transport/spdy` | exec、port-forward |
| `k8s.io/client-go/kubernetes/fake` | 单元测试 |

---

## 检查清单

- [ ] `client-go`、`api`、`apimachinery` 三个模块同版本？
- [ ] 函数接收 `kubernetes.Interface`，测试用 `fake.NewClientset`？
- [ ] 长期监听用 Informer 而非裸 Watch，`WaitForCacheSync` 后再读缓存？
- [ ] `AddEventHandler` 的 error 已处理，`DeleteFunc` 处理了 tombstone？
- [ ] 修改缓存对象前 `DeepCopy`，写回用 `RetryOnConflict` 或 `Patch`？
- [ ] 工作队列只存 key，处理逻辑幂等，重试有上限？
- [ ] 控制器 QPS/Burst 调高，RBAC 最小权限？

---

## 参考资料

- [references/examples.md](references/examples.md) - 完整可编译代码（客户端、CRUD、Watch、Informer、Controller、exec/port-forward/logs、错误处理、测试）
- [client-go pkg.go.dev](https://pkg.go.dev/k8s.io/client-go)
- [client-go examples](https://github.com/kubernetes/client-go/tree/master/examples)
- [sample-controller](https://github.com/kubernetes/sample-controller)
