# 结构型模式 - 完整代码实现

## 目录

- [1. 适配器模式 Adapter](#1-适配器模式adapter)
- [2. 桥接模式 Bridge](#2-桥接模式bridge)
- [3. 组合模式 Composite](#3-组合模式composite)
- [4. 装饰器模式 Decorator](#4-装饰器模式decorator)
- [5. 外观模式 Facade](#5-外观模式facade)
- [6. 享元模式 Flyweight](#6-享元模式flyweight)
- [7. 代理模式 Proxy](#7-代理模式proxy)

---

## 1. 适配器模式（Adapter）

**意图**：将一个类的接口转换成客户期望的另一个接口

```go
// 目标接口
type Logger interface {
    Log(level string, msg string, fields map[string]any)
}

// 第三方库（不兼容）
type ZapLogger struct{ *zap.Logger }

// 适配器
type ZapAdapter struct {
    zap *zap.Logger
}

func (a *ZapAdapter) Log(level string, msg string, fields map[string]any) {
    zapFields := make([]zap.Field, 0, len(fields))
    for k, v := range fields {
        zapFields = append(zapFields, zap.Any(k, v))
    }
    switch level {
    case "info":
        a.zap.Info(msg, zapFields...)
    case "error":
        a.zap.Error(msg, zapFields...)
    }
}
```

---

## 2. 桥接模式（Bridge）

**意图**：将抽象与实现分离，使它们可以独立变化

```go
// 实现层接口
type MessageSender interface {
    Send(message string) error
}

type EmailSender struct{}
type SMSSender struct{}
type SlackSender struct{}

// 抽象层
type Notification struct {
    sender MessageSender
}

func (n *Notification) Notify(msg string) error {
    return n.sender.Send(msg)
}

// 扩展抽象
type UrgentNotification struct {
    Notification
}

func (u *UrgentNotification) Notify(msg string) error {
    return u.sender.Send("[URGENT] " + msg)
}
```

---

## 3. 组合模式（Composite）

**意图**：将对象组合成树形结构以表示"部分-整体"层次

```go
type Component interface {
    Execute() string
    Add(Component)
    Remove(Component)
}

type Leaf struct {
    name string
}

func (l *Leaf) Execute() string { return l.name }
func (l *Leaf) Add(Component)    {}
func (l *Leaf) Remove(Component) {}

type Composite struct {
    name     string
    children []Component
}

func (c *Composite) Execute() string {
    results := []string{c.name}
    for _, child := range c.children {
        results = append(results, child.Execute())
    }
    return strings.Join(results, " -> ")
}

func (c *Composite) Add(child Component) {
    c.children = append(c.children, child)
}
```

---

## 4. 装饰器模式（Decorator）

**意图**：动态地给对象添加额外职责

```go
type Handler interface {
    Handle(ctx context.Context, req Request) (Response, error)
}

// 日志装饰器
func WithLogging(h Handler, logger Logger) Handler {
    return HandlerFunc(func(ctx context.Context, req Request) (Response, error) {
        logger.Info("request started", "id", req.ID)
        start := time.Now()
        resp, err := h.Handle(ctx, req)
        logger.Info("request completed", "id", req.ID, "duration", time.Since(start))
        return resp, err
    })
}

// 重试装饰器
func WithRetry(h Handler, maxRetries int) Handler {
    return HandlerFunc(func(ctx context.Context, req Request) (Response, error) {
        var lastErr error
        for i := 0; i <= maxRetries; i++ {
            resp, err := h.Handle(ctx, req)
            if err == nil {
                return resp, nil
            }
            lastErr = err
            time.Sleep(time.Duration(i*100) * time.Millisecond)
        }
        return Response{}, lastErr
    })
}

// 组合
handler := WithLogging(WithRetry(baseHandler, 3), logger)
```

---

## 5. 外观模式（Facade）

**意图**：为子系统中的一组接口提供统一的高层接口

```go
type OrderFacade struct {
    inventory *InventoryService
    payment   *PaymentService
    shipping  *ShippingService
    notify    *NotificationService
}

func (f *OrderFacade) PlaceOrder(ctx context.Context, order Order) error {
    // 检查库存
    if err := f.inventory.Reserve(ctx, order.Items); err != nil {
        return fmt.Errorf("inventory: %w", err)
    }

    // 处理支付
    if err := f.payment.Charge(ctx, order.Payment); err != nil {
        f.inventory.Release(ctx, order.Items)
        return fmt.Errorf("payment: %w", err)
    }

    // 安排配送
    if err := f.shipping.Schedule(ctx, order.Address); err != nil {
        f.payment.Refund(ctx, order.Payment)
        f.inventory.Release(ctx, order.Items)
        return fmt.Errorf("shipping: %w", err)
    }

    // 发送通知
    f.notify.SendConfirmation(ctx, order.Email)
    return nil
}
```

---

## 6. 享元模式（Flyweight）

**意图**：运用共享技术有效地支持大量细粒度对象

```go
type Icon struct {
    name   string
    pixels []byte // 大量数据
}

type IconFactory struct {
    cache map[string]*Icon
    mu    sync.RWMutex
}

func (f *IconFactory) GetIcon(name string) *Icon {
    f.mu.RLock()
    if icon, ok := f.cache[name]; ok {
        f.mu.RUnlock()
        return icon
    }
    f.mu.RUnlock()

    f.mu.Lock()
    defer f.mu.Unlock()

    // 双重检查
    if icon, ok := f.cache[name]; ok {
        return icon
    }

    icon := loadIcon(name)
    f.cache[name] = icon
    return icon
}
```

---

## 7. 代理模式（Proxy）

**意图**：为其他对象提供一种代理以控制对这个对象的访问

```go
// 缓存代理
type CachingProxy struct {
    service Service
    cache   *lru.Cache
    ttl     time.Duration
}

func (p *CachingProxy) Query(ctx context.Context, key string) (Result, error) {
    if cached, ok := p.cache.Get(key); ok {
        return cached.(Result), nil
    }

    result, err := p.service.Query(ctx, key)
    if err != nil {
        return Result{}, err
    }

    p.cache.Add(key, result)
    return result, nil
}

// 延迟加载代理
type LazyProxy struct {
    init    sync.Once
    service Service
    create  func() Service
}

func (p *LazyProxy) Query(ctx context.Context, key string) (Result, error) {
    p.init.Do(func() {
        p.service = p.create()
    })
    return p.service.Query(ctx, key)
}
```
