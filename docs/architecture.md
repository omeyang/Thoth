# 当前架构

Thoth 是纯 Agent Skills 仓库，只包含两个职责不同的技能。旧版综合插件架构已在 2026-11-20 的全面重写中移除，历史可从 Git 提交 `d791748` 之前的版本读取。

## 组件

```text
explain-business-visually
├── SKILL.md                  三层模型与四步入口
├── references/               事实、教学、六字段契约、视觉门禁
├── scripts/audit_explainer.py 内容与动画语义审计
└── templates/                证据台账、teach-back、评分表

ui-craft
├── SKILL.md                  视觉与交互入口
├── references/               设计、交互、评审方法
├── assets/                   可交互技术讲解页示例
└── scripts/
    ├── html_hygiene.py       唯一共享 HTML 卫生层
    └── audit_ui.py           UI 审计命令行
```

`audit_explainer.py` 在源码仓库中读取 `ui-craft` 的共享模块；构建独立业务图解包时，`package-skill.py` 将该模块注入其 `scripts/`。不维护第二份复制实现。

## 验收边界

| 层 | 工具 | 能证明什么 | 不能证明什么 |
| --- | --- | --- | --- |
| 契约与 HTML | 单元测试、两个审计器 | 字段自洽、引用存在、静态硬错误 | 读者已经理解 |
| 真实画面 | Chromium、桌面/375px 截图、交互走查 | 页面实际呈现与操作结果 | 业务事实正确 |
| 理解 | 独立 teach-back 盲测与评分表 | 读者能复述、决策、指出边界 | 未覆盖场景都正确 |

三个 fixture 是明确标注的假设场景，只用于回归技能机制，不充当生产证据。

## 已删除的旧边界

仓库不再包含 Claude/Codex 插件清单、Go 与中间件技能、子代理、Git Hooks、MCP 配置、项目模板、定时审查工作流或 Wiki 同步。`scripts/validate.sh` 会阻止这些旧根目录被无意恢复。
