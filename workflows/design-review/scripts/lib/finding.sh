#!/usr/bin/env bash
# design-review finding self-check 校验
# 不要直接执行；由其他脚本 source

[ -n "${_DR_FINDING_LOADED:-}" ] && return 0
_DR_FINDING_LOADED=1

# 必填字段（与 WORKFLOW.md §4.7 同步）
_DR_FINDING_REQUIRED_FIELDS=(
    id severity source_agent source_role confidence
    q1_real_scenario q2_avoidable_by_process q3_old_arch_handling q4_not_hallucinated
    control_in_our_hands concrete_scenario
    proposed_action
)

# 含糊词
_DR_VAGUE_WORDS=(TBD TODO 大概 可能 也许 unknown n/a 未知)

count_vague_words() {
    local text="$1"
    local count=0
    local w
    for w in "${_DR_VAGUE_WORDS[@]}"; do
        local occurrences
        occurrences="$(grep -o -F -i -- "$w" <<< "$text" | wc -l)"
        count=$((count + occurrences))
    done
    echo "$count"
}

downgrade_confidence() {
    case "$1" in
        High)        echo "Medium" ;;
        Medium)      echo "Speculative" ;;
        Speculative) echo "REJECT" ;;
        *)           echo "REJECT" ;;
    esac
}

# validate_finding <yaml-file>
# exit 0 → OK <new-confidence>
# exit 1 → REJECT <reasons>
# exit 2 → 输入非法
validate_finding() {
    local f="$1"
    [ -f "$f" ] || { echo "validate_finding: 文件不存在 $f" >&2; return 2; }
    yq eval '.' "$f" >/dev/null 2>&1 || { echo "validate_finding: yaml 非法" >&2; return 2; }

    local reasons=()

    local field val
    for field in "${_DR_FINDING_REQUIRED_FIELDS[@]}"; do
        val="$(yq eval ".finding.${field} // \"__MISSING__\"" "$f")"
        if [ "$val" = "__MISSING__" ] || [ "$val" = "null" ] || [ -z "$val" ]; then
            reasons+=("缺字段 ${field}")
        fi
    done

    local nt_type
    nt_type="$(yq eval '.finding.numbers_tagged | type' "$f" 2>/dev/null)"
    if [ "$nt_type" != "!!seq" ]; then
        reasons+=("numbers_tagged 必须是数组 (got $nt_type)")
    fi

    local ev_type ev_count
    ev_type="$(yq eval '.finding.evidence | type' "$f" 2>/dev/null)"
    if [ "$ev_type" != "!!seq" ]; then
        reasons+=("evidence 必须是数组 (got $ev_type)")
    else
        ev_count="$(yq eval '.finding.evidence | length' "$f")"
        if [ "$ev_count" -lt 1 ]; then
            reasons+=("evidence 至少需 1 项")
        fi
    fi

    if [ "${#reasons[@]}" -gt 0 ]; then
        printf 'REJECT %s\n' "$(IFS='; '; echo "${reasons[*]}")"
        return 1
    fi

    local all_text vague
    all_text="$(yq eval '
        .finding.q1_real_scenario, .finding.q2_avoidable_by_process,
        .finding.q3_old_arch_handling, .finding.q4_not_hallucinated,
        .finding.control_in_our_hands, .finding.concrete_scenario,
        .finding.proposed_action' "$f" | tr '\n' ' ')"
    vague="$(count_vague_words "$all_text")"

    local conf
    conf="$(yq eval '.finding.confidence' "$f")"

    local downgrades="$vague"
    [ "$downgrades" -gt 3 ] && downgrades=3

    local i=0
    while [ "$i" -lt "$downgrades" ]; do
        conf="$(downgrade_confidence "$conf")"
        i=$((i + 1))
    done

    if [ "$conf" = "REJECT" ]; then
        printf 'REJECT confidence 降级到 REJECT (vague_words=%d)\n' "$vague"
        return 1
    fi

    printf 'OK %s (vague_words=%d)\n' "$conf" "$vague"
    return 0
}
