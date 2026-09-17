---
description: 自然语言提问是否触发 k8s-go 技能
tags: [trigger]
max_turns: 6
allowed_tools: [Read, Glob, Grep, Skill]
---

用 client-go 写一个 controller，监听 Deployment 变化并用工作队列处理事件。
