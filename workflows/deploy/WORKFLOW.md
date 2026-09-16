# 部署工作流

从代码到 Kubernetes 集群的标准化部署流程。

## 前置条件

### 工具

| 工具 | 用途 | 检查命令 |
|------|------|---------|
| `go` ≥ 1.21 | 编译和测试 | `go version` |
| `docker` | 镜像构建 | `docker version` |
| `kubectl` | 集群操作 | `kubectl version --client` |
| `helm` ≥ 3.0 | Chart 部署 | `helm version` |
| `kubeconform` | YAML 校验（推荐） | `kubeconform -v` |
| `golangci-lint` | 预检 lint | `golangci-lint version` |

### 环境要求

- 可访问的 Kubernetes 集群（`kubectl cluster-info` 正常）
- 有推送权限的容器镜像仓库
- `kubeconfig` 已配置正确的 context 和 namespace

### 组件依赖

| 组件 | 路径 | 必需 |
|------|------|------|
| `k8s-devops` Agent | `agents/k8s-devops/AGENT.md` | 是 |
| `k8s-go` Skill | `skills/k8s-go/SKILL.md` | 推荐 |
| `block-dangerous.sh` Hook | `hooks/scripts/block-dangerous.sh` | 是（防误操作） |
| `session-context.sh` Hook | `hooks/scripts/session-context.sh` | 推荐 |
| `kubernetes` MCP | `mcp/configs/go-backend-full.json` | 推荐 |

## 适用场景

- 新服务首次部署
- 版本升级
- 回滚操作

## 流程定义

```
┌─────────────────────────────────────────────────┐
│  1. 预检                                         │
│     • git status 确认工作区干净                    │
│     • go test -race ./... 全量测试通过             │
│     • golangci-lint run ./... 无错误              │
│     • 确认目标 K8s context                        │
└──────────────────────┬──────────────────────────┘
                       ▼
┌─────────────────────────────────────────────────┐
│  2. 构建                                         │
│     • docker build -t <image>:<tag> .            │
│     • docker push <image>:<tag>                  │
│     • 记录 image digest                          │
└──────────────────────┬──────────────────────────┘
                       ▼
┌─────────────────────────────────────────────────┐
│  3. 清单验证                                      │
│     • helm template 渲染确认                      │
│     • kubeconform 校验 YAML                       │
│     • 确认 resource limits/requests               │
│     • 确认 probe 配置                             │
│     • 确认 PDB 配置                               │
└──────────────────────┬──────────────────────────┘
                       ▼
┌─────────────────────────────────────────────────┐
│  4. 部署                                         │
│     • helm upgrade --install <release> ./chart   │
│     • kubectl rollout status deployment/<name>   │
│     • 等待所有 Pod Ready                          │
└──────────────────────┬──────────────────────────┘
                       ▼
┌─────────────────────────────────────────────────┐
│  5. 验证                                         │
│     • 健康检查: curl /healthz, /readyz           │
│     • 日志检查: kubectl logs (无异常)              │
│     • 指标检查: Prometheus 指标正常                │
│     • 冒烟测试: 核心 API 调用验证                  │
└──────────────────────┬──────────────────────────┘
                       ▼
              ┌────────────────┐
              │   验证通过？    │
              └────┬─────┬─────┘
                   │ 是  │ 否
                   ▼     ▼
              完成      回滚
                       helm rollback <release>
```

## 使用的组件

| 组件 | 类型 | 用途 |
|------|------|------|
| `k8s-devops` | Agent | 部署执行主体 |
| `k8s-go` | Skill | K8s 操作指导 |
| `block-dangerous.sh` | Hook | 拦截生产环境误操作 |
| `session-context.sh` | Hook | 注入当前 K8s context |
| `kubernetes` | MCP | 集群操作 |

## Agent 调用方式

部署工作流由 `k8s-devops` Agent 主导执行，全流程通过单次 Task 调用完成。`block-dangerous.sh` Hook 在后台自动守护，拦截生产环境误操作。

### 标准部署

```
Task(
  subagent_type = "general-purpose",
  prompt = """
  <agents/k8s-devops/AGENT.md 全文>

  ## 任务

  将服务部署到 Kubernetes。

  - 目标环境: <context-name>, namespace: <namespace>
  - 操作类型: deploy
  - Helm Chart 目录: ./deploy/helm/<service-name>
  - 镜像: <registry>/<image>:<tag>

  ## 执行步骤
  1. 预检: git status 确认工作区干净，go test -race ./... 通过
  2. 构建: docker build + push（如镜像未就绪）
  3. 清单验证: helm template + kubeconform 校验
  4. 部署: helm upgrade --install
  5. 验证: kubectl rollout status + 健康检查 + 日志检查
  6. 输出部署报告（Pod 状态、镜像 digest、验证结果）

  ## 安全约束
  - 生产环境所有破坏性操作必须先 --dry-run=client
  - 输出完整命令等用户确认后再执行
  """
)
```

### 回滚部署

```
Task(
  subagent_type = "general-purpose",
  prompt = """
  <agents/k8s-devops/AGENT.md 全文>

  ## 任务

  回滚服务到上一版本。

  - 目标环境: <context-name>, namespace: <namespace>
  - 操作类型: debug + deploy
  - Release 名称: <release-name>

  ## 执行步骤
  1. helm history <release> 查看版本历史
  2. 确认回滚目标版本
  3. helm rollback <release> <revision> --dry-run 预览
  4. 等用户确认后执行回滚
  5. kubectl rollout status 验证
  6. 检查日志和健康状态
  """
)
```

### Manifest 审查（不执行部署）

```
Task(
  subagent_type = "general-purpose",
  prompt = """
  <agents/k8s-devops/AGENT.md 全文>

  ## 任务

  审查 Kubernetes manifests，不执行部署。

  - 操作类型: review manifests
  - 相关文件: ./deploy/helm/<service-name>/

  ## 审查要点
  - resource requests/limits 是否合理
  - probe 配置是否完整
  - PDB 是否配置
  - securityContext 是否安全（nonRoot, readOnly）
  - 标签是否符合 app.kubernetes.io 规范
  - Secret 是否通过 Sealed/External Secrets 管理
  """
)
```

### Hook 守护说明

部署过程中，`block-dangerous.sh` Hook 自动拦截以下操作：
- `kubectl delete/drain/cordon` 针对生产 context
- `rm -rf` 意外删除
- `git push --force` 到 main/master

如果被拦截，Agent 会收到 stderr 反馈并调整方案。无需人工干预。

## 回滚流程

```bash
# Helm 回滚
helm rollback <release> <revision>

# 或手动回滚镜像
kubectl set image deployment/<name> <container>=<image>:<previous-tag>

# 验证回滚
kubectl rollout status deployment/<name>
kubectl logs -f deployment/<name>
```

## 安全检查清单

- [ ] 确认目标环境 (`kubectl config current-context`)
- [ ] 确认命名空间 (非 default)
- [ ] 镜像来自受信任的 registry
- [ ] Secret 通过 Sealed Secrets 或 External Secrets 管理
- [ ] 网络策略已配置
- [ ] RBAC 权限最小化
- [ ] 资源限制已设置

## Dockerfile 模板

```dockerfile
FROM golang:1.23-alpine AS builder
RUN apk add --no-cache git ca-certificates
WORKDIR /app
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /server ./cmd/server

FROM scratch
COPY --from=builder /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/
COPY --from=builder /server /server
USER 65534:65534
ENTRYPOINT ["/server"]
```
