---
name: api-design-go
description: "Go API 设计专家 - RESTful 规范、版本控制、分页策略、错误处理、HATEOAS、契约优先、内容协商。适用：HTTP API 设计、微服务接口、公开 API、RESTful 端点、分页实现、错误响应标准化。不适用：gRPC/Protobuf 接口设计（应使用 grpc-go 专家）、GraphQL API、内部 RPC 通信（无需 REST 规范）。触发词：API, REST, RESTful, HTTP, endpoint, pagination, cursor, HATEOAS, RFC 7807, versioning, rate limit, 接口设计, 分页, 错误处理"
user-invocable: true
allowed-tools: Bash, Read, Write, Edit, Grep, Glob
---

# Go API 设计专家

使用 Go 设计高质量 HTTP API：$ARGUMENTS

---

## 1. RESTful 设计原则

### URL 设计规范

```
# 资源命名（名词复数）
GET    /users              # 列表
POST   /users              # 创建
GET    /users/{id}         # 获取
PUT    /users/{id}         # 全量更新
PATCH  /users/{id}         # 部分更新
DELETE /users/{id}         # 删除

# 子资源
GET    /users/{id}/orders  # 用户的订单

# 正确的搜索/过滤
GET    /users?status=active&role=admin

# 批量操作（使用动作资源）
POST   /users/bulk-delete
POST   /orders/batch
```

### HTTP 方法语义

| 方法 | 幂等 | 安全 | 用途 |
|------|------|------|------|
| GET | Y | Y | 获取资源 |
| HEAD | Y | Y | 获取元信息 |
| OPTIONS | Y | Y | 获取支持的方法 |
| PUT | Y | N | 全量替换 |
| DELETE | Y | N | 删除资源 |
| POST | N | N | 创建资源 |
| PATCH | N | N | 部分更新 |

---

## 2. 版本控制

- **URL 路径版本（推荐）**：`/api/v1/users`，路由注册 `r.PathPrefix("/api/v1").Subrouter()`
- **Header 版本**：`API-Version` / `Accept-Version` header + 中间件注入 context
- **版本弃用**：设置 `Deprecation: true` + `Sunset` + `Link: successor-version` 响应头

---

## 3. 分页策略

### 游标分页（推荐用于大数据集）

- `CursorPage[T]` 结构：Items + NextCursor + HasMore
- 游标编码：base64 of `{ID, CreatedAt}` JSON
- 数据库查询：`WHERE (created_at, id) < ($1, $2) ORDER BY created_at DESC LIMIT N+1`

### 偏移分页（仅用于小数据集）

- `OffsetPage[T]` 结构：Items + Total + Page + PageSize + TotalPages
- 数据库查询：`LIMIT $1 OFFSET $2` + 单独 COUNT 查询

### 分页选择指南

| 场景 | 推荐方式 | 原因 |
|------|---------|------|
| 实时数据流 | 游标 | 数据变化不会导致重复/遗漏 |
| 大数据集 (>10K) | 游标 | 性能稳定，O(1) |
| 静态小数据集 | 偏移 | 支持跳页 |
| 搜索结果 | 偏移 | 用户习惯跳页 |

---

## 4. 错误处理

- **RFC 7807 Problem Details**：Type + Title + Status + Detail + Instance + Errors + TraceID
- **FieldError** 结构：Field + Message + Code
- **ErrorHandler** 根据 `errors.Is`/`errors.As` 映射到对应 HTTP 状态码
- 内部错误不暴露详情，返回 500 + 日志记录

---

## 5. 请求/响应设计

- **请求验证**：`DecodeAndValidate[T]` 泛型函数，JSON 解码 + go-playground/validator
- **响应封装**：`Response[T]{Data, Meta}` 统一格式
- **特殊响应**：`Created` (201+Location)、`NoContent` (204)、`Accepted` (202+taskID)

---

## 6. HATEOAS（超媒体驱动）

- `Link{Href, Rel, Method}` 结构
- `WithLinks[T]` 为单个资源添加操作链接
- `CollectionResponse[T]` 集合响应含分页链接

---

## 7. 内容协商与速率限制

- **内容协商中间件**：根据 Accept header 选择 JSON/XML/CSV 响应格式
- **速率限制响应头**：`X-RateLimit-Limit`/`Remaining`/`Reset` + `Retry-After`

---

## 最佳实践

### URL 设计
- 使用名词复数
- 最多 2 层嵌套
- 使用连字符而非下划线

### 版本控制
- 优先使用 URL 版本
- 提供弃用时间表
- 维护至少 2 个版本

### 分页
- 大数据集用游标
- 返回 `has_more` 标志
- 限制 `page_size` 上限

### 错误处理
- 遵循 RFC 7807
- 包含 trace_id
- 字段错误返回具体位置

---

## 检查清单

- [ ] URL 遵循 RESTful 命名？
- [ ] 有版本控制策略？
- [ ] 分页方式合理？
- [ ] 错误响应标准化？
- [ ] 返回适当状态码？
- [ ] 速率限制有响应头？
- [ ] 支持内容协商？
- [ ] 请求有验证？

## 参考资料

- [完整代码实现](references/examples.md) - 版本控制、分页、错误处理、HATEOAS、内容协商的完整 Go 实现
