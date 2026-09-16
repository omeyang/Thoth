#!/usr/bin/env bash
# design-review Δ 收敛判定
# 不要直接执行；由其他脚本 source

[ -n "${_DR_CONVERGE_LOADED:-}" ] && return 0
_DR_CONVERGE_LOADED=1

# compute_deltas <prev.yaml> <curr.yaml>
# 输出 4 行：findings_new=N / findings_refuted=N / classification_changed=N / vote_changed=N
compute_deltas() {
    local prev="$1"
    local curr="$2"

    [ -f "$prev" ] || { echo "compute_deltas: prev 不存在: $prev" >&2; return 1; }
    [ -f "$curr" ] || { echo "compute_deltas: curr 不存在: $curr" >&2; return 1; }

    local findings_new=0 findings_refuted=0 class_changed=0 vote_changed=0

    local curr_ids prev_ids
    curr_ids="$(yq eval '.findings[].cross_id' "$curr")"
    prev_ids="$(yq eval '.findings[].cross_id' "$prev")"

    local cid
    # findings_new：在 curr 而不在 prev 的
    while IFS= read -r cid; do
        [ -z "$cid" ] && continue
        if ! grep -qFx -- "$cid" <<< "$prev_ids"; then
            findings_new=$((findings_new + 1))
        fi
    done <<< "$curr_ids"

    # 逐个对比共有的 cross_id
    while IFS= read -r cid; do
        [ -z "$cid" ] && continue
        if grep -qFx -- "$cid" <<< "$curr_ids"; then
            local prev_class curr_class
            prev_class="$(yq eval ".findings[] | select(.cross_id == \"$cid\") | .classification" "$prev")"
            curr_class="$(yq eval ".findings[] | select(.cross_id == \"$cid\") | .classification" "$curr")"

            if [ "$prev_class" != "$curr_class" ]; then
                class_changed=$((class_changed + 1))
                if [ "$curr_class" = "舍弃" ] && \
                   { [ "$prev_class" = "必修" ] || [ "$prev_class" = "存疑" ]; }; then
                    findings_refuted=$((findings_refuted + 1))
                fi
            fi

            for t in T1 T2 T3 T4; do
                local pv cv
                pv="$(yq eval ".findings[] | select(.cross_id == \"$cid\") | .votes.${t}" "$prev")"
                cv="$(yq eval ".findings[] | select(.cross_id == \"$cid\") | .votes.${t}" "$curr")"
                [ "$pv" != "$cv" ] && vote_changed=$((vote_changed + 1))
            done
        fi
    done <<< "$prev_ids"

    printf 'findings_new=%d\nfindings_refuted=%d\nclassification_changed=%d\nvote_changed=%d\n' \
        "$findings_new" "$findings_refuted" "$class_changed" "$vote_changed"
}

# decide_convergence <round> <min> <max> <stuck-count> <dispute-count> <delta-lines...>
decide_convergence() {
    local round="$1"
    local min="$2"
    local max="$3"
    local stuck="$4"
    local dispute="$5"
    shift 5

    [[ "$round $min $max $stuck $dispute" =~ ^[0-9]+\ [0-9]+\ [0-9]+\ [0-9]+\ [0-9]+$ ]] || {
        echo "decide_convergence: 前 5 参必须是非负整数" >&2; return 1; }
    [ "$min" -gt "$max" ] && { echo "decide_convergence: min > max" >&2; return 1; }

    local findings_new=0 findings_refuted=0 class_changed=0 vote_changed=0
    local kv
    for kv in "$@"; do
        case "$kv" in
            findings_new=*)            findings_new="${kv#*=}" ;;
            findings_refuted=*)        findings_refuted="${kv#*=}" ;;
            classification_changed=*)  class_changed="${kv#*=}" ;;
            vote_changed=*)            vote_changed="${kv#*=}" ;;
        esac
    done

    local stuck_threshold="${DR_STUCK_THRESHOLD:-3}"
    local dispute_threshold="${DR_DISPUTE_THRESHOLD:-3}"

    if [ "$round" -lt "$min" ]; then
        echo "CONTINUE (round=$round < min=$min)"
        return 0
    fi
    if [ "$dispute" -ge "$dispute_threshold" ] && [ "$class_changed" -gt 0 ]; then
        echo "UNRESOLVED_DISPUTE (dispute_count=$dispute >= $dispute_threshold + class_changed>0)"
        return 0
    fi
    if [ "$stuck" -ge "$stuck_threshold" ] && [ "$vote_changed" -gt 0 ] && [ "$class_changed" -eq 0 ]; then
        echo "STABLE_BUT_VOTING (stuck_count=$stuck >= $stuck_threshold + vote_changed>0 + class_changed=0)"
        return 0
    fi
    if [ "$round" -ge "$max" ]; then
        echo "MAX_REACHED (round=$round >= max=$max)"
        return 0
    fi
    local total_delta=$((findings_new + findings_refuted + class_changed + vote_changed))
    if [ "$total_delta" -eq 0 ]; then
        echo "CONVERGED (4 Δ 全 0)"
        return 0
    fi
    echo "CONTINUE (Δ_new=$findings_new refuted=$findings_refuted class=$class_changed vote=$vote_changed)"
}

# update_stuck_dispute_counters <prev-stuck> <prev-dispute> <delta-lines...>
# 输出 "<new-stuck> <new-dispute>"
update_stuck_dispute_counters() {
    local prev_stuck="$1"
    local prev_dispute="$2"
    shift 2

    local class_changed=0 vote_changed=0
    local kv
    for kv in "$@"; do
        case "$kv" in
            classification_changed=*) class_changed="${kv#*=}" ;;
            vote_changed=*)           vote_changed="${kv#*=}" ;;
        esac
    done

    local new_stuck="$prev_stuck"
    local new_dispute="$prev_dispute"

    if [ "$class_changed" -gt 0 ]; then
        new_dispute=$((prev_dispute + 1))
        new_stuck=0
    elif [ "$vote_changed" -gt 0 ]; then
        new_stuck=$((prev_stuck + 1))
    else
        new_stuck=0
        new_dispute=0
    fi

    printf '%d %d\n' "$new_stuck" "$new_dispute"
}
