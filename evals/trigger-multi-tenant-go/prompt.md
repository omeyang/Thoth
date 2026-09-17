---
description: 自然语言提问是否触发 multi-tenant-go 技能
tags: [trigger]
max_turns: 6
allowed_tools: [Read, Glob, Grep, Skill]
---

SaaS 系统的 tenant ID 需要从 HTTP header 一路传到 gRPC 和数据库查询，Go 里怎么做租户上下文传播和数据隔离？
