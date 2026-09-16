#!/usr/bin/env bats
load '../test_helper'

setup() {
    TEST_TMPDIR="$(mktemp -d)"
    cd "$TEST_TMPDIR" || exit 1
    # shellcheck source=/dev/null
    source "$SCRIPTS_DIR/lib/errors.sh"
}

teardown() {
    rm -rf "$TEST_TMPDIR"
}

@test "_yaml_dq 含双引号 → yq 合法且原样还原" {
    s='含 "引号" 和 \反斜杠'
    printf 'k: %s\n' "$(_yaml_dq "$s")" > out.yaml
    yq e '.' out.yaml >/dev/null
    [ "$(yq e '.k' out.yaml)" = "$s" ]
}

@test "_yaml_dq 多引号文本 grayVersion 空串 → 合法" {
    s='grayVersion="" 隐式表达，与 selector 重叠'
    printf 'k: %s\n' "$(_yaml_dq "$s")" > out.yaml
    yq e '.' out.yaml >/dev/null
    [ "$(yq e '.k' out.yaml)" = "$s" ]
}

@test "_yaml_dq 把内嵌换行压成空格 → 单行合法" {
    s="$(printf 'line1\nline2')"
    printf 'k: %s\n' "$(_yaml_dq "$s")" > out.yaml
    yq e '.' out.yaml >/dev/null
    [ "$(yq e '.k' out.yaml)" = "line1 line2" ]
}

@test "exit codes defined" {
    [ "$EXIT_OK" -eq 0 ]
    [ "$EXIT_SEVERITY_FAIL" -eq 1 ]
    [ "$EXIT_CONFIG" -eq 2 ]
    [ "$EXIT_NO_TARGET" -eq 3 ]
    [ "$EXIT_FORCE_STOP" -eq 4 ]
    [ "$EXIT_UNRESOLVED" -eq 5 ]
    [ "$EXIT_INTERRUPTED" -eq 130 ]
}

@test "die prints to stderr and exits" {
    run bash -c "source $SCRIPTS_DIR/lib/errors.sh && die 'oops' 3"
    [ "$status" -eq 3 ]
    [[ "$output" == *"oops"* ]]
}

@test "die default code is EXIT_CONFIG" {
    run bash -c "source $SCRIPTS_DIR/lib/errors.sh && die 'config bad'"
    [ "$status" -eq 2 ]
}
