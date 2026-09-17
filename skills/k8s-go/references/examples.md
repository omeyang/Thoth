# Kubernetes Go - 完整代码示例

## 目录

- [导入与依赖](#导入与依赖)
- [客户端](#客户端)
- [CRUD](#crud)
- [Watch](#watch)
- [Informer](#informer)
- [Controller](#controller)
- [常用操作](#常用操作)
- [错误处理](#错误处理)
- [测试（fake clientset）](#测试fake-clientset)

---

所有代码在 go1.24.6 + `k8s.io/client-go v0.34.10`（`k8s.io/api`、`k8s.io/apimachinery` 同版本）下通过 `go vet` 与 `go test`。示例合并在一个包里，导入块只列一次。

```text
go get k8s.io/client-go@v0.34.10 k8s.io/api@v0.34.10 k8s.io/apimachinery@v0.34.10
```

注意：`v0.34.11` 起 go.mod 的 go 指令超出 go1.24 基线，Go 1.24 工具链只能停在 `v0.34.10`；三个模块必须同版本。

---

## 导入与依赖

```go
package k8s

import (
	"bytes"
	"context"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"os"
	"path/filepath"
	"time"

	corev1 "k8s.io/api/core/v1"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/labels"
	"k8s.io/apimachinery/pkg/watch"
	"k8s.io/client-go/informers"
	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/kubernetes/scheme"
	"k8s.io/client-go/rest"
	"k8s.io/client-go/tools/cache"
	"k8s.io/client-go/tools/clientcmd"
	"k8s.io/client-go/tools/portforward"
	"k8s.io/client-go/tools/remotecommand"
	"k8s.io/client-go/transport/spdy"
	"k8s.io/client-go/util/retry"
	"k8s.io/client-go/util/workqueue"
)
```

---

## 客户端

```go
// InClusterClient 集群内运行（Pod 内，使用 ServiceAccount）
func InClusterClient() (*kubernetes.Clientset, error) {
	config, err := rest.InClusterConfig()
	if err != nil {
		return nil, err
	}
	return kubernetes.NewForConfig(config)
}

// OutOfClusterClient 集群外运行（kubeconfig）
func OutOfClusterClient(kubeconfig string) (*kubernetes.Clientset, error) {
	config, err := clientcmd.BuildConfigFromFlags("", kubeconfig)
	if err != nil {
		return nil, err
	}
	return kubernetes.NewForConfig(config)
}

// AutoConfig 优先集群内配置，失败回退到 ~/.kube/config
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

func AutoClient() (*kubernetes.Clientset, error) {
	config, err := AutoConfig()
	if err != nil {
		return nil, err
	}
	config.QPS = 50    // 客户端限流，默认 5
	config.Burst = 100 // 默认 10
	return kubernetes.NewForConfig(config)
}
```

---

## CRUD

```go
func CreatePod(ctx context.Context, client kubernetes.Interface, ns string) (*corev1.Pod, error) {
	pod := &corev1.Pod{
		ObjectMeta: metav1.ObjectMeta{
			Name:      "my-pod",
			Namespace: ns,
			Labels:    map[string]string{"app": "myapp"},
		},
		Spec: corev1.PodSpec{
			Containers: []corev1.Container{{
				Name:  "main",
				Image: "nginx:1.28",
			}},
		},
	}
	return client.CoreV1().Pods(ns).Create(ctx, pod, metav1.CreateOptions{})
}

func GetPod(ctx context.Context, client kubernetes.Interface, ns, name string) (*corev1.Pod, error) {
	return client.CoreV1().Pods(ns).Get(ctx, name, metav1.GetOptions{})
}

func ListPods(ctx context.Context, client kubernetes.Interface, ns string) (*corev1.PodList, error) {
	return client.CoreV1().Pods(ns).List(ctx, metav1.ListOptions{LabelSelector: "app=myapp"})
}

func UpdatePod(ctx context.Context, client kubernetes.Interface, pod *corev1.Pod) (*corev1.Pod, error) {
	return client.CoreV1().Pods(pod.Namespace).Update(ctx, pod, metav1.UpdateOptions{})
}

func DeletePod(ctx context.Context, client kubernetes.Interface, ns, name string) error {
	return client.CoreV1().Pods(ns).Delete(ctx, name, metav1.DeleteOptions{})
}
```

---

## Watch

```go
func WatchPods(ctx context.Context, client kubernetes.Interface, ns string) error {
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
			slog.Info("pod added", slog.String("name", pod.Name))
		case watch.Modified:
			slog.Info("pod modified", slog.String("name", pod.Name))
		case watch.Deleted:
			slog.Info("pod deleted", slog.String("name", pod.Name))
		case watch.Error, watch.Bookmark:
		}
	}
	return nil // ResultChan 关闭：调用方需自行重建 watch（或改用 informer）
}
```

---

## Informer

`AddEventHandler` 返回 `(ResourceEventHandlerRegistration, error)`，错误要处理。`UpdateFunc` 会被 resync 周期性触发，比较 `ResourceVersion` 跳过无变化事件。

```go
func RunInformer(ctx context.Context, client kubernetes.Interface) error {
	factory := informers.NewSharedInformerFactory(client, 30*time.Second)
	podInformer := factory.Core().V1().Pods().Informer()

	_, err := podInformer.AddEventHandler(cache.ResourceEventHandlerFuncs{
		AddFunc: func(obj any) {
			pod := obj.(*corev1.Pod)
			slog.Info("pod added", slog.String("ns", pod.Namespace), slog.String("name", pod.Name))
		},
		UpdateFunc: func(oldObj, newObj any) {
			oldPod, newPod := oldObj.(*corev1.Pod), newObj.(*corev1.Pod)
			if oldPod.ResourceVersion == newPod.ResourceVersion {
				return // resync 触发的重复事件
			}
			slog.Info("pod updated", slog.String("ns", newPod.Namespace), slog.String("name", newPod.Name))
		},
		DeleteFunc: func(obj any) {
			pod, ok := obj.(*corev1.Pod)
			if !ok {
				// 缓存过期时收到的是 DeletedFinalStateUnknown
				tombstone, ok := obj.(cache.DeletedFinalStateUnknown)
				if !ok {
					slog.Warn("unexpected object", slog.String("type", fmt.Sprintf("%T", obj)))
					return
				}
				pod, ok = tombstone.Obj.(*corev1.Pod)
				if !ok {
					slog.Warn("unexpected tombstone object", slog.String("type", fmt.Sprintf("%T", tombstone.Obj)))
					return
				}
			}
			slog.Info("pod deleted", slog.String("ns", pod.Namespace), slog.String("name", pod.Name))
		},
	})
	if err != nil {
		return fmt.Errorf("add event handler: %w", err)
	}

	factory.Start(ctx.Done())
	if !cache.WaitForCacheSync(ctx.Done(), podInformer.HasSynced) {
		return fmt.Errorf("failed to sync cache")
	}

	// 从本地缓存读取，不打 API Server
	lister := factory.Core().V1().Pods().Lister()
	pods, err := lister.Pods("default").List(labels.Everything())
	if err != nil {
		return err
	}
	slog.Info("cached pods", slog.Int("count", len(pods)))

	<-ctx.Done()
	return nil
}
```

---

## Controller

队列只存 `namespace/name`；处理时从 informer 缓存取最新对象并 `DeepCopy`，写回用 `RetryOnConflict`。

```go
type Controller struct {
	client    kubernetes.Interface
	informer  cache.SharedIndexInformer
	workqueue workqueue.TypedRateLimitingInterface[string]
}

func NewController(client kubernetes.Interface) (*Controller, error) {
	factory := informers.NewSharedInformerFactory(client, 30*time.Second)
	informer := factory.Core().V1().Pods().Informer()

	c := &Controller{
		client:   client,
		informer: informer,
		workqueue: workqueue.NewTypedRateLimitingQueueWithConfig(
			workqueue.DefaultTypedControllerRateLimiter[string](),
			workqueue.TypedRateLimitingQueueConfig[string]{Name: "pods"},
		),
	}

	_, err := informer.AddEventHandler(cache.ResourceEventHandlerFuncs{
		AddFunc: c.enqueue,
		UpdateFunc: func(_, newObj any) {
			c.enqueue(newObj)
		},
		DeleteFunc: c.enqueue,
	})
	if err != nil {
		return nil, err
	}
	return c, nil
}

// enqueue 只入队 namespace/name，处理时再从缓存取最新对象
func (c *Controller) enqueue(obj any) {
	key, err := cache.DeletionHandlingMetaNamespaceKeyFunc(obj) // 兼容 tombstone
	if err != nil {
		slog.Warn("key func", slog.Any("error", err))
		return
	}
	c.workqueue.Add(key)
}

func (c *Controller) Run(ctx context.Context, workers int) error {
	defer c.workqueue.ShutDown()

	go c.informer.Run(ctx.Done())
	if !cache.WaitForCacheSync(ctx.Done(), c.informer.HasSynced) {
		return fmt.Errorf("failed to sync cache")
	}

	for range workers {
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
		if c.workqueue.NumRequeues(key) < 5 {
			c.workqueue.AddRateLimited(key) // 指数退避重试
			return true
		}
		slog.Error("give up", slog.String("key", key), slog.Any("error", err))
	}
	c.workqueue.Forget(key)
	return true
}

func (c *Controller) syncHandler(ctx context.Context, key string) error {
	namespace, name, err := cache.SplitMetaNamespaceKey(key)
	if err != nil {
		return err
	}

	// 优先读 informer 缓存
	obj, exists, err := c.informer.GetIndexer().GetByKey(key)
	if err != nil {
		return err
	}
	if !exists {
		slog.Info("pod deleted", slog.String("key", key))
		return nil
	}
	pod := obj.(*corev1.Pod).DeepCopy() // 缓存对象只读，修改前先 DeepCopy

	// 需要写回时按最新版本更新
	return retry.RetryOnConflict(retry.DefaultRetry, func() error {
		latest, err := c.client.CoreV1().Pods(namespace).Get(ctx, name, metav1.GetOptions{})
		if apierrors.IsNotFound(err) {
			return nil
		}
		if err != nil {
			return err
		}
		if latest.Labels == nil {
			latest.Labels = map[string]string{}
		}
		latest.Labels["processed"] = "true"
		latest.Labels["phase"] = string(pod.Status.Phase)
		_, err = c.client.CoreV1().Pods(namespace).Update(ctx, latest, metav1.UpdateOptions{})
		return err
	})
}
```

---

## 常用操作

exec / port-forward 需要 `*rest.Config`，日志只需要 clientset。

```go
// ExecInPod 在容器内执行命令
func ExecInPod(ctx context.Context, config *rest.Config, client kubernetes.Interface,
	namespace, podName, container string, command []string, stdout, stderr io.Writer) error {

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

	exec, err := remotecommand.NewSPDYExecutor(config, http.MethodPost, req.URL())
	if err != nil {
		return err
	}
	return exec.StreamWithContext(ctx, remotecommand.StreamOptions{
		Stdout: stdout,
		Stderr: stderr,
	})
}

// PortForward 本地端口转发到 Pod；阻塞直到 ctx 结束
func PortForward(ctx context.Context, config *rest.Config, client kubernetes.Interface,
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
	dialer := spdy.NewDialer(upgrader, &http.Client{Transport: transport}, http.MethodPost, url)

	stopChan := make(chan struct{})
	readyChan := make(chan struct{})
	ports := []string{fmt.Sprintf("%d:%d", localPort, podPort)}

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

// GetPodLogs 读取容器日志尾部
func GetPodLogs(ctx context.Context, client kubernetes.Interface,
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
func ClassifyError(err error) string {
	switch {
	case err == nil:
		return "ok"
	case apierrors.IsNotFound(err):
		return "not found"
	case apierrors.IsConflict(err):
		return "conflict, retry with latest resourceVersion"
	case apierrors.IsAlreadyExists(err):
		return "already exists"
	case apierrors.IsForbidden(err):
		return "forbidden, check RBAC"
	case apierrors.IsTooManyRequests(err):
		return "throttled, back off"
	default:
		return err.Error()
	}
}

// LabelPod 读-改-写，冲突自动重试
func LabelPod(ctx context.Context, client kubernetes.Interface, ns, name, key, value string) error {
	return retry.RetryOnConflict(retry.DefaultRetry, func() error {
		pod, err := client.CoreV1().Pods(ns).Get(ctx, name, metav1.GetOptions{})
		if err != nil {
			return err
		}
		if pod.Labels == nil {
			pod.Labels = map[string]string{}
		}
		pod.Labels[key] = value
		_, err = client.CoreV1().Pods(ns).Update(ctx, pod, metav1.UpdateOptions{})
		return err
	})
}
```

---

## 测试（fake clientset）

`fake.NewClientset` 替代已弃用的 `NewSimpleClientset`，支持 field selector 与 managed fields。

```go
package k8s

import (
	"context"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/client-go/kubernetes/fake"
)

func TestListPods(t *testing.T) {
	// NewClientset 支持 field selector 与 managed fields；NewSimpleClientset 已弃用
	client := fake.NewClientset(
		&corev1.Pod{
			ObjectMeta: metav1.ObjectMeta{
				Name:      "test-pod",
				Namespace: "default",
				Labels:    map[string]string{"app": "myapp"},
			},
		},
	)

	pods, err := ListPods(context.Background(), client, "default")
	require.NoError(t, err)
	assert.Len(t, pods.Items, 1)
}

func TestLabelPod(t *testing.T) {
	client := fake.NewClientset(&corev1.Pod{
		ObjectMeta: metav1.ObjectMeta{Name: "p", Namespace: "default"},
	})

	require.NoError(t, LabelPod(context.Background(), client, "default", "p", "env", "test"))

	pod, err := client.CoreV1().Pods("default").Get(context.Background(), "p", metav1.GetOptions{})
	require.NoError(t, err)
	assert.Equal(t, "test", pod.Labels["env"])
}
```
