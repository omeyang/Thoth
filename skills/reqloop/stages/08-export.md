# 阶段 8 — 生态导出 (export)

## 动机

reqloop 的产物是 Markdown + YAML + JSONL，方便 AI/人工阅读，但不直接对接传统 ALM：
IBM DOORS、Polarion、Jama、Inflectra Spira、Jira Xray 都以 **OSLC / ReqIF** 为事实交换标准。
本阶段把 `.reqloop/` 产物映射成这些格式，让验收结果能回流企业级需求管理系统。

可选阶段：用户需要时通过 `/reqloop export <id>` 触发，不在默认流程里。

## 输出格式

### 1. ReqIF 2.1（OMG 标准）

文件：`.reqloop/export/{id}.reqif`

映射规则：

| reqloop 字段 | ReqIF 字段 |
|-------------|-----------|
| `requirements[].id` | `SPEC-OBJECT IDENTIFIER` |
| `requirements[].ears` | `ATTRIBUTE-VALUE-STRING` name=`Description` |
| `requirements[].source.ref` | `ATTRIBUTE-VALUE-STRING` name=`SourceRef` |
| `requirements[].status` | `ATTRIBUTE-VALUE-ENUMERATION` name=`VerificationStatus` |
| `requirements[].code_anchors` | `RELATION-GROUP` → 外部 link（git://...）|
| `requirements[].test_anchors` | `RELATION-GROUP` → 外部 link |

### 2. OSLC-RM Turtle（W3C 语义网格式）

文件：`.reqloop/export/{id}.ttl`

每条 requirement 映射为 `oslc_rm:Requirement`：
```turtle
<#REQ-001> a oslc_rm:Requirement ;
    dcterms:identifier "REQ-001" ;
    dcterms:title "WHEN 金额>1000, THE 系统 SHALL 触发风控" ;
    oslc_rm:implementedBy <git://repo-a/pkg/foo/bar.go#L42-L68> ;
    oslc_rm:validatedBy <git://repo-a/pkg/foo/bar_test.go#TestRiskCheck> ;
    reqloop:verificationStatus "covered" ;
    reqloop:confidence "high" .
```

### 3. Traceability Matrix CSV（兜底格式）

文件：`.reqloop/export/{id}-trace.csv`

为不支持 OSLC 的系统（如某些国产 ALM）提供扁平 CSV：
```
req_id,ears,source_type,source_ref,code_file,code_lines,test_case,status,confidence
REQ-001,"WHEN ...",tracker,AC-3,pkg/foo/bar.go,"42-68",TestRiskCheck,covered,high
```

### 4. Jira Xray / Zephyr JSON

文件：`.reqloop/export/{id}-xray.json`

用于把"业务场景 → 测试用例"映射写回测试管理工具。

## 步骤

1. 读取 `.reqloop/backspec-{id}.md` 的 §1 结构化 YAML（必须已 confirm）
2. 读取 `.reqloop/decisions-{id}.jsonl`，聚合最终 verdict/confidence
3. 按目标格式转换，写入 `.reqloop/export/`
4. 若配置了对接端点（`~/.reqloop/export-config.yaml`），用对应工具推送：
   - DOORS Next Generation：OSLC-RM REST API
   - Jama：REST API v1
   - Spira：REST API
   - Jira Xray：GraphQL

## 配置样例

`~/.reqloop/export-config.yaml`：
```yaml
formats: [reqif, csv]           # 默认导出格式
targets:
  - name: spira-prod
    kind: spira
    url: https://spira.company.com/api/v7_0
    auth: { env: SPIRA_TOKEN }
    project_id: 42
  - name: jira-xray
    kind: xray
    url: https://jira.company.com
    auth: { env: JIRA_TOKEN }
```

## 失败处理

- 反讲文档未 confirm → 拒绝导出（避免泄漏未裁决的需求）
- 外部 API 失败 → 本地产物仍保留，控制台提示手动上传路径
- 字段映射缺失 → 导出空值并标 `reqloop:incomplete true`，不静默丢弃

## 非目标

- 不做 ALM 系统的双向同步（本地是单向源头，避免冲突）
- 不覆盖用户在 ALM 中手动添加的字段（只更新 reqloop 命名空间字段）
