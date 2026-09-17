---
description: 自然语言提问是否触发 idempotency-go 技能
tags: [trigger]
max_turns: 6
allowed_tools: [Read, Glob, Grep, Skill]
---

支付接口需要幂等，客户端传 Idempotency-Key，用 Go 和 Redis 怎么实现去重和状态追踪？
