#!/usr/bin/env bash
# design-review 立场抽样 + 对抗强度扰动
# 约束：4 队里 ≥2 队为非 pro（con/neutral），其中 ≥1 队必为 con；即最多 2 队 pro。
# 不要直接执行；由其他脚本 source

[ -n "${_DR_STANCE_LOADED:-}" ] && return 0
_DR_STANCE_LOADED=1

# _random_int <max> — 输出 [0, max) 整数
_random_int() {
    local max="$1"
    [ "$max" -le 0 ] && { echo 0; return; }

    local n
    if [ -n "${DR_STANCE_RANDOM_SEED:-}" ]; then
        DR_STANCE_CALL_COUNT="${DR_STANCE_CALL_COUNT:-0}"
        DR_STANCE_CALL_COUNT=$((DR_STANCE_CALL_COUNT + 1))
        n=$(( (DR_STANCE_RANDOM_SEED * 31 + DR_STANCE_CALL_COUNT * 17) % max ))
    else
        n=$(( $(od -An -N2 -tu2 /dev/urandom | tr -d ' ') % max ))
    fi
    echo "$n"
}

sample_stance() {
    local pool="$1"
    [ -z "$pool" ] && { echo "sample_stance: 池不能为空" >&2; return 1; }

    local -a items
    IFS=',' read -r -a items <<< "$pool"
    local n="${#items[@]}"
    local idx
    idx="$(_random_int "$n")"
    echo "${items[$idx]}"
}

shuffle_team_stances() {
    local pool="$1"
    for t in T1 T2 T3 T4; do
        printf '%s=%s\n' "$t" "$(sample_stance "$pool")"
    done
}

# enforce_con <T1=s> <T2=s> <T3=s> <T4=s>
# 保障对抗强度：4 队里 ≥2 队非 pro（con/neutral），其中 ≥1 队必为 con。
# 等价约束：最多 2 队 pro，且至少 1 队 con。
# 做法（保持随机，不写死具体哪队）：
#   1. 若没有 con，随机挑 1 队改成 con；
#   2. 若 pro 数 > 2，随机挑 pro 队逐个改成 con，直到 pro ≤ 2。
enforce_con() {
    [ $# -eq 4 ] || { echo "enforce_con: 需 4 个 T<i>=<stance> 参数" >&2; return 1; }

    # 载入到可改数组
    local -a out cand
    out=("$@")
    local e i pick target con pro

    # 1. 保障 ≥1 con：没有 con 就随机挑一队改 con（优先削一个 pro）
    con=0
    for e in "${out[@]}"; do [ "${e#*=}" = "con" ] && con=$((con + 1)); done
    if [ "$con" -eq 0 ]; then
        # 候选优先 pro（改 con 同时削 pro），无 pro 才用 neutral
        cand=()
        for i in "${!out[@]}"; do [ "${out[$i]#*=}" = "pro" ] && cand+=("$i"); done
        [ "${#cand[@]}" -eq 0 ] && for i in "${!out[@]}"; do [ "${out[$i]#*=}" = "neutral" ] && cand+=("$i"); done
        if [ "${#cand[@]}" -gt 0 ]; then
            pick="$(_random_int "${#cand[@]}")"
            target="${cand[$pick]}"
            out[target]="${out[target]%%=*}=con"
        fi
    fi

    # 2. 保障最多 2 队 pro（即 ≥2 队非 pro）：超额时随机挑 pro 队改成 con
    while :; do
        pro=0
        for e in "${out[@]}"; do [ "${e#*=}" = "pro" ] && pro=$((pro + 1)); done
        [ "$pro" -le 2 ] && break
        cand=()
        for i in "${!out[@]}"; do [ "${out[$i]#*=}" = "pro" ] && cand+=("$i"); done
        [ "${#cand[@]}" -eq 0 ] && break
        pick="$(_random_int "${#cand[@]}")"
        target="${cand[$pick]}"
        out[target]="${out[target]%%=*}=con"
    done

    printf '%s\n' "${out[@]}"
}
