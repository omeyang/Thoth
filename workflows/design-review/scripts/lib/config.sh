#!/usr/bin/env bash
# design-review yaml 配置加载与默认合并
# 不要直接执行；由其他脚本 source
#
# 用法：load_config <yaml-path>
# 设置 CFG_* 全局变量与 CFG_TEAMS / CFG_REFS_PATHS / CFG_REFS_TIERS 数组
#
# shellcheck disable=SC2034
# 多数变量被 source 后的脚本消费 — SC2034 在此误报

[ -n "${_DR_CONFIG_LOADED:-}" ] && return 0
_DR_CONFIG_LOADED=1

# 内置默认值，与 WORKFLOW.md §8 同步
_config_init_defaults() {
    # 留空 = 不传 --model，继承 ~/.claude/settings.json 的当前模型。
    # 钉死模型名会在 Anthropic 换代后变成指向不存在模型的死配置。
    CFG_LLM_CLAUDE_MODEL=""
    CFG_LLM_CODEX_COMMAND="codex"
    CFG_LLM_CLAUDE_BIN="claude"
    CFG_LLM_CODEX_BIN="codex"
    CFG_LLM_CALL_TIMEOUT=1200
    CFG_LLM_CALL_RETRY=1

    declare -gA CFG_TEAMS
    CFG_TEAMS[T1]="claude"
    CFG_TEAMS[T2]="codex"
    CFG_TEAMS[T3]="claude"
    CFG_TEAMS[T4]="codex"

    CFG_ORCHESTRATOR_TOOL="claude"
    CFG_ORCHESTRATOR_TEMPLATE="templates/orchestrator.md"
    CFG_CONSOLIDATOR_TOOL="claude"
    CFG_CONSOLIDATOR_TEMPLATE="templates/consolidator.md"

    CFG_ROUNDS_MIN=2
    CFG_ROUNDS_MAX=5
    CFG_ROUNDS_STUCK_THRESHOLD=3
    CFG_ROUNDS_DISPUTE_THRESHOLD=3

    CFG_STANCE_VALUES="pro,con,neutral"
    CFG_STANCE_ENFORCE_CON="true"

    # 闭环裁判：异质双裁判 + 位置交换去偏（默认开）
    CFG_JUDGE_DUAL="true"          # false → 退回单裁判纯票数路径
    CFG_JUDGE_TOOL_A="claude"      # judge A 工具（正序）
    CFG_JUDGE_TOOL_B="codex"       # judge B 工具（逆序）；与 A 相同则靠 model/seed 退化区分

    CFG_BUDGET_TOKENS_PER_SUBAGENT=30000
    CFG_BUDGET_TOKENS_PER_TEAM_ROUND=200000
    CFG_BUDGET_TOKENS_PER_ROUND_TOTAL=800000
    CFG_BUDGET_TOKENS_PER_RUN_TOTAL=4000000
    CFG_BUDGET_DEGRADE_ROLE_ORDER="R5,R4,R3"

    CFG_VERIFY_ENABLED="true"
    CFG_VERIFY_CMD="scripts/lint-doc.sh"
    CFG_VERIFY_TIMEOUT=120

    CFG_OUTPUT_SUPPLEMENT_DIR="redesign"
    CFG_OUTPUT_SUPPLEMENT_PATTERN="201-{topic}-supplement.md"
    CFG_OUTPUT_PATCH_REPORT_DIR="redesign/.design-runs"
    CFG_OUTPUT_TEMP_DIR="/tmp/design-review-runs"

    CFG_LOGGING_FILE="docs/design-review-log.md"
    CFG_LOGGING_DAILY_CHECK="false"

    CFG_POLICY_FAIL_ON_SEVERITY="P1"
    CFG_POLICY_STRICT_ON_ERROR="false"

    CFG_REFS_PATHS=()
    CFG_REFS_TIERS=()

    CFG_TARGET_DEFAULT=""
    CFG_TARGET_EXCLUDE=()

    # 审查范围：聚焦哪个区域（如「调度 Pod」），哪些区域未设计/待补不计必修
    CFG_SCOPE_FOCUS=""
    CFG_SCOPE_OUT_OF_SCOPE=()
    CFG_SCOPE_NOTE=""

    # 背景文档：非审查目标但作为权威上下文注入（系统总览 / 父级设计）+ 文档关系说明
    CFG_BG_PATHS=()
    CFG_BG_ROLES=()
    CFG_BG_RELATIONS=""

    # 项目 profile（插件）：名字或路径；空 = 不用 profile，全走内置模板
    CFG_PROFILE=""
    # roles.Rn.template 显式指定的角色模板路径（相对路径先按 profile 目录再按 design-review 目录解析）
    declare -gA CFG_ROLE_TEMPLATES
    CFG_ROLE_TEMPLATES=()
}

