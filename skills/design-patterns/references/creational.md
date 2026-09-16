# 创建型模式 - 完整代码实现

## 目录

- [1. 单例模式 Singleton](#1-单例模式singleton)
- [2. 工厂方法 Factory Method](#2-工厂方法factory-method)
- [3. 抽象工厂 Abstract Factory](#3-抽象工厂abstract-factory)
- [4. 建造者模式 Builder](#4-建造者模式builder)
- [5. 函数选项模式 Functional Options](#5-函数选项模式functional-options)
- [6. 原型模式 Prototype](#6-原型模式prototype)

---

## 1. 单例模式（Singleton）

**意图**：确保一个类只有一个实例，并提供全局访问点

```go
// Go 惯用方式：sync.Once
var (
    instance *Database
    once     sync.Once
)

func GetDatabase() *Database {
    once.Do(func() {
        instance = &Database{/* 初始化 */}
    })
    return instance
}
```

**适用场景**：配置管理、连接池、日志记录器
**注意**：被认为是反模式，优先考虑依赖注入

---

## 2. 工厂方法（Factory Method）

**意图**：定义创建对象的接口，让子类决定实例化哪个类

```go
type Storage interface {
    Save(key string, data []byte) error
    Load(key string) ([]byte, error)
}

func NewStorage(typ string) (Storage, error) {
    switch typ {
    case "file":
        return &FileStorage{}, nil
    case "redis":
        return &RedisStorage{}, nil
    case "s3":
        return &S3Storage{}, nil
    default:
        return nil, fmt.Errorf("unknown storage: %s", typ)
    }
}
```

**适用场景**：根据配置创建不同实现、插件系统

---

## 3. 抽象工厂（Abstract Factory）

**意图**：创建相关或依赖对象的家族，而不指定具体类

```go
type UIFactory interface {
    CreateButton() Button
    CreateDialog() Dialog
    CreateMenu() Menu
}

type DarkThemeFactory struct{}
type LightThemeFactory struct{}

func (f *DarkThemeFactory) CreateButton() Button {
    return &DarkButton{}
}
```

**适用场景**：跨平台 UI、主题切换、产品族

---

## 4. 建造者模式（Builder）

**意图**：将复杂对象的构建与表示分离

```go
type ServerBuilder struct {
    server Server
}

func NewServerBuilder() *ServerBuilder {
    return &ServerBuilder{server: Server{Port: 8080}}
}

func (b *ServerBuilder) Host(h string) *ServerBuilder {
    b.server.Host = h
    return b
}

func (b *ServerBuilder) Port(p int) *ServerBuilder {
    b.server.Port = p
    return b
}

func (b *ServerBuilder) WithTLS(cert, key string) *ServerBuilder {
    b.server.TLS = &TLSConfig{Cert: cert, Key: key}
    return b
}

func (b *ServerBuilder) Build() (*Server, error) {
    if err := b.server.validate(); err != nil {
        return nil, err
    }
    return &b.server, nil
}

// 使用
server, _ := NewServerBuilder().
    Host("0.0.0.0").
    Port(443).
    WithTLS("cert.pem", "key.pem").
    Build()
```

---

## 5. 函数选项模式（Functional Options）— Go 惯用

**意图**：灵活配置，避免构造函数参数爆炸

```go
type Option func(*Config)

func WithTimeout(d time.Duration) Option {
    return func(c *Config) { c.Timeout = d }
}

func WithRetries(n int) Option {
    return func(c *Config) { c.Retries = n }
}

func WithLogger(l Logger) Option {
    return func(c *Config) { c.Logger = l }
}

func NewClient(addr string, opts ...Option) *Client {
    cfg := &Config{Timeout: 30 * time.Second, Retries: 3}
    for _, opt := range opts {
        opt(cfg)
    }
    return &Client{addr: addr, config: cfg}
}

// 使用
client := NewClient("localhost:8080",
    WithTimeout(10*time.Second),
    WithRetries(5),
)
```

---

## 6. 原型模式（Prototype）

**意图**：通过克隆现有对象来创建新对象

```go
type Cloneable interface {
    Clone() Cloneable
}

type Document struct {
    Title   string
    Content string
    Meta    map[string]string
}

func (d *Document) Clone() Cloneable {
    meta := make(map[string]string)
    for k, v := range d.Meta {
        meta[k] = v
    }
    return &Document{
        Title:   d.Title,
        Content: d.Content,
        Meta:    meta,
    }
}
```
