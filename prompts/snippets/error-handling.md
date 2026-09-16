# 错误处理片段

## 错误包装

```go
result, err := repo.FindByID(ctx, id)
if err != nil {
    return fmt.Errorf("find user %s: %w", id, err)
}
```

## 自定义错误类型

```go
type NotFoundError struct {
    Entity string
    ID     string
}

func (e *NotFoundError) Error() string {
    return fmt.Sprintf("%s not found: %s", e.Entity, e.ID)
}

// 使用
if errors.As(err, &NotFoundError{}) {
    // 404
}
```

## 哨兵错误

```go
var (
    ErrNotFound    = errors.New("not found")
    ErrConflict    = errors.New("conflict")
    ErrUnauthorized = errors.New("unauthorized")
)

// 使用
if errors.Is(err, ErrNotFound) {
    // 404
}
```

## 多错误收集

```go
var errs []error
for _, item := range items {
    if err := process(item); err != nil {
        errs = append(errs, fmt.Errorf("item %s: %w", item.ID, err))
    }
}
return errors.Join(errs...)
```
