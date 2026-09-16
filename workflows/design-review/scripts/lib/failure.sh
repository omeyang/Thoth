#!/usr/bin/env bash
# design-review 失败语义判定
# 不要直接执行；由其他脚本 source

[ -n "${_DR_FAILURE_LOADED:-}" ] && return 0
_DR_FAILURE_LOADED=1

# _is_team_absent <yaml-file> → return 0 if absent
_is_team_absent() {
    local f="$1"
    [ -f "$f" ] || return 0
    [ -s "$f" ] || return 0
    yq eval '.' "$f" >/dev/null 2>&1 || return 0
    local team
    team="$(yq eval '.team // "__MISSING__"' "$f" 2>/dev/null)"
    [ "$team" = "__MISSING__" ] && return 0
    [ -z "$team" ] && return 0
    return 1
}

# count_absent_teams <T1.yaml> <T2.yaml> <T3.yaml> <T4.yaml>
count_absent_teams() {
    [ $# -eq 4 ] || { echo "count_absent_teams: 需 4 参数" >&2; return 1; }
    local n=0
    local f
    for f in "$@"; do
        if _is_team_absent "$f"; then
            n=$((n + 1))
        fi
    done
    echo "$n"
}

# should_abort_round <absent-count>
# exit 0 = 继续；exit 2 = 中止
should_abort_round() {
    local n="$1"
    [[ "$n" =~ ^[0-9]+$ ]] || { echo "should_abort_round: 入参必须是非负整数" >&2; return 1; }
    if [ "$n" -ge 2 ]; then
        return 2
    fi
    return 0
}

# next_role_to_drop <enabled-csv> <degrade-order-csv>
next_role_to_drop() {
    local enabled="$1"
    local order="$2"

    local -a enabled_arr order_arr
    IFS=',' read -r -a enabled_arr <<< "$enabled"
    IFS=',' read -r -a order_arr <<< "$order"

    local r
    for r in "${order_arr[@]}"; do
        local e found=0
        for e in "${enabled_arr[@]}"; do
            if [ "$e" = "$r" ]; then
                found=1
                break
            fi
        done
        if [ "$found" -eq 1 ]; then
            echo "$r"
            return 0
        fi
    done

    return 1
}

# degrade_roles <enabled-csv> <degrade-order-csv>
# 输出降级后 enabled-csv（去掉一个），无可降时输出原值 + exit 1
degrade_roles() {
    local enabled="$1"
    local order="$2"
    local drop
    if ! drop="$(next_role_to_drop "$enabled" "$order")"; then
        echo "$enabled"
        return 1
    fi
    local -a arr out
    IFS=',' read -r -a arr <<< "$enabled"
    local x
    for x in "${arr[@]}"; do
        [ "$x" != "$drop" ] && out+=("$x")
    done
    local IFS=,
    echo "${out[*]}"
}
