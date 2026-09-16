# 行为型模式 - 完整代码实现

## 目录

- [1. 责任链模式 Chain of Responsibility](#1-责任链模式chain-of-responsibility)
- [2. 命令模式 Command](#2-命令模式command)
- [3. 迭代器模式 Iterator](#3-迭代器模式iterator)
- [4. 中介者模式 Mediator](#4-中介者模式mediator)
- [5. 备忘录模式 Memento](#5-备忘录模式memento)
- [6. 观察者模式 Observer](#6-观察者模式observer)
- [7. 状态模式 State](#7-状态模式state)
- [8. 策略模式 Strategy](#8-策略模式strategy)
- [9. 模板方法 Template Method](#9-模板方法template-method)
- [10. 访问者模式 Visitor](#10-访问者模式visitor)

---

## 1. 责任链模式（Chain of Responsibility）

**意图**：使多个对象都有机会处理请求

```go
// HTTP 中间件链
type Middleware func(http.Handler) http.Handler

func Chain(h http.Handler, mws ...Middleware) http.Handler {
    for i := len(mws) - 1; i >= 0; i-- {
        h = mws[i](h)
    }
    return h
}

func LoggingMiddleware(next http.Handler) http.Handler {
    return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
        log.Printf("%s %s", r.Method, r.URL.Path)
        next.ServeHTTP(w, r)
    })
}

func AuthMiddleware(next http.Handler) http.Handler {
    return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
        if r.Header.Get("Authorization") == "" {
            http.Error(w, "unauthorized", 401)
            return
        }
        next.ServeHTTP(w, r)
    })
}

// 使用
handler := Chain(finalHandler, LoggingMiddleware, AuthMiddleware, RateLimitMiddleware)
```

---

## 2. 命令模式（Command）

**意图**：将请求封装为对象，从而可以参数化、排队或记录请求

```go
type Command interface {
    Execute() error
    Undo() error
}

type CreateFileCommand struct {
    path    string
    content []byte
}

func (c *CreateFileCommand) Execute() error {
    return os.WriteFile(c.path, c.content, 0644)
}

func (c *CreateFileCommand) Undo() error {
    return os.Remove(c.path)
}

// 命令管理器（支持撤销）
type CommandManager struct {
    history []Command
}

func (m *CommandManager) Execute(cmd Command) error {
    if err := cmd.Execute(); err != nil {
        return err
    }
    m.history = append(m.history, cmd)
    return nil
}

func (m *CommandManager) Undo() error {
    if len(m.history) == 0 {
        return errors.New("nothing to undo")
    }
    cmd := m.history[len(m.history)-1]
    m.history = m.history[:len(m.history)-1]
    return cmd.Undo()
}
```

---

## 3. 迭代器模式（Iterator）

**意图**：提供一种方法顺序访问聚合对象中的各个元素

```go
// Go 1.23+ 使用 iter 包
func (t *Tree[T]) All() iter.Seq[T] {
    return func(yield func(T) bool) {
        t.iterate(t.root, yield)
    }
}

func (t *Tree[T]) iterate(node *Node[T], yield func(T) bool) bool {
    if node == nil {
        return true
    }
    return t.iterate(node.left, yield) &&
           yield(node.value) &&
           t.iterate(node.right, yield)
}

// 使用
for v := range tree.All() {
    fmt.Println(v)
}
```

---

## 4. 中介者模式（Mediator）

**意图**：用一个中介对象来封装一系列对象交互

```go
type EventBus struct {
    handlers map[string][]func(Event)
    mu       sync.RWMutex
}

func NewEventBus() *EventBus {
    return &EventBus{handlers: make(map[string][]func(Event))}
}

func (eb *EventBus) Subscribe(eventType string, handler func(Event)) {
    eb.mu.Lock()
    defer eb.mu.Unlock()
    eb.handlers[eventType] = append(eb.handlers[eventType], handler)
}

func (eb *EventBus) Publish(event Event) {
    eb.mu.RLock()
    handlers := eb.handlers[event.Type]
    eb.mu.RUnlock()

    for _, h := range handlers {
        go h(event)
    }
}
```

---

## 5. 备忘录模式（Memento）

**意图**：在不破坏封装的前提下，捕获并外部化对象的内部状态

```go
type EditorMemento struct {
    content  string
    cursor   int
    savedAt  time.Time
}

type Editor struct {
    content string
    cursor  int
}

func (e *Editor) Save() *EditorMemento {
    return &EditorMemento{
        content: e.content,
        cursor:  e.cursor,
        savedAt: time.Now(),
    }
}

func (e *Editor) Restore(m *EditorMemento) {
    e.content = m.content
    e.cursor = m.cursor
}

// 历史管理
type History struct {
    mementos []*EditorMemento
}

func (h *History) Push(m *EditorMemento) {
    h.mementos = append(h.mementos, m)
}

func (h *History) Pop() *EditorMemento {
    if len(h.mementos) == 0 {
        return nil
    }
    m := h.mementos[len(h.mementos)-1]
    h.mementos = h.mementos[:len(h.mementos)-1]
    return m
}
```

---

## 6. 观察者模式（Observer）

**意图**：定义对象间的一对多依赖，状态变化时通知所有依赖者

```go
type Observer interface {
    OnNotify(event Event)
}

type Subject struct {
    observers []Observer
    mu        sync.RWMutex
}

func (s *Subject) Attach(o Observer) {
    s.mu.Lock()
    defer s.mu.Unlock()
    s.observers = append(s.observers, o)
}

func (s *Subject) Notify(event Event) {
    s.mu.RLock()
    observers := make([]Observer, len(s.observers))
    copy(observers, s.observers)
    s.mu.RUnlock()

    for _, o := range observers {
        o.OnNotify(event)
    }
}

// Go 风格：使用 channel
type Subscription struct {
    Events <-chan Event
    cancel func()
}

func (s *Subject) SubscribeChan(bufSize int) *Subscription {
    ch := make(chan Event, bufSize)
    done := make(chan struct{})
    // ... 注册
    return &Subscription{Events: ch, cancel: func() { close(done) }}
}
```

---

## 7. 状态模式（State）

**意图**：允许对象在内部状态改变时改变行为

```go
type OrderState interface {
    Process(o *Order) error
    Cancel(o *Order) error
    Ship(o *Order) error
    String() string
}

type Order struct {
    ID    string
    state OrderState
}

func (o *Order) SetState(s OrderState) { o.state = s }
func (o *Order) Process() error        { return o.state.Process(o) }
func (o *Order) Cancel() error         { return o.state.Cancel(o) }
func (o *Order) Ship() error           { return o.state.Ship(o) }

type PendingState struct{}

func (s *PendingState) Process(o *Order) error {
    o.SetState(&ProcessingState{})
    return nil
}

func (s *PendingState) Cancel(o *Order) error {
    o.SetState(&CancelledState{})
    return nil
}

func (s *PendingState) Ship(o *Order) error {
    return errors.New("cannot ship pending order")
}

func (s *PendingState) String() string { return "pending" }
```

---

## 8. 策略模式（Strategy）

**意图**：定义一系列算法，把它们封装起来，并使它们可互换

```go
type Compressor interface {
    Compress(data []byte) ([]byte, error)
    Decompress(data []byte) ([]byte, error)
}

type GzipCompressor struct{}
type ZstdCompressor struct{}
type LZ4Compressor struct{}

type FileProcessor struct {
    compressor Compressor
}

func (p *FileProcessor) SetCompressor(c Compressor) {
    p.compressor = c
}

func (p *FileProcessor) ProcessFile(path string) error {
    data, err := os.ReadFile(path)
    if err != nil {
        return err
    }

    compressed, err := p.compressor.Compress(data)
    if err != nil {
        return err
    }

    return os.WriteFile(path+".compressed", compressed, 0644)
}
```

---

## 9. 模板方法（Template Method）

**意图**：定义算法骨架，将某些步骤延迟到子类

```go
type DataExporter interface {
    FetchData(ctx context.Context) ([]Record, error)
    Transform(records []Record) []byte
    GetExtension() string
}

// 模板方法
func Export(ctx context.Context, exporter DataExporter, path string) error {
    records, err := exporter.FetchData(ctx)
    if err != nil {
        return err
    }

    data := exporter.Transform(records)
    filename := path + exporter.GetExtension()

    return os.WriteFile(filename, data, 0644)
}

type CSVExporter struct{ db *sql.DB }
type JSONExporter struct{ db *sql.DB }
type ExcelExporter struct{ db *sql.DB }

func (e *CSVExporter) GetExtension() string { return ".csv" }
func (e *JSONExporter) GetExtension() string { return ".json" }
```

---

## 10. 访问者模式（Visitor）

**意图**：在不改变元素类的前提下定义作用于元素的新操作

```go
type Visitor interface {
    VisitFile(f *File)
    VisitDirectory(d *Directory)
}

type Element interface {
    Accept(v Visitor)
}

type File struct {
    Name string
    Size int64
}

func (f *File) Accept(v Visitor) { v.VisitFile(f) }

type Directory struct {
    Name     string
    Children []Element
}

func (d *Directory) Accept(v Visitor) {
    v.VisitDirectory(d)
    for _, child := range d.Children {
        child.Accept(v)
    }
}

// 具体访问者：计算总大小
type SizeCalculator struct {
    TotalSize int64
}

func (c *SizeCalculator) VisitFile(f *File) {
    c.TotalSize += f.Size
}

func (c *SizeCalculator) VisitDirectory(d *Directory) {}
```
