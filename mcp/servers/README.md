# MCP 服务器参考

按技术栈分类的推荐 MCP 服务器及其能力说明。

## 基础设施

### Kubernetes

| 服务器 | 语言 | 方式 | 适用场景 |
|--------|------|------|---------|
| [kubernetes-mcp-server](https://github.com/Flux159/mcp-server-kubernetes) | TypeScript | 包装 kubectl/helm CLI | 快速接入，支持 Helm |
| [containers/kubernetes-mcp-server](https://github.com/containers/kubernetes-mcp-server) | Go | 直连 K8s API | 高性能，单二进制，多集群 |

**工具能力:** Pod/Deployment/Service/ConfigMap 增删改查、日志查看、Helm 安装/卸载、端口转发

## 数据库

### MongoDB

| 服务器 | 安装方式 |
|--------|---------|
| [mongodb-mcp-server](https://www.mongodb.com/docs/mcp-server/get-started/) | `npx -y mongodb-mcp-server` |

**工具能力:** 集合列表、文档查询（find/aggregate）、索引管理、数据库统计

### ClickHouse

| 服务器 | 安装方式 |
|--------|---------|
| [mcp-clickhouse](https://github.com/ClickHouse/mcp-clickhouse) | `uvx mcp-clickhouse` |

**工具能力:** 表结构查看、SELECT 查询、查询性能分析、系统表查询

### Redis

| 服务器 | 安装方式 |
|--------|---------|
| [@modelcontextprotocol/server-redis](https://github.com/modelcontextprotocol/servers) | `npx -y @modelcontextprotocol/server-redis redis://localhost:6379` |

**工具能力:** KV 读写、TTL 管理、Hash/Set/List/ZSet 操作、键扫描

> 注意：`@redis/mcp-server` npm 包不存在。Redis 官方 MCP 是 Python 包，上表使用 MCP 官方的 Node.js 实现。

## 消息队列

### Kafka

| 服务器 | 语言 | 安装方式 |
|--------|------|---------|
| [kafka-mcp-server](https://github.com/tuannvm/kafka-mcp-server) | Go | `go run github.com/tuannvm/kafka-mcp-server@latest` |

> 注意：`@nicholasgriffintn/kafka-mcp-server` npm 包不存在，已移除。推荐使用 tuannvm 的 Go 实现。

**工具能力:** Topic 创建/列表、消息发送/消费、消费者组管理、Offset 查看

## 可观测性

### OpenTelemetry

| 服务器 | 安装方式 |
|--------|---------|
| [opentelemetry-mcp](https://github.com/traceloop/opentelemetry-mcp-server) | `uvx opentelemetry-mcp` |

**工具能力:** 搜索 Trace/Span、获取完整链路、错误发现、服务列表、LLM 用量统计
**支持后端:** Jaeger、Grafana Tempo、Traceloop

## 通用工具

### GitHub

| 服务器 | 安装方式 |
|--------|---------|
| [@modelcontextprotocol/server-github](https://github.com/modelcontextprotocol/servers) | `npx -y @modelcontextprotocol/server-github` |

**工具能力:** PR/Issue 操作、代码搜索、文件读取、仓库管理

### Sequential Thinking

| 服务器 | 安装方式 |
|--------|---------|
| [@modelcontextprotocol/server-sequential-thinking](https://github.com/modelcontextprotocol/servers) | `npx -y @modelcontextprotocol/server-sequential-thinking` |

**工具能力:** 逐步推理、复杂问题分解、思维链辅助
