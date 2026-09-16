#!/usr/bin/env bats
load '../test_helper'

setup() {
    TEST_TMPDIR="$(mktemp -d)"
    cd "$TEST_TMPDIR" || exit 1
    # shellcheck source=/dev/null
    source "$SCRIPTS_DIR/lib/errors.sh"
    # shellcheck source=/dev/null
    source "$SCRIPTS_DIR/lib/failure.sh"

    for t in T1 T2 T3 T4; do
        cat > "$TEST_TMPDIR/teamreport-${t}.yaml" <<EOF
team: $t
findings: []
EOF
    done
}

teardown() {
    rm -rf "$TEST_TMPDIR"
}

@test "count_absent_teams 全到 → 0" {
    local n
    n="$(count_absent_teams \
        "$TEST_TMPDIR/teamreport-T1.yaml" \
        "$TEST_TMPDIR/teamreport-T2.yaml" \
        "$TEST_TMPDIR/teamreport-T3.yaml" \
        "$TEST_TMPDIR/teamreport-T4.yaml")"
    [ "$n" -eq 0 ]
}

@test "count_absent_teams 1 队文件不存在 → 1" {
    rm "$TEST_TMPDIR/teamreport-T2.yaml"
    local n
    n="$(count_absent_teams \
        "$TEST_TMPDIR/teamreport-T1.yaml" \
        "$TEST_TMPDIR/teamreport-T2.yaml" \
        "$TEST_TMPDIR/teamreport-T3.yaml" \
        "$TEST_TMPDIR/teamreport-T4.yaml")"
    [ "$n" -eq 1 ]
}

@test "count_absent_teams 1 队 0 字节 → 1" {
    : > "$TEST_TMPDIR/teamreport-T3.yaml"
    local n
    n="$(count_absent_teams \
        "$TEST_TMPDIR/teamreport-T1.yaml" \
        "$TEST_TMPDIR/teamreport-T2.yaml" \
        "$TEST_TMPDIR/teamreport-T3.yaml" \
        "$TEST_TMPDIR/teamreport-T4.yaml")"
    [ "$n" -eq 1 ]
}

@test "count_absent_teams 1 队 yaml 非法 → 1" {
    echo "not: valid: yaml: :::" > "$TEST_TMPDIR/teamreport-T4.yaml"
    local n
    n="$(count_absent_teams \
        "$TEST_TMPDIR/teamreport-T1.yaml" \
        "$TEST_TMPDIR/teamreport-T2.yaml" \
        "$TEST_TMPDIR/teamreport-T3.yaml" \
        "$TEST_TMPDIR/teamreport-T4.yaml")"
    [ "$n" -eq 1 ]
}

@test "count_absent_teams 1 队缺 team 字段 → 1" {
    echo "findings: []" > "$TEST_TMPDIR/teamreport-T1.yaml"
    local n
    n="$(count_absent_teams \
        "$TEST_TMPDIR/teamreport-T1.yaml" \
        "$TEST_TMPDIR/teamreport-T2.yaml" \
        "$TEST_TMPDIR/teamreport-T3.yaml" \
        "$TEST_TMPDIR/teamreport-T4.yaml")"
    [ "$n" -eq 1 ]
}

@test "count_absent_teams 2 队缺 → 2" {
    rm "$TEST_TMPDIR/teamreport-T1.yaml" "$TEST_TMPDIR/teamreport-T2.yaml"
    local n
    n="$(count_absent_teams \
        "$TEST_TMPDIR/teamreport-T1.yaml" \
        "$TEST_TMPDIR/teamreport-T2.yaml" \
        "$TEST_TMPDIR/teamreport-T3.yaml" \
        "$TEST_TMPDIR/teamreport-T4.yaml")"
    [ "$n" -eq 2 ]
}

@test "should_abort_round 缺席 0 → exit 0" {
    run should_abort_round 0
    [ "$status" -eq 0 ]
}

@test "should_abort_round 缺席 1 → exit 0（其他 3 队继续）" {
    run should_abort_round 1
    [ "$status" -eq 0 ]
}

@test "should_abort_round 缺席 2 → exit 2（本轮作废）" {
    run should_abort_round 2
    [ "$status" -eq 2 ]
}

@test "should_abort_round 缺席 3 → exit 2" {
    run should_abort_round 3
    [ "$status" -eq 2 ]
}

@test "next_role_to_drop 全 R 启用 → R5（按 degrade-order 头部）" {
    local r
    r="$(next_role_to_drop "R1,R2,R3,R4,R5" "R5,R4,R3")"
    [ "$r" = "R5" ]
}

@test "next_role_to_drop R5 已跳 → R4" {
    local r
    r="$(next_role_to_drop "R1,R2,R3,R4" "R5,R4,R3")"
    [ "$r" = "R4" ]
}

@test "next_role_to_drop R4 R5 已跳 → R3" {
    local r
    r="$(next_role_to_drop "R1,R2,R3" "R5,R4,R3")"
    [ "$r" = "R3" ]
}

@test "next_role_to_drop 全跳完 → exit 1" {
    run next_role_to_drop "R1,R2" "R5,R4,R3"
    [ "$status" -eq 1 ]
}

@test "degrade_roles 从 5 角色降到 4" {
    local r
    r="$(degrade_roles "R1,R2,R3,R4,R5" "R5,R4,R3")"
    [ "$r" = "R1,R2,R3,R4" ]
}

@test "degrade_roles 从 4 角色降到 3" {
    local r
    r="$(degrade_roles "R1,R2,R3,R4" "R5,R4,R3")"
    [ "$r" = "R1,R2,R3" ]
}

@test "degrade_roles 无可降 → 输出原值 + exit 1" {
    run degrade_roles "R1,R2" "R5,R4,R3"
    [ "$status" -eq 1 ]
}
