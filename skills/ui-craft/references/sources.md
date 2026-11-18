# 来源与许可

调研日期：2026-11-18。本 Skill 是面向 Thoth 的独立编写与整合，不捆绑上游代码、模板、图片或字体。下表记录方法来源，方便继续追踪原项目。

| 项目 | 吸收的方法 | 上游许可/说明 |
| --- | --- | --- |
| [Anthropic frontend-design](https://github.com/anthropics/skills/tree/main/skills/frontend-design) | 先建立主题相关的设计契约；识别生成式默认风格；一处大胆、其余克制 | Apache-2.0 |
| [Impeccable](https://github.com/pbakaus/impeccable) | 对已有界面做定向评审；将反模板与技术质量检查放入交付前 | Apache-2.0 |
| [Oil UI](https://github.com/oil-oil/oil-ui) | 工具页首屏直接进入内容；多方向必须有实质差异；真实截图与减法评审 | MIT（见上游） |
| [Taste Skill](https://github.com/Leonxlnx/taste-skill) | 真实素材与真实产品画面；按页面类型限制特效；浏览器门禁 | MIT |
| [Emil Kowalski Skills](https://github.com/emilkowalski/skills) | 动效先判断频率与目的；重视曲线、可中断性、按压与焦点等细节 | 见上游各文件 |
| [UI UX Pro Max](https://github.com/nextlevelbuilder/ui-ux-pro-max-skill) | 将风格、色彩、字体、行业与 UX 规则组织为可检索设计决策 | MIT |
| [Vercel Web Interface Guidelines](https://github.com/vercel-labs/web-interface-guidelines) | 语义、焦点、表单、响应式、动效和内容边界的具体检查项 | 见上游 |
| [Chinese Font Selector](https://github.com/Songzhi-lab/chinese-font-selector) | 中文字体授权意识、中英混排、行距与字体加载成本 | 文档 MIT；字体各自许可 |
| [Microsoft Frontend Design Review](https://github.com/microsoft/skills/blob/main/.github/skills/frontend-design-review/SKILL.md) | 顺畅行动、工艺质量、可信构建三维评审；设计系统与动作层级检查 | MIT；本 Skill 将固定交互次数等规则改为情境化判断 |
| [Google Labs Stitch Skills](https://github.com/google-labs-code/stitch-skills) | 语义化 `DESIGN.md`：自然语言角色与精确值并存，从现有实现提炼设计系统 | 见上游；仓库注明不是正式支持的 Google 产品 |
| [OpenAI Figma Implement Design](https://github.com/openai/skills/blob/main/skills/.curated/figma-implement-design/SKILL.md) | 设计上下文与截图双证据、工程约定映射、组件复用与增量视觉校准 | 见上游；仅在具备 Figma 证据时启用 |

参考体验：

- [优设美地](https://allan.xin/)：提炼内容优先、首屏工具直达、克制底色与单一高亮、图像主导卡片等设计方法。
- [Shopify Design](https://shopify.design/)：提炼品牌展示页的单一主张、超大标题与克制正文、大量留白、真实作品视频墙；同时用静态海报、媒体预算和减少动态效果约束这些手法。

两者代表不同页面任务，不把展示型大 Hero 套到工具或技术讲解页。未复制其代码、品牌、字体、图片、视频或文案。

## 再分发边界

- Thoth 中新增文本与脚本遵循仓库 MIT License。
- 上游名称与链接仅用于归因和方法说明，不表示上游为 Thoth 背书。
- 若未来直接复制上游文件或资产，必须同时保留对应版权与许可文本，并标明修改。
- 字体、照片、图标和参考站内容不因本 Skill 的 MIT 许可而自动获得再分发授权。
