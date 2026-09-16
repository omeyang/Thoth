# 并发模式片段

## Worker Pool

```go
func processItems(ctx context.Context, items []Item, workers int) error {
    g, ctx := errgroup.WithContext(ctx)
    ch := make(chan Item)

    // 生产者
    g.Go(func() error {
        defer close(ch)
        for _, item := range items {
            select {
            case ch <- item:
            case <-ctx.Done():
                return ctx.Err()
            }
        }
        return nil
    })

    // 消费者
    for range workers {
        g.Go(func() error {
            for item := range ch {
                if err := handle(ctx, item); err != nil {
                    return err
                }
            }
            return nil
        })
    }

    return g.Wait()
}
```

## 超时控制

```go
ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
defer cancel()

result, err := doWork(ctx)
if errors.Is(err, context.DeadlineExceeded) {
    // 超时处理
}
```

## 优雅关机

```go
ctx, cancel := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
defer cancel()

// 启动服务
go server.Serve(listener)

<-ctx.Done()
slog.Info("shutting down")

shutdownCtx, shutdownCancel := context.WithTimeout(context.Background(), 10*time.Second)
defer shutdownCancel()
server.Shutdown(shutdownCtx)
```

## Fan-out/Fan-in

```go
g, ctx := errgroup.WithContext(ctx)
results := make([]Result, len(sources))

for i, src := range sources {
    g.Go(func() error {
        r, err := fetch(ctx, src)
        if err != nil {
            return err
        }
        results[i] = r // 各自写不同的 index，无竞态
        return nil
    })
}

if err := g.Wait(); err != nil {
    return nil, err
}
```