# _yq <path> <yaml-file>
# yq v4 取值；缺失返回空
_yq() {
    local path="$1"
    local file="$2"
    yq eval "${path} // \"\"" "$file" 2>/dev/null
}

load_config() {
    local f="$1"
    [ -f "$f" ] || die "配置文件不存在：$f" "$EXIT_CONFIG"

    _config_init_defaults

    local v

    v="$(_yq '.llm.claude_model' "$f")"; [ -n "$v" ] && CFG_LLM_CLAUDE_MODEL="$v"
    v="$(_yq '.llm.codex_command' "$f")"; [ -n "$v" ] && CFG_LLM_CODEX_COMMAND="$v"
    v="$(_yq '.llm.claude_bin' "$f")"; [ -n "$v" ] && CFG_LLM_CLAUDE_BIN="$v"
    v="$(_yq '.llm.codex_bin' "$f")"; [ -n "$v" ] && CFG_LLM_CODEX_BIN="$v"
    v="$(_yq '.llm.call_timeout_seconds' "$f")"; [ -n "$v" ] && CFG_LLM_CALL_TIMEOUT="$v"
    v="$(_yq '.llm.call_retry' "$f")"; [ -n "$v" ] && CFG_LLM_CALL_RETRY="$v"

    for tk in T1 T2 T3 T4; do
        v="$(_yq ".teams.${tk}.tool" "$f")"
        [ -n "$v" ] && CFG_TEAMS["$tk"]="$v"
    done

    v="$(_yq '.orchestrator.tool' "$f")"; [ -n "$v" ] && CFG_ORCHESTRATOR_TOOL="$v"
    v="$(_yq '.orchestrator.template' "$f")"; [ -n "$v" ] && CFG_ORCHESTRATOR_TEMPLATE="$v"
    v="$(_yq '.consolidator.tool' "$f")"; [ -n "$v" ] && CFG_CONSOLIDATOR_TOOL="$v"
    v="$(_yq '.consolidator.template' "$f")"; [ -n "$v" ] && CFG_CONSOLIDATOR_TEMPLATE="$v"

    v="$(_yq '.rounds.min' "$f")"; [ -n "$v" ] && CFG_ROUNDS_MIN="$v"
    v="$(_yq '.rounds.max' "$f")"; [ -n "$v" ] && CFG_ROUNDS_MAX="$v"
    v="$(_yq '.rounds.stuck_threshold_rounds' "$f")"; [ -n "$v" ] && CFG_ROUNDS_STUCK_THRESHOLD="$v"
    v="$(_yq '.rounds.dispute_threshold_rounds' "$f")"; [ -n "$v" ] && CFG_ROUNDS_DISPUTE_THRESHOLD="$v"

    v="$(_yq '.judge.dual' "$f")"; [ -n "$v" ] && CFG_JUDGE_DUAL="$v"
    v="$(_yq '.judge.tool_a' "$f")"; [ -n "$v" ] && CFG_JUDGE_TOOL_A="$v"
    v="$(_yq '.judge.tool_b' "$f")"; [ -n "$v" ] && CFG_JUDGE_TOOL_B="$v"

    v="$(_yq '.budget.tokens_per_subagent' "$f")"; [ -n "$v" ] && CFG_BUDGET_TOKENS_PER_SUBAGENT="$v"
    v="$(_yq '.budget.tokens_per_team_round' "$f")"; [ -n "$v" ] && CFG_BUDGET_TOKENS_PER_TEAM_ROUND="$v"
    v="$(_yq '.budget.tokens_per_round_total' "$f")"; [ -n "$v" ] && CFG_BUDGET_TOKENS_PER_ROUND_TOTAL="$v"
    v="$(_yq '.budget.tokens_per_run_total' "$f")"; [ -n "$v" ] && CFG_BUDGET_TOKENS_PER_RUN_TOTAL="$v"

    v="$(_yq '.verify.enabled' "$f")"; [ -n "$v" ] && CFG_VERIFY_ENABLED="$v"
    v="$(_yq '.verify.cmd' "$f")"; [ -n "$v" ] && CFG_VERIFY_CMD="$v"
    v="$(_yq '.verify.timeout_seconds' "$f")"; [ -n "$v" ] && CFG_VERIFY_TIMEOUT="$v"

    v="$(_yq '.output.supplement_dir' "$f")"; [ -n "$v" ] && CFG_OUTPUT_SUPPLEMENT_DIR="$v"
    v="$(_yq '.output.supplement_pattern' "$f")"; [ -n "$v" ] && CFG_OUTPUT_SUPPLEMENT_PATTERN="$v"
    v="$(_yq '.output.patch_and_report_dir' "$f")"; [ -n "$v" ] && CFG_OUTPUT_PATCH_REPORT_DIR="$v"
    v="$(_yq '.output.temp_dir' "$f")"; [ -n "$v" ] && CFG_OUTPUT_TEMP_DIR="$v"

    v="$(_yq '.logging.file' "$f")"; [ -n "$v" ] && CFG_LOGGING_FILE="$v"
    v="$(_yq '.logging.daily_check_enabled' "$f")"; [ -n "$v" ] && CFG_LOGGING_DAILY_CHECK="$v"

    v="$(_yq '.policy.fail_on_severity' "$f")"; [ -n "$v" ] && CFG_POLICY_FAIL_ON_SEVERITY="$v"
    v="$(_yq '.policy.strict_on_error' "$f")"; [ -n "$v" ] && CFG_POLICY_STRICT_ON_ERROR="$v"

    v="$(_yq '.target.default' "$f")"; [ -n "$v" ] && CFG_TARGET_DEFAULT="$v"

    local exclude_count
    exclude_count="$(yq eval '.target.exclude | length' "$f" 2>/dev/null)"
    if [ -n "$exclude_count" ] && [ "$exclude_count" -gt 0 ]; then
        local j=0
        while [ "$j" -lt "$exclude_count" ]; do
            CFG_TARGET_EXCLUDE+=("$(yq eval ".target.exclude[$j]" "$f")")
            j=$((j + 1))
        done
    fi

    v="$(_yq '.scope.focus' "$f")"; [ -n "$v" ] && CFG_SCOPE_FOCUS="$v"
    v="$(_yq '.scope.note' "$f")"; [ -n "$v" ] && CFG_SCOPE_NOTE="$v"
    local oos_count
    oos_count="$(yq eval '.scope.out_of_scope | length' "$f" 2>/dev/null)"
    if [ -n "$oos_count" ] && [ "$oos_count" != "null" ] && [ "$oos_count" -gt 0 ]; then
        local k=0
        while [ "$k" -lt "$oos_count" ]; do
            CFG_SCOPE_OUT_OF_SCOPE+=("$(yq eval ".scope.out_of_scope[$k]" "$f")")
            k=$((k + 1))
        done
    fi

    v="$(_yq '.profile' "$f")"; [ -n "$v" ] && CFG_PROFILE="$v"

    local rk
    for rk in R1 R2 R3 R4 R5; do
        v="$(_yq ".roles.${rk}.template" "$f")"
        [ -n "$v" ] && CFG_ROLE_TEMPLATES["$rk"]="$v"
    done

    v="$(_yq '.background.relations' "$f")"; [ -n "$v" ] && CFG_BG_RELATIONS="$v"
    local bg_count
    bg_count="$(yq eval '.background.docs | length' "$f" 2>/dev/null)"
    if [ -n "$bg_count" ] && [ "$bg_count" != "null" ] && [ "$bg_count" -gt 0 ]; then
        local m=0
        while [ "$m" -lt "$bg_count" ]; do
            CFG_BG_PATHS+=("$(yq eval ".background.docs[$m].path" "$f")")
            CFG_BG_ROLES+=("$(yq eval ".background.docs[$m].role // \"\"" "$f")")
            m=$((m + 1))
        done
    fi

    local refs_count
    refs_count="$(yq eval '.refs.manifest | length' "$f" 2>/dev/null)"
    if [ -z "$refs_count" ] || [ "$refs_count" -lt 1 ]; then
        die "refs.manifest 至少需 1 项" "$EXIT_CONFIG"
    fi
    local i=0
    while [ "$i" -lt "$refs_count" ]; do
        CFG_REFS_PATHS+=("$(yq eval ".refs.manifest[$i].path" "$f")")
        CFG_REFS_TIERS+=("$(yq eval ".refs.manifest[$i].tier" "$f")")
        i=$((i + 1))
    done

    return 0
}
