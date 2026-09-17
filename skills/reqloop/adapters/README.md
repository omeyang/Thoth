# reqloop 适配器（adapter）

reqloop 的流水线本身不绑定任何需求管理系统、代码托管平台、CI 或测试平台。
所有"与外部系统打交道"的动作都被抽成 5 个**槽位（slot）**，由适配器包（adapter pack）提供具体做法。
Thoth 内置 `lite` 适配器（只依赖 git + 本地测试命令）；企业内部工具链的适配器放在私有插件仓库里，按下文的查找顺序加载。

## 5 个槽位

| 槽位 | 职责 | 消费阶段 | 产物 |
|------|------|---------|------|
| `requirements` | 按需求 ID 拉取需求单原文、验收标准、评论、关联子需求 | 阶段 1 gather | `.reqloop/req-{id}.md` |
| `code` | 采集与需求关联的全部代码变更（可能跨多个仓库） | 阶段 2 collect-code | `.reqloop/code-{id}/` |
| `ci` | 在指定环境执行 build / test / lint 并拉回日志 | 阶段 5 runtime | `.reqloop/runtime-{id}.md` 的「CI 结果」段 |
| `e2e` | 匹配并执行端到端回归，归档报告 | 阶段 6 e2e | `.reqloop/e2e-{id}.md` |
| `defects` | 为失败项创建缺陷并把缺陷 ID 写回报告 | 阶段 7 report | `.reqloop/acceptance-{id}.md` 的「失败项对应缺陷」表 |

阶段 3（反讲）、4a（审查）、4b（影响分析）、8（导出）不经过适配器，所有适配器共用。

## 适配器包结构

```
<name>/
├── adapter.yaml        # 元信息
├── requirements.md     # requirements 槽位的执行指令
├── code.md             # code 槽位
├── ci.md               # ci 槽位
├── e2e.md              # e2e 槽位
└── defects.md          # defects 槽位
```

`adapter.yaml` 字段：

```yaml
name: lite                       # 适配器名，与目录名一致
description: 一句话说明
id_patterns: []                  # 需求 ID 正则列表；命中即自动选用本适配器（空 = 不参与自动匹配）
source_types: [tracker, PRD, inferred-from-code]   # 允许写进反讲 §1 `source.type` 的值
tools: [git, gh]                 # 本适配器依赖的 skill / CLI，执行前逐个探活
defect_id_prefix: "issue-"       # 缺陷 ID 前缀，阶段 7 报告用
```

每个槽位文件都按同一骨架书写：**输入 → 步骤 → 输出字段 → 失败处理**。
阶段文件（`stages/0X-*.md`）只描述与适配器无关的骨架和门禁，槽位文件描述"用什么工具、怎么调、拉哪些字段"。

## 查找顺序

给定适配器名 `<name>`，按下列顺序找到第一个存在 `adapter.yaml` 的目录：

1. `./.reqloop/adapters/<name>`（项目内私有）
2. `$THOTH_PROFILES/reqloop/adapters/<name>`（插件根目录，环境变量）
3. `${XDG_CONFIG_HOME:-$HOME/.config}/thoth/profiles/reqloop/adapters/<name>`（插件根目录，默认位置）
4. `<reqloop>/adapters/<name>`（Thoth 内置）

## 选择规则

优先级从高到低，首个命中即生效：

1. 命令行 `--adapter <name>`；`--lite` 等价于 `--adapter lite`
2. 工作目录下 `.reqloop.yaml` 的 `adapter: <name>`
3. 自动匹配：把需求 ID 依次与**所有可发现适配器**（按上面 4 个位置枚举）的 `id_patterns` 匹配，唯一命中则选用；多个命中时向用户确认
4. 兜底：`lite`

选定后，AI 在开始阶段 1 前向用户报告「适配器：<name>（来源路径）」，并逐个探活 `adapter.yaml.tools`；缺失工具时按各槽位文件的失败处理执行，不得静默切换到别的适配器。

## `.reqloop.yaml`（可选）

```yaml
adapter: lite            # 固定使用的适配器
base: main               # lite 的 diff 基线
test_cmd: "make test"    # lite 的验证命令（覆盖自动推断）
```

## 编写新适配器

1. 复制 `adapters/lite/` 为模板，改 `adapter.yaml`
2. 逐槽位替换工具调用；不要改动阶段文件中的门禁与产物格式
3. 私有适配器放到插件根目录的 `reqloop/adapters/<name>/`，不要提交到 Thoth
