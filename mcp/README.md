# mcp

项目级 `.mcp.json` 模板。MCP 服务器连接的是具体项目的基础设施，凭证按项目走，所以不随插件自动装载，而是复制到目标项目根目录：

```bash
cp Thoth/mcp/configs/go-backend-full.json your-project/.mcp.json
```

| 模板 | 内容 | 场景 |
|------|------|------|
| `go-backend-full.json` | GitHub、Kubernetes、MongoDB、Redis、ClickHouse、Kafka、Sequential Thinking | Go 微服务全栈开发、线上排查 |
| `go-backend-minimal.json` | GitHub、Sequential Thinking | 纯代码开发、开源贡献 |
| `observability.json` | OpenTelemetry（Jaeger / Tempo） | 链路排查，与 full 叠加使用 |

## 环境变量

模板用 `${VAR}` 与 `${VAR:-默认值}` 引用环境变量（Claude Code 的 `.mcp.json` 支持这种展开）。Codex 的 MCP 配置在 `~/.codex/config.toml` 的 `[mcp_servers.<name>]`，不支持 `${VAR}`，用 `codex mcp add` 逐个添加并通过 `env_vars` 透传环境变量。

```bash
GITHUB_TOKEN=github_pat_xxx            # GitHub 官方 MCP（HTTP），需要 PAT
MONGODB_URI=mongodb://localhost:27017
REDIS_URL=redis://localhost:6379/0
CLICKHOUSE_HOST=localhost              # 其余 CLICKHOUSE_* 有默认值
KAFKA_BROKERS=localhost:9092
OTEL_BACKEND_TYPE=jaeger               # observability.json
OTEL_BACKEND_URL=http://localhost:16686
```

把这些放进 `.env` 并加入 `.gitignore`。`protect-secrets` 钩子会拦截对 `.env` 的读写。

## 服务器清单

各服务器的来源、能力与替代实现见 [servers/README.md](./servers/README.md)。

## 安全

- MongoDB 模板默认 `--readOnly`；生产库统一用只读账号。
- Kubernetes MCP 使用当前 kubeconfig context，切环境前先确认。
- GitHub MCP 走官方托管服务，PAT 只授予需要的权限范围。
