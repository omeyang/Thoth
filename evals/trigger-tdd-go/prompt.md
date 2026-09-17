---
description: 自然语言提问是否触发 tdd-go 技能
tags: [trigger]
max_turns: 6
allowed_tools: [Read, Glob, Grep, Skill]
---

用 TDD 的方式给 pkg/ratelimit 实现一个令牌桶限流器，先写失败测试。
