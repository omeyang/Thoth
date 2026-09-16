# Go 并发模式 - 完整代码实现

## 目录

- [Pipeline 模式](#pipeline-模式)
- [Fan-Out/Fan-In 模式](#fan-outfan-in-模式)
- [Worker Pool 模式](#worker-pool-模式)
- [errgroup 并发控制](#errgroup-并发控制)

---

## Pipeline 模式

```go
func generator[T any](items ...T) <-chan T {
    out := make(chan T)
    go func() {
        defer close(out)
        for _, item := range items {
            out <- item
        }
    }()
    return out
}

func transform[T, R any](in <-chan T, fn func(T) R) <-chan R {
    out := make(chan R)
    go func() {
        defer close(out)
        for v := range in {
            out <- fn(v)
        }
    }()
    return out
}

func filter[T any](in <-chan T, predicate func(T) bool) <-chan T {
    out := make(chan T)
    go func() {
        defer close(out)
        for v := range in {
            if predicate(v) {
                out <- v
            }
        }
    }()
    return out
}

// 使用
result := filter(
    transform(generator(1, 2, 3, 4, 5), func(n int) int { return n * n }),
    func(n int) bool { return n > 10 },
)
```

---

## Fan-Out/Fan-In 模式

```go
func fanOut[T any](in <-chan T, workers int, process func(T) T) []<-chan T {
    outs := make([]<-chan T, workers)
    for i := 0; i < workers; i++ {
        outs[i] = func() <-chan T {
            out := make(chan T)
            go func() {
                defer close(out)
                for v := range in {
                    out <- process(v)
                }
            }()
            return out
        }()
    }
    return outs
}

func fanIn[T any](channels ...<-chan T) <-chan T {
    var wg sync.WaitGroup
    out := make(chan T)

    wg.Add(len(channels))
    for _, ch := range channels {
        go func(c <-chan T) {
            defer wg.Done()
            for v := range c {
                out <- v
            }
        }(ch)
    }

    go func() {
        wg.Wait()
        close(out)
    }()

    return out
}
```

---

## Worker Pool 模式

```go
type WorkerPool[T any, R any] struct {
    workers int
    jobs    chan T
    results chan R
    process func(T) R
}

func NewWorkerPool[T any, R any](workers int, process func(T) R) *WorkerPool[T, R] {
    return &WorkerPool[T, R]{
        workers: workers,
        jobs:    make(chan T, workers*2),
        results: make(chan R, workers*2),
        process: process,
    }
}

func (p *WorkerPool[T, R]) Start(ctx context.Context) {
    for i := 0; i < p.workers; i++ {
        go func() {
            for {
                select {
                case <-ctx.Done():
                    return
                case job, ok := <-p.jobs:
                    if !ok {
                        return
                    }
                    p.results <- p.process(job)
                }
            }
        }()
    }
}

func (p *WorkerPool[T, R]) Submit(job T) { p.jobs <- job }
func (p *WorkerPool[T, R]) Results() <-chan R { return p.results }
```

---

## errgroup 并发控制

```go
import "golang.org/x/sync/errgroup"

func fetchAll(ctx context.Context, urls []string) ([]Response, error) {
    results := make([]Response, len(urls))
    g, ctx := errgroup.WithContext(ctx)
    g.SetLimit(10) // 最多 10 个并发

    for i, url := range urls {
        i, url := i, url
        g.Go(func() error {
            resp, err := fetch(ctx, url)
            if err != nil {
                return err
            }
            results[i] = resp
            return nil
        })
    }

    if err := g.Wait(); err != nil {
        return nil, err
    }
    return results, nil
}
```
