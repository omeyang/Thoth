# MCP 服务器参考

模板里用到的服务器及其来源，2026-09-17 核实。

| 服务器 | 来源 | 启动方式 | 能力 |
|--------|------|---------|------|
| GitHub | [github/github-mcp-server](https://github.com/github/github-mcp-server)（官方） | HTTP `https://api.githubcopilot.com/mcp/`，`Authorization: Bearer <PAT>` | PR / Issue / 代码搜索 / 仓库管理；本地可用 `docker run ghcr.io/github/github-mcp-server` |
| Kubernetes | [containers/kubernetes-mcp-server](https://github.com/containers/kubernetes-mcp-server) | `npx -y kubernetes-mcp-server@latest` | Pod / Deployment / Service 增删改查、日志、Helm、多集群 |
| MongoDB | [mongodb-js/mongodb-mcp-server](https://github.com/mongodb-js/mongodb-mcp-server)（官方） | `npx -y mongodb-mcp-server --readOnly`，`MDB_MCP_CONNECTION_STRING` | 集合、find / aggregate、索引、统计 |
| Redis | [redis/mcp-redis](https://github.com/redis/mcp-redis)（官方） | `uvx --from redis-mcp-server@latest redis-mcp-server --url <url>` | KV / Hash / List / Set / ZSet / Stream、JSON、向量检索 |
| ClickHouse | [ClickHouse/mcp-clickhouse](https://github.com/ClickHouse/mcp-clickhouse)（官方） | `uvx mcp-clickhouse`，`CLICKHOUSE_*` | 表结构、SELECT、系统表 |
| Kafka | [tuannvm/kafka-mcp-server](https://github.com/tuannvm/kafka-mcp-server) | `go run github.com/tuannvm/kafka-mcp-server@latest` | Topic、生产消费、消费者组、Offset |
| OpenTelemetry | [traceloop/opentelemetry-mcp-server](https://github.com/traceloop/opentelemetry-mcp-server) | `uvx opentelemetry-mcp`，`BACKEND_TYPE` / `BACKEND_URL` | Trace / Span 搜索、错误发现、服务列表；后端 Jaeger、Tempo |
| Sequential Thinking | [modelcontextprotocol/servers](https://github.com/modelcontextprotocol/servers) | `npx -y @modelcontextprotocol/server-sequential-thinking` | 逐步推理 |

已停用：`@modelcontextprotocol/server-github`、`@modelcontextprotocol/server-redis` 两个 npm 包 2026-07 起标记为 deprecated，模板已改用上表的官方实现。

`uvx` 来自 [uv](https://docs.astral.sh/uv/)；Redis MCP 需要 Python 3.14+。
