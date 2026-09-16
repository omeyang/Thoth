# 项目原则（示例）

> 本文件由 design-review 作为「项目原则」追加注入每个 agent prompt，优先级高于通用 `templates/principles.md`。
> 只写项目特有的内容；通用原则不要复制过来。不得删除通用原则"硬约束"段任一条。

## 1. 判断基准（细化通用原则 1.1–1.3）

| # | 原则 |
|---|---|
| 1.1 | 基线系统 = `/path/to/legacy-service`（功能权威）与 `/path/to/legacy-gateway`（路由权威）；目标架构见背景文档 `design/00-overview.md` |
| 1.2 | 契约事实到 `/path/to/contract-registry` 核实；数据形态到 `/path/to/data-export` 核实 |

## 3. 节奏（细化通用原则 3.1–3.4）

| # | 原则 |
|---|---|
| 3.1 | 词表位置：`design/00-overview.md §12` |
| 3.2 | `/path/to/project/docs/` 下旧设计文档不作依据 |
| 3.4 | 最终要移除的老组件：`legacy-service` 租户侧进程 |

## 5. 控制权边界

- 应用零平台 API 权限（见 ADR-0003）
- 客户监控栈由客户运维管理，应用只能告警
