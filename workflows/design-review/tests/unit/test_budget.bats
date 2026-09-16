#!/usr/bin/env bats
load '../test_helper'

setup() {
    TEST_TMPDIR="$(mktemp -d)"
    cd "$TEST_TMPDIR" || exit 1
    # shellcheck source=/dev/null
    source "$SCRIPTS_DIR/lib/errors.sh"
    # shellcheck source=/dev/null
    source "$SCRIPTS_DIR/lib/log.sh"
    # shellcheck source=/dev/null
    source "$SCRIPTS_DIR/lib/state.sh"
    # shellcheck source=/dev/null
    source "$SCRIPTS_DIR/lib/failure.sh"
    # shellcheck source=/dev/null
    source "$SCRIPTS_DIR/lib/budget.sh"

    RUN_DIR="$TEST_TMPDIR/run"
    mkdir -p "$RUN_DIR/R1"
    state_init "$RUN_DIR" "r" "t" "c"

    for t in T1 T2 T3 T4; do
        cat > "$RUN_DIR/R1/teamreport-${t}.yaml" <<EOF
team: $t
findings: []
EOF
    done
}

teardown() {
    rm -rf "$TEST_TMPDIR"
}

@test "estimate_round_tokens 输出非零正整数" {
    local n
    n="$(estimate_round_tokens "$RUN_DIR/R1")"
    [[ "$n" =~ ^[0-9]+$ ]]
    [ "$n" -gt 0 ]
}

@test "estimate_round_tokens 大文件估算更大" {
    head -c 10000 /dev/urandom | base64 > "$RUN_DIR/R1/teamreport-T1.yaml"
    local n1
    n1="$(estimate_round_tokens "$RUN_DIR/R1")"

    cat > "$RUN_DIR/R1/teamreport-T1.yaml" <<'EOF'
team: T1
findings: []
EOF
    local n2
    n2="$(estimate_round_tokens "$RUN_DIR/R1")"

    [ "$n1" -gt "$n2" ]
}

@test "check_round_budget 本轮 5000 < 10000 → exit 0" {
    run check_round_budget "$RUN_DIR/R1" 10000
    [ "$status" -eq 0 ]
}

@test "check_round_budget 本轮 5000 > 100 → exit 1" {
    run check_round_budget "$RUN_DIR/R1" 100
    [ "$status" -eq 1 ]
}

@test "check_and_degrade 未超 → 不动 enabled_roles" {
    export CFG_BUDGET_TOKENS_PER_RUN_TOTAL=1000000
    state_set "$RUN_DIR" tokens_used_total 100
    export CFG_BUDGET_DEGRADE_ROLE_ORDER="R5,R4,R3"
    run check_and_degrade_for_next_round "$RUN_DIR"
    [ "$status" -eq 0 ]
    [ "$(state_get "$RUN_DIR" enabled_roles)" = "R1,R2,R3,R4,R5" ]
}

@test "check_and_degrade 超预算 → 降一档（去 R5）" {
    export CFG_BUDGET_TOKENS_PER_RUN_TOTAL=1000
    state_set "$RUN_DIR" tokens_used_total 5000
    export CFG_BUDGET_DEGRADE_ROLE_ORDER="R5,R4,R3"
    run check_and_degrade_for_next_round "$RUN_DIR"
    [ "$status" -eq 0 ]
    [ "$(state_get "$RUN_DIR" enabled_roles)" = "R1,R2,R3,R4" ]
}

@test "check_and_degrade 连续 3 次降到 R3" {
    export CFG_BUDGET_TOKENS_PER_RUN_TOTAL=1000
    export CFG_BUDGET_DEGRADE_ROLE_ORDER="R5,R4,R3"

    state_set "$RUN_DIR" tokens_used_total 5000
    check_and_degrade_for_next_round "$RUN_DIR"
    state_set "$RUN_DIR" tokens_used_total 10000
    check_and_degrade_for_next_round "$RUN_DIR"
    state_set "$RUN_DIR" tokens_used_total 15000
    check_and_degrade_for_next_round "$RUN_DIR"

    [ "$(state_get "$RUN_DIR" enabled_roles)" = "R1,R2" ]
}

@test "check_and_degrade 已无可降 → exit 1" {
    export CFG_BUDGET_TOKENS_PER_RUN_TOTAL=1000
    export CFG_BUDGET_DEGRADE_ROLE_ORDER="R5,R4,R3"
    state_set "$RUN_DIR" enabled_roles "R1,R2"
    state_set "$RUN_DIR" tokens_used_total 5000

    run check_and_degrade_for_next_round "$RUN_DIR"
    [ "$status" -eq 1 ]
    [ "$(state_get "$RUN_DIR" enabled_roles)" = "R1,R2" ]
}
