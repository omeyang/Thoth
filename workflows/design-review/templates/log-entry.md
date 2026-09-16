# Log Entry · 日志条目模板

## 用途

本模板被 `scripts/lib/finalize.sh::finalize_run` 用 `envsubst` 替换变量后追加到日志文件（默认 `docs/design-review-log.md`）。

**纯模板，不需 LLM 生成**。变量见下表。

## 变量

| 变量 | 含义 |
|---|---|
| `${DR_LOG_DATE}` | RFC3339 日期时间（如 `2026-05-27 14:32:11`）|
| `${DR_RUN_ID}` | run id（如 `20260527-143211-x4f2`）|
| `${DR_TARGET}` | 被审文档路径 |
| `${DR_DECISION}` | CONVERGED / MAX_REACHED / ... |
| `${DR_TOTAL_ROUNDS}` | 总轮数 |
| `${DR_MIN}` / `${DR_MAX}` | min / max rounds 配置 |
| `${DR_STANCES}` | 4 队最终立场（如 `T1=pro T2=con T3=neutral T4=con`）|
| `${DR_ENABLED_ROLES}` | 最终启用的角色（如 `R1,R2,R3,R4,R5` 或 `R1,R2,R3,R4`）|
| `${DR_MUST_COUNT}` / `${DR_MAYBE_COUNT}` / `${DR_DISCARD_COUNT}` | 必修/存疑/舍弃 数量 |
| `${DR_P0}` / `${DR_P1}` / `${DR_P2}` / `${DR_P3}` | 必修严重度分布 |
| `${DR_SUPPLEMENT_PATH}` | supplement.md 路径 |
| `${DR_PATCH_PATH}` | suggested-patch.diff 路径 |
| `${DR_REPORT_PATH}` | review-report.md 路径 |
| `${DR_TOKENS_USED}` | token 用量 |
| `${DR_EXIT_CODE}` | 退出码 |

## 模板

下面是 envsubst 替换前的模板内容（在 `<!-- ENTRY_START -->` 与 `<!-- ENTRY_END -->` 标记之间）。`finalize.sh` 用 awk 抽取此段后 envsubst 替换 `${DR_*}` 为运行时值，追加到 `${CFG_LOGGING_FILE}`：

<!-- ENTRY_START -->
## ${DR_LOG_DATE} TARGET=${DR_TARGET} RUN=${DR_RUN_ID}

- 决策：${DR_DECISION}
- 轮次：跑了 ${DR_TOTAL_ROUNDS} 轮 / min=${DR_MIN} / max=${DR_MAX}
- 4 队最终立场：${DR_STANCES}
- 启用角色：${DR_ENABLED_ROLES}
- 合议：必修=${DR_MUST_COUNT} (P0=${DR_P0} P1=${DR_P1} P2=${DR_P2} P3=${DR_P3}) / 存疑=${DR_MAYBE_COUNT} / 舍弃=${DR_DISCARD_COUNT}
- 产出文件：
  - ${DR_SUPPLEMENT_PATH}
  - ${DR_PATCH_PATH}
  - ${DR_REPORT_PATH}
- token 用量：${DR_TOKENS_USED}
- 退出码：${DR_EXIT_CODE}
<!-- ENTRY_END -->

## 边界

- 模板不嵌入完整 finding 内容（避免日志爆炸）— 只写统计 + 产物路径
- 用户要详情看 ${DR_REPORT_PATH}
