# prompts

提示词模板和可复用的提示词片段。

## 目录结构

```
prompts/
├── README.md
├── system/                       # System Prompt / CLAUDE.md 模板
│   ├── CLAUDE.md.tmpl            # Go 微服务项目 CLAUDE.md 模板
│   └── CLAUDE-domain.md.tmpl     # 领域上下文模板（子目录级）
├── task/                         # 任务型提示词
│   ├── code-review.md            # 代码审查任务
│   ├── bug-investigation.md      # Bug 排查任务
│   └── feature-implementation.md # 功能实现任务
└── snippets/                     # 可复用的代码片段
    ├── error-handling.md          # 错误处理模式
    └── concurrency.md             # 并发模式
```

## 使用方式

### CLAUDE.md 模板

1. 复制 `system/CLAUDE.md.tmpl` 到目标项目根目录，重命名为 `CLAUDE.md`
2. 替换 `{{PLACEHOLDER}}` 为实际值
3. 根据项目特点删减不需要的部分
4. 对于大型项目，在子目录中使用 `CLAUDE-domain.md.tmpl` 提供领域上下文

### 任务提示词

任务提示词定义了标准化的执行流程，可以:
- 在 CLAUDE.md 中引用: "代码审查流程参考 prompts/task/code-review.md"
- 作为 Agent 的工作指令
- 作为自定义 Skill 的执行步骤

### 代码片段

代码片段提供常用模式的参考实现，可以:
- 在编码时快速引用
- 在 CLAUDE.md 中作为代码规范的具体示例
- 在 Agent 定义中作为输出模板

## 模板变量说明

| 变量 | 说明 | 示例 |
|------|------|------|
| `{{PROJECT_NAME}}` | 项目名称 | user-service |
| `{{PROJECT_DESCRIPTION}}` | 一句话描述 | 用户管理微服务 |
| `{{GO_VERSION}}` | Go 版本 | 1.23 |
| `{{SERVICE}}` | 服务名 | user-service |
| `{{NAMESPACE}}` | K8s 命名空间 | platform |
| `{{DATABASES}}` | 数据库列表 | MongoDB, Redis |
| `{{MESSAGE_QUEUE}}` | 消息队列 | Kafka |
| `{{CI_CD}}` | CI/CD 工具 | GitHub Actions |
