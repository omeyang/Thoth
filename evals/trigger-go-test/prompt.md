---
description: 自然语言提问是否触发 go-test 技能
tags: [trigger]
max_turns: 6
allowed_tools: [Read, Glob, Grep, Skill]
---

为 pkg/parser 里的 Parse 函数写表驱动单元测试和基准测试，外部依赖用 mock。
