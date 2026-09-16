#!/usr/bin/env bash
# design-review 顶层流程串接
# 不要直接执行；由其他脚本 source

[ -n "${_DR_ORCHESTRATOR_LOADED:-}" ] && return 0
_DR_ORCHESTRATOR_LOADED=1

# run_one_round <run-dir> <round-num> <target> <min> <max>
run_one_round() {
    local run_dir="$1"
    local round_num="$2"
    local target="$3"
    local min="$4"
    local max="$5"

    local round_dir="$run_dir/R${round_num}"
    mkdir -p "$round_dir"

    # 抽 stance
    local stances enforced
    stances="$(shuffle_team_stances "${CFG_STANCE_VALUES:-pro,con,neutral}" | tr '\n' ' ')"
    # shellcheck disable=SC2086
    enforced="$(enforce_con $stances)"

    {
        echo "$enforced" | while IFS='=' read -r t s; do
            [ -n "$t" ] && printf '%s: %s\n' "$t" "$s"
        done
    } > "$round_dir/stances.yaml"

    # 阶段 A
    if ! run_phase_a "$round_dir" "$round_dir/stances.yaml" "$target" "$run_dir" "$round_num"; then
        return 2
    fi

    # 阶段 B（机器归并 + 真 LLM 跨队对抗）
    run_phase_b "$round_dir" "$round_num" "$target" "$run_dir"

    # 阶段 C（含异质双裁判 + 位置交换去偏；DR_DUAL_JUDGE=0 退回单裁判纯票数路径）
    run_phase_c "$round_dir" "$round_num" "$target" "$run_dir"

    # 阶段 D
    local prev_consensus
    if [ "$round_num" -gt 1 ]; then
        prev_consensus="$run_dir/R$((round_num - 1))/consensus.yaml"
    else
        prev_consensus="$round_dir/_empty-prev.yaml"
        echo "round: 0" > "$prev_consensus"
        echo "findings: []" >> "$prev_consensus"
    fi

    local decision
    decision="$(run_phase_d "$round_dir/consensus.yaml" "$prev_consensus" "$round_num" "$min" "$max" "$run_dir")"

    # 更新 token 用量
    local rt tot
    rt="$(estimate_round_tokens "$round_dir")"
    tot="$(state_get "$run_dir" tokens_used_total)"
    [ -z "$tot" ] && tot=0
    state_set "$run_dir" tokens_used_total "$((tot + rt))"

    state_set "$run_dir" last_completed_round "$round_num"

    echo "$decision"
    return 0
}

# run_design_review <run-dir> <target> <min> <max>
run_design_review() {
    local run_dir="$1"
    local target="$2"
    local min="$3"
    local max="$4"

    local round=0
    local decision="CONTINUE"

    while [[ "$decision" == CONTINUE* ]]; do
        round=$((round + 1))
        state_set "$run_dir" current_round "$round"

        if ! decision="$(run_one_round "$run_dir" "$round" "$target" "$min" "$max")"; then
            state_set "$run_dir" status aborted
            warn "run_design_review: 第 $round 轮异常中止 (≥2 队缺席等)"
            return 2
        fi

        info "Round $round: $decision"

        check_and_degrade_for_next_round "$run_dir" >/dev/null || true

        if [ "$round" -ge "$max" ] && [[ "$decision" == CONTINUE* ]]; then
            decision="MAX_REACHED (force-stopped at round=$round)"
            break
        fi
    done

    case "$decision" in
        CONVERGED*)            state_set "$run_dir" status converged ;;
        MAX_REACHED*)          state_set "$run_dir" status max_reached ;;
        STABLE_BUT_VOTING*)    state_set "$run_dir" status stable_voting ;;
        UNRESOLVED_DISPUTE*)   state_set "$run_dir" status unresolved_dispute ;;
        *)                     state_set "$run_dir" status unknown ;;
    esac

    local last_consensus="$run_dir/R${round}/consensus.yaml"
    local base
    base="$(dirname "$(dirname "$target")")"
    [ "$base" = "." ] && base="$(pwd)"

    finalize_run "$run_dir" "$last_consensus" "$target" "$decision" "$base"

    return 0
}
