# {{PROJECT_NAME}}

{{PROJECT_DESCRIPTION}}

## 任务入口

| 任务 | 命令 |
|------|------|
| 构建 | `go build ./...` |
| 测试 | `go test -race -count=1 ./...` |
| Lint | `golangci-lint run ./...`（v2.8.0，配置见 `.golangci.yml`） |
| 本地依赖 | `docker compose up -d` |
| 启动 | `go run ./cmd/{{SERVICE}}` |
| 部署 | `helm upgrade --install {{SERVICE}} ./deploy/charts/{{SERVICE}} -n {{NAMESPACE}}` |

## 硬约束

- Go 版本固定 **go1.24.6**；不使用 1.25+ API。
- 技术栈：{{DATABASES}}；消息：{{MESSAGE_QUEUE}}；可观测：OpenTelemetry；部署：Kubernetes + Helm。
- 工程标准以 [Maat](https://github.com/omeyang/Maat) 为准；Go 代码规则见 `.claude/rules/go.md`。
- 提交信息遵循 Conventional Commits。

## 项目结构

```
cmd/{{SERVICE}}/      应用入口
internal/             业务代码（domain / usecase / repository / delivery / infrastructure）
pkg/                  对外导出的共享库
api/                  Proto 与 OpenAPI
deploy/               Helm Chart、K8s 清单、Dockerfile
```

## 文档导航

- 架构决策：`docs/adr/`
- API 清单：`docs/api.md`
- 变更记录：`CHANGELOG.md`
