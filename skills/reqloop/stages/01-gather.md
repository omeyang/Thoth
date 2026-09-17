# 阶段 1 — 需求采集 (gather)

## 目标

拉取需求单原文 + （可选）更详细的 PRD，作为反讲的**声明侧**输入源 A。

## 输入

- 需求 ID（任意唯一标识；适配器的 `id_patterns` 决定路由，见 `adapters/README.md`）
- （可选）PRD 文档路径 / 链接

## 步骤

1. **选定适配器**
   - 按 `adapters/README.md` 的选择规则确定适配器，向用户报告「适配器：<name>（来源路径）」
   - 逐个探活 `adapter.yaml.tools`

2. **拉取需求单**（执行适配器 `requirements.md` 槽位）
   - 必拉字段：标题、描述、验收标准、关联迭代/版本、处理人
   - 必拉：评论区（常含补充说明和变更）
   - 必拉：关联的子需求 / 拆分项（若有）
   - 具体用什么工具、字段如何映射，由槽位文件决定；本文件不写死

3. **询问是否附加 PRD**
   - 若用户提供 PRD 路径，读取全文附加
   - 若用户提供链接（wiki / 飞书等），提示用户手工下载后提供路径（不自动抓取）
   - 若无，跳过（后续反讲只依赖需求单 + 代码）

4. **写入产物**

## 产物

`.reqloop/req-{id}.md`，格式：

```markdown
---
id: {id}
stage_status: complete | in_progress
adapter: {适配器名}
source: {适配器定义的来源标识，如 tracker | pr | commits | manual}
fetched_at: {ISO8601}
has_prd: true | false
---

## 需求单原文
...

## 验收标准
...

## 评论补充
...

## PRD 附加（若有）
...
```

## 失败处理

- 需求单拉取失败 → 中止流程，提示用户检查权限或 ID
- PRD 读取失败 → 警告但不中止，记录 `has_prd: false`
