#!/usr/bin/env bats
load '../test_helper'

setup() {
    TEST_TMPDIR="$(mktemp -d)"
    cd "$TEST_TMPDIR" || exit 1
    # shellcheck source=/dev/null
    source "$SCRIPTS_DIR/lib/errors.sh"
    # shellcheck source=/dev/null
    source "$SCRIPTS_DIR/lib/state.sh"
}

teardown() {
    rm -rf "$TEST_TMPDIR"
}

@test "state_init 创建 state.yaml 含基础字段" {
    state_init "$TEST_TMPDIR" "test-run-001" "redesign/foo.md" ".design-review.yaml"
    [ -f "$TEST_TMPDIR/state.yaml" ]
    [ "$(state_get "$TEST_TMPDIR" run_id)" = "test-run-001" ]
    [ "$(state_get "$TEST_TMPDIR" target)" = "redesign/foo.md" ]
    [ "$(state_get "$TEST_TMPDIR" current_round)" = "0" ]
    [ "$(state_get "$TEST_TMPDIR" stuck_count)" = "0" ]
    [ "$(state_get "$TEST_TMPDIR" dispute_count)" = "0" ]
    [ "$(state_get "$TEST_TMPDIR" tokens_used_total)" = "0" ]
    [ "$(state_get "$TEST_TMPDIR" status)" = "in_progress" ]
    [ "$(state_get "$TEST_TMPDIR" enabled_roles)" = "R1,R2,R3,R4,R5" ]
}

@test "state_set 覆盖字段" {
    state_init "$TEST_TMPDIR" "x" "y" "z"
    state_set "$TEST_TMPDIR" status converged
    [ "$(state_get "$TEST_TMPDIR" status)" = "converged" ]
}

@test "state_set 改 enabled_roles" {
    state_init "$TEST_TMPDIR" "x" "y" "z"
    state_set "$TEST_TMPDIR" enabled_roles "R1,R2,R3,R4"
    [ "$(state_get "$TEST_TMPDIR" enabled_roles)" = "R1,R2,R3,R4" ]
}

@test "state_increment stuck_count" {
    state_init "$TEST_TMPDIR" "x" "y" "z"
    state_increment "$TEST_TMPDIR" stuck_count
    [ "$(state_get "$TEST_TMPDIR" stuck_count)" = "1" ]
    state_increment "$TEST_TMPDIR" stuck_count
    state_increment "$TEST_TMPDIR" stuck_count
    [ "$(state_get "$TEST_TMPDIR" stuck_count)" = "3" ]
}

@test "state_increment current_round" {
    state_init "$TEST_TMPDIR" "x" "y" "z"
    state_increment "$TEST_TMPDIR" current_round
    state_increment "$TEST_TMPDIR" current_round
    [ "$(state_get "$TEST_TMPDIR" current_round)" = "2" ]
}

@test "state_get 不存在的 key 返空 + exit 0" {
    state_init "$TEST_TMPDIR" "x" "y" "z"
    local v
    v="$(state_get "$TEST_TMPDIR" no_such)"
    [ -z "$v" ]
}

@test "state_init updated_at / created_at RFC3339" {
    state_init "$TEST_TMPDIR" "x" "y" "z"
    local t
    t="$(state_get "$TEST_TMPDIR" created_at)"
    [[ "$t" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z?$ ]]
}

@test "state_set 同时更新 updated_at" {
    state_init "$TEST_TMPDIR" "x" "y" "z"
    sleep 1
    state_set "$TEST_TMPDIR" status converged
    local created updated
    created="$(state_get "$TEST_TMPDIR" created_at)"
    updated="$(state_get "$TEST_TMPDIR" updated_at)"
    [ "$created" != "$updated" ]
}
