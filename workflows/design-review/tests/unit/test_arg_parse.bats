#!/usr/bin/env bats
load '../test_helper'

setup() {
    TEST_TMPDIR="$(mktemp -d)"
    cd "$TEST_TMPDIR" || exit 1
    # shellcheck source=/dev/null
    source "$SCRIPTS_DIR/lib/errors.sh"
    # shellcheck source=/dev/null
    source "$SCRIPTS_DIR/lib/args.sh"
}

teardown() {
    rm -rf "$TEST_TMPDIR"
}

@test "默认值正确" {
    parse_args
    [ "$DR_MIN_ROUNDS" -eq 2 ]
    [ "$DR_MAX_ROUNDS" -eq 5 ]
    [ "$DR_DRY_RUN" -eq 0 ]
    [ "$DR_VERBOSE" -eq 0 ]
    [ "$DR_QUIET" -eq 0 ]
    [ "$DR_SKIP_VERIFY" -eq 0 ]
    [ "$DR_NO_PATCH" -eq 0 ]
    [ "$DR_NO_SUPPLEMENT" -eq 0 ]
}

@test "--rounds 等价 min=max" {
    parse_args --rounds 3
    [ "$DR_MIN_ROUNDS" -eq 3 ]
    [ "$DR_MAX_ROUNDS" -eq 3 ]
}

@test "--min-rounds / --max-rounds 分别覆盖" {
    parse_args --min-rounds 1 --max-rounds 4
    [ "$DR_MIN_ROUNDS" -eq 1 ]
    [ "$DR_MAX_ROUNDS" -eq 4 ]
}

@test "--scope 设置 focus + set 标志" {
    parse_args --scope "调度 Pod"
    [ "$DR_SCOPE_FOCUS" = "调度 Pod" ]
    [ "$DR_SCOPE_FOCUS_SET" -eq 1 ]
}

@test "默认无 --scope → focus 空 + set=0" {
    parse_args
    [ -z "$DR_SCOPE_FOCUS" ]
    [ "$DR_SCOPE_FOCUS_SET" -eq 0 ]
}

@test "min > max 报错并退出 2" {
    run parse_args --min-rounds 5 --max-rounds 3
    [ "$status" -eq 2 ]
    [[ "$output" == *"min-rounds 不可大于 max-rounds"* ]]
}

@test "TARGET 位置参数收集" {
    parse_args foo.md bar.md
    [ "${DR_TARGETS[0]}" = "foo.md" ]
    [ "${DR_TARGETS[1]}" = "bar.md" ]
}

@test "--target 等价位置参数（可多次）" {
    parse_args --target foo.md --target bar.md
    [ "${DR_TARGETS[0]}" = "foo.md" ]
    [ "${DR_TARGETS[1]}" = "bar.md" ]
}

@test "--target 逗号分隔" {
    parse_args --target "foo.md,bar.md"
    [ "${DR_TARGETS[0]}" = "foo.md" ]
    [ "${DR_TARGETS[1]}" = "bar.md" ]
}

@test "--enable-roles 解析" {
    parse_args --enable-roles R1,R3,R5
    [ "${DR_ENABLED_ROLES[0]}" = "R1" ]
    [ "${DR_ENABLED_ROLES[1]}" = "R3" ]
    [ "${DR_ENABLED_ROLES[2]}" = "R5" ]
}

@test "--verbose / --quiet 同时给报错" {
    run parse_args --verbose --quiet
    [ "$status" -eq 2 ]
    [[ "$output" == *"--verbose 与 --quiet 互斥"* ]]
}

@test "--help 退出 0 并打印 USAGE" {
    run parse_args --help
    [ "$status" -eq 0 ]
    [[ "$output" == *"USAGE"* ]]
}

@test "--version 退出 0 并打印版本" {
    run parse_args --version
    [ "$status" -eq 0 ]
    [[ "$output" == *"design-review"* ]]
}

@test "未知参数报错" {
    run parse_args --no-such-flag
    [ "$status" -eq 2 ]
    [[ "$output" == *"未知参数"* ]]
}

@test "--dry-run 设置标志" {
    parse_args --dry-run
    [ "$DR_DRY_RUN" -eq 1 ]
}
