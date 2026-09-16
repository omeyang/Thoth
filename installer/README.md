# thoth-reqloop

reqloop 工作流的安装器。把"需求自验收闭环"装进你的 AI 编码工具。

## 快速开始

**最省事的方式 — 交互模式**（自动探测已装工具，默认勾选）：

```bash
npx -y thoth-reqloop
```

```
reqloop installer  (zero-dep, interactive)

Detected AI tool configs on this machine:
  ✓ 1. claude-code    (~/.claude exists)
    2. codex          (not found)
  ✓ 3. costrict       (~/.costrict exists)
    4. costrict-cli   (not found)

? Targets to install (numbers/names comma-separated, or "all") [detected: claude-code, costrict]:
? Scope [user] (user/project):
? Proceed? [Y/n]
```

**脚本 / CI 模式**（显式传参，不启动交互）：

```bash
# 装到 Claude Code
npx -y thoth-reqloop install claude-code

# 装到 Codex CLI（OpenAI）
npx -y thoth-reqloop install codex

# 装到 costrict（VS Code 扩展）
npx -y thoth-reqloop install costrict

# 装到 costrict-cli（opencode fork）
npx -y thoth-reqloop install costrict-cli

# 一次装到全部 4 个
npx -y thoth-reqloop install all
```

## 装到哪里？

| 目标 | 用户作用域 | 项目作用域 | 形态 |
|------|-----------|-----------|------|
| claude-code | `~/.claude/skills/reqloop/` + `~/.claude/commands/reqloop.md` | `.claude/...` | skill + slash command |
| codex | `~/.codex/prompts/reqloop.md` | — | prompt（内嵌 skill） |
| costrict | `~/.costrict/skills/reqloop/` + `~/.costrict/commands/reqloop.md` | `.costrict/...` | skill + command |
| costrict-cli | `~/.config/costrict/skill/reqloop/` + `~/.config/costrict/command/reqloop.md` | `.costrict/skill|command/...` | 单数目录名 |

> codex 无 skill 概念，安装器会把 SKILL.md + WORKFLOW.md 内嵌进 prompt。

## 子命令

```
install <target>    安装（支持 --scope user|project）
uninstall <target>  卸载
list                列出所有目标及路径
doctor              体检：显示每个目标的安装状态
```

`<target>` 可以是：`claude-code` / `codex` / `costrict` / `costrict-cli` / `all`。

## 使用方式（安装完之后）

所有目标工具里都可以通过 `/reqloop <需求ID>` 调起：

```
/reqloop PR-42 --lite                            # 内置 lite 适配器，仅需 git
/reqloop PRJ-67890 --prd ./prd.md --env staging   # 企业适配器按需求 ID 自动路由
/reqloop PRJ-12345 --from 4                       # 断点续跑
```

## 工作流定义

见 `../workflows/reqloop/WORKFLOW.md`。7 阶段、3 条硬性取舍（阶段 3 人工 confirm 门禁 / 三源冲突以代码为准 / 阶段 5 不下业务结论）。外部系统通过适配器接入，见 `../workflows/reqloop/adapters/README.md`。

## 本地调试（无需 npm 发布）

```bash
cd installer
node bin/install.mjs install claude-code
node bin/install.mjs doctor
node bin/install.mjs uninstall claude-code
```

仓库内运行时，installer 会直接使用 `../workflows/reqloop/` 作为 payload，无需 `prepack` 构建。

## 发布

```bash
cd installer
npm publish --access public
```

`prepack` 钩子会自动将 `../workflows/reqloop/` 拷贝进 `payload/`，保证发布的 tarball 自包含。
