# mcp

MCP (Model Context Protocol) 服务器配置和参考文档。

## 目录结构

```
mcp/
├── README.md
├── configs/                    # .mcp.json 配置模板
│   ├── go-backend-full.json    # 完整配置（K8s+DB+MQ+OTel+GitHub）
│   ├── go-backend-minimal.json # 最小配置（GitHub+推理）
│   └── observability.json      # 可观测性配置（OTel）
└── servers/
    └── README.md               # MCP 服务器参考清单
```

## 快速开始

### 1. 选择配置模板

```bash
# 完整配置（推荐）
cp /path/to/Thoth/mcp/configs/go-backend-full.json your-project/.mcp.json

# 最小配置
cp /path/to/Thoth/mcp/configs/go-backend-minimal.json your-project/.mcp.json
```

### 2. 设置环境变量

配置中使用 `${VAR}` 格式引用环境变量。在项目中创建 `.env` 文件（记得加入 `.gitignore`）：

```bash
# .env — 完整配置所需的环境变量
GITHUB_TOKEN=ghp_xxxxx

# MongoDB
MONGODB_URI=mongodb://localhost:27017
MONGO_DEFAULT_DATABASE=mydb

# Redis
REDIS_URL=redis://localhost:6379

# ClickHouse
CLICKHOUSE_HOST=localhost
CLICKHOUSE_PORT=8123
CLICKHOUSE_USER=default
CLICKHOUSE_PASSWORD=
CLICKHOUSE_SECURE=false

# Kafka
KAFKA_BROKERS=localhost:9092
KAFKA_SASL_MECHANISM=
KAFKA_SASL_USERNAME=
KAFKA_SASL_PASSWORD=

# OpenTelemetry (observability.json)
OTEL_BACKEND_TYPE=jaeger
OTEL_BACKEND_URL=http://localhost:16686
```

### 3. CLI 快速添加

也可以通过 `claude mcp add` 命令逐个添加：

```bash
claude mcp add github -- npx -y @modelcontextprotocol/server-github
claude mcp add kubernetes -- npx -y kubernetes-mcp-server@latest
claude mcp add redis -- npx -y @modelcontextprotocol/server-redis redis://localhost:6379
claude mcp add mongodb -- npx -y mongodb-mcp-server
claude mcp add sequential-thinking -- npx -y @modelcontextprotocol/server-sequential-thinking
```

## 配置组合建议

| 场景 | 配置 |
|------|------|
| Go 微服务全栈开发 | `go-backend-full.json` |
| 纯代码开发（无基础设施） | `go-backend-minimal.json` |
| 线上问题排查 | `go-backend-full.json` + `observability.json` |
| 开源项目贡献 | `go-backend-minimal.json` |

## 安全注意事项

- `.mcp.json` 中的 token/密码应通过环境变量引用，**不要硬编码**
- 将 `.env` 加入 `.gitignore`
- 生产环境数据库建议使用只读账号
- Kubernetes MCP 使用当前 kubeconfig context，注意切换环境
