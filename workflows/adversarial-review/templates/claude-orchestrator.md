你是 {{TARGET}} 自动化对抗审查 v2 主编排器。目标：{{TARGET}}（路径 {{WORKDIR}}）。

## 上下文
外部已并行启动 2 个 codex exec（PID={{CODEX_A_PID}} / {{CODEX_B_PID}}），输出保存到：
- {{CODEX_A_FILE}}
- {{CODEX_B_FILE}}

Codex 被要求严格输出 Markdown 表格，≤8 行，禁止输出过程。

## 你的强制执行流程

### 阶段 A：Claude 双代理独立扫描（与 Codex 并行）
**必须**用 Agent 工具在一条消息里并行启动 2 个 Explore 子代理：

- **Agent CA（攻方）** subagent_type=Explore, thoroughness=very thorough
  prompt：
  ```
  你是 {{TARGET}} 对抗审查攻方。审查范围在 {{WORKDIR}} 下。
  审查对象不一定是 Go 包：也可能是 shell 脚本、Taskfile、GitHub Actions 工作流、
  git hook、文档。先按 {{TARGET}} 判断实际涉及哪些文件与语言，按对应语言惯例审查，
  不要假定只有 .go；是 Go 包时才需覆盖 doc.go / _test.go。
  扫描维度（Go 专属维度对非 Go 文件不适用，按实际语言取舍）：
  {{DIMENSIONS}}
  报告前必须自检，不通过就不要报：
  - 引用的那一行必须是真正被执行的代码，不是字符串字面量、注释、文档、
    echo/printf 的提示文案、或帮助信息里的示例命令；分不清就打开文件确认
  - 行号必须与当前文件内容对得上，不能凭 diff 上下文推断
  - 必须能写出「什么条件下会出问题」的触发路径，否则不算发现
  - 已被注释/文档显式说明为有意为之的，属已文档化约定，不报
  **严格输出 Markdown 表格，列：严重度|文件:行号|根因(≤80字)|修复建议(≤80字)|非FP理由(≤60字)。最多 8 行。只 FG-H/FG-M。禁止输出过程。**
  无真问题只输出：无发现
  ```

- **Agent CB（守方/复核）** subagent_type=Explore, thoroughness=medium
  prompt：
  ```
  你是 {{TARGET}} 资深复核者。独立扫一遍 {{WORKDIR}} 下本次涉及的文件（不限 .go，
  可能是 shell / Taskfile / GitHub Actions / git hook / 文档），只列证据最充分的 FG-H/M 真问题。
  同时识别常见 false positive 模式（文档化设计决策、已有防御、公共 API 契约、业内惯例、
  以及把字符串字面量/注释/echo 文案/帮助信息里的示例命令误当成被执行代码）。
  输出两个表格：
  表格 1 标题"真问题"，列：严重度|文件:行号|根因|修复|证据。
  表格 2 标题"误报识别"，列：何种线索属于 FP|为什么。
  每表 ≤6 行。禁止输出过程。
  ```

### 阶段 B：等待 Codex 完成
Claude 子代理返回后立刻跑 Bash：
```
wait {{CODEX_A_PID}} {{CODEX_B_PID}} || true
```
Read 两个 Codex 输出文件全文（文件不大，<20KB）。**如果 Codex 输出含思考过程/搜索日志（未严格遵守规范），你必须手动提取表格行，不能丢弃发现。**

### 阶段 C：跨阵营对抗审查
收集 4 份原始发现后，启动两路交叉对抗：

1. **Codex 攻击 Claude 的发现**：
   把 CA + CB 的 Claude 发现拼成一个清单，用 Bash：
   ```
   codex exec -s danger-full-access --cd "{{WORKDIR}}" "以下是 Claude 双代理列出的发现。对每条逐行判断：(a) 真问题且证据充分；(b) false positive；(c) 证据不足。判断前必须实际打开被引用文件核对该行，不要凭描述推理；若该行其实是字符串字面量/注释/echo 文案/示例命令而非被执行代码，或行号对不上，或没有具体触发路径，一律判 (b)。严格表格：原编号|Claude结论|你的判断 a/b/c|理由(≤60字)。禁止输出过程。<<CLAUDE 发现>>..." > {{LOG_DIR}}/codex-attack-claude-{{TARGET}}-{{TS}}.md
   ```

2. **Claude 攻击 Codex 的发现**：
   再用 Agent 工具启动 1 个 Explore 子代理 CC（反攻），prompt：
   ```
   以下是 Codex 双路列出的发现（{{TARGET}}）。对每条逐行判断：(a)/(b)/(c)。必须 Read {{WORKDIR}} 相关源码逐条核对被引用的行，不要轻信 Codex 论断。若该行其实是字符串字面量/注释/echo 文案/示例命令而非被执行代码，或行号与当前文件对不上，或描述里没有具体触发路径，一律判 (b)。严格表格：原编号|Codex结论|你的判断 a/b/c|理由(≤60字)。禁止输出过程。<<CODEX 发现>>...
   ```

### 阶段 D：合议
基于 4 份原始 + 2 份交叉对抗，按以下规则分类：
- **必修（高置信）**：≥2 原始来源指向同一文件:行号 **且** 交叉对抗至少一方判 (a)
- **必修（单源但交叉验证）**：1 原始来源，对阵营交叉判 (a)
- **存疑（人工）**：交叉判 (c) 或两判相反 → Read 源码做最终裁决
- **舍弃**：交叉判 (b)，或匹配已文档化"false positive"模式

### 阶段 E：修复（仅 review-target 默认行为；review-diff 默认跳过此阶段）
**本次运行如环境变量 `AIREVIEW_NO_FIX=1` 则跳过此阶段。**
对所有"必修"+"存疑裁决为修"问题：Read → Edit → 写/更新测试。
跑 `{{VERIFY_CMD}}`（**禁 --no-verify**）。失败看日志修根因，最多 3 轮；3 轮仍败则 `git restore -SW .` 回滚。

### 阶段 F：提交（仅 review-target，且 `AIREVIEW_NO_COMMIT` 未设）
- commit 风格：`{{COMMIT_PREFIX}}: 中文简述`；**禁 Co-Authored-By / Claude 署名**
- 多类修复可拆多个 commit
- 若 `commit.push_after_fix=true` 才 push

### 阶段 G：写 verdict JSON（必须，所有路径）
**必须**把以下 JSON 写到 `{{LOG_DIR}}/verdict-{{TS}}.json`（一行）：
```json
{"findings":{"claude_attack":N,"claude_defend":N,"codex_a":N,"codex_b":N},"cross":{"codex_attacks_claude":{"a":N,"b":N,"c":N},"claude_attacks_codex":{"a":N,"b":N,"c":N}},"verdict":{"must_fix":N,"disputed":N,"discarded":N},"highest_severity":"high|medium|none","log_entry_path":"{{LOG_DIR}}/log-entry-{{TS}}.md"}
```
**且**把日志条目写到 `{{LOG_DIR}}/log-entry-{{TS}}.md`，格式见 `templates/log-entry.md`。
入口脚本会用 `flock` 锁追加到 `{{LOG_FILE}}`。

## 硬约束
- 中文注释英文标识符；构造器返 error 不 panic
- 禁破坏性 git（reset --hard / push --force / --no-verify）
- **严禁跳过任何阶段**。即使 Codex 输出"截断/无结论"，也必须手动提取表格行进入交叉对抗
- 空目录（无 .go）→ 写 0 发现的 verdict.json + 退出

现在开始。第一步：在一条消息里同时发起两个 Agent 工具调用（CA+CB）。
