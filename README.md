# Thoth

Thoth 提供三个职责独立、可单独安装、也可组合使用的 Agent Skills。统一采用开放的 `SKILL.md` 目录格式，不要求安装额外命令行工具。

## 三个 Skill

| Skill | 独立职责 | 典型触发 |
| --- | --- | --- |
| [`ui-craft`](skills/ui-craft/SKILL.md) | 视觉方向、品牌与项目风格、中文排版、反 AI 模板感、响应式、交互与真实画面验收 | 页面很丑、不高级、美化、UI/UX、视觉改版 |
| [`explain-business-visually`](skills/explain-business-visually/SKILL.md) | 费曼稿、金字塔/SCQA、主谓宾完整、贴切示例、场景区分、近误对比、必要动画和 teach-back | 讲明白、讲人话、图解、举例、动画演示 |
| [`verify-business-reality`](skills/verify-business-reality/SKILL.md) | 求实、求是、防幻觉、正证反证、真实场景、影响链、调用方、接口假设与决策依据 | 防幻觉、证据核查、影响分析、真实业务、调用链 |

三者不互相依赖。可以只用其中一个，也可以组合：

```text
先使用 verify-business-reality 核验事实、反证和影响范围，
再使用 explain-business-visually 把结论讲明白，
最后使用 ui-craft 按我们的视觉偏好制作并验收页面。
```

组合时保持顺序：先确认“是不是真的”，再解决“是否讲得懂”，最后完成“是否好看且可用”。客户端不支持自动串联时，由用户逐个调用即可。

## 安装与调用

每个 `skills/<name>/` 都是完整 Skill 目录。Windows 与 macOS 使用相同文件内容，安装入口或目录按客户端区分：

| 客户端 | 安装或发现方式 |
| --- | --- |
| [ChatGPT Desktop](https://help.openai.com/en/articles/20001066-skills-in-chatgpt) | Skills → Create → Upload from your computer；上传所选 Skill 目录的 ZIP |
| [Kimi Desktop / Kimi Work](https://www.kimi.ai/zh-hans/features/skills) | 通过开源技能 URL 安装，或上传 `.zip` / `.md`；支持组合技能 |
| [ZCode](https://zcode.z.ai/cn/docs/skill) | 用户级目录 `~/.zcode/skills/<name>/SKILL.md`，随后在设置中刷新并启用 |
| [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness/blob/master/docs/subsystems/skills.md) | 项目 `.dsh/skills/` 或共享 `.agents/skills/`；用户级 `~/.dsh/skills/` |
| [Claude Code](https://docs.anthropic.com/en/docs/claude-code/skills) | 项目 `.claude/skills/`，用户级 `~/.claude/skills/`；用 `/skill-name` 调用 |
| Codex CLI | 项目或用户级 `.agents/skills/`；具体调用语法以当前 Codex 版本为准 |
| [Kimi Code CLI](https://moonshotai.org.cn/kimi-code/en/customization/skills) | `.kimi-code/skills/` 或共享 `.agents/skills/`；支持 `/skill:<name>` |

其他支持开放 Agent Skills 的 CLI，优先尝试 `.agents/skills/<name>/SKILL.md`，再核对当前客户端文档。格式兼容不等于已在所有客户端完成运行认证；本仓库只做结构与链接检查，实际安装后应在目标客户端做一次触发和组合测试。

## 方法来源

- 视觉：Anthropic、Vercel、Microsoft、Google、OpenAI、Figma 及社区设计实践，详见 `ui-craft/references/sources.md`。
- 讲解：费曼、Diátaxis、金字塔、SCQA、Google 技术写作、自我解释、提取练习和认知负荷，详见 Skill 内 `references/methods.md`。
- 核验：Anthropic 的引用与不确定性建议、OpenAI 评测实践、Chain-of-Verification 及当前项目的业务影响链规则，详见 Skill 内 `references/methods.md`。

上游方法只提供流程启发，不能替代当前项目证据、真实页面验收或读者盲测。

## 许可

MIT，见 [LICENSE](LICENSE)。
