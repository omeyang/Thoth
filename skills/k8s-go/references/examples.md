# Kubernetes Go 完整代码示例

## 目录

- [创建客户端](#创建客户端)
- [CRUD 操作](#crud-操作)
- [Watch 和 Informer](#watch-和-informer)
  - [使用 Watch](#使用-watch)
  - [使用 SharedInformer](#使用-sharedinformer推荐)
- [Controller 模式](#controller-模式)
- [常用操作](#常用操作)
  - [执行 Pod 命令](#执行-pod-命令)
  - [端口转发](#端口转发)
  - [获取 Pod 日志](#获取-pod-日志)
- [错误处理](#错误处理)
- [测试](#测试)
- [常用依赖](#常用依赖)

---

## 创建客户端

```go
import (
    "k8s.io/client-go/kubernetes"
    "k8s.io/client-go/rest"
    "k8s.io/client-go/tools/clientcmd"
)

// 集群内运行（Pod 内）
func inClusterClient() (*kubernetes.Clientset, error) {
    config, err := rest.InClusterConfig()
    if err != nil {
        return nil, err
    }
    return kubernetes.NewForConfig(config)
}

// 集群外运行（使用 kubeconfig）
func outOfClusterClient(kubeconfig string) (*kubernetes.Clientset, error) {
    config, err := clientcmd.BuildConfigFromFlags("", kubeconfig)
    if err != nil {
        return nil, err
    }
    return kubernetes.NewForConfig(config)
}

// 自动检测环境
func autoClient() (*kubernetes.Clientset, error) {
    config, err := rest.InClusterConfig()
    if err != nil {
        // 回退到 kubeconfig
        kubeconfig := filepath.Join(os.Getenv("HOME"), ".kube", "config")
        config, err = clientcmd.BuildConfigFromFlags("", kubeconfig)
        if err != nil {
            return nil, err
        }
    }
    return kubernetes.NewForConfig(config)
}
```

---

## CRUD 操作

```go
import (
    corev1 "k8s.io/api/core/v1"
    metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
)

// 创建
func createPod(ctx context.Context, client *kubernetes.Clientset) error {
    pod := &corev1.Pod{
        ObjectMeta: metav1.ObjectMeta{
            Name:      "my-pod",
            Namespace: "default",
            Labels: map[string]string{
                "app": "myapp",
            },
        },
        Spec: corev1.PodSpec{
            Containers: []corev1.Container{
                {
                    Name:  "main",
                    Image: "nginx:latest",
                },
            },
        },
    }

    _, err := client.CoreV1().Pods("default").Create(ctx, pod, metav1.CreateOptions{})
    return err
}

// 读取
func getPod(ctx context.Context, client *kubernetes.Clientset, name, ns string) (*corev1.Pod, error) {
    return client.CoreV1().Pods(ns).Get(ctx, name, metav1.GetOptions{})
}

// 列表
func listPods(ctx context.Context, client *kubernetes.Clientset, ns string) (*corev1.PodList, error) {
    return client.CoreV1().Pods(ns).List(ctx, metav1.ListOptions{
        LabelSelector: "app=myapp",
    })
}

// 更新
func updatePod(ctx context.Context, client *kubernetes.Clientset, pod *corev1.Pod) error {
    _, err := client.CoreV1().Pods(pod.Namespace).Update(ctx, pod, metav1.UpdateOptions{})
    return err
}

// 删除
func deletePod(ctx context.Context, client *kubernetes.Clientset, name, ns string) error {
    return client.CoreV1().Pods(ns).Delete(ctx, name, metav1.DeleteOptions{})
}
```

---

## Watch 和 Informer

### 使用 Watch

```go
func watchPods(ctx context.Context, client *kubernetes.Clientset, ns string) error {
    watcher, err := client.CoreV1().Pods(ns).Watch(ctx, metav1.ListOptions{})
    if err != nil {
        return err
    }
    defer watcher.Stop()

    for event := range watcher.ResultChan() {
        pod, ok := event.Object.(*corev1.Pod)
        if !ok {
            continue
        }

        switch event.Type {
        case watch.Added:
            log.Printf("Pod added: %s", pod.Name)
        case watch.Modified:
            log.Printf("Pod modified: %s", pod.Name)
        case watch.Deleted:
            log.Printf("Pod deleted: %s", pod.Name)
        }
    }
    return nil
}
```

### 使用 SharedInformer（推荐）

```go
import (
    "k8s.io/client-go/informers"
    "k8s.io/client-go/tools/cache"
)

func runInformer(ctx context.Context, client *kubernetes.Clientset) error {
    // 创建 informer factory
    factory := informers.NewSharedInformerFactory(client, 30*time.Second)

    // 获取 Pod informer
    podInformer := factory.Core().V1().Pods().Informer()

    // 添加事件处理器
    podInformer.AddEventHandler(cache.ResourceEventHandlerFuncs{
        AddFunc: func(obj interface{}) {
            pod := obj.(*corev1.Pod)
            log.Printf("Pod added: %s/%s", pod.Namespace, pod.Name)
        },
        UpdateFunc: func(oldObj, newObj interface{}) {
            newPod := newObj.(*corev1.Pod)
            log.Printf("Pod updated: %s/%s", newPod.Namespace, newPod.Name)
        },
        DeleteFunc: func(obj interface{}) {
            // 处理 tombstone 对象（informer 缓存过期时会收到 DeletedFinalStateUnknown）
            pod, ok := obj.(*corev1.Pod)
            if !ok {
                tombstone, ok := obj.(cache.DeletedFinalStateUnknown)
                if !ok {
                    log.Printf("unexpected object type: %T", obj)
                    return
                }
                pod, ok = tombstone.Obj.(*corev1.Pod)
                if !ok {
                    log.Printf("unexpected tombstone object type: %T", tombstone.Obj)
                    return
                }
            }
            log.Printf("Pod deleted: %s/%s", pod.Namespace, pod.Name)
        },
    })

    // 启动 informer
    factory.Start(ctx.Done())

    // 等待缓存同步
    if !cache.WaitForCacheSync(ctx.Done(), podInformer.HasSynced) {
        return fmt.Errorf("failed to sync cache")
    }

    <-ctx.Done()
    return nil
}
```

---

## Controller 模式

```go
import (
    "k8s.io/client-go/util/workqueue"
)

type Controller struct {
    client    *kubernetes.Clientset
    informer  cache.SharedIndexInformer
    workqueue workqueue.TypedRateLimitingInterface[string]
}

func NewController(client *kubernetes.Clientset) *Controller {
    factory := informers.NewSharedInformerFactory(client, 30*time.Second)
    informer := factory.Core().V1().Pods().Informer()

    c := &Controller{
        client:    client,
        informer:  informer,
        workqueue: workqueue.NewTypedRateLimitingQueue(
            workqueue.DefaultTypedControllerRateLimiter[string](),
        ),
    }

    informer.AddEventHandler(cache.ResourceEventHandlerFuncs{
        AddFunc: c.enqueue,
        UpdateFunc: func(old, new interface{}) {
            c.enqueue(new)
        },
        DeleteFunc: c.enqueue,
    })

    return c
}

func (c *Controller) enqueue(obj interface{}) {
    key, err := cache.MetaNamespaceKeyFunc(obj)
    if err != nil {
        return
    }
    c.workqueue.Add(key)
}

func (c *Controller) Run(ctx context.Context, workers int) error {
    defer c.workqueue.ShutDown()

    // 启动 informer
    go c.informer.Run(ctx.Done())

    // 等待缓存同步
    if !cache.WaitForCacheSync(ctx.Done(), c.informer.HasSynced) {
        return fmt.Errorf("failed to sync cache")
    }

    // 启动 worker
    for i := 0; i < workers; i++ {
        go c.worker(ctx)
    }

    <-ctx.Done()
    return nil
}

func (c *Controller) worker(ctx context.Context) {
    for c.processNextItem(ctx) {
    }
}

func (c *Controller) processNextItem(ctx context.Context) bool {
    key, shutdown := c.workqueue.Get()
    if shutdown {
        return false
    }
    defer c.workqueue.Done(key)

    if err := c.syncHandler(ctx, key); err != nil {
        c.workqueue.AddRateLimited(key)
        return true
    }

    c.workqueue.Forget(key)
    return true
}

func (c *Controller) syncHandler(ctx context.Context, key string) error {
    namespace, name, err := cache.SplitMetaNamespaceKey(key)
    if err != nil {
        return err
    }

    // 获取对象并处理
    pod, err := c.client.CoreV1().Pods(namespace).Get(ctx, name, metav1.GetOptions{})
    if err != nil {
        if errors.IsNotFound(err) {
            return nil // 已删除，忽略
        }
        return err
    }

    // 实现你的业务逻辑
    log.Printf("Processing pod: %s/%s", pod.Namespace, pod.Name)
    return nil
}
```

---

## 常用操作

### 执行 Pod 命令

```go
import (
    "k8s.io/client-go/kubernetes/scheme"
    "k8s.io/client-go/tools/remotecommand"
)

func execInPod(ctx context.Context, config *rest.Config, client *kubernetes.Clientset,
    namespace, podName, container string, command []string) error {

    req := client.CoreV1().RESTClient().Post().
        Resource("pods").
        Name(podName).
        Namespace(namespace).
        SubResource("exec").
        VersionedParams(&corev1.PodExecOptions{
            Container: container,
            Command:   command,
            Stdin:     false,
            Stdout:    true,
            Stderr:    true,
        }, scheme.ParameterCodec)

    exec, err := remotecommand.NewSPDYExecutor(config, "POST", req.URL())
    if err != nil {
        return err
    }

    return exec.StreamWithContext(ctx, remotecommand.StreamOptions{
        Stdout: os.Stdout,
        Stderr: os.Stderr,
    })
}
```

### 端口转发

```go
import (
    "k8s.io/client-go/transport/spdy"
)

func portForward(ctx context.Context, config *rest.Config, client *kubernetes.Clientset,
    namespace, podName string, localPort, podPort int) error {

    url := client.CoreV1().RESTClient().Post().
        Resource("pods").
        Namespace(namespace).
        Name(podName).
        SubResource("portforward").
        URL()

    transport, upgrader, err := spdy.RoundTripperFor(config)
    if err != nil {
        return err
    }

    dialer := spdy.NewDialer(upgrader, &http.Client{Transport: transport}, "POST", url)

    ports := []string{fmt.Sprintf("%d:%d", localPort, podPort)}
    stopChan := make(chan struct{}, 1)
    readyChan := make(chan struct{})

    pf, err := portforward.New(dialer, ports, stopChan, readyChan, os.Stdout, os.Stderr)
    if err != nil {
        return err
    }

    go func() {
        <-ctx.Done()
        close(stopChan)
    }()

    return pf.ForwardPorts()
}
```

### 获取 Pod 日志

```go
func getPodLogs(ctx context.Context, client *kubernetes.Clientset,
    namespace, podName, container string, tailLines int64) (string, error) {

    req := client.CoreV1().Pods(namespace).GetLogs(podName, &corev1.PodLogOptions{
        Container: container,
        TailLines: &tailLines,
    })

    stream, err := req.Stream(ctx)
    if err != nil {
        return "", err
    }
    defer stream.Close()

    var buf bytes.Buffer
    if _, err := io.Copy(&buf, stream); err != nil {
        return "", err
    }

    return buf.String(), nil
}
```

---

## 错误处理

```go
import (
    apierrors "k8s.io/apimachinery/pkg/api/errors"
)

// 检查错误类型
if apierrors.IsNotFound(err) {
    // 资源不存在
}

if apierrors.IsConflict(err) {
    // 版本冲突，需要重试
}

if apierrors.IsAlreadyExists(err) {
    // 资源已存在
}

if apierrors.IsForbidden(err) {
    // 权限不足
}

// 重试冲突
err = retry.RetryOnConflict(retry.DefaultRetry, func() error {
    // 获取最新版本
    pod, err := client.CoreV1().Pods(ns).Get(ctx, name, metav1.GetOptions{})
    if err != nil {
        return err
    }

    // 修改
    pod.Labels["updated"] = "true"

    // 更新
    _, err = client.CoreV1().Pods(ns).Update(ctx, pod, metav1.UpdateOptions{})
    return err
})
```

---

## 测试

### 使用 fake client

```go
import (
    "k8s.io/client-go/kubernetes/fake"
)

func TestController(t *testing.T) {
    // 创建 fake 客户端
    client := fake.NewSimpleClientset(
        &corev1.Pod{
            ObjectMeta: metav1.ObjectMeta{
                Name:      "test-pod",
                Namespace: "default",
            },
        },
    )

    // 使用 fake 客户端测试
    pods, err := client.CoreV1().Pods("default").List(
        context.Background(),
        metav1.ListOptions{},
    )
    require.NoError(t, err)
    assert.Len(t, pods.Items, 1)
}
```

---

## 常用依赖

```go
import (
    // API 类型
    corev1 "k8s.io/api/core/v1"
    appsv1 "k8s.io/api/apps/v1"
    metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"

    // 客户端
    "k8s.io/client-go/kubernetes"
    "k8s.io/client-go/rest"
    "k8s.io/client-go/tools/clientcmd"

    // Informer
    "k8s.io/client-go/informers"
    "k8s.io/client-go/tools/cache"

    // 工作队列
    "k8s.io/client-go/util/workqueue"
    "k8s.io/client-go/util/retry"

    // 错误处理
    apierrors "k8s.io/apimachinery/pkg/api/errors"
)
```
