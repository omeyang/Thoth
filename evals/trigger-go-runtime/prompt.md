---
description: 自然语言提问是否触发 go-runtime 技能
tags: [trigger]
max_turns: 6
allowed_tools: [Read, Glob, Grep, Skill]
---

解释一下 Go 调度器 GMP 在 goroutine 阻塞在网络 IO 时是怎么处理的，以及 GC 三色标记为什么需要写屏障。
