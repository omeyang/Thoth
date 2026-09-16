#!/usr/bin/env bash
# design-review token 预算监督 + 自动降级
# 不要直接执行；由其他脚本 source

[ -n "${_DR_BUDGET_LOADED:-}" ] && return 0
_DR_BUDGET_LOADED=1

# estimate_round_tokens <round-dir>
# 粗略估算：每 yaml 文件大小（字节）/ 4 + 1000 输入 prompt 估算
estimate_round_tokens() {
    local round_dir="$1"
    local total=0
    local f
    for t in T1 T2 T3 T4; do
        f="$round_dir/teamreport-${t}.yaml"
        if [ -f "$f" ]; then
            local sz
            sz="$(wc -c < "$f")"
            total=$(( total + sz / 4 + 1000 ))
        fi
        # 跨队对抗投票产物（真 LLM 模式才有）
        f="$round_dir/xattack-vote-${t}.yaml"
        if [ -f "$f" ]; then
            local xsz
            xsz="$(wc -c < "$f")"
            total=$(( total + xsz / 4 + 500 ))
        fi
    done
    echo "$total"
}

# check_round_budget <round-dir> <budget>
check_round_budget() {
    local round_dir="$1"
    local budget="$2"
    local used
    used="$(estimate_round_tokens "$round_dir")"
    if [ "$used" -gt "$budget" ]; then
        return 1
    fi
    return 0
}

# check_and_degrade_for_next_round <run-dir>
check_and_degrade_for_next_round() {
    local run_dir="$1"
    local used
    used="$(state_get "$run_dir" tokens_used_total)"
    [ -z "$used" ] && used=0

    local cap="${CFG_BUDGET_TOKENS_PER_RUN_TOTAL:-4000000}"
    local order="${CFG_BUDGET_DEGRADE_ROLE_ORDER:-R5,R4,R3}"

    if [ "$used" -le "$cap" ]; then
        state_get "$run_dir" enabled_roles
        return 0
    fi

    local current new
    current="$(state_get "$run_dir" enabled_roles)"
    if new="$(degrade_roles "$current" "$order" 2>/dev/null)"; then
        state_set "$run_dir" enabled_roles "$new"
        warn "budget: tokens_used=$used > cap=$cap → 降级 $current → $new"
        echo "$new"
        return 0
    else
        warn "budget: tokens_used=$used > cap=$cap，但已无可降级角色"
        echo "$current"
        return 1
    fi
}
