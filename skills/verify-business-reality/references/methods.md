# 核验方法与来源

调研日期：2026-11-20。以下来源用于选择核验机制，不能证明任何具体业务事实。

| 来源 | 吸收的方法 | 边界 |
| --- | --- | --- |
| [Anthropic：Reduce hallucinations](https://docs.anthropic.com/en/docs/test-and-evaluate/strengthen-guardrails/reduce-hallucinations) | 允许“不知道”；用原文和引用锚定回答；逐条验证声明，无法支持就撤回 | 引用存在不等于引用支持结论 |
| [Anthropic：Prompting best practices](https://docs.anthropic.com/claude/prompt-library) | 先打开并调查代码，不评价未读代码 | 当前项目仍需实际检索调用方和测试 |
| [OpenAI：Evaluation best practices](https://developers.openai.com/api/docs/guides/evaluation-best-practices) | 用代表性任务评估工具选择、指令遵循和功能正确性；优先清晰的通过/失败判定 | 不用单一 LLM 分数代替业务证据 |
| [Dhuliawala 等：Chain-of-Verification](https://arxiv.org/abs/2309.11495) | 起草后生成核验问题，独立查证，再修正答案 | 自我复核仍可能共享错误前提，需要外部材料 |
| [Nature：Evaluating large language models for accuracy incentivizes hallucinations](https://www.nature.com/articles/s41586-026-10549-w) | 评测不能只奖励答对，要合理评价不确定性，避免逼迫模型猜测 | 不据此推断某个具体模型的一定行为 |

本 Skill 额外保留业务特有规则：正证与反证、历史意图、数据流/调用链/接口顺序、影响范围、接口假设等级和场景适配。这些规则来自当前项目需求，不归因给上述来源。
