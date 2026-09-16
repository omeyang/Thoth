# Go API 设计 - 完整代码实现

## 目录

- [版本控制](#版本控制)
  - [URL 路径版本](#url-路径版本)
  - [Header 版本](#header-版本)
  - [版本弃用](#版本弃用)
- [分页策略](#分页策略)
  - [游标分页](#游标分页)
  - [偏移分页](#偏移分页)
- [错误处理](#错误处理)
  - [标准错误响应](#标准错误响应)
  - [HTTP 状态码映射](#http-状态码映射)
- [请求/响应设计](#请求响应设计)
  - [请求验证](#请求验证)
  - [响应封装](#响应封装)
- [HATEOAS](#hateoas)
- [内容协商](#内容协商)
- [速率限制](#速率限制)

---

## 版本控制

### URL 路径版本

```go
// 路由注册
func RegisterRoutes(r *mux.Router) {
    v1 := r.PathPrefix("/api/v1").Subrouter()
    v1.HandleFunc("/users", v1ListUsers).Methods("GET")
    v1.HandleFunc("/users/{id}", v1GetUser).Methods("GET")

    v2 := r.PathPrefix("/api/v2").Subrouter()
    v2.HandleFunc("/users", v2ListUsers).Methods("GET")
    v2.HandleFunc("/users/{id}", v2GetUser).Methods("GET")
}

// 版本化响应
type UserV1 struct {
    ID   string `json:"id"`
    Name string `json:"name"`
}

type UserV2 struct {
    ID        string `json:"id"`
    FirstName string `json:"first_name"`
    LastName  string `json:"last_name"`
    Email     string `json:"email"`
}
```

### Header 版本

```go
func VersionMiddleware(next http.Handler) http.Handler {
    return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
        version := r.Header.Get("API-Version")
        if version == "" {
            version = r.Header.Get("Accept-Version")
        }
        if version == "" {
            version = "1" // 默认版本
        }

        ctx := context.WithValue(r.Context(), "api-version", version)
        next.ServeHTTP(w, r.WithContext(ctx))
    })
}

func GetAPIVersion(ctx context.Context) string {
    if v, ok := ctx.Value("api-version").(string); ok {
        return v
    }
    return "1"
}
```

### 版本弃用

```go
func DeprecationMiddleware(deprecatedVersions map[string]time.Time) func(http.Handler) http.Handler {
    return func(next http.Handler) http.Handler {
        return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
            version := GetAPIVersion(r.Context())

            if sunset, ok := deprecatedVersions[version]; ok {
                w.Header().Set("Deprecation", "true")
                w.Header().Set("Sunset", sunset.Format(http.TimeFormat))
                w.Header().Set("Link", `</api/v2>; rel="successor-version"`)
            }

            next.ServeHTTP(w, r)
        })
    }
}
```

---

## 分页策略

### 游标分页

```go
type CursorPage[T any] struct {
    Items      []T    `json:"items"`
    NextCursor string `json:"next_cursor,omitempty"`
    HasMore    bool   `json:"has_more"`
}

type CursorParams struct {
    Cursor string
    Limit  int
}

func ParseCursorParams(r *http.Request) CursorParams {
    limit, _ := strconv.Atoi(r.URL.Query().Get("limit"))
    if limit <= 0 || limit > 100 {
        limit = 20
    }

    return CursorParams{
        Cursor: r.URL.Query().Get("cursor"),
        Limit:  limit,
    }
}

// 游标编码（包含排序字段值 + ID）
type Cursor struct {
    ID        string    `json:"id"`
    CreatedAt time.Time `json:"created_at"`
}

func EncodeCursor(c Cursor) string {
    data, _ := json.Marshal(c)
    return base64.URLEncoding.EncodeToString(data)
}

func DecodeCursor(s string) (Cursor, error) {
    data, err := base64.URLEncoding.DecodeString(s)
    if err != nil {
        return Cursor{}, err
    }

    var c Cursor
    err = json.Unmarshal(data, &c)
    return c, err
}

// 数据库查询
func (r *UserRepo) ListWithCursor(ctx context.Context, cursor string, limit int) (*CursorPage[User], error) {
    query := `SELECT id, name, created_at FROM users`
    args := []any{}

    if cursor != "" {
        c, err := DecodeCursor(cursor)
        if err != nil {
            return nil, fmt.Errorf("invalid cursor: %w", err)
        }
        // 基于 (created_at, id) 的游标条件
        query += ` WHERE (created_at, id) < ($1, $2)`
        args = append(args, c.CreatedAt, c.ID)
    }

    query += ` ORDER BY created_at DESC, id DESC LIMIT $` + strconv.Itoa(len(args)+1)
    args = append(args, limit+1) // 多查一条判断是否有更多

    rows, err := r.db.QueryContext(ctx, query, args...)
    if err != nil {
        return nil, err
    }
    defer rows.Close()

    var users []User
    for rows.Next() {
        var u User
        if err := rows.Scan(&u.ID, &u.Name, &u.CreatedAt); err != nil {
            return nil, err
        }
        users = append(users, u)
    }

    page := &CursorPage[User]{
        Items:   users,
        HasMore: len(users) > limit,
    }

    if page.HasMore {
        page.Items = users[:limit]
        last := page.Items[len(page.Items)-1]
        page.NextCursor = EncodeCursor(Cursor{ID: last.ID, CreatedAt: last.CreatedAt})
    }

    return page, nil
}
```

### 偏移分页

```go
type OffsetPage[T any] struct {
    Items      []T   `json:"items"`
    Total      int64 `json:"total"`
    Page       int   `json:"page"`
    PageSize   int   `json:"page_size"`
    TotalPages int   `json:"total_pages"`
}

type OffsetParams struct {
    Page     int
    PageSize int
}

func ParseOffsetParams(r *http.Request) OffsetParams {
    page, _ := strconv.Atoi(r.URL.Query().Get("page"))
    if page < 1 {
        page = 1
    }

    pageSize, _ := strconv.Atoi(r.URL.Query().Get("page_size"))
    if pageSize <= 0 || pageSize > 100 {
        pageSize = 20
    }

    return OffsetParams{Page: page, PageSize: pageSize}
}

func (r *UserRepo) ListWithOffset(ctx context.Context, params OffsetParams) (*OffsetPage[User], error) {
    // 计算总数
    var total int64
    err := r.db.QueryRowContext(ctx, "SELECT COUNT(*) FROM users").Scan(&total)
    if err != nil {
        return nil, err
    }

    offset := (params.Page - 1) * params.PageSize
    rows, err := r.db.QueryContext(ctx,
        "SELECT id, name FROM users ORDER BY created_at DESC LIMIT $1 OFFSET $2",
        params.PageSize, offset,
    )
    if err != nil {
        return nil, err
    }
    defer rows.Close()

    var users []User
    for rows.Next() {
        var u User
        if err := rows.Scan(&u.ID, &u.Name); err != nil {
            return nil, err
        }
        users = append(users, u)
    }

    totalPages := int((total + int64(params.PageSize) - 1) / int64(params.PageSize))

    return &OffsetPage[User]{
        Items:      users,
        Total:      total,
        Page:       params.Page,
        PageSize:   params.PageSize,
        TotalPages: totalPages,
    }, nil
}
```

---

## 错误处理

### 标准错误响应

```go
// RFC 7807 Problem Details
type ProblemDetail struct {
    Type     string         `json:"type"`               // 错误类型 URI
    Title    string         `json:"title"`              // 简短描述
    Status   int            `json:"status"`             // HTTP 状态码
    Detail   string         `json:"detail,omitempty"`   // 详细说明
    Instance string         `json:"instance,omitempty"` // 请求 URI
    Errors   []FieldError   `json:"errors,omitempty"`   // 字段错误
    TraceID  string         `json:"trace_id,omitempty"` // 追踪 ID
}

type FieldError struct {
    Field   string `json:"field"`
    Message string `json:"message"`
    Code    string `json:"code,omitempty"`
}

// 错误类型常量
const (
    ErrTypeValidation   = "https://api.example.com/errors/validation"
    ErrTypeNotFound     = "https://api.example.com/errors/not-found"
    ErrTypeUnauthorized = "https://api.example.com/errors/unauthorized"
    ErrTypeForbidden    = "https://api.example.com/errors/forbidden"
    ErrTypeConflict     = "https://api.example.com/errors/conflict"
    ErrTypeRateLimit    = "https://api.example.com/errors/rate-limit"
    ErrTypeInternal     = "https://api.example.com/errors/internal"
)

func NewProblemDetail(status int, errType, title string) *ProblemDetail {
    return &ProblemDetail{
        Type:   errType,
        Title:  title,
        Status: status,
    }
}

func (p *ProblemDetail) WithDetail(detail string) *ProblemDetail {
    p.Detail = detail
    return p
}

func (p *ProblemDetail) WithFieldErrors(errors []FieldError) *ProblemDetail {
    p.Errors = errors
    return p
}

func (p *ProblemDetail) WithTraceID(traceID string) *ProblemDetail {
    p.TraceID = traceID
    return p
}

func (p *ProblemDetail) WriteTo(w http.ResponseWriter) {
    w.Header().Set("Content-Type", "application/problem+json")
    w.WriteHeader(p.Status)
    json.NewEncoder(w).Encode(p)
}
```

### HTTP 状态码映射

```go
var statusCodeMap = map[error]int{
    ErrNotFound:         http.StatusNotFound,
    ErrValidation:       http.StatusBadRequest,
    ErrUnauthorized:     http.StatusUnauthorized,
    ErrForbidden:        http.StatusForbidden,
    ErrConflict:         http.StatusConflict,
    ErrRateLimited:      http.StatusTooManyRequests,
    ErrServiceUnavail:   http.StatusServiceUnavailable,
}

func ErrorHandler(w http.ResponseWriter, r *http.Request, err error) {
    traceID := GetTraceID(r.Context())

    var problem *ProblemDetail

    switch {
    case errors.Is(err, ErrNotFound):
        problem = NewProblemDetail(404, ErrTypeNotFound, "Resource not found")

    case errors.Is(err, ErrValidation):
        problem = NewProblemDetail(400, ErrTypeValidation, "Validation failed")
        var ve *ValidationError
        if errors.As(err, &ve) {
            problem.WithFieldErrors(ve.Fields)
        }

    case errors.Is(err, ErrUnauthorized):
        problem = NewProblemDetail(401, ErrTypeUnauthorized, "Authentication required")

    case errors.Is(err, ErrForbidden):
        problem = NewProblemDetail(403, ErrTypeForbidden, "Access denied")

    case errors.Is(err, ErrConflict):
        problem = NewProblemDetail(409, ErrTypeConflict, "Resource conflict")

    case errors.Is(err, ErrRateLimited):
        problem = NewProblemDetail(429, ErrTypeRateLimit, "Rate limit exceeded")
        w.Header().Set("Retry-After", "60")

    default:
        // 内部错误不暴露详情
        problem = NewProblemDetail(500, ErrTypeInternal, "Internal server error")
        slog.Error("internal error", slog.Any("error", err), slog.String("trace_id", traceID))
    }

    problem.Instance = r.URL.Path
    problem.TraceID = traceID
    problem.WriteTo(w)
}
```

---

## 请求/响应设计

### 请求验证

```go
type CreateUserRequest struct {
    Email     string `json:"email" validate:"required,email"`
    Name      string `json:"name" validate:"required,min=2,max=100"`
    Password  string `json:"password" validate:"required,min=8"`
    BirthDate string `json:"birth_date" validate:"omitempty,datetime=2006-01-02"`
}

// 使用 go-playground/validator
var validate = validator.New()

func DecodeAndValidate[T any](r *http.Request) (T, error) {
    var req T

    if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
        return req, fmt.Errorf("invalid JSON: %w", err)
    }

    if err := validate.Struct(req); err != nil {
        var ve validator.ValidationErrors
        if errors.As(err, &ve) {
            fields := make([]FieldError, 0, len(ve))
            for _, fe := range ve {
                fields = append(fields, FieldError{
                    Field:   toSnakeCase(fe.Field()),
                    Message: validationMessage(fe),
                    Code:    fe.Tag(),
                })
            }
            return req, &ValidationError{Fields: fields}
        }
        return req, err
    }

    return req, nil
}

func validationMessage(fe validator.FieldError) string {
    switch fe.Tag() {
    case "required":
        return "This field is required"
    case "email":
        return "Must be a valid email address"
    case "min":
        return fmt.Sprintf("Must be at least %s characters", fe.Param())
    case "max":
        return fmt.Sprintf("Must be at most %s characters", fe.Param())
    default:
        return fmt.Sprintf("Failed validation: %s", fe.Tag())
    }
}
```

### 响应封装

```go
// 统一成功响应
type Response[T any] struct {
    Data T      `json:"data"`
    Meta *Meta  `json:"meta,omitempty"`
}

type Meta struct {
    RequestID string `json:"request_id,omitempty"`
    Timestamp int64  `json:"timestamp"`
}

func JSON[T any](w http.ResponseWriter, r *http.Request, status int, data T) {
    w.Header().Set("Content-Type", "application/json")
    w.WriteHeader(status)

    resp := Response[T]{
        Data: data,
        Meta: &Meta{
            RequestID: GetRequestID(r.Context()),
            Timestamp: time.Now().Unix(),
        },
    }

    json.NewEncoder(w).Encode(resp)
}

// 创建成功 (201 + Location)
func Created[T any](w http.ResponseWriter, r *http.Request, location string, data T) {
    w.Header().Set("Location", location)
    JSON(w, r, http.StatusCreated, data)
}

// 无内容 (204)
func NoContent(w http.ResponseWriter) {
    w.WriteHeader(http.StatusNoContent)
}

// 接受处理 (202)
func Accepted(w http.ResponseWriter, r *http.Request, taskID string) {
    w.Header().Set("Location", "/tasks/"+taskID)
    JSON(w, r, http.StatusAccepted, map[string]string{
        "task_id": taskID,
        "status":  "processing",
    })
}
```

---

## HATEOAS

```go
type Link struct {
    Href   string `json:"href"`
    Rel    string `json:"rel"`
    Method string `json:"method,omitempty"`
}

type HATEOASResponse[T any] struct {
    Data  T      `json:"data"`
    Links []Link `json:"_links"`
}

func WithLinks[T any](data T, links ...Link) HATEOASResponse[T] {
    return HATEOASResponse[T]{
        Data:  data,
        Links: links,
    }
}

// 使用示例
func GetUser(w http.ResponseWriter, r *http.Request) {
    userID := chi.URLParam(r, "id")
    user, _ := userService.Get(r.Context(), userID)

    resp := WithLinks(user,
        Link{Href: "/users/" + userID, Rel: "self", Method: "GET"},
        Link{Href: "/users/" + userID, Rel: "update", Method: "PUT"},
        Link{Href: "/users/" + userID, Rel: "delete", Method: "DELETE"},
        Link{Href: "/users/" + userID + "/orders", Rel: "orders", Method: "GET"},
    )

    JSON(w, r, http.StatusOK, resp)
}

// 集合响应
type CollectionResponse[T any] struct {
    Items []T    `json:"items"`
    Links []Link `json:"_links"`
    Page  *PageInfo `json:"page,omitempty"`
}

type PageInfo struct {
    Size       int  `json:"size"`
    TotalItems int  `json:"total_items"`
    TotalPages int  `json:"total_pages"`
    Number     int  `json:"number"`
}

func ListUsers(w http.ResponseWriter, r *http.Request) {
    users, total, _ := userService.List(r.Context(), 1, 20)

    resp := CollectionResponse[User]{
        Items: users,
        Page: &PageInfo{
            Size:       20,
            TotalItems: int(total),
            TotalPages: int((total + 19) / 20),
            Number:     1,
        },
        Links: []Link{
            {Href: "/users?page=1", Rel: "self"},
            {Href: "/users?page=2", Rel: "next"},
            {Href: "/users", Rel: "create", Method: "POST"},
        },
    }

    JSON(w, r, http.StatusOK, resp)
}
```

---

## 内容协商

```go
func ContentNegotiationMiddleware(next http.Handler) http.Handler {
    return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
        accept := r.Header.Get("Accept")

        var contentType string
        switch {
        case strings.Contains(accept, "application/json"):
            contentType = "application/json"
        case strings.Contains(accept, "application/xml"):
            contentType = "application/xml"
        case strings.Contains(accept, "text/csv"):
            contentType = "text/csv"
        default:
            contentType = "application/json"
        }

        ctx := context.WithValue(r.Context(), "content-type", contentType)
        next.ServeHTTP(w, r.WithContext(ctx))
    })
}

func Respond(w http.ResponseWriter, r *http.Request, status int, data any) {
    contentType := r.Context().Value("content-type").(string)
    w.Header().Set("Content-Type", contentType)
    w.WriteHeader(status)

    switch contentType {
    case "application/xml":
        xml.NewEncoder(w).Encode(data)
    case "text/csv":
        writeCSV(w, data)
    default:
        json.NewEncoder(w).Encode(data)
    }
}
```

---

## 速率限制

```go
func RateLimitHeaders(w http.ResponseWriter, limit, remaining int, resetAt time.Time) {
    w.Header().Set("X-RateLimit-Limit", strconv.Itoa(limit))
    w.Header().Set("X-RateLimit-Remaining", strconv.Itoa(remaining))
    w.Header().Set("X-RateLimit-Reset", strconv.FormatInt(resetAt.Unix(), 10))
    w.Header().Set("RateLimit-Limit", strconv.Itoa(limit))
    w.Header().Set("RateLimit-Remaining", strconv.Itoa(remaining))
    w.Header().Set("RateLimit-Reset", strconv.FormatInt(resetAt.Unix(), 10))
}

func RateLimitExceeded(w http.ResponseWriter, resetAt time.Time) {
    retryAfter := int(time.Until(resetAt).Seconds())
    if retryAfter < 1 {
        retryAfter = 1
    }

    w.Header().Set("Retry-After", strconv.Itoa(retryAfter))
    RateLimitHeaders(w, 100, 0, resetAt)

    problem := NewProblemDetail(429, ErrTypeRateLimit, "Rate limit exceeded").
        WithDetail(fmt.Sprintf("Try again in %d seconds", retryAfter))
    problem.WriteTo(w)
}
```
