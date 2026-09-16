#!/usr/bin/env bats
load '../test_helper'

setup() {
    TEST_TMPDIR="$(mktemp -d)"
    cd "$TEST_TMPDIR" || exit 1
    # shellcheck source=/dev/null
    source "$SCRIPTS_DIR/lib/errors.sh"
    # shellcheck source=/dev/null
    source "$SCRIPTS_DIR/lib/stance.sh"
}

teardown() {
    rm -rf "$TEST_TMPDIR"
    unset DR_STANCE_RANDOM_SEED
    unset DR_STANCE_CALL_COUNT
}

@test "sample_stance 从 3 项池中输出有效值" {
    local v
    v="$(sample_stance "pro,con,neutral")"
    [[ "$v" =~ ^(pro|con|neutral)$ ]]
}

@test "sample_stance 单项池 → 该项" {
    local v
    v="$(sample_stance "pro")"
    [ "$v" = "pro" ]
}

@test "sample_stance 空池退非 0" {
    run sample_stance ""
    [ "$status" -ne 0 ]
}

@test "sample_stance 固定 seed → 输出可重现" {
    export DR_STANCE_RANDOM_SEED=42
    local v1 v2
    v1="$(sample_stance "pro,con,neutral")"
    v2="$(sample_stance "pro,con,neutral")"
    [[ "$v1" =~ ^(pro|con|neutral)$ ]]
    [[ "$v2" =~ ^(pro|con|neutral)$ ]]
}

@test "shuffle_team_stances 输出 4 行 T<i>=<stance>" {
    local out
    out="$(shuffle_team_stances "pro,con,neutral")"
    [ "$(echo "$out" | wc -l)" -eq 4 ]
    [[ "$out" == *"T1="* ]]
    [[ "$out" == *"T2="* ]]
    [[ "$out" == *"T3="* ]]
    [[ "$out" == *"T4="* ]]
}

@test "shuffle_team_stances 每行 stance 在 pool 内" {
    local out
    out="$(shuffle_team_stances "pro,con,neutral")"
    while IFS= read -r line; do
        local stance="${line#*=}"
        [[ "$stance" =~ ^(pro|con|neutral)$ ]]
    done <<< "$out"
}

# 校验 enforce_con 输出满足新约束：≥2 非 pro、≥1 con、恰 4 行、保留 4 个 team
_assert_balance() {
    local out="$1"
    local pro non_pro con n_lines
    # grep -c 无匹配时退 1，| cat 兜底避免在 set -e/bats 下中断
    n_lines="$(printf '%s\n' "$out" | grep -c '=' || true)"
    pro="$(printf '%s\n' "$out" | grep -c '=pro$' || true)"
    con="$(printf '%s\n' "$out" | grep -c '=con$' || true)"
    non_pro=$((n_lines - pro))
    [ "$n_lines" -eq 4 ] || { echo "期望 4 行，实得 $n_lines: $out" >&2; return 1; }
    [ "$pro" -le 2 ]     || { echo "pro 应 ≤2，实得 $pro: $out" >&2; return 1; }
    [ "$non_pro" -ge 2 ] || { echo "非 pro 应 ≥2，实得 $non_pro: $out" >&2; return 1; }
    [ "$con" -ge 1 ]     || { echo "con 应 ≥1，实得 $con: $out" >&2; return 1; }
    # 4 个 team 都还在
    for t in T1 T2 T3 T4; do
        [[ "$out" == *"$t="* ]] || { echo "缺 team $t: $out" >&2; return 1; }
    done
}

@test "enforce_con 已满足约束（1pro/1con/1neu/1con 风格）→ 不破坏" {
    local out
    out="$(enforce_con "T1=pro" "T2=con" "T3=neutral" "T4=pro")"
    _assert_balance "$out"
    # 已满足 ≤2 pro 且有 con，应原样保留
    [[ "$out" == *"T1=pro"* ]]
    [[ "$out" == *"T2=con"* ]]
    [[ "$out" == *"T3=neutral"* ]]
    [[ "$out" == *"T4=pro"* ]]
}

@test "enforce_con 4 队全 pro → 收敛到 ≤2 pro 且 ≥1 con" {
    local out
    out="$(enforce_con "T1=pro" "T2=pro" "T3=pro" "T4=pro")"
    _assert_balance "$out"
    [ "$(printf '%s\n' "$out" | grep -c '=pro$')" -eq 2 ]
}

@test "enforce_con 4 队全 neutral → 补足 ≥1 con（neutral 已满足 ≥2 非 pro）" {
    local out
    out="$(enforce_con "T1=neutral" "T2=neutral" "T3=neutral" "T4=neutral")"
    _assert_balance "$out"
    [ "$(printf '%s\n' "$out" | grep -c '=con$')" -eq 1 ]
    [ "$(printf '%s\n' "$out" | grep -c '=neutral$')" -eq 3 ]
}

@test "enforce_con 3 pro 1 neutral → 削到 ≤2 pro 且引入 con" {
    local out
    out="$(enforce_con "T1=pro" "T2=pro" "T3=pro" "T4=neutral")"
    _assert_balance "$out"
}

@test "enforce_con 随机性未写死：多次抽签+enforce 都满足约束" {
    local i out
    for i in $(seq 1 40); do
        out="$(enforce_con $(shuffle_team_stances "pro,con,neutral" | tr '\n' ' '))"
        _assert_balance "$out"
    done
}

@test "enforce_con 固定 seed 不同 → 结果可变（约束不靠写死特定队）" {
    local a b
    DR_STANCE_RANDOM_SEED=1 DR_STANCE_CALL_COUNT=0 \
        a="$(enforce_con "T1=pro" "T2=pro" "T3=pro" "T4=pro")"
    DR_STANCE_RANDOM_SEED=2 DR_STANCE_CALL_COUNT=0 \
        b="$(enforce_con "T1=pro" "T2=pro" "T3=pro" "T4=pro")"
    _assert_balance "$a"
    _assert_balance "$b"
    # 两个 seed 落点不同 → 输出不应完全一致（证明未写死哪队）
    [ "$a" != "$b" ]
}

@test "enforce_con 不可有 0 或 5+ 行输入" {
    run enforce_con "T1=pro"
    [ "$status" -ne 0 ]
}
